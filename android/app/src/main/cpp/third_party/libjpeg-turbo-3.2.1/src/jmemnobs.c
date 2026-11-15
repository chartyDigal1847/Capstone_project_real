/*
 * jmemnobs.c
 *
 * This file was part of the Independent JPEG Group's software:
 * Copyright (C) 1992-1996, Thomas G. Lane.
 * libjpeg-turbo Modifications:
 * Copyright (C) 2017-2018, 2024, D. R. Commander.
 * For conditions of distribution and use, see the accompanying README.ijg
 * file.
 *
 * Android LocalSpot adaptation: virtual arrays use a bounded in-memory
 * budget and spill to an anonymous temporary file under TMPDIR.  The JNI
 * caller sets TMPDIR to the application's private cache before decoding.
 */

#define JPEG_INTERNALS
#include "jinclude.h"
#include "jpeglib.h"
#include "jmemsys.h"            /* import the system-dependent declarations */
#include <sys/types.h>
#include <unistd.h>

#define LOCALSPOT_JPEG_MEMORY_LIMIT (32L * 1024L * 1024L)

static void read_backing_store(j_common_ptr cinfo, backing_store_ptr info,
                               void *buffer, long offset, long count)
{
  if (fseeko(info->temp_file, (off_t)offset, SEEK_SET) != 0)
    ERREXIT(cinfo, JERR_TFILE_SEEK);
  if (fread(buffer, (size_t)count, 1, info->temp_file) != 1)
    ERREXIT(cinfo, JERR_TFILE_READ);
}

static void write_backing_store(j_common_ptr cinfo, backing_store_ptr info,
                                void *buffer, long offset, long count)
{
  if (fseeko(info->temp_file, (off_t)offset, SEEK_SET) != 0)
    ERREXIT(cinfo, JERR_TFILE_SEEK);
  if (fwrite(buffer, (size_t)count, 1, info->temp_file) != 1)
    ERREXIT(cinfo, JERR_TFILE_WRITE);
}

static void close_backing_store(j_common_ptr cinfo, backing_store_ptr info)
{
  if (info->temp_file != NULL) fclose(info->temp_file);
  info->temp_file = NULL;
}


/*
 * Memory allocation and freeing are controlled by the regular library
 * routines malloc() and free().
 */

GLOBAL(void *)
jpeg_get_small(j_common_ptr cinfo, size_t sizeofobject)
{
  return (void *)MALLOC(sizeofobject);
}

GLOBAL(void)
jpeg_free_small(j_common_ptr cinfo, void *object, size_t sizeofobject)
{
  free(object);
}


/*
 * "Large" objects are treated the same as "small" ones.
 */

GLOBAL(void *)
jpeg_get_large(j_common_ptr cinfo, size_t sizeofobject)
{
  return (void *)MALLOC(sizeofobject);
}

GLOBAL(void)
jpeg_free_large(j_common_ptr cinfo, void *object, size_t sizeofobject)
{
  free(object);
}


/*
 * This routine computes the total memory space available for allocation.
 */

GLOBAL(size_t)
jpeg_mem_available(j_common_ptr cinfo, size_t min_bytes_needed,
                   size_t max_bytes_needed, size_t already_allocated)
{
  if (cinfo->mem->max_memory_to_use) {
    if ((size_t)cinfo->mem->max_memory_to_use > already_allocated)
      return cinfo->mem->max_memory_to_use - already_allocated;
    else
      return 0;
  } else {
    size_t remaining = LOCALSPOT_JPEG_MEMORY_LIMIT > already_allocated ?
      (size_t)LOCALSPOT_JPEG_MEMORY_LIMIT - already_allocated : 0;
    return remaining < max_bytes_needed ? remaining : max_bytes_needed;
  }
}


/*
 * Backing store (temporary file) management.
 */

GLOBAL(void)
jpeg_open_backing_store(j_common_ptr cinfo, backing_store_ptr info,
                        long total_bytes_needed)
{
  const char *directory = getenv("TMPDIR");
  char path[512];
  if (directory == NULL || directory[0] == '\0') directory = "/data/local/tmp";
  int length = snprintf(path, sizeof(path), "%s/locals-jpeg-XXXXXX", directory);
  if (length < 0 || (size_t)length >= sizeof(path))
    ERREXITS(cinfo, JERR_TFILE_CREATE, "cache path too long");
  int fd = mkstemp(path);
  if (fd < 0) ERREXITS(cinfo, JERR_TFILE_CREATE, path);
  if (unlink(path) != 0) {
    close(fd);
    unlink(path);
    ERREXITS(cinfo, JERR_TFILE_CREATE, "cannot unlink backing file");
  }
  info->temp_file = fdopen(fd, "w+b");
  if (info->temp_file == NULL) {
    close(fd);
    ERREXITS(cinfo, JERR_TFILE_CREATE, "cannot open backing file");
  }
  info->read_backing_store = read_backing_store;
  info->write_backing_store = write_backing_store;
  info->close_backing_store = close_backing_store;
}


/*
 * These routines take care of any system-dependent initialization and
 * cleanup required.  Here, there isn't any.
 */

GLOBAL(long)
jpeg_mem_init(j_common_ptr cinfo)
{
  return LOCALSPOT_JPEG_MEMORY_LIMIT;
}

GLOBAL(void)
jpeg_mem_term(j_common_ptr cinfo)
{
  /* no work */
}
