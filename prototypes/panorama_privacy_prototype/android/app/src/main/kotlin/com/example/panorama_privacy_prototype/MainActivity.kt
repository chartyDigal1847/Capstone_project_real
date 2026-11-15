package com.example.panorama_privacy_prototype

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.RectF
import android.net.Uri
import android.content.ContentResolver
import androidx.exifinterface.media.ExifInterface
import androidx.annotation.Keep
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector.ObjectDetectorOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.atomic.AtomicBoolean
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlin.math.*

class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val channelName = "localspot/panorama_privacy_prototype"
    private val cancelled = AtomicBoolean(false)
    @Volatile private var progressSink: EventChannel.EventSink? = null

    companion object {
        init { System.loadLibrary("pano_stream") }
    }

    private external fun nativeWriteJpeg(sourcePath: String, outputPath: String, cachePath: String,
                                         masks: DoubleArray, expectedWidth: Int, expectedHeight: Int): Boolean

    @Keep
    @Suppress("unused")
    private fun onNativeProgress(current: Int, total: Int): Boolean {
        if (isDebuggableBuild() && (current == total || current % 1200 == 0)) logMemory("jpeg-row-$current")
        emitProgress("encoding full-resolution JPEG", current, total)
        return cancelled.get()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "listDebugFixtures") {
                    if (!isDebuggableBuild()) { result.error("unavailable", "Fixture loading is debug-only.", null); return@setMethodCallHandler }
                    result.success(listDebugFixtures())
                    return@setMethodCallHandler
                }
                if (call.method != "process" && call.method != "applyMasks" && call.method != "cancel") {
                    result.notImplemented(); return@setMethodCallHandler
                }
                if (call.method == "cancel") { cancelled.set(true); result.success(null); return@setMethodCallHandler }
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("invalid-argument", "A panorama path is required.", null); return@setMethodCallHandler
                }
                val masks = call.argument<List<Map<String, Double>>>("masks") ?: emptyList()
                cancelled.set(false)
                executor.execute {
                    try {
                        val response = if (call.method == "process") processPanorama(path)
                            else applyMasks(path, masks)
                        check(!cancelled.get()) { "Processing was cancelled." }
                        runOnUiThread { result.success(response) }
                    } catch (error: Throwable) {
                        android.util.Log.e("PanoPrivacy", "Local processing failed", error)
                        val code = if (cancelled.get()) "cancelled" else "processing-failed"
                        runOnUiThread { result.error(code, error.message ?: "Panorama processing failed.", null) }
                    }
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "$channelName/progress")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { progressSink = events }
                override fun onCancel(arguments: Any?) { progressSink = null }
            })
    }

    private fun listDebugFixtures(): List<Map<String, Any>> {
        val root = getExternalFilesDir(null) ?: error("App-specific external files storage is unavailable.")
        val directory = File(root, "test-fixtures")
        if (!directory.exists() && !directory.mkdirs()) error("Could not create the app-private fixture directory.")
        if (!directory.exists()) return emptyList()
        return listOf("Wikimania_2023_360_group_photo.jpg", "35C3_Panorama.jpg").mapNotNull { name ->
            val file = File(directory, name)
            if (!file.isFile) return@mapNotNull null
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, options)
            val digest = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
            mapOf("name" to name, "path" to file.absolutePath, "width" to options.outWidth,
                "height" to options.outHeight, "bytes" to file.length(), "sha256" to digest)
        }
    }

    private fun isDebuggableBuild(): Boolean =
        applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0

    private fun emitProgress(stage: String, current: Int, total: Int) {
        runOnUiThread { progressSink?.success(mapOf("stage" to stage, "current" to current, "total" to total)) }
    }

    private fun processPanorama(path: String): Map<String, Any> {
        val uri = sourceUri(path)
        val started = System.nanoTime()
        val detectionImage = decodeForDetection(uri)
        require(detectionImage.width >= 2 * detectionImage.height) { "Select a full equirectangular panorama (2:1 aspect ratio)." }
        val faces = FaceDetection.getClient(
            FaceDetectorOptions.Builder().setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                .setMinFaceSize(0.025f).build()
        )
        val people = ObjectDetector.createFromOptions(
            this,
            ObjectDetectorOptions.builder().setBaseOptions(
                com.google.mediapipe.tasks.core.BaseOptions.builder().setModelAssetPath("efficientdet_lite0.tflite").build()
            ).setRunningMode(RunningMode.IMAGE).setMaxResults(40).setScoreThreshold(0.22f).build()
        )
        val regions = mutableListOf<Region>()
        var faceCount = 0
        var personCount = 0
        try {
            // Four azimuths at the equator and +/-45°, plus both poles. Each 100° view
            // overlaps its neighbours; the pole views and shifted rings cover the seams.
            for ((index, viewCenter) in PanoramaProjection.views.withIndex()) {
                check(!cancelled.get()) { "Processing was cancelled." }
                val yaw = viewCenter.yawDegrees
                val pitch = viewCenter.pitchDegrees
                val view = perspectiveView(detectionImage, yaw, pitch, 640, PanoramaProjection.FOV_DEGREES)
                try {
                    val image = InputImage.fromBitmap(view, 0)
                    val detectedFaces = Tasks.await(faces.process(image))
                    for (face in detectedFaces) {
                        regions.add(mapRect(yaw, pitch, 100.0, 100.0, view.width, view.height, RectF(face.boundingBox)))
                        faceCount++
                    }
                    val mpImage = BitmapImageBuilder(view).build()
                    for (detection in people.detect(mpImage).detections()) {
                        val person = detection.categories().any { it.categoryName()?.equals("person", true) == true && it.score() >= 0.22f }
                        if (person) {
                            val box = detection.boundingBox()
                            regions.add(mapRect(yaw, pitch, 100.0, 100.0, view.width, view.height, box))
                            personCount++
                        }
                    }
                } finally { view.recycle() }
                emitProgress("detecting", index + 1, PanoramaProjection.views.size)
            }
        } finally {
            faces.close()
            people.close()
            detectionImage.recycle()
        }
        val merged = mergeRegions(regions)
        val output = writeDerivative(uri, merged.map { SphericalRegion(it.x, it.y, it.w, it.h) })
        return output + mapOf(
            "faceDetections" to faceCount,
            "personDetections" to personCount,
            "regions" to merged.map { mapOf("x" to it.x, "y" to it.y, "w" to it.w, "h" to it.h) },
            "elapsedMs" to ((System.nanoTime() - started) / 1_000_000L),
        )
    }

    private fun applyMasks(path: String, masks: List<Map<String, Double>>): Map<String, Any> {
        check(!cancelled.get()) { "Processing was cancelled." }
        require(masks.isNotEmpty()) { "Add a manual blur region before applying corrections." }
        val uri = sourceUri(path)
        val regions = masks.map {
            SphericalRegion((it["x"] ?: error("Invalid mask")), (it["y"] ?: error("Invalid mask")),
                (it["w"] ?: error("Invalid mask")), (it["h"] ?: error("Invalid mask")))
        }
        return writeDerivative(uri, regions)
    }

    private fun writeDerivative(uri: Uri, regions: List<SphericalRegion>): Map<String, Any> {
        val (sourceFile, copiedSource) = materializeSource(uri)
        val outFile = File(cacheDir, "panorama-private-derivative-${System.nanoTime()}.jpg")
        var previewFile: File? = null
        try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            require(bounds.outWidth > 0 && bounds.outHeight > 0 && bounds.outWidth >= bounds.outHeight * 2) {
                "The source must be a supported 2:1 equirectangular panorama."
            }
            // Progressive JPEG decoders can spill coefficient arrays to cache.
            // Reserve a conservative six bytes per source pixel plus output/slop.
            val scratchEstimate = Math.addExact(Math.multiplyExact(
                Math.multiplyExact(bounds.outWidth.toLong(), bounds.outHeight.toLong()), 6L), 64L * 1024L * 1024L)
            require(android.os.StatFs(cacheDir.absolutePath).availableBytes >= scratchEstimate) {
                "Not enough free private storage for safe full-resolution processing (about ${scratchEstimate / (1024L * 1024L)} MiB required)."
            }
            val rotation = contentResolver.openInputStream(uri)?.use { ExifInterface(it).rotationDegrees } ?: 0
            require(rotation == 0) { "Rotated EXIF panoramas are not supported; rotate and save the image first." }
            FileInputStream(sourceFile).use { input ->
                require(input.read() == 0xff && input.read() == 0xd8) { "Full-resolution streaming currently supports JPEG panoramas only." }
            }
            val flatMasks = DoubleArray(regions.size * 4)
            regions.forEachIndexed { index, region ->
                flatMasks[index * 4] = region.x
                flatMasks[index * 4 + 1] = region.y
                flatMasks[index * 4 + 2] = region.w
                flatMasks[index * 4 + 3] = region.h
            }
            check(nativeWriteJpeg(sourceFile.absolutePath, outFile.absolutePath, cacheDir.absolutePath,
                flatMasks, bounds.outWidth, bounds.outHeight)) {
                if (cancelled.get()) "Processing was cancelled." else "The streaming JPEG encoder did not complete."
            }
            check(outFile.isFile && outFile.length() > 0L) { "JPEG derivative output is empty." }
            if (isDebuggableBuild()) logMemory("before-preview-decode")
            val preview = decodeSampled(Uri.fromFile(outFile), 2048)
            if (isDebuggableBuild()) logMemory("preview-decoded-${preview.width}x${preview.height}")
            val previewOutput = File(cacheDir, "panorama-preview-${System.nanoTime()}.jpg")
            previewFile = previewOutput
            try {
                FileOutputStream(previewOutput).use { check(preview.compress(Bitmap.CompressFormat.JPEG, 88, it)) { "Preview encoding failed." } }
            } finally { preview.recycle() }
            if (isDebuggableBuild()) logMemory("preview-recycled")
            check(previewOutput.length() > 0L) { "Preview output is empty." }
            return mapOf("path" to outFile.absolutePath, "previewPath" to previewOutput.absolutePath,
                "width" to bounds.outWidth, "height" to bounds.outHeight, "bytes" to outFile.length())
        } catch (error: Throwable) {
            outFile.delete()
            previewFile?.delete()
            throw error
        } finally {
            if (copiedSource) sourceFile.delete()
        }
    }

    private fun logMemory(stage: String) {
        val memory = android.os.Debug.MemoryInfo()
        android.os.Debug.getMemoryInfo(memory)
        android.util.Log.i("PanoMemory", "$stage pss=${memory.totalPss}KB native=${memory.nativePss}KB dalvik=${memory.dalvikPss}KB other=${memory.otherPss}KB")
    }

    private fun materializeSource(uri: Uri): Pair<File, Boolean> {
        if (uri.scheme == ContentResolver.SCHEME_FILE) return File(uri.path ?: error("Invalid panorama path.")) to false
        if (uri.scheme == null) return File(uri.path ?: error("Invalid panorama path.")) to false
        val copy = File(cacheDir, "panorama-input-${System.nanoTime()}.jpg")
        val input = contentResolver.openInputStream(uri) ?: error("Could not open selected panorama.")
        input.use { source -> FileOutputStream(copy).use { source.copyTo(it) } }
        return copy to true
    }

    private data class Region(val x: Double, val y: Double, val w: Double, val h: Double)

    private fun sourceUri(path: String): Uri = if (Uri.parse(path).scheme == null) Uri.fromFile(File(path)) else Uri.parse(path)

    private fun decodeForDetection(uri: Uri): Bitmap {
        val rotation = contentResolver.openInputStream(uri)?.use { ExifInterface(it).rotationDegrees } ?: 0
        require(rotation == 0) { "Rotated EXIF panoramas are not supported; rotate and save the image first." }
        return decodeSampled(uri, 4096)
    }

    private fun decodeSampled(uri: Uri, maxWidth: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "The selected file is not a supported image." }
        val sample = max(1, ceil(bounds.outWidth.toDouble() / maxWidth).toInt())
        val decoded = contentResolver.openInputStream(uri)?.use { input ->
            BitmapFactory.decodeStream(input, null, BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            })
        } ?: error("Could not decode panorama image.")
        if (decoded.width <= maxWidth) return decoded
        return Bitmap.createScaledBitmap(decoded, maxWidth,
            (decoded.height * maxWidth.toDouble() / decoded.width).roundToInt(), true).also { decoded.recycle() }
    }

    private fun perspectiveView(src: Bitmap, yaw: Double, pitch: Double, size: Int, fov: Double): Bitmap {
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(size * size)
        val py = Math.toRadians(pitch); val yw = Math.toRadians(yaw); val tangent = tan(Math.toRadians(fov) / 2)
        val forward = doubleArrayOf(sin(yw) * cos(py), sin(py), cos(yw) * cos(py))
        val right = doubleArrayOf(cos(yw), 0.0, -sin(yw))
        val up = doubleArrayOf(-sin(yw) * sin(py), cos(py), -cos(yw) * sin(py))
        for (j in 0 until size) for (i in 0 until size) {
            val cx = (2.0 * (i + .5) / size - 1) * tangent
            val cy = (1 - 2.0 * (j + .5) / size) * tangent
            var dx = forward[0] + cx * right[0] + cy * up[0]
            var dy = forward[1] + cx * right[1] + cy * up[1]
            var dz = forward[2] + cx * right[2] + cy * up[2]
            val length = sqrt(dx * dx + dy * dy + dz * dz); dx /= length; dy /= length; dz /= length
            val u = ((atan2(dx, dz) / (2 * PI) + .5 + 1) % 1.0)
            val v = (.5 - asin(dy.coerceIn(-1.0, 1.0)) / PI).coerceIn(0.0, 1.0)
            val x = (u * src.width).toInt().coerceIn(0, src.width - 1)
            val y = (v * src.height).toInt().coerceIn(0, src.height - 1)
            pixels[j * size + i] = src.getPixel(x, y)
        }
        out.setPixels(pixels, 0, size, 0, 0, size, size)
        return out
    }

    private fun mapRect(yaw: Double, pitch: Double, hfov: Double, vfov: Double, width: Int, height: Int, box: RectF): Region {
        val points = mutableListOf<Pair<Double, Double>>()
        val inset = (min(box.width(), box.height()) * .12f).coerceAtLeast(2f)
        for (iy in 0..8) for (ix in 0..8) {
            val px = (box.left - inset + (box.width() + 2 * inset) * ix / 8).coerceIn(0f, width.toFloat())
            val py = (box.top - inset + (box.height() + 2 * inset) * iy / 8).coerceIn(0f, height.toFloat())
            points.add(screenToUv(yaw, pitch, hfov, vfov, width, height, px, py))
        }
        val sorted = points.map { it.first }.sorted()
        var largestGap = -1.0; var gapAt = 0
        for (i in sorted.indices) {
            val next = if (i == sorted.lastIndex) sorted[0] + 1 else sorted[i + 1]
            if (next - sorted[i] > largestGap) { largestGap = next - sorted[i]; gapAt = i }
        }
        val start = sorted[(gapAt + 1) % sorted.size]
        val end = sorted[gapAt] + if (sorted[gapAt] < start) 1 else 0
        val minY = points.minOf { it.second }; val maxY = points.maxOf { it.second }
        val w = (end - start).coerceAtMost(.45)
        val h = (maxY - minY).coerceAtMost(.45)
        return Region((start - .02).let { if (it < 0) it + 1 else it }, (minY - .02).coerceAtLeast(0.0),
            (w + .04).coerceAtMost(.5), (h + .04).coerceAtMost(.5))
    }

    private fun screenToUv(yaw: Double, pitch: Double, hfov: Double, vfov: Double, width: Int, height: Int, x: Float, y: Float): Pair<Double, Double> {
        val py = Math.toRadians(pitch); val yw = Math.toRadians(yaw)
        val fx = (2.0 * x / width - 1) * tan(Math.toRadians(hfov) / 2)
        val fy = (1 - 2.0 * y / height) * tan(Math.toRadians(vfov) / 2)
        val f = doubleArrayOf(sin(yw) * cos(py), sin(py), cos(yw) * cos(py))
        val r = doubleArrayOf(cos(yw), 0.0, -sin(yw)); val u = doubleArrayOf(-sin(yw) * sin(py), cos(py), -cos(yw) * sin(py))
        val dx = f[0] + fx * r[0] + fy * u[0]; val dy = f[1] + fx * r[1] + fy * u[1]; val dz = f[2] + fx * r[2] + fy * u[2]
        return ((atan2(dx, dz) / (2 * PI) + .5 + 1) % 1.0) to (.5 - asin(dy.coerceIn(-1.0, 1.0)) / PI)
    }

    private fun mergeRegions(regions: List<Region>): List<Region> {
        // Keep overlap as conservative coverage rather than risk a merge that removes pixels.
        return regions.filter { it.w > .001 && it.h > .001 }
    }

}

private data class SphericalRegion(val x: Double, val y: Double, val w: Double, val h: Double)
