#ifndef MARIADB_WASI_FILE_SHIM_H
#define MARIADB_WASI_FILE_SHIM_H

#if defined(__wasi__)

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

__attribute__((import_module("wasmtime_mariadb_files"), import_name("open")))
int32_t wasmtime_mariadb_host_file_open(const char *path, int32_t flags,
                                       int32_t mode);
__attribute__((import_module("wasmtime_mariadb_files"), import_name("close")))
int32_t wasmtime_mariadb_host_file_close(int32_t fd);
__attribute__((import_module("wasmtime_mariadb_files"), import_name("read")))
int32_t wasmtime_mariadb_host_file_read(int32_t fd, void *buf, int32_t len);
__attribute__((import_module("wasmtime_mariadb_files"), import_name("write")))
int32_t wasmtime_mariadb_host_file_write(int32_t fd, const void *buf,
                                        int32_t len);
__attribute__((import_module("wasmtime_mariadb_files"), import_name("pread")))
int32_t wasmtime_mariadb_host_file_pread(int32_t fd, void *buf, int32_t len,
                                        int64_t offset);
__attribute__((import_module("wasmtime_mariadb_files"), import_name("pwrite")))
int32_t wasmtime_mariadb_host_file_pwrite(int32_t fd, const void *buf,
                                         int32_t len, int64_t offset);
__attribute__((import_module("wasmtime_mariadb_files"), import_name("seek")))
int64_t wasmtime_mariadb_host_file_seek(int32_t fd, int64_t offset,
                                       int32_t whence);
__attribute__((
    import_module("wasmtime_mariadb_files"), import_name("truncate")))
int32_t wasmtime_mariadb_host_file_truncate(int32_t fd, int64_t size);
__attribute__((import_module("wasmtime_mariadb_files"), import_name("sync")))
int32_t wasmtime_mariadb_host_file_sync(int32_t fd, int32_t data_only);
__attribute__((import_module("wasmtime_mariadb_files"), import_name("fstat")))
int32_t wasmtime_mariadb_host_file_fstat(
    int32_t fd, int64_t *size, int64_t *blocks, int64_t *block_size,
    int64_t *dev, int32_t *mode, int64_t *atime, int64_t *mtime,
    int64_t *ctime);

static inline int wasmtime_mariadb_file_decode_i32(int32_t rc) {
  if (rc < 0) {
    errno = -rc;
    return -1;
  }
  return rc;
}

static inline ssize_t wasmtime_mariadb_file_decode_ssize(int32_t rc) {
  if (rc < 0) {
    errno = -rc;
    return -1;
  }
  return (ssize_t)rc;
}

static inline int wasmtime_mariadb_file_open3(const char *path, int flags,
                                              mode_t mode) {
  return wasmtime_mariadb_file_decode_i32(
      wasmtime_mariadb_host_file_open(path, flags, (int32_t)mode));
}

static inline int wasmtime_mariadb_file_open2(const char *path, int flags) {
  return wasmtime_mariadb_file_open3(path, flags, 0);
}

static inline int wasmtime_mariadb_file_mkstemp(char *path) {
  static uint32_t counter = 0;
  static const char alphabet[] =
      "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
  const size_t alphabet_len = sizeof(alphabet) - 1;
  size_t len = strlen(path);

  if (len < 6 || memcmp(path + len - 6, "XXXXXX", 6) != 0) {
    errno = EINVAL;
    return -1;
  }

  for (uint32_t attempt = 0; attempt < 10000; attempt++) {
    uintptr_t value =
        (uintptr_t)__sync_fetch_and_add(&counter, 1) ^ (uintptr_t)path;
    value ^= (uintptr_t)&counter;

    for (size_t i = 0; i < 6; i++) {
      value = value * 1103515245u + 12345u + i;
      path[len - 6 + i] = alphabet[value % alphabet_len];
    }

    int fd = wasmtime_mariadb_file_open3(path, O_RDWR | O_CREAT | O_EXCL,
                                         S_IRUSR | S_IWUSR);
    if (fd >= 0) {
      return fd;
    }
    if (errno != EEXIST) {
      return -1;
    }
  }

  errno = EEXIST;
  return -1;
}

#define WASMTIME_MARIADB_FILE_OPEN_SELECT(_1, _2, _3, NAME, ...) NAME
#define wasmtime_mariadb_file_open(...)                                      \
  WASMTIME_MARIADB_FILE_OPEN_SELECT(__VA_ARGS__,                            \
                                    wasmtime_mariadb_file_open3,             \
                                    wasmtime_mariadb_file_open2)(__VA_ARGS__)

static inline int wasmtime_mariadb_file_close(int fd) {
  return wasmtime_mariadb_file_decode_i32(
      wasmtime_mariadb_host_file_close(fd));
}

static inline ssize_t wasmtime_mariadb_file_read(int fd, void *buf,
                                                 size_t len) {
  if (len > INT32_MAX) {
    errno = EINVAL;
    return -1;
  }
  return wasmtime_mariadb_file_decode_ssize(
      wasmtime_mariadb_host_file_read(fd, buf, (int32_t)len));
}

static inline ssize_t wasmtime_mariadb_file_write(int fd, const void *buf,
                                                  size_t len) {
  if (len > INT32_MAX) {
    errno = EINVAL;
    return -1;
  }
  return wasmtime_mariadb_file_decode_ssize(
      wasmtime_mariadb_host_file_write(fd, buf, (int32_t)len));
}

static inline ssize_t wasmtime_mariadb_file_pread(int fd, void *buf,
                                                  size_t len, off_t offset) {
  if (len > INT32_MAX) {
    errno = EINVAL;
    return -1;
  }
  return wasmtime_mariadb_file_decode_ssize(wasmtime_mariadb_host_file_pread(
      fd, buf, (int32_t)len, (int64_t)offset));
}

static inline ssize_t wasmtime_mariadb_file_pwrite(int fd, const void *buf,
                                                   size_t len, off_t offset) {
  if (len > INT32_MAX) {
    errno = EINVAL;
    return -1;
  }
  return wasmtime_mariadb_file_decode_ssize(wasmtime_mariadb_host_file_pwrite(
      fd, buf, (int32_t)len, (int64_t)offset));
}

static inline off_t wasmtime_mariadb_file_seek(int fd, off_t offset,
                                               int whence) {
  int64_t rc = wasmtime_mariadb_host_file_seek(fd, (int64_t)offset, whence);
  if (rc < 0) {
    errno = (int)-rc;
    return (off_t)-1;
  }
  return (off_t)rc;
}

static inline int wasmtime_mariadb_file_truncate(int fd, off_t size) {
  return wasmtime_mariadb_file_decode_i32(
      wasmtime_mariadb_host_file_truncate(fd, (int64_t)size));
}

static inline int wasmtime_mariadb_file_sync(int fd, int data_only) {
  return wasmtime_mariadb_file_decode_i32(
      wasmtime_mariadb_host_file_sync(fd, data_only));
}

static inline int wasmtime_mariadb_file_fstat(int fd, struct stat *st) {
  int64_t size = 0;
  int64_t blocks = 0;
  int64_t block_size = 4096;
  int64_t dev = 1;
  int64_t atime = 0;
  int64_t mtime = 0;
  int64_t ctime = 0;
  int32_t mode = S_IFREG | 0600;
  int rc = wasmtime_mariadb_file_decode_i32(
      wasmtime_mariadb_host_file_fstat(fd, &size, &blocks, &block_size, &dev,
                                       &mode, &atime, &mtime, &ctime));

  if (rc != 0) {
    return rc;
  }

  memset(st, 0, sizeof(*st));
  st->st_dev = (dev_t)dev;
  st->st_nlink = 1;
  st->st_mode = (mode_t)mode;
  st->st_size = (off_t)size;
  st->st_blksize = (blksize_t)block_size;
  st->st_blocks = (blkcnt_t)blocks;
  st->st_atime = (time_t)atime;
  st->st_mtime = (time_t)mtime;
  st->st_ctime = (time_t)ctime;
  return 0;
}

#endif /* __wasi__ */

#endif /* MARIADB_WASI_FILE_SHIM_H */
