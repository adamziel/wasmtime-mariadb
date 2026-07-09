#ifndef MYSQL_WASI_SYS_RESOURCE_H
#define MYSQL_WASI_SYS_RESOURCE_H

#if defined(__wasi__)

#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <sys/time.h>
#include <sys/types.h>

typedef unsigned long long rlim_t;

struct rlimit {
  rlim_t rlim_cur;
  rlim_t rlim_max;
};

struct rusage {
  struct timeval ru_utime;
  struct timeval ru_stime;
  long ru_maxrss;
  long ru_ixrss;
  long ru_idrss;
  long ru_isrss;
  long ru_minflt;
  long ru_majflt;
  long ru_nswap;
  long ru_inblock;
  long ru_oublock;
  long ru_msgsnd;
  long ru_msgrcv;
  long ru_nsignals;
  long ru_nvcsw;
  long ru_nivcsw;
};

#define RUSAGE_SELF 0
#define RUSAGE_CHILDREN (-1)
#define RUSAGE_THREAD 1

#define RLIM_INFINITY (~0ULL)
#define RLIM_SAVED_CUR RLIM_INFINITY
#define RLIM_SAVED_MAX RLIM_INFINITY

#define RLIMIT_CPU 0
#define RLIMIT_FSIZE 1
#define RLIMIT_DATA 2
#define RLIMIT_STACK 3
#define RLIMIT_CORE 4
#define RLIMIT_RSS 5
#define RLIMIT_NPROC 6
#define RLIMIT_NOFILE 7
#define RLIMIT_MEMLOCK 8
#define RLIMIT_AS 9
#define RLIMIT_LOCKS 10
#define RLIMIT_SIGPENDING 11
#define RLIMIT_MSGQUEUE 12
#define RLIMIT_NICE 13
#define RLIMIT_RTPRIO 14
#define RLIMIT_RTTIME 15
#define RLIMIT_NLIMITS 16

static inline int getrlimit(int resource, struct rlimit *limit) {
  if (resource != RLIMIT_NOFILE || limit == NULL) {
    errno = EINVAL;
    return -1;
  }
  limit->rlim_cur = 65535;
  limit->rlim_max = 65535;
  return 0;
}

static inline int setrlimit(int resource, const struct rlimit *limit) {
  (void)limit;
  if (resource != RLIMIT_NOFILE) {
    errno = EINVAL;
    return -1;
  }
  return 0;
}

static inline int getrusage(int who, struct rusage *usage) {
  if ((who != RUSAGE_SELF && who != RUSAGE_THREAD) || usage == NULL) {
    errno = EINVAL;
    return -1;
  }
  memset(usage, 0, sizeof(*usage));
  return 0;
}

#else
#include_next <sys/resource.h>
#endif

#endif /* MYSQL_WASI_SYS_RESOURCE_H */
