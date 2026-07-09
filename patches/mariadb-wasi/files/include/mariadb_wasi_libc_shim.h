#ifndef MARIADB_WASI_LIBC_SHIM_H
#define MARIADB_WASI_LIBC_SHIM_H

#if defined(__wasi__)

#include <errno.h>
#include <fenv.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include "sys/resource.h"
#include <unistd.h>

#ifndef F_RDLCK
#define F_RDLCK 0
#endif
#ifndef F_WRLCK
#define F_WRLCK 1
#endif
#ifndef F_UNLCK
#define F_UNLCK 2
#endif
#ifndef F_GETLK
#define F_GETLK 5
#endif
#ifndef F_GETFL
#define F_GETFL 3
#endif
#ifndef F_SETFL
#define F_SETFL 4
#endif
#ifndef F_GETFD
#define F_GETFD 1
#endif
#ifndef F_SETFD
#define F_SETFD 2
#endif
#ifndef F_SETLK
#define F_SETLK 6
#endif
#ifndef F_SETLKW
#define F_SETLKW 7
#endif
#ifndef F_TO_EOF
#define F_TO_EOF 0
#endif

#ifndef HAVE_FDATASYNC
#define HAVE_FDATASYNC 1
#endif

#ifndef SO_LINGER
#define SO_LINGER 13
#endif

#ifndef P_tmpdir
#define P_tmpdir "/tmp"
#endif

#ifndef SIG_SETMASK
#define SIG_SETMASK 2
#endif
#ifndef SIG_BLOCK
#define SIG_BLOCK 0
#endif
#ifndef SIG_UNBLOCK
#define SIG_UNBLOCK 1
#endif
#ifndef SA_RESETHAND
#define SA_RESETHAND 0x80000000
#endif
#ifndef SA_NODEFER
#define SA_NODEFER 0x40000000
#endif
#ifndef SA_SIGINFO
#define SA_SIGINFO 4
#endif
#ifndef ILL_ILLOPC
#define ILL_ILLOPC 1
#endif
#ifndef ILL_ILLOPN
#define ILL_ILLOPN 2
#endif
#ifndef ILL_ILLADR
#define ILL_ILLADR 3
#endif
#ifndef ILL_ILLTRP
#define ILL_ILLTRP 4
#endif
#ifndef ILL_PRVOPC
#define ILL_PRVOPC 5
#endif
#ifndef ILL_PRVREG
#define ILL_PRVREG 6
#endif
#ifndef ILL_COPROC
#define ILL_COPROC 7
#endif
#ifndef ILL_BADSTK
#define ILL_BADSTK 8
#endif
#ifndef FPE_INTDIV
#define FPE_INTDIV 1
#endif
#ifndef FPE_INTOVF
#define FPE_INTOVF 2
#endif
#ifndef FPE_FLTDIV
#define FPE_FLTDIV 3
#endif
#ifndef FPE_FLTOVF
#define FPE_FLTOVF 4
#endif
#ifndef FPE_FLTUND
#define FPE_FLTUND 5
#endif
#ifndef FPE_FLTRES
#define FPE_FLTRES 6
#endif
#ifndef FPE_FLTINV
#define FPE_FLTINV 7
#endif
#ifndef FPE_FLTSUB
#define FPE_FLTSUB 8
#endif
#ifndef SEGV_MAPERR
#define SEGV_MAPERR 1
#endif
#ifndef SEGV_ACCERR
#define SEGV_ACCERR 2
#endif
#ifndef BUS_ADRALN
#define BUS_ADRALN 1
#endif
#ifndef BUS_ADRERR
#define BUS_ADRERR 2
#endif
#ifndef BUS_OBJERR
#define BUS_OBJERR 3
#endif
#ifndef TRAP_BRKPT
#define TRAP_BRKPT 1
#endif
#ifndef TRAP_TRACE
#define TRAP_TRACE 2
#endif

typedef struct siginfo_t {
  int si_signo;
  int si_errno;
  int si_code;
  pid_t si_pid;
  uid_t si_uid;
  void *si_addr;
} siginfo_t;

struct sigaction {
  union {
    void (*sa_handler)(int);
    void (*sa_sigaction)(int, siginfo_t *, void *);
  } __sa_handler;
  sigset_t sa_mask;
  int sa_flags;
};

#define sa_handler __sa_handler.sa_handler
#define sa_sigaction __sa_handler.sa_sigaction

static inline int wasmtime_mariadb_sigemptyset(sigset_t *set) {
  if (set != NULL) memset(set, 0, sizeof(*set));
  return 0;
}

static inline int wasmtime_mariadb_sigfillset(sigset_t *set) {
  if (set != NULL) memset(set, 0xff, sizeof(*set));
  return 0;
}

static inline int wasmtime_mariadb_sigaddset(sigset_t *set, int signum) {
  (void)set;
  (void)signum;
  return 0;
}

static inline int wasmtime_mariadb_sigdelset(sigset_t *set, int signum) {
  (void)set;
  (void)signum;
  return 0;
}

static inline int wasmtime_mariadb_sigismember(const sigset_t *set,
                                              int signum) {
  (void)set;
  (void)signum;
  return 0;
}

static inline int sigaction(int signum, const struct sigaction *act,
                            struct sigaction *oldact) {
  (void)signum;
  (void)act;
  if (oldact != NULL) memset(oldact, 0, sizeof(*oldact));
  return 0;
}

static inline int wasmtime_mariadb_sigprocmask(int how, const sigset_t *set,
                                              sigset_t *oldset) {
  (void)how;
  (void)set;
  if (oldset != NULL) memset(oldset, 0, sizeof(*oldset));
  return 0;
}

static inline int wasmtime_mariadb_pthread_sigmask(int how,
                                                  const sigset_t *set,
                                                  sigset_t *oldset) {
  return wasmtime_mariadb_sigprocmask(how, set, oldset);
}

static inline int wasmtime_mariadb_sigwait(const sigset_t *set, int *signum) {
  (void)set;
  if (signum != NULL) *signum = 0;
  return ENOSYS;
}

static inline int wasmtime_mariadb_sigwaitinfo(const sigset_t *set,
                                              siginfo_t *info) {
  (void)set;
  if (info != NULL) memset(info, 0, sizeof(*info));
  errno = ENOSYS;
  return -1;
}

#define sigemptyset wasmtime_mariadb_sigemptyset
#define sigfillset wasmtime_mariadb_sigfillset
#define sigaddset wasmtime_mariadb_sigaddset
#define sigdelset wasmtime_mariadb_sigdelset
#define sigismember wasmtime_mariadb_sigismember
#define sigprocmask wasmtime_mariadb_sigprocmask
#define pthread_sigmask wasmtime_mariadb_pthread_sigmask
#define sigwait wasmtime_mariadb_sigwait
#define sigwaitinfo wasmtime_mariadb_sigwaitinfo

static inline int fedisableexcept(int excepts) {
  (void)excepts;
  return 0;
}

typedef int (*wasmtime_mariadb_qsort_r_comparator)(const void *, const void *,
                                                  void *);

static wasmtime_mariadb_qsort_r_comparator
    wasmtime_mariadb_qsort_r_comparator_fn = NULL;
static void *wasmtime_mariadb_qsort_r_comparator_arg = NULL;

static int wasmtime_mariadb_qsort_r_adapter(const void *left,
                                           const void *right) {
  return wasmtime_mariadb_qsort_r_comparator_fn(
      left, right, wasmtime_mariadb_qsort_r_comparator_arg);
}

static inline void qsort_r(void *base, size_t nmemb, size_t size,
                           wasmtime_mariadb_qsort_r_comparator compar,
                           void *arg) {
  wasmtime_mariadb_qsort_r_comparator_fn = compar;
  wasmtime_mariadb_qsort_r_comparator_arg = arg;
  qsort(base, nmemb, size, wasmtime_mariadb_qsort_r_adapter);
  wasmtime_mariadb_qsort_r_comparator_fn = NULL;
  wasmtime_mariadb_qsort_r_comparator_arg = NULL;
}

static inline off_t tell(int fd) { return lseek(fd, 0, SEEK_CUR); }

static inline int wasmtime_mariadb_dup(int oldfd) {
  (void)oldfd;
  errno = ENOSYS;
  return -1;
}

static inline int wasmtime_mariadb_dup2(int oldfd, int newfd) {
  if (oldfd == newfd) return newfd;
  (void)oldfd;
  (void)newfd;
  errno = ENOSYS;
  return -1;
}

#define dup wasmtime_mariadb_dup
#define dup2 wasmtime_mariadb_dup2

static inline int wasmtime_mariadb_chmod(const char *path, mode_t mode) {
  (void)path;
  (void)mode;
  return 0;
}

static inline int wasmtime_mariadb_fchmod(int fd, mode_t mode) {
  (void)fd;
  (void)mode;
  return 0;
}

#define chmod wasmtime_mariadb_chmod
#define fchmod wasmtime_mariadb_fchmod

static inline int wasmtime_mariadb_pthread_kill(pthread_t thread, int signum) {
  (void)thread;
  (void)signum;
  return ENOSYS;
}

#define pthread_kill wasmtime_mariadb_pthread_kill

static inline int wasmtime_mariadb_pthread_attr_setscope(
    pthread_attr_t *attr, int scope) {
  (void)attr;
  (void)scope;
  return 0;
}

static inline int wasmtime_mariadb_pthread_setname_np(pthread_t thread,
                                                     const char *name) {
  (void)thread;
  (void)name;
  return 0;
}

static inline char *getpassphrase(const char *prompt) {
  static char empty_password[1] = {0};
  (void)prompt;
  return empty_password;
}

static inline char *getpass(const char *prompt) {
  return getpassphrase(prompt);
}

#define pthread_attr_setscope wasmtime_mariadb_pthread_attr_setscope
#define pthread_setname_np wasmtime_mariadb_pthread_setname_np

static inline int wasmtime_mariadb_msync(void *addr, size_t len, int flags) {
  (void)addr;
  (void)len;
  (void)flags;
  return 0;
}

static inline int wasmtime_mariadb_madvise(void *addr, size_t len, int advice) {
  (void)addr;
  (void)len;
  (void)advice;
  return 0;
}

static inline int lockf(int fd, int cmd, off_t len) {
  (void)fd;
  (void)cmd;
  (void)len;
  return 0;
}

static inline int kill(pid_t pid, int signum) {
  (void)pid;
  (void)signum;
  return 0;
}

static inline int pipe(int fds[2]) {
  (void)fds;
  errno = ENOSYS;
  return -1;
}

#define msync wasmtime_mariadb_msync
#define madvise wasmtime_mariadb_madvise

static inline uid_t wasmtime_mariadb_getuid(void) { return 1; }
static inline uid_t wasmtime_mariadb_geteuid(void) { return 1; }
static inline gid_t wasmtime_mariadb_getgid(void) { return 1; }
static inline gid_t wasmtime_mariadb_getegid(void) { return 1; }

static inline int wasmtime_mariadb_initgroups(const char *user, gid_t group) {
  (void)user;
  (void)group;
  errno = ENOSYS;
  return -1;
}

static inline int wasmtime_mariadb_setgid(gid_t group) {
  (void)group;
  errno = ENOSYS;
  return -1;
}

static inline int wasmtime_mariadb_setuid(uid_t user) {
  (void)user;
  errno = ENOSYS;
  return -1;
}

static inline int wasmtime_mariadb_setregid(gid_t real_group,
                                           gid_t effective_group) {
  (void)real_group;
  (void)effective_group;
  errno = ENOSYS;
  return -1;
}

static inline int wasmtime_mariadb_setreuid(uid_t real_user,
                                           uid_t effective_user) {
  (void)real_user;
  (void)effective_user;
  errno = ENOSYS;
  return -1;
}

static inline int wasmtime_mariadb_chroot(const char *path) {
  (void)path;
  errno = ENOSYS;
  return -1;
}

#define getuid wasmtime_mariadb_getuid
#define geteuid wasmtime_mariadb_geteuid
#define getgid wasmtime_mariadb_getgid
#define getegid wasmtime_mariadb_getegid
#define initgroups wasmtime_mariadb_initgroups
#define setgid wasmtime_mariadb_setgid
#define setuid wasmtime_mariadb_setuid
#define setregid wasmtime_mariadb_setregid
#define setreuid wasmtime_mariadb_setreuid
#define chroot wasmtime_mariadb_chroot

static char wasmtime_mariadb_tzname_utc[] = "UTC";
static char *tzname[2] = {wasmtime_mariadb_tzname_utc,
                          wasmtime_mariadb_tzname_utc};

static inline void tzset(void) {}

static inline mode_t wasmtime_mariadb_umask(mode_t mask) {
  (void)mask;
  return 0;
}

#define umask wasmtime_mariadb_umask

static inline void *wasmtime_mariadb_memalign(size_t alignment, size_t size) {
  void *ptr = NULL;
  if (posix_memalign(&ptr, alignment, size) != 0) return NULL;
  return ptr;
}

#define memalign wasmtime_mariadb_memalign

static inline int wasmtime_mariadb_pthread_cancel(pthread_t thread) {
  (void)thread;
  return ENOSYS;
}

#if defined(__GNUC__)
#define MARIADB_WASI_NORETURN __attribute__((__noreturn__))
#else
#define MARIADB_WASI_NORETURN
#endif

static inline MARIADB_WASI_NORETURN void wasmtime_mariadb_pthread_exit(
    void *value_ptr) {
  (void)value_ptr;
  abort();
}

#undef MARIADB_WASI_NORETURN

#define pthread_cancel wasmtime_mariadb_pthread_cancel
#define pthread_exit wasmtime_mariadb_pthread_exit

static inline int wasmtime_mariadb_chown(const char *path, uid_t owner,
                                        gid_t group) {
  (void)path;
  (void)owner;
  (void)group;
  return 0;
}

#define chown wasmtime_mariadb_chown

static inline int wasmtime_mariadb_mkstemp(char *pattern) {
  static const char alphabet[] = "abcdefghijklmnopqrstuvwxyz0123456789";
  size_t len = strlen(pattern);
  if (len < 6 || strcmp(pattern + len - 6, "XXXXXX") != 0) {
    errno = EINVAL;
    return -1;
  }

  for (unsigned attempt = 0; attempt < 36 * 36 * 36; ++attempt) {
    unsigned value = attempt;
    for (size_t i = 0; i < 6; ++i) {
      pattern[len - 1 - i] = alphabet[value % 36];
      value /= 36;
    }

    int fd = open(pattern, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd >= 0) return fd;
    if (errno != EEXIST) return -1;
  }

  errno = EEXIST;
  return -1;
}

#define mkstemp wasmtime_mariadb_mkstemp

#endif /* __wasi__ */

#endif /* MARIADB_WASI_LIBC_SHIM_H */
