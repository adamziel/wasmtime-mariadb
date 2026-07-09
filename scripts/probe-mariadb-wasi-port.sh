#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${MARIADB_SOURCE:-$root/third_party/mariadb-server}"
build_dir="${MARIADB_WASI_PORT_BUILD_DIR:-$root/build/mariadb-wasi-port}"
src_dir="$build_dir/src"
cmake_build_dir="$build_dir/build"
host_build_dir="$build_dir/host-build"
openssl_prefix="${OPENSSL_WASI_PREFIX:-$root/build/openssl-wasi/install}"
image="${WASI_SDK_IMAGE:-ghcr.io/webassembly/wasi-sdk:wasi-sdk-33}"
host_image="${HOST_BUILD_IMAGE:-debian:bookworm-slim}"
log_file="${MARIADB_WASI_PORT_PROBE_LOG:-$build_dir/probe.log}"
target="${MARIADB_WASI_PORT_TARGET:-mariadbd}"

if [[ ! -f "$source_dir/CMakeLists.txt" ]]; then
  MARIADB_SOURCE="$source_dir" "$root/scripts/fetch-mariadb-source.sh"
fi

if [[ ! -f "$openssl_prefix/lib/libssl.a" || ! -f "$openssl_prefix/lib/libcrypto.a" ]]; then
  OPENSSL_WASI_BUILD_DIR="$(dirname "$openssl_prefix")" "$root/scripts/build-openssl-wasi.sh"
fi

mkdir -p "$build_dir"
docker run --rm -v "$build_dir:/build:z" "$image" \
  sh -c 'rm -rf /build/* /build/.[!.]* /build/..?*'

mkdir -p "$src_dir" "$cmake_build_dir" "$host_build_dir"
git -C "$source_dir" archive HEAD | tar -x -C "$src_dir"

cp "$root/patches/mariadb-wasi/files/include/mariadb_wasi_socket_shim.h" \
  "$src_dir/include/mariadb_wasi_socket_shim.h"
cp "$root/patches/mariadb-wasi/files/include/mariadb_wasi_file_shim.h" \
  "$src_dir/include/mariadb_wasi_file_shim.h"
cp "$root/patches/mariadb-wasi/files/include/mariadb_wasi_libc_shim.h" \
  "$src_dir/include/mariadb_wasi_libc_shim.h"
cp "$root/patches/mariadb-wasi/files/include/netdb.h" "$src_dir/include/netdb.h"
cp "$root/patches/mariadb-wasi/files/include/pwd.h" "$src_dir/include/pwd.h"
cp "$root/patches/mariadb-wasi/files/include/syslog.h" "$src_dir/include/syslog.h"
mkdir -p "$src_dir/include/sys"
cp "$root/patches/mariadb-wasi/files/include/sys/resource.h" \
  "$src_dir/include/sys/resource.h"
cp "$root/patches/mariadb-wasi/files/include/sys/times.h" \
  "$src_dir/include/sys/times.h"
cp "$root/patches/mariadb-wasi/files/sql/mariadb_wasi_socket_shim.c" \
  "$src_dir/sql/mariadb_wasi_socket_shim.c"

patch_mariadb_source() {
  local src="$1"

  perl -0pi -e '
    s/ADD_SUBDIRECTORY\(client\)/# ADD_SUBDIRECTORY(client) -- skipped for WASI server probe/;
    s/ADD_SUBDIRECTORY\(tests\)/# ADD_SUBDIRECTORY(tests) -- skipped for WASI server probe/;
    s/ADD_SUBDIRECTORY\(mysql-test\)/# ADD_SUBDIRECTORY(mysql-test) -- skipped for WASI server probe/;
    s/ADD_SUBDIRECTORY\(mysql-test\/lib\/My\/SafeProcess\)/# ADD_SUBDIRECTORY(mysql-test\/lib\/My\/SafeProcess) -- skipped for WASI server probe/;
    s/ADD_SUBDIRECTORY\(sql-bench\)/# ADD_SUBDIRECTORY(sql-bench) -- skipped for WASI server probe/;
    s/ADD_SUBDIRECTORY\(man\)/# ADD_SUBDIRECTORY(man) -- skipped for WASI server probe/;
    s/INCLUDE\(mariadb_connector_c\)/MESSAGE\(STATUS "Skipping MariaDB Connector\/C for WASI server probe"\)/;
    s/IF\(NOT WITHOUT_SERVER\)\n  # Define target for minimal mtr-testable build.*?ADD_DEPENDENCIES\(smoketest minbuild\)\nENDIF\(\)\n/IF(NOT WITHOUT_SERVER)\n  # minbuild and smoketest are skipped for the WASI server probe.\nENDIF()\n/s;
  ' "$src/CMakeLists.txt"

  perl -0pi -e '
    s/MACRO \(MYSQL_CHECK_READLINE\)\n  IF \(NOT WIN32\)/MACRO (MYSQL_CHECK_READLINE)\n  IF(CMAKE_SYSTEM_NAME STREQUAL "WASI")\n    SET(MY_READLINE_INCLUDE_DIR "")\n    SET(MY_READLINE_LIBRARY "")\n    SET(HAVE_TERM_H 0 CACHE INTERNAL "" FORCE)\n  ELSEIF (NOT WIN32)/;
    s/  ENDIF\(NOT WIN32\)\n  CHECK_INCLUDE_FILES \("curses.h;term.h" HAVE_TERM_H\)/  ENDIF()\n  IF(NOT CMAKE_SYSTEM_NAME STREQUAL "WASI")\n    CHECK_INCLUDE_FILES ("curses.h;term.h" HAVE_TERM_H)\n  ENDIF()/;
  ' "$src/cmake/readline.cmake"

  perl -0pi -e '
    s/(  ExternalProject_Add\(\n    pcre2)/  SET(PCRE2_EXTRA_CMAKE_ARGS)\n  IF(CMAKE_TOOLCHAIN_FILE)\n    LIST(APPEND PCRE2_EXTRA_CMAKE_ARGS "-DCMAKE_TOOLCHAIN_FILE=\${CMAKE_TOOLCHAIN_FILE}")\n  ENDIF()\n  IF(CMAKE_TRY_COMPILE_TARGET_TYPE)\n    LIST(APPEND PCRE2_EXTRA_CMAKE_ARGS "-DCMAKE_TRY_COMPILE_TARGET_TYPE=\${CMAKE_TRY_COMPILE_TARGET_TYPE}")\n  ENDIF()\n  IF(CMAKE_EXE_LINKER_FLAGS)\n    LIST(APPEND PCRE2_EXTRA_CMAKE_ARGS "-DCMAKE_EXE_LINKER_FLAGS=\${CMAKE_EXE_LINKER_FLAGS}")\n  ENDIF()\n  IF(CMAKE_SHARED_LINKER_FLAGS)\n    LIST(APPEND PCRE2_EXTRA_CMAKE_ARGS "-DCMAKE_SHARED_LINKER_FLAGS=\${CMAKE_SHARED_LINKER_FLAGS}")\n  ENDIF()\n\n$1/;
    s/(      "-DCMAKE_C_COMPILER=\$\{CMAKE_C_COMPILER\}"\n)/$1      \${PCRE2_EXTRA_CMAKE_ARGS}\n/;
  ' "$src/cmake/pcre.cmake"

  perl -0pi -e '
    s/(#include <netinet\/in.h>\n  #define SOCKBUF_T void)/$1\n  #if defined(__wasi__)\n    #include "mariadb_wasi_socket_shim.h"\n    #define socket(...) wasmtime_mariadb_socket(__VA_ARGS__)\n    #define bind(...) wasmtime_mariadb_bind(__VA_ARGS__)\n    #define listen(...) wasmtime_mariadb_listen(__VA_ARGS__)\n    #define accept(...) wasmtime_mariadb_accept(__VA_ARGS__)\n    #define connect(...) wasmtime_mariadb_connect(__VA_ARGS__)\n    #define getsockname(...) wasmtime_mariadb_getsockname(__VA_ARGS__)\n    #define getpeername(...) wasmtime_mariadb_getpeername(__VA_ARGS__)\n    #define setsockopt(...) wasmtime_mariadb_setsockopt(__VA_ARGS__)\n    #define getsockopt(...) wasmtime_mariadb_getsockopt(__VA_ARGS__)\n    #define send(...) wasmtime_mariadb_send(__VA_ARGS__)\n    #define recv(...) wasmtime_mariadb_recv(__VA_ARGS__)\n    #define sendto(...) wasmtime_mariadb_sendto(__VA_ARGS__)\n    #define recvfrom(...) wasmtime_mariadb_recvfrom(__VA_ARGS__)\n    #define shutdown(...) wasmtime_mariadb_shutdown(__VA_ARGS__)\n    #define fcntl(...) wasmtime_mariadb_fcntl(__VA_ARGS__)\n  #endif/;
    s/(#include "mysql\/psi\/psi.h")/#if defined(__wasi__)\n#undef HAVE_ACCEPT4\n#endif\n$1/;
    s/(#endif\n\n\/\*\* \@} \(end of group psi_api_socket\) \*\/)/#if defined(__wasi__)\n#undef socket\n#undef bind\n#undef listen\n#undef accept\n#undef connect\n#undef getsockname\n#undef getpeername\n#undef setsockopt\n#undef getsockopt\n#undef send\n#undef recv\n#undef sendto\n#undef recvfrom\n#undef shutdown\n#undef fcntl\n#endif\n\n$1/;
    s/\n#endif\s*$/\n#if defined(__wasi__)\n#undef socket\n#undef bind\n#undef listen\n#undef accept\n#undef connect\n#undef getsockname\n#undef getpeername\n#undef setsockopt\n#undef getsockopt\n#undef send\n#undef recv\n#undef sendto\n#undef recvfrom\n#undef shutdown\n#undef fcntl\n#endif\n\n#endif\n/s;
  ' "$src/include/mysql/psi/mysql_socket.h"

  perl -0pi -e '
    s/#define closesocket\(A\)\s+close\(A\)/#if defined(__wasi__)\n#define closesocket(A) wasmtime_mariadb_close(A)\n#else\n#define closesocket(A) close(A)\n#endif/g;
  ' "$src/include/my_global.h"

  perl -0pi -e '
    s/#if !defined\(_WIN32\) && !defined\(HAVE_KQUEUE\)/#if !defined(_WIN32) && !defined(HAVE_KQUEUE) && !defined(__wasi__)/;
  ' "$src/include/violite.h"

  perl -0pi -e '
    s/(SET \(SQL_SOURCE\n)/$1               mariadb_wasi_socket_shim.c\n/;
  ' "$src/sql/CMakeLists.txt"

  perl -0pi -e '
    s/(#include <mysql\/client_plugin.h>)/#ifdef __wasi__\n#include "mariadb_wasi_socket_shim.h"\n#define MARIADB_WASI_CLIENT_SOCKET wasmtime_mariadb_socket\n#define MARIADB_WASI_CLIENT_BIND wasmtime_mariadb_bind\n#define MARIADB_WASI_CLIENT_GETSOCKNAME wasmtime_mariadb_getsockname\n#else\n#define MARIADB_WASI_CLIENT_SOCKET socket\n#define MARIADB_WASI_CLIENT_BIND bind\n#define MARIADB_WASI_CLIENT_GETSOCKNAME getsockname\n#endif\n$1/;
    s/#if defined\(HAVE_SYS_UN_H\)/#if defined(HAVE_SYS_UN_H) \&\& !defined(__wasi__)/g;
    s/\bsocket\((t_res->ai_family, t_res->ai_socktype, t_res->ai_protocol)\)/MARIADB_WASI_CLIENT_SOCKET($1)/g;
    s/\bbind\((sock, curr_bind_ai->ai_addr,\s*static_cast<int>\(curr_bind_ai->ai_addrlen\))\)/MARIADB_WASI_CLIENT_BIND($1)/g;
    s/\bgetsockname\((vio_fd\(vio\), &addr, &addrlen)\)/MARIADB_WASI_CLIENT_GETSOCKNAME($1)/g;
  ' "$src/sql-common/client.c"

  perl -0pi -e '
    s/#include <signal.h>/#if !defined(__wasi__)\n#include <signal.h>\n#endif/;
  ' "$src/sql/signal_handler.cc" "$src/mysys/my_thr_init.c" || true

  perl -0pi -e '
    s/  SSL_set_fd\(ssl, \(int\)sd\);/#if defined(__wasi__) \&\& defined(OPENSSL_NO_SOCK)\n  \/* OpenSSL is built no-sock for WASI. TLS needs a custom BIO bridge. *\/\n  *errptr= 0;\n  SSL_free(ssl);\n  DBUG_RETURN(1);\n#else\n  SSL_set_fd(ssl, (int)sd);\n#endif/;
  ' "$src/vio/viossl.c"

  perl -0pi -e '
    s/(#include "vio_priv\.h"\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_socket_shim.h"\n#define setsockopt(...) wasmtime_mariadb_setsockopt(__VA_ARGS__)\n#define shutdown(...) wasmtime_mariadb_shutdown(__VA_ARGS__)\n#define fcntl(...) wasmtime_mariadb_fcntl(__VA_ARGS__)\n#define recv(...) wasmtime_mariadb_recv(__VA_ARGS__)\n#define poll(...) wasmtime_mariadb_poll(__VA_ARGS__)\n#endif\n/;
  ' "$src/vio/viosocket.c"

  perl -0pi -e '
    s/(#include "sql_priv\.h"\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_socket_shim.h"\n#endif\n/;
    s/\bfcntl\(/wasmtime_mariadb_fcntl(/g;
    s/\bpoll\(/wasmtime_mariadb_poll(/g;
    s/(  int termination_fds\[2\];\n  if \(pipe\(termination_fds\)\)\n  \{\n    sql_print_error\("pipe\(\) failed %d", errno\);\n    DBUG_VOID_RETURN;\n  \}\n#ifdef FD_CLOEXEC\n  for \(int fd : termination_fds\)\n    \(void\)wasmtime_mariadb_fcntl\(fd, F_SETFD, FD_CLOEXEC\);\n#endif\n  mysql_mutex_lock\(&LOCK_start_thread\);\n  termination_event_fd= termination_fds\[1\];\n  mysql_mutex_unlock\(&LOCK_start_thread\);\n\n  struct pollfd event_fd;\n  event_fd\.fd= termination_fds\[0\];\n  event_fd\.events= POLLIN;\n  fds\.push\(event_fd\);\n)/#if !defined(__wasi__)\n$1#endif\n/s;
    s/(  for\(int fd : termination_fds\)\n    close\(fd\);\n  termination_event_fd= -1;\n)/#if !defined(__wasi__)\n$1#endif\n/s;
  ' "$src/sql/mysqld.cc"

  perl -0pi -e '
    s/#if defined\(HAVE_MALLOC_ZONE\)/#if defined(HAVE_MALLOC_ZONE) \&\& !defined(__wasi__)/g;
    s/#elif defined\(HAVE_MALLOC_ZONE\)/#elif defined(HAVE_MALLOC_ZONE) \&\& !defined(__wasi__)/g;
    s/#if defined\(HAVE_MALLINFO2\)/#if defined(HAVE_MALLINFO2) \&\& !defined(__wasi__)/g;
    s/#elif defined\(HAVE_MALLINFO\)/#elif defined(HAVE_MALLINFO) \&\& !defined(__wasi__)/g;
    s/#if defined\(HAVE_MALLINFO\) \|\| defined\(HAVE_MALLINFO2\)/#if (defined(HAVE_MALLINFO) || defined(HAVE_MALLINFO2)) \&\& !defined(__wasi__)/g;
  ' "$src/sql/sql_test.cc"

  perl -0pi -e '
    s/(#include "mysys_err\.h"\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#define open(...) wasmtime_mariadb_file_open(__VA_ARGS__)\n#define close(...) wasmtime_mariadb_file_close(__VA_ARGS__)\n#endif\n/;
  ' "$src/mysys/my_open.c"

  perl -0pi -e '
    s/#else\n  if \(MyFlags & MY_NOSYMLINKS\)\n    fd = open_nosymlinks\(FileName, Flags \| O_CLOEXEC, my_umask\);\n  else\n    fd = open\(FileName, Flags \| O_CLOEXEC, my_umask\);\n#endif/#else\n#if defined(__wasi__)\n  fd = open(FileName, Flags | O_CLOEXEC, my_umask);\n#else\n  if (MyFlags \& MY_NOSYMLINKS)\n    fd = open_nosymlinks(FileName, Flags | O_CLOEXEC, my_umask);\n  else\n    fd = open(FileName, Flags | O_CLOEXEC, my_umask);\n#endif\n#endif/;
  ' "$src/mysys/my_open.c"

  perl -0pi -e '
    s/(#include "mysys_err\.h"\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#define open(...) wasmtime_mariadb_file_open(__VA_ARGS__)\n#endif\n/;
  ' "$src/mysys/my_create.c"

  perl -0pi -e '
    s/(#include\s+<my_dir\.h>[^\n]*\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#define fstat(...) wasmtime_mariadb_file_fstat(__VA_ARGS__)\n#define stat(...) wasmtime_mariadb_file_stat(__VA_ARGS__)\n#endif\n/;
  ' "$src/mysys/my_lib.c"

  perl -0pi -e '
    s/(#include <errno\.h>\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#define read(...) wasmtime_mariadb_file_read(__VA_ARGS__)\n#endif\n/;
  ' "$src/mysys/my_read.c"

  perl -0pi -e '
    s/(#include <errno\.h>\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#define write(...) wasmtime_mariadb_file_write(__VA_ARGS__)\n#endif\n/;
  ' "$src/mysys/my_write.c"

  perl -0pi -e '
    s/(#include <errno\.h>\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#define pread(...) wasmtime_mariadb_file_pread(__VA_ARGS__)\n#define pwrite(...) wasmtime_mariadb_file_pwrite(__VA_ARGS__)\n#endif\n/;
  ' "$src/mysys/my_pread.c"

  perl -0pi -e '
    s/(#include "mysys_err\.h"\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#define lseek(...) wasmtime_mariadb_file_seek(__VA_ARGS__)\n#define tell(fd) wasmtime_mariadb_file_seek((fd), 0, SEEK_CUR)\n#endif\n/;
  ' "$src/mysys/my_seek.c"

  perl -0pi -e '
    s/(#include "mysys_err\.h"\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#define ftruncate(...) wasmtime_mariadb_file_truncate(__VA_ARGS__)\n#endif\n/;
  ' "$src/mysys/my_chsize.c"

  perl -0pi -e '
    s/(#include <errno\.h>\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#define fdatasync(fd) wasmtime_mariadb_file_sync((fd), 1)\n#define fsync(fd) wasmtime_mariadb_file_sync((fd), 0)\n#endif\n/;
  ' "$src/mysys/my_sync.c"

  perl -0pi -e '
    s/(#include <mysys_err.h>\n)/$1#if defined(__wasi__)\n#undef MAP_HUGETLB\n#undef MAP_HUGE_SHIFT\n#ifndef MAP_ANONYMOUS\n#define MAP_ANONYMOUS 0x20\n#endif\n#endif\n/;
    s/(#endif \/\* HAVE_MMAP && !_WIN32 \*\/)/$1\n#if defined(__wasi__) && !defined(OS_MAP_ANON)\n#define OS_MAP_ANON MAP_ANONYMOUS\n#endif/;
    s/(  DBUG_ENTER\("my_large_malloc"\);\n)/$1#if defined(__wasi__)\n  DBUG_RETURN(my_malloc_lock(*size, MYF(my_flags | MY_ZEROFILL)));\n#endif\n/s;
    s/(  DBUG_ENTER\("my_large_virtual_alloc"\);\n)/$1#if defined(__wasi__)\n  DBUG_RETURN((char*) my_malloc_lock(*size, MYF(MY_ZEROFILL | MY_WME)));\n#endif\n/s;
    s/(  DBUG_ENTER\("my_large_free"\);\n)/$1#if defined(__wasi__)\n  my_free_lock(ptr);\n  DBUG_VOID_RETURN;\n#endif\n/s;
  ' "$src/mysys/my_largepage.c"

  perl -0pi -e '
    s/(  DBUG_ASSERT\(ptr\);\n)/$1#if defined(__wasi__)\n  (void) size;\n  return ptr;\n#endif\n/s;
    s/(void my_virtual_mem_decommit\(char \*ptr, size_t size\)\n\{\n)/$1#if defined(__wasi__)\n  memset(ptr, 0, size);\n  return;\n#endif\n/s;
    s/(void my_virtual_mem_release\(char \*ptr, size_t size\)\n\{\n)/$1#if defined(__wasi__)\n  (void) size;\n  my_free_lock(ptr);\n  return;\n#endif\n/s;
  ' "$src/mysys/my_virtual_mem.c"

  perl -0pi -e '
    s/(  DBUG_PRINT\("my",\("fd: %d  Op: %d  start: %ld  Length: %ld  MyFlags: %lu",\n\s+fd,locktype,\(long\) start,\(long\) length,MyFlags\)\);\n)/$1#if defined(__wasi__)\n  DBUG_RETURN(0);\n#endif\n/s;
  ' "$src/mysys/my_lock.c"

  perl -0pi -e '
    s/(#include <errno\.h>\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#define open(...) wasmtime_mariadb_file_open(__VA_ARGS__)\n#define close(...) wasmtime_mariadb_file_close(__VA_ARGS__)\n#define mkstemp(...) wasmtime_mariadb_file_mkstemp(__VA_ARGS__)\n#endif\n/;
  ' "$src/mysys/mf_tempfile.c"

  perl -0pi -e '
    s/IF\(UNIX\)\n SET \(MYSYS_SOURCES \$\{MYSYS_SOURCES\} my_addr_resolve\.c my_setuser\.c\)\nENDIF\(\)/IF(UNIX)\n SET (MYSYS_SOURCES \${MYSYS_SOURCES} my_addr_resolve.c my_setuser.c)\nELSEIF(CMAKE_SYSTEM_NAME STREQUAL "WASI")\n SET (MYSYS_SOURCES \${MYSYS_SOURCES} my_setuser.c)\nENDIF()/;
  ' "$src/mysys/CMakeLists.txt"

  perl -0pi -e '
    s/IF\(UNIX\)\n      ADD_CUSTOM_COMMAND\(TARGET \$\{target\} POST_BUILD/IF(UNIX OR CMAKE_SYSTEM_NAME STREQUAL "WASI")\n      ADD_CUSTOM_COMMAND(TARGET \${target} POST_BUILD/;
  ' "$src/cmake/mysql_add_executable.cmake"

  perl -0pi -e '
    s/(ENDIF\(\)\nENDIF\(\)\n\n)(CHECK_CXX_SOURCE_COMPILES\("\n#include <pthread.h>)/$1IF(CMAKE_SYSTEM_NAME STREQUAL "WASI")\n  SET(SOCKET_SIZE_TYPE socklen_t)\nENDIF()\n\n$2/s;
  ' "$src/configure.cmake"

  perl -0pi -e '
    s/(#include "tpool\.h"\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#endif\n/;
    s/(  switch \(cb->m_opcode\)\n  \{\n  case aio_opcode::AIO_PREAD:\n    ret_len= pread\(cb->m_fh, cb->m_buffer, cb->m_len, cb->m_offset\);\n    break;\n  case aio_opcode::AIO_PWRITE:\n    ret_len= pwrite\(cb->m_fh, cb->m_buffer, cb->m_len, cb->m_offset\);\n    break;\n)/#if defined(__wasi__)\n  switch (cb->m_opcode)\n  {\n  case aio_opcode::AIO_PREAD:\n    ret_len= wasmtime_mariadb_file_pread(cb->m_fh, cb->m_buffer, cb->m_len,\n                                         cb->m_offset);\n    break;\n  case aio_opcode::AIO_PWRITE:\n    ret_len= wasmtime_mariadb_file_pwrite(cb->m_fh, cb->m_buffer, cb->m_len,\n                                          cb->m_offset);\n    break;\n#else\n$1#endif\n/s;
  ' "$src/tpool/tpool_generic.cc"

  perl -0pi -e '
    s/(#include "os0file\.h"\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#endif\n/;
    s/(  if \(request\.is_read\(\)\)\n    return IF_WIN\(tpool::pread\(m_fh, m_buf, n, m_offset\), pread\(m_fh, m_buf, n, m_offset\)\);\n  return IF_WIN\(tpool::pwrite\(m_fh, m_buf, n, m_offset\), pwrite\(m_fh, m_buf, n, m_offset\)\);\n)/#if defined(__wasi__)\n  if (request.is_read())\n    return wasmtime_mariadb_file_pread(m_fh, m_buf, n, m_offset);\n  return wasmtime_mariadb_file_pwrite(m_fh, m_buf, n, m_offset);\n#else\n$1#endif\n/s;
    s/(static int os_file_sync_posix\(os_file_t file\) noexcept\n\{\n)/$1#if defined(__wasi__)\n  auto func= [](os_file_t fd) { return wasmtime_mariadb_file_sync(fd, 1); };\n  auto func_name= "fdatasync()";\n#else\n/s;
    s/(#else\n  auto func= fdatasync;\n  auto func_name= "fdatasync\(\)";\n#endif\n)/$1#endif\n/s;
    s/file = open\(name, create_flag \| direct_flag, my_umask\);/file = wasmtime_mariadb_file_open(\n\t\t\tname, create_flag | direct_flag, my_umask);/g;
    s/file = open\(name, create_flag, my_umask\);/file = wasmtime_mariadb_file_open(name, create_flag, my_umask);/g;
    s/int f= open\(b, O_RDONLY\);/int f= wasmtime_mariadb_file_open(b, O_RDONLY);/g;
    s/f= open\(b, O_RDONLY\);/f= wasmtime_mariadb_file_open(b, O_RDONLY);/g;
    s/ssize_t l= read\(f, b, sizeof b\);/ssize_t l= wasmtime_mariadb_file_read(f, b, sizeof b);/g;
    s/\bclose\(file\);/wasmtime_mariadb_file_close(file);/g;
    s/\bclose\(f\);/wasmtime_mariadb_file_close(f);/g;
    s/int ret= close\(file\);/int ret= wasmtime_mariadb_file_close(file);/g;
    s/return lseek\(file, 0, SEEK_END\);/return wasmtime_mariadb_file_seek(file, 0, SEEK_END);/g;
    s/int\s+res = ftruncate\(file, size\);/int\tres = wasmtime_mariadb_file_truncate(file, size);/g;
    s/return\(!ftruncate\(fileno\(file\), ftell\(file\)\)\);/return(!wasmtime_mariadb_file_truncate(fileno(file), ftell(file)));/g;
    s/bool success = !ftruncate\(file, size\);/bool success = !wasmtime_mariadb_file_truncate(file, size);/g;
    s/if \(fstat\(file, &st\) \|\| !os_file_log_maybe_unbuffered\(st\)\)/if (wasmtime_mariadb_file_fstat(file, \&st) || !os_file_log_maybe_unbuffered(st))/g;
    s/if \(!fstat\(file, &statbuf\)\)/if (!wasmtime_mariadb_file_fstat(file, \&statbuf))/g;
    s/(int os_file_lock\(int fd, const char \*name\) noexcept\n\{\n)/$1#if defined(__wasi__)\n\t(void) fd;\n\t(void) name;\n\treturn 0;\n#endif\n/s;
  ' "$src/storage/innobase/os/os0file.cc"

  perl -0pi -e '
    s/(#include "log0log\.h"\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#endif\n/;
    s/(    s= IF_WIN\(tpool::pread\(m_file, data, size, offset\),\n              pread\(m_file, data, size, offset\)\);\n)/#if defined(__wasi__)\n    s= wasmtime_mariadb_file_pread(m_file, data, size, offset);\n#else\n$1#endif\n/s;
    s/(    s= IF_WIN\(tpool::pwrite\(m_file, data, size, offset\),\n              pwrite\(m_file, data, size, offset\)\);\n)/#if defined(__wasi__)\n    s= wasmtime_mariadb_file_pwrite(m_file, data, size, offset);\n#else\n$1#endif\n/s;
    s/if \(!fstat\(file, &st\)\)/if (!wasmtime_mariadb_file_fstat(file, \&st))/g;
  ' "$src/storage/innobase/log/log0log.cc"

  perl -0pi -e '
    s/(  if \(opt_bin_log\)\n    return &mysql_bin_log;\n)/#if defined(__wasi__)\n  if (!opt_bin_log)\n    return \&tc_log_dummy;\n#endif\n$1/s;
  ' "$src/sql/log.h"

  perl -0pi -e '
    s/  if \(RAND_bytes\(buf, num\) != 1\)\n    return MY_AES_OPENSSL_ERROR;/#if defined(__wasi__)\n  if (wasmtime_mariadb_random_bytes(buf, num))\n    return MY_AES_OPENSSL_ERROR;\n#else\n  if (RAND_bytes(buf, num) != 1)\n    return MY_AES_OPENSSL_ERROR;\n#endif/s;
  ' "$src/mysys_ssl/my_crypt.cc"

  perl -0pi -e '
    s/(#include "os0file\.h"\n)/$1#if defined(__wasi__)\n#include "mariadb_wasi_file_shim.h"\n#endif\n/;
    s/fstat\(m_handle, &m_file_info\);/wasmtime_mariadb_file_fstat(m_handle, \&m_file_info);/g;
  ' "$src/storage/innobase/fsp/fsp0file.cc"
}

patch_mariadb_source "$src_dir"
: > "$log_file"

if ! docker run --rm \
  -v "$src_dir:/mariadb:ro,z" \
  -v "$host_build_dir:/host-build:z" \
  -w /host-build \
  "$host_image" \
  sh -euxc '
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bison \
      ca-certificates \
      cmake \
      g++ \
      libncurses-dev \
      libssl-dev \
      make \
      ninja-build \
      perl \
      pkg-config \
      zlib1g-dev
    cmake -S /mariadb -B /host-build -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DUPDATE_SUBMODULES=OFF \
      -DWITH_UNIT_TESTS=OFF \
      -DWITHOUT_SERVER=OFF \
      -DWITH_EMBEDDED_SERVER=OFF \
      -DWITH_WSREP=OFF \
      -DPLUGIN_INNOBASE=STATIC \
      -DPLUGIN_ROCKSDB=NO \
      -DPLUGIN_MROONGA=NO \
      -DPLUGIN_TOKUDB=NO \
      -DPLUGIN_SPIDER=NO \
      -DPLUGIN_SPHINX=NO \
      -DPLUGIN_CONNECT=NO \
      -DPLUGIN_PERFSCHEMA=NO \
      -DPLUGIN_COLUMNSTORE=NO \
      -DPLUGIN_OQGRAPH=NO \
      -DPLUGIN_FEDERATED=NO \
      -DPLUGIN_FEDERATEDX=NO \
      -DPLUGIN_FEEDBACK=NO \
      -DPLUGIN_S3=NO \
      -DWITH_SSL=system \
      -DWITH_PCRE=bundled \
      -DWITH_ZLIB=bundled
    cmake --build /host-build --target import_executables
  ' >> "$log_file" 2>&1; then
  tail -n 180 "$log_file"
  exit 1
fi

if ! docker run --rm \
  -e MARIADB_WASI_PORT_TARGET="$target" \
  -v "$src_dir:/mariadb:ro,z" \
  -v "$cmake_build_dir:/build:z" \
  -v "$host_build_dir:/host-build:ro,z" \
  -v "$openssl_prefix:/openssl-wasi:ro,z" \
  -w /build \
  "$image" \
  sh -euxc '
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bison
    fi

    wasi_sdk_path="${WASI_SDK_PATH:-/opt/wasi-sdk}"
    toolchain="$wasi_sdk_path/share/cmake/wasi-sdk-pthread.cmake"
    if [ ! -f "$toolchain" ]; then
      toolchain="$(find / -path "*/share/cmake/wasi-sdk-pthread.cmake" -print -quit)"
    fi
    test -n "$toolchain"

    cmake -S /mariadb -B /build -GNinja \
      -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
      -DCMAKE_BUILD_TYPE=Release \
      -DUPDATE_SUBMODULES=OFF \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DCMAKE_C_FLAGS="-include /mariadb/include/mariadb_wasi_libc_shim.h -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -DUSE_MUTEX_INSTEAD_OF_RW_LOCKS" \
      -DCMAKE_CXX_FLAGS="-include /mariadb/include/mariadb_wasi_libc_shim.h -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -DUSE_MUTEX_INSTEAD_OF_RW_LOCKS" \
      -DCMAKE_EXE_LINKER_FLAGS="-fwasm-exceptions -lwasi-emulated-getpid -lwasi-emulated-mman -lwasi-emulated-signal -lunwind -Wl,--initial-memory=134217728 -Wl,--max-memory=1073741824" \
      -DCMAKE_SHARED_LINKER_FLAGS="-fwasm-exceptions -lwasi-emulated-getpid -lwasi-emulated-mman -lwasi-emulated-signal -lunwind -Wl,--initial-memory=134217728 -Wl,--max-memory=1073741824" \
      -DIMPORT_EXECUTABLES=/host-build/import_executables.cmake \
      -DHAVE_SIGWAIT=1 \
      -DHAVE_SIGWAITINFO=1 \
      -DHAVE_PTHREAD_SIGMASK=1 \
      -DHAVE_PTHREAD_ATTR_SETSCOPE=1 \
      -DHAVE_FCNTL=1 \
      -DHAVE_MEMCPY=1 \
      -DHAVE_MEMMOVE=1 \
      -DHAVE_BFILL=0 \
      -DHAVE_GETPASS=1 \
      -DHAVE_GETPASSPHRASE=1 \
      -DHAVE_PWD_H=1 \
      -DHAVE_MKSTEMP=1 \
      -DHAVE_MKOSTEMP=0 \
      -DHAVE_MALLINFO=0 \
      -DHAVE_MALLINFO2=0 \
      -DHAVE_MALLOC_ZONE=0 \
      -DHAVE_MMAP=1 \
      -DHAVE_MMAP64=0 \
      -DHAVE_CLOCK_GETTIME=1 \
      -DHAVE_GETHRTIME=0 \
      -DHAVE_READ_REAL_TIME=0 \
      -DHAVE_GETCWD=1 \
      -DHAVE_GETWD=0 \
      -DHAVE_SIGSET=0 \
      -DHAVE_SYS_UN_H=0 \
      -DHAVE_PRINTSTACK=0 \
      -DHAVE_BACKTRACE=0 \
      -DHAVE_BACKTRACE_SYMBOLS=0 \
      -DHAVE_BACKTRACE_SYMBOLS_FD=0 \
      -DHAVE_PTHREAD_GETATTR_NP=0 \
      -DHAVE_SCHED_YIELD=1 \
      -DHAVE_PTHREAD_YIELD_NP=0 \
      -DWITH_UNIT_TESTS=OFF \
      -DWITHOUT_SERVER=OFF \
      -DWITH_EMBEDDED_SERVER=OFF \
      -DWITH_WSREP=OFF \
      -DDISABLE_THREADPOOL=ON \
      -DPLUGIN_INNOBASE=STATIC \
      -DPLUGIN_ROCKSDB=NO \
      -DPLUGIN_MROONGA=NO \
      -DPLUGIN_TOKUDB=NO \
      -DPLUGIN_SPIDER=NO \
      -DPLUGIN_SPHINX=NO \
      -DPLUGIN_CONNECT=NO \
      -DPLUGIN_PERFSCHEMA=NO \
      -DPLUGIN_COLUMNSTORE=NO \
      -DPLUGIN_OQGRAPH=NO \
      -DPLUGIN_FEDERATED=NO \
      -DPLUGIN_FEDERATEDX=NO \
      -DPLUGIN_FEEDBACK=NO \
      -DPLUGIN_S3=NO \
      -DWITH_SSL=system \
      -DOPENSSL_ROOT_DIR=/openssl-wasi \
      -DOPENSSL_INCLUDE_DIR=/openssl-wasi/include \
      -DOPENSSL_SSL_LIBRARY=/openssl-wasi/lib/libssl.a \
      -DOPENSSL_CRYPTO_LIBRARY=/openssl-wasi/lib/libcrypto.a \
      -DOPENSSL_USE_STATIC_LIBS=TRUE \
      -DWITH_PCRE=bundled \
      -DWITH_ZLIB=bundled \
      -DHAVE_FDATASYNC=1 \
      -DHAVE_KQUEUE=0 \
      -DHAVE_EPOLL=0 \
      -DHAVE_TIMER_CREATE=0 \
      -DHAVE_TIMER_SETTIME=0 \
      -DHAVE_POSIX_MEMALIGN=1

    cmake --build /build --target "$MARIADB_WASI_PORT_TARGET"
  ' >> "$log_file" 2>&1; then
  tail -n 220 "$log_file"
  exit 1
fi

printf 'MariaDB WASI port probe built target: %s\n' "$target"
printf 'Build directory: %s\n' "$cmake_build_dir"
