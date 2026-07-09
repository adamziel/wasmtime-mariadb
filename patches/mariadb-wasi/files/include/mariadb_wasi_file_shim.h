#ifndef MARIADB_WASI_FILE_SHIM_H
#define MARIADB_WASI_FILE_SHIM_H

#if defined(__wasi__)

#include <errno.h>
#include <limits.h>
#include <stdint.h>
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

static inline int wasmtime_mariadb_file_open(const char *path, int flags,
                                             mode_t mode) {
  return wasmtime_mariadb_file_decode_i32(
      wasmtime_mariadb_host_file_open(path, flags, (int32_t)mode));
}

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

#endif /* __wasi__ */

#endif /* MARIADB_WASI_FILE_SHIM_H */
