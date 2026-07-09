#include "mariadb_wasi_socket_shim.h"

#if defined(__wasi__)

#include "netdb.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("socket")))
int32_t wasmtime_mariadb_host_socket(int32_t domain, int32_t type,
                                    int32_t protocol);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("bind")))
int32_t wasmtime_mariadb_host_bind(int32_t fd, const void *addr,
                                  int32_t addr_len);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("listen")))
int32_t wasmtime_mariadb_host_listen(int32_t fd, int32_t backlog);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("accept")))
int32_t wasmtime_mariadb_host_accept(int32_t fd, void *addr,
                                    uint32_t *addr_len);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("connect")))
int32_t wasmtime_mariadb_host_connect(int32_t fd, const void *addr,
                                     int32_t addr_len);
__attribute__((
    import_module("wasmtime_mariadb_sockets"), import_name("getsockname")))
int32_t wasmtime_mariadb_host_getsockname(int32_t fd, void *addr,
                                         uint32_t *addr_len);
__attribute__((
    import_module("wasmtime_mariadb_sockets"), import_name("getpeername")))
int32_t wasmtime_mariadb_host_getpeername(int32_t fd, void *addr,
                                         uint32_t *addr_len);
__attribute__((
    import_module("wasmtime_mariadb_sockets"), import_name("setsockopt")))
int32_t wasmtime_mariadb_host_setsockopt(int32_t fd, int32_t level,
                                        int32_t optname, const void *optval,
                                        int32_t optlen);
__attribute__((
    import_module("wasmtime_mariadb_sockets"), import_name("getsockopt")))
int32_t wasmtime_mariadb_host_getsockopt(int32_t fd, int32_t level,
                                        int32_t optname, void *optval,
                                        uint32_t *optlen);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("send")))
int32_t wasmtime_mariadb_host_send(int32_t fd, const void *buf, int32_t len,
                                  int32_t flags);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("recv")))
int32_t wasmtime_mariadb_host_recv(int32_t fd, void *buf, int32_t len,
                                  int32_t flags);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("sendto")))
int32_t wasmtime_mariadb_host_sendto(int32_t fd, const void *buf, int32_t len,
                                    int32_t flags, const void *addr,
                                    int32_t addr_len);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("recvfrom")))
int32_t wasmtime_mariadb_host_recvfrom(int32_t fd, void *buf, int32_t len,
                                      int32_t flags, void *addr,
                                      uint32_t *addr_len);
__attribute__((
    import_module("wasmtime_mariadb_sockets"), import_name("shutdown")))
int32_t wasmtime_mariadb_host_shutdown(int32_t fd, int32_t how);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("close")))
int32_t wasmtime_mariadb_host_close(int32_t fd);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("fcntl")))
int32_t wasmtime_mariadb_host_fcntl(int32_t fd, int32_t cmd, int32_t arg);
__attribute__((import_module("wasmtime_mariadb_sockets"), import_name("poll")))
int32_t wasmtime_mariadb_host_poll(struct pollfd *fds, int32_t nfds,
                                  int32_t timeout);

static int decode_i32(int32_t rc) {
  if (rc < 0) {
    errno = -rc;
    return -1;
  }
  return rc;
}

static ssize_t decode_ssize(int32_t rc) {
  if (rc < 0) {
    errno = -rc;
    return -1;
  }
  return (ssize_t)rc;
}

static int checked_size_to_i32(size_t value, int32_t *out) {
  if (value > INT32_MAX) {
    errno = EINVAL;
    return -1;
  }
  *out = (int32_t)value;
  return 0;
}

static int checked_socklen_to_i32(socklen_t value, int32_t *out) {
  if (value > INT32_MAX) {
    errno = EINVAL;
    return -1;
  }
  *out = (int32_t)value;
  return 0;
}

int wasmtime_mariadb_socket(int domain, int type, int protocol) {
  return decode_i32(wasmtime_mariadb_host_socket(domain, type, protocol));
}

int wasmtime_mariadb_bind(int fd, const struct sockaddr *addr, socklen_t len) {
  int32_t checked_len;
  if (checked_socklen_to_i32(len, &checked_len) != 0) return -1;
  return decode_i32(wasmtime_mariadb_host_bind(fd, addr, checked_len));
}

int wasmtime_mariadb_listen(int fd, int backlog) {
  return decode_i32(wasmtime_mariadb_host_listen(fd, backlog));
}

int wasmtime_mariadb_accept(int fd, struct sockaddr *addr, socklen_t *addr_len) {
  return decode_i32(
      wasmtime_mariadb_host_accept(fd, addr, (uint32_t *)addr_len));
}

int wasmtime_mariadb_connect(int fd, const struct sockaddr *addr,
                            socklen_t len) {
  int32_t checked_len;
  if (checked_socklen_to_i32(len, &checked_len) != 0) return -1;
  return decode_i32(wasmtime_mariadb_host_connect(fd, addr, checked_len));
}

int wasmtime_mariadb_getsockname(int fd, struct sockaddr *addr,
                                socklen_t *addr_len) {
  return decode_i32(
      wasmtime_mariadb_host_getsockname(fd, addr, (uint32_t *)addr_len));
}

int wasmtime_mariadb_getpeername(int fd, struct sockaddr *addr,
                                socklen_t *addr_len) {
  return decode_i32(
      wasmtime_mariadb_host_getpeername(fd, addr, (uint32_t *)addr_len));
}

int wasmtime_mariadb_setsockopt(int fd, int level, int optname,
                               const void *optval, socklen_t optlen) {
  int32_t checked_len;
  if (checked_socklen_to_i32(optlen, &checked_len) != 0) return -1;
  return decode_i32(wasmtime_mariadb_host_setsockopt(fd, level, optname, optval,
                                                    checked_len));
}

int wasmtime_mariadb_getsockopt(int fd, int level, int optname, void *optval,
                               socklen_t *optlen) {
  return decode_i32(wasmtime_mariadb_host_getsockopt(
      fd, level, optname, optval, (uint32_t *)optlen));
}

ssize_t wasmtime_mariadb_send(int fd, const void *buf, size_t len, int flags) {
  int32_t checked_len;
  if (checked_size_to_i32(len, &checked_len) != 0) return -1;
  return decode_ssize(wasmtime_mariadb_host_send(fd, buf, checked_len, flags));
}

ssize_t wasmtime_mariadb_recv(int fd, void *buf, size_t len, int flags) {
  int32_t checked_len;
  if (checked_size_to_i32(len, &checked_len) != 0) return -1;
  return decode_ssize(wasmtime_mariadb_host_recv(fd, buf, checked_len, flags));
}

ssize_t wasmtime_mariadb_sendto(int fd, const void *buf, size_t len, int flags,
                               const struct sockaddr *addr,
                               socklen_t addr_len) {
  int32_t checked_len;
  int32_t checked_addr_len;
  if (checked_size_to_i32(len, &checked_len) != 0) return -1;
  if (checked_socklen_to_i32(addr_len, &checked_addr_len) != 0) return -1;
  return decode_ssize(wasmtime_mariadb_host_sendto(
      fd, buf, checked_len, flags, addr, checked_addr_len));
}

ssize_t wasmtime_mariadb_recvfrom(int fd, void *buf, size_t len, int flags,
                                 struct sockaddr *addr, socklen_t *addr_len) {
  int32_t checked_len;
  if (checked_size_to_i32(len, &checked_len) != 0) return -1;
  return decode_ssize(wasmtime_mariadb_host_recvfrom(
      fd, buf, checked_len, flags, addr, (uint32_t *)addr_len));
}

int wasmtime_mariadb_shutdown(int fd, int how) {
  return decode_i32(wasmtime_mariadb_host_shutdown(fd, how));
}

int wasmtime_mariadb_close(int fd) {
  return decode_i32(wasmtime_mariadb_host_close(fd));
}

int wasmtime_mariadb_fcntl(int fd, int cmd, ...) {
  int arg = 0;
  if (cmd != F_GETFL) {
    va_list ap;
    va_start(ap, cmd);
    arg = va_arg(ap, int);
    va_end(ap);
  }
  return decode_i32(wasmtime_mariadb_host_fcntl(fd, cmd, arg));
}

int wasmtime_mariadb_poll(struct pollfd *fds, nfds_t nfds, int timeout) {
  if (nfds > INT32_MAX) {
    errno = EINVAL;
    return -1;
  }
  return decode_i32(wasmtime_mariadb_host_poll(fds, (int32_t)nfds, timeout));
}

int wasmtime_mariadb_ppoll(struct pollfd *fds, nfds_t nfds,
                          const struct timespec *timeout,
                          const void *sigmask) {
  (void)sigmask;
  int timeout_ms = -1;
  if (timeout != NULL) {
    if (timeout->tv_sec > (INT_MAX / 1000)) {
      errno = EINVAL;
      return -1;
    }
    timeout_ms = (int)(timeout->tv_sec * 1000);
    timeout_ms += (int)(timeout->tv_nsec / 1000000);
  }
  return wasmtime_mariadb_poll(fds, nfds, timeout_ms);
}

static char *dup_cstr(const char *value) {
  if (value == NULL) return NULL;
  size_t len = strlen(value) + 1;
  char *copy = malloc(len);
  if (copy == NULL) return NULL;
  memcpy(copy, value, len);
  return copy;
}

static int parse_service_port(const char *service, in_port_t *port) {
  char *end = NULL;
  unsigned long parsed = 0;
  if (service == NULL || *service == '\0') {
    *port = 0;
    return 0;
  }
  parsed = strtoul(service, &end, 10);
  if (*end != '\0' || parsed > 65535) return EAI_NONAME;
  *port = htons((in_port_t)parsed);
  return 0;
}

static int alloc_addrinfo(int family, int socktype, int protocol,
                          socklen_t addrlen, struct addrinfo **out) {
  struct addrinfo *ai = calloc(1, sizeof(*ai));
  if (ai == NULL) return EAI_MEMORY;
  ai->ai_addr = calloc(1, addrlen);
  if (ai->ai_addr == NULL) {
    free(ai);
    return EAI_MEMORY;
  }
  ai->ai_family = family;
  ai->ai_socktype = socktype;
  ai->ai_protocol = protocol;
  ai->ai_addrlen = addrlen;
  *out = ai;
  return 0;
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res) {
  int family = hints != NULL ? hints->ai_family : AF_UNSPEC;
  int socktype = hints != NULL ? hints->ai_socktype : SOCK_STREAM;
  int protocol = hints != NULL ? hints->ai_protocol : 0;
  int passive = hints != NULL && (hints->ai_flags & AI_PASSIVE);
  int rc = 0;
  in_port_t port = 0;

  if (res == NULL) return EAI_FAIL;
  *res = NULL;
  rc = parse_service_port(service, &port);
  if (rc != 0) return rc;

  if (socktype == 0) socktype = SOCK_STREAM;

  if (family == AF_UNSPEC) {
    family = (node != NULL && strchr(node, ':') != NULL) ? AF_INET6 : AF_INET;
  }

  if (family == AF_INET) {
    struct addrinfo *ai = NULL;
    struct sockaddr_in *addr = NULL;
    rc = alloc_addrinfo(AF_INET, socktype, protocol, sizeof(*addr), &ai);
    if (rc != 0) return rc;
    addr = (struct sockaddr_in *)ai->ai_addr;
    addr->sin_family = AF_INET;
    addr->sin_port = port;
    if (node == NULL || node[0] == '\0' || strcmp(node, "*") == 0) {
      addr->sin_addr.s_addr = passive ? htonl(INADDR_ANY) : htonl(INADDR_LOOPBACK);
    } else if (strcmp(node, "localhost") == 0) {
      addr->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    } else if (inet_pton(AF_INET, node, &addr->sin_addr) != 1) {
      freeaddrinfo(ai);
      return EAI_NONAME;
    }
    if (hints != NULL && (hints->ai_flags & AI_CANONNAME)) {
      ai->ai_canonname = dup_cstr(node != NULL ? node : "");
      if (ai->ai_canonname == NULL) {
        freeaddrinfo(ai);
        return EAI_MEMORY;
      }
    }
    *res = ai;
    return 0;
  }

  if (family == AF_INET6) {
    struct addrinfo *ai = NULL;
    struct sockaddr_in6 *addr = NULL;
    rc = alloc_addrinfo(AF_INET6, socktype, protocol, sizeof(*addr), &ai);
    if (rc != 0) return rc;
    addr = (struct sockaddr_in6 *)ai->ai_addr;
    addr->sin6_family = AF_INET6;
    addr->sin6_port = port;
    if (node == NULL || node[0] == '\0' || strcmp(node, "*") == 0) {
      addr->sin6_addr = passive ? in6addr_any : in6addr_loopback;
    } else if (strcmp(node, "localhost") == 0) {
      addr->sin6_addr = in6addr_loopback;
    } else if (inet_pton(AF_INET6, node, &addr->sin6_addr) != 1) {
      freeaddrinfo(ai);
      return EAI_NONAME;
    }
    if (hints != NULL && (hints->ai_flags & AI_CANONNAME)) {
      ai->ai_canonname = dup_cstr(node != NULL ? node : "");
      if (ai->ai_canonname == NULL) {
        freeaddrinfo(ai);
        return EAI_MEMORY;
      }
    }
    *res = ai;
    return 0;
  }

  return EAI_FAMILY;
}

void freeaddrinfo(struct addrinfo *res) {
  while (res != NULL) {
    struct addrinfo *next = res->ai_next;
    free(res->ai_addr);
    free(res->ai_canonname);
    free(res);
    res = next;
  }
}

const char *gai_strerror(int errcode) {
  switch (errcode) {
    case 0:
      return "success";
    case EAI_BADFLAGS:
      return "bad flags";
    case EAI_NONAME:
      return "name does not resolve";
    case EAI_AGAIN:
      return "temporary resolver failure";
    case EAI_FAIL:
      return "resolver failure";
    case EAI_FAMILY:
      return "address family unsupported";
    case EAI_SOCKTYPE:
      return "socket type unsupported";
    case EAI_MEMORY:
      return "out of memory";
    case EAI_SYSTEM:
      return "system error";
    case EAI_OVERFLOW:
      return "buffer overflow";
    default:
      return "resolver error";
  }
}

int getnameinfo(const struct sockaddr *sa, socklen_t salen, char *host,
                socklen_t hostlen, char *serv, socklen_t servlen, int flags) {
  (void)salen;
  if ((flags & NI_NAMEREQD) != 0) return EAI_NONAME;

  if (sa->sa_family == AF_INET) {
    const struct sockaddr_in *addr = (const struct sockaddr_in *)sa;
    if (host != NULL && hostlen > 0 &&
        inet_ntop(AF_INET, &addr->sin_addr, host, hostlen) == NULL) {
      return EAI_OVERFLOW;
    }
    if (serv != NULL && servlen > 0 &&
        snprintf(serv, servlen, "%u", (unsigned)ntohs(addr->sin_port)) >=
            (int)servlen) {
      return EAI_OVERFLOW;
    }
    return 0;
  }

  if (sa->sa_family == AF_INET6) {
    const struct sockaddr_in6 *addr = (const struct sockaddr_in6 *)sa;
    if (host != NULL && hostlen > 0 &&
        inet_ntop(AF_INET6, &addr->sin6_addr, host, hostlen) == NULL) {
      return EAI_OVERFLOW;
    }
    if (serv != NULL && servlen > 0 &&
        snprintf(serv, servlen, "%u", (unsigned)ntohs(addr->sin6_port)) >=
            (int)servlen) {
      return EAI_OVERFLOW;
    }
    return 0;
  }

  return EAI_FAMILY;
}

#endif /* __wasi__ */
