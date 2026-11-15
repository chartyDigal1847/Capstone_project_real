#include <jni.h>
#include <stdio.h>
#include <jpeglib.h>
#include <jerror.h>
#include <android/log.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define LOG_TAG "PanoStream"
#define MOSAIC_CELL 24
#define MAX_DIMENSION 50000

typedef struct {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
} pano_error_mgr;

typedef struct { int left; int right; } pano_interval;

static void pano_error_exit(j_common_ptr info) {
  pano_error_mgr *error = (pano_error_mgr *)info->err;
  longjmp(error->jump, 1);
}

static int compare_intervals(const void *a, const void *b) {
  const pano_interval *left = (const pano_interval *)a;
  const pano_interval *right = (const pano_interval *)b;
  return left->left < right->left ? -1 : left->left > right->left ? 1 : 0;
}

static int clamp_int(int value, int low, int high) {
  return value < low ? low : value > high ? high : value;
}

static void add_span(pano_interval *spans, int *count, int left, int right, int width) {
  left = clamp_int(left, 0, width);
  right = clamp_int(right, 0, width);
  if (right > left) {
    spans[*count].left = left;
    spans[*count].right = right;
    (*count)++;
  }
}

static int build_active_intervals(const double *masks, int mask_count, int y,
                                  int width, int height, pano_interval *spans) {
  int count = 0;
  for (int i = 0; i < mask_count; i++) {
    const double x = masks[i * 4];
    const double top_norm = masks[i * 4 + 1];
    const double w = masks[i * 4 + 2];
    const double h = masks[i * 4 + 3];
    const int top = clamp_int((int)(top_norm * height), 0, height - 1);
    const int bottom = clamp_int(top + (int)(h * height + 0.5), top + 1, height);
    if (y < top || y >= bottom) continue;
    const int left = clamp_int((int)(x * width + 0.5), 0, width - 1);
    const int right = left + (int)(w * width + 0.5);
    if (right <= width) {
      add_span(spans, &count, left, right > left ? right : left + 1, width);
    } else {
      add_span(spans, &count, left, width, width);
      add_span(spans, &count, 0, right - width, width);
    }
  }
  if (count < 2) return count;
  qsort(spans, (size_t)count, sizeof(pano_interval), compare_intervals);
  int merged = 0;
  for (int i = 0; i < count; i++) {
    if (merged == 0 || spans[i].left > spans[merged - 1].right) {
      spans[merged++] = spans[i];
    } else if (spans[i].right > spans[merged - 1].right) {
      spans[merged - 1].right = spans[i].right;
    }
  }
  return merged;
}

static void throw_state(JNIEnv *env, const char *message) {
  jclass error = (*env)->FindClass(env, "java/lang/IllegalStateException");
  if (error != NULL) (*env)->ThrowNew(env, error, message);
}

JNIEXPORT jboolean JNICALL
Java_com_example_test_11_MainActivity_nativeWriteJpeg(
    JNIEnv *env, jobject self, jstring source_path, jstring output_path,
    jstring cache_path, jdoubleArray mask_data, jint expected_width, jint expected_height) {
  const char *source_name = (*env)->GetStringUTFChars(env, source_path, NULL);
  const char *output_name = (*env)->GetStringUTFChars(env, output_path, NULL);
  const char *cache_name = (*env)->GetStringUTFChars(env, cache_path, NULL);
  if (source_name == NULL || output_name == NULL || cache_name == NULL) {
    if (source_name != NULL) (*env)->ReleaseStringUTFChars(env, source_path, source_name);
    if (output_name != NULL) (*env)->ReleaseStringUTFChars(env, output_path, output_name);
    if (cache_name != NULL) (*env)->ReleaseStringUTFChars(env, cache_path, cache_name);
    return JNI_FALSE;
  }
  if (setenv("TMPDIR", cache_name, 1) != 0) {
    throw_state(env, "Could not configure private JPEG backing storage.");
    (*env)->ReleaseStringUTFChars(env, source_path, source_name);
    (*env)->ReleaseStringUTFChars(env, output_path, output_name);
    (*env)->ReleaseStringUTFChars(env, cache_path, cache_name);
    return JNI_FALSE;
  }

  const jsize mask_length = (*env)->GetArrayLength(env, mask_data);
  if (mask_length % 4 != 0) {
    throw_state(env, "Invalid spherical mask data.");
    goto invalid_masks;
  }
  const int mask_count = mask_length / 4;
  double *masks = (double *)calloc((size_t)(mask_length == 0 ? 1 : mask_length), sizeof(double));
  if (masks == NULL) {
    throw_state(env, "Not enough memory for panorama masks.");
    goto invalid_masks;
  }
  if (mask_length > 0) (*env)->GetDoubleArrayRegion(env, mask_data, 0, mask_length, masks);
  if ((*env)->ExceptionCheck(env)) { free(masks); goto invalid_masks; }

  FILE *source_file = fopen(source_name, "rb");
  FILE *output_file = fopen(output_name, "wb");
  if (source_file == NULL || output_file == NULL) {
    if (source_file != NULL) fclose(source_file);
    if (output_file != NULL) fclose(output_file);
    free(masks);
    throw_state(env, "Could not open panorama JPEG input or output.");
    goto invalid_masks;
  }

  struct jpeg_decompress_struct decoder;
  struct jpeg_compress_struct encoder;
  pano_error_mgr error;
  volatile int decoder_created = 0;
  volatile int encoder_created = 0;
  JSAMPLE * volatile block_rows = NULL;
  JSAMPLE * volatile output_row = NULL;
  uint32_t * volatile sums = NULL;
  JSAMPLE * volatile mosaic = NULL;
  pano_interval * volatile spans = NULL;
  memset(&decoder, 0, sizeof(decoder));
  memset(&encoder, 0, sizeof(encoder));
  decoder.err = jpeg_std_error(&error.pub);
  encoder.err = jpeg_std_error(&error.pub);
  error.pub.error_exit = pano_error_exit;

  if (setjmp(error.jump)) {
    free((void *)block_rows); free((void *)output_row); free((void *)sums);
    free((void *)mosaic); free((void *)spans);
    if (encoder_created) jpeg_destroy_compress(&encoder);
    if (decoder_created) jpeg_destroy_decompress(&decoder);
    fclose(source_file);
    fclose(output_file);
    remove(output_name);
    free(masks);
    throw_state(env, "JPEG scanline processing failed.");
    goto invalid_masks;
  }

  jpeg_create_decompress(&decoder);
  decoder_created = 1;
  jpeg_stdio_src(&decoder, source_file);
  if (jpeg_read_header(&decoder, TRUE) != JPEG_HEADER_OK) {
    ERREXIT(&decoder, JERR_NO_IMAGE);
  }
  decoder.out_color_space = JCS_RGB;
  decoder.do_fancy_upsampling = TRUE;
  jpeg_start_decompress(&decoder);
  const int width = (int)decoder.output_width;
  const int height = (int)decoder.output_height;
  if (width != expected_width || height != expected_height || width < 2 * height ||
      width > MAX_DIMENSION || height > MAX_DIMENSION || decoder.output_components != 3) {
    jpeg_abort_decompress(&decoder);
    jpeg_destroy_decompress(&decoder);
    decoder_created = 0;
    fclose(source_file); fclose(output_file); remove(output_name); free(masks);
    throw_state(env, "Source dimensions or JPEG color format changed during processing.");
    goto invalid_masks;
  }

  jpeg_create_compress(&encoder);
  encoder_created = 1;
  jpeg_stdio_dest(&encoder, output_file);
  encoder.image_width = (JDIMENSION)width;
  encoder.image_height = (JDIMENSION)height;
  encoder.input_components = 3;
  encoder.in_color_space = JCS_RGB;
  jpeg_set_defaults(&encoder);
  jpeg_set_quality(&encoder, 92, TRUE);
  jpeg_start_compress(&encoder, TRUE);

  const int cells_x = (width + MOSAIC_CELL - 1) / MOSAIC_CELL;
  size_t block_size = (size_t)MOSAIC_CELL * (size_t)width * 3U;
  block_rows = (JSAMPLE *)malloc(block_size);
  output_row = (JSAMPLE *)malloc((size_t)width * 3U);
  sums = (uint32_t *)calloc((size_t)cells_x * 3U, sizeof(uint32_t));
  mosaic = (JSAMPLE *)malloc((size_t)cells_x * 3U);
  spans = (pano_interval *)malloc(sizeof(pano_interval) * (size_t)(mask_count * 2 + 1));
  if (block_rows == NULL || output_row == NULL || sums == NULL || mosaic == NULL || spans == NULL) {
    free((void *)block_rows); block_rows = NULL;
    free((void *)output_row); output_row = NULL;
    free((void *)sums); sums = NULL;
    free((void *)mosaic); mosaic = NULL;
    free((void *)spans); spans = NULL;
    jpeg_abort_compress(&encoder); jpeg_abort_decompress(&decoder);
    jpeg_destroy_compress(&encoder); encoder_created = 0;
    jpeg_destroy_decompress(&decoder); decoder_created = 0;
    fclose(source_file); fclose(output_file); remove(output_name); free(masks);
    throw_state(env, "Not enough memory for bounded panorama scanline buffers.");
    goto invalid_masks;
  }

  jclass activity_class = (*env)->GetObjectClass(env, self);
  jmethodID progress_method = (*env)->GetMethodID(env, activity_class, "onNativeProgress", "(II)Z");
  if (progress_method == NULL || (*env)->ExceptionCheck(env)) {
    free(block_rows); free(output_row); free(sums); free(mosaic); free(spans);
    jpeg_abort_compress(&encoder); jpeg_abort_decompress(&decoder);
    jpeg_destroy_compress(&encoder); encoder_created = 0;
    jpeg_destroy_decompress(&decoder); decoder_created = 0;
    fclose(source_file); fclose(output_file); remove(output_name); free(masks);
    goto invalid_masks;
  }

  int cancelled = 0;
  while (decoder.output_scanline < decoder.output_height) {
    const int block_height = (int)((decoder.output_height - decoder.output_scanline) < MOSAIC_CELL ?
                                    decoder.output_height - decoder.output_scanline : MOSAIC_CELL);
    const int block_top = (int)decoder.output_scanline;
    memset(sums, 0, (size_t)cells_x * 3U * sizeof(uint32_t));
    for (int row_index = 0; row_index < block_height; row_index++) {
      JSAMPROW row = block_rows + (size_t)row_index * (size_t)width * 3U;
      if (jpeg_read_scanlines(&decoder, &row, 1) != 1) ERREXIT(&decoder, JERR_FILE_READ);
      for (int x = 0; x < width; x++) {
        const int cell = x / MOSAIC_CELL;
        sums[cell * 3] += row[x * 3];
        sums[cell * 3 + 1] += row[x * 3 + 1];
        sums[cell * 3 + 2] += row[x * 3 + 2];
      }
    }
    for (int cell = 0; cell < cells_x; cell++) {
      const int n = block_height * ((cell == cells_x - 1 && width % MOSAIC_CELL != 0) ? width % MOSAIC_CELL : MOSAIC_CELL);
      mosaic[cell * 3] = (JSAMPLE)(sums[cell * 3] / n);
      mosaic[cell * 3 + 1] = (JSAMPLE)(sums[cell * 3 + 1] / n);
      mosaic[cell * 3 + 2] = (JSAMPLE)(sums[cell * 3 + 2] / n);
    }
    for (int row_index = 0; row_index < block_height; row_index++) {
      const int y = block_top + row_index;
      JSAMPLE *source_row = block_rows + (size_t)row_index * (size_t)width * 3U;
      memcpy(output_row, source_row, (size_t)width * 3U);
      const int span_count = build_active_intervals(masks, mask_count, y, width, height, spans);
      for (int span_index = 0; span_index < span_count; span_index++) {
        for (int x = spans[span_index].left; x < spans[span_index].right; x++) {
          memcpy(output_row + (size_t)x * 3U, mosaic + (x / MOSAIC_CELL) * 3, 3U);
        }
      }
      JSAMPROW output_pointer = output_row;
      if (jpeg_write_scanlines(&encoder, &output_pointer, 1) != 1) ERREXIT(&encoder, JERR_FILE_WRITE);
    }
    if (((block_top + block_height) % 240 == 0) || block_top + block_height == height) {
      const jboolean should_cancel = (*env)->CallBooleanMethod(env, self, progress_method,
          (jint)(block_top + block_height), (jint)height);
      if ((*env)->ExceptionCheck(env)) { cancelled = 1; break; }
      if (should_cancel == JNI_TRUE) { cancelled = 1; break; }
    }
  }

  free((void *)block_rows); block_rows = NULL;
  free((void *)output_row); output_row = NULL;
  free((void *)sums); sums = NULL;
  free((void *)mosaic); mosaic = NULL;
  free((void *)spans); spans = NULL;
  free(masks);
  if (cancelled) {
    jpeg_abort_compress(&encoder); jpeg_abort_decompress(&decoder);
    jpeg_destroy_compress(&encoder); encoder_created = 0;
    jpeg_destroy_decompress(&decoder); decoder_created = 0;
    fclose(source_file); fclose(output_file); remove(output_name);
    (*env)->ReleaseStringUTFChars(env, source_path, source_name);
    (*env)->ReleaseStringUTFChars(env, output_path, output_name);
    (*env)->ReleaseStringUTFChars(env, cache_path, cache_name);
    return JNI_FALSE;
  }
  jpeg_finish_decompress(&decoder);
  jpeg_finish_compress(&encoder);
  jpeg_destroy_compress(&encoder); encoder_created = 0;
  jpeg_destroy_decompress(&decoder); decoder_created = 0;
  const int close_source = fclose(source_file);
  const int close_output = fclose(output_file);
  const int success = close_source == 0 && close_output == 0;
  if (!success) remove(output_name);
  (*env)->ReleaseStringUTFChars(env, source_path, source_name);
  (*env)->ReleaseStringUTFChars(env, output_path, output_name);
  (*env)->ReleaseStringUTFChars(env, cache_path, cache_name);
  return success ? JNI_TRUE : JNI_FALSE;

invalid_masks:
  (*env)->ReleaseStringUTFChars(env, source_path, source_name);
  (*env)->ReleaseStringUTFChars(env, output_path, output_name);
  (*env)->ReleaseStringUTFChars(env, cache_path, cache_name);
  return JNI_FALSE;
}
