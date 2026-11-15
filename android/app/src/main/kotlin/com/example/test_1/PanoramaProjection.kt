package com.example.test_1

import kotlin.math.*

/** Shared geometry for the detector's rectilinear sphere samples and seam-safe masks. */
internal object PanoramaProjection {
    const val FOV_DEGREES = 100.0
    data class View(val yawDegrees: Double, val pitchDegrees: Double)
    val views: List<View> = buildList {
        for (pitch in listOf(0.0, 45.0, -45.0)) for (yaw in listOf(0.0, 90.0, 180.0, 270.0)) add(View(yaw, pitch))
        add(View(0.0, 90.0)); add(View(0.0, -90.0))
    }

    /** True when this spherical direction falls inside at least one sampled view. */
    fun isCovered(longitudeDegrees: Double, latitudeDegrees: Double): Boolean {
        val lon = Math.toRadians(longitudeDegrees)
        val lat = Math.toRadians(latitudeDegrees)
        val direction = doubleArrayOf(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
        val edge = tan(Math.toRadians(FOV_DEGREES / 2))
        return views.any { view ->
            val yaw = Math.toRadians(view.yawDegrees)
            val pitch = Math.toRadians(view.pitchDegrees)
            val forward = doubleArrayOf(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
            val right = doubleArrayOf(cos(yaw), 0.0, -sin(yaw))
            val up = doubleArrayOf(-sin(yaw) * sin(pitch), cos(pitch), -cos(yaw) * sin(pitch))
            val depth = dot(direction, forward)
            depth > 0 && abs(dot(direction, right) / depth) <= edge && abs(dot(direction, up) / depth) <= edge
        }
    }

    /** Returns half-open horizontal pixel spans, splitting a mask that crosses the seam. */
    fun horizontalSegments(x: Double, width: Double, imageWidth: Int): List<Pair<Int, Int>> {
        require(imageWidth > 0 && x in 0.0..1.0 && width >= 0.0 && width <= 1.0)
        val left = (x * imageWidth).roundToInt().coerceIn(0, imageWidth - 1)
        val right = left + (width * imageWidth).roundToInt()
        return if (right <= imageWidth) listOf(left to right.coerceAtLeast(left + 1))
        else listOf(left to imageWidth, 0 to (right - imageWidth).coerceAtLeast(1))
    }

    private fun dot(a: DoubleArray, b: DoubleArray) = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
