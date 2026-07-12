//! Windows implementation of MariaDB's small POSIX-style socket import ABI.
//!
//! MariaDB's Wasm module carries Unix/WASI socket constants and sockaddr bytes.
//! Winsock has different constants and a `SOCKET` handle type, so this module
//! translates at the host boundary while keeping guest descriptors stable
//! across Wasmtime stores and guest pthreads.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use wasmtime::{Caller, Linker, Result};
use windows_sys::Win32::Networking::WinSock as ws;

use crate::{
    AppState,
    guest_abi::{self, neg_errno},
};

const MODULE_NAME: &str = "wasmtime_mariadb_sockets";
const GUEST_FD_BASE: i32 = 10_000;
const MAX_POLL_FDS: usize = 16_384;

const GUEST_AF_INET_ALT: i32 = 1;
const GUEST_AF_INET: i32 = 2;
const GUEST_AF_INET6: i32 = 10;
const GUEST_SOCK_STREAM: i32 = 1;
const GUEST_SOCK_DGRAM: i32 = 2;
const GUEST_SOCK_STREAM_ALT: i32 = 6;
const GUEST_SOCK_DGRAM_ALT: i32 = 5;
const GUEST_SOCK_CLOEXEC_ALT: i32 = 0x2000;
const GUEST_SOCK_NONBLOCK_ALT: i32 = 0x4000;
const GUEST_F_GETFD: i32 = 1;
const GUEST_F_SETFD: i32 = 2;
const GUEST_F_GETFL: i32 = 3;
const GUEST_F_SETFL: i32 = 4;
const GUEST_O_NONBLOCK: i32 = 1;
const GUEST_O_NONBLOCK_POSIX: i32 = 0o4000;
const GUEST_TIMEVAL_BYTES: usize = 8;
const GUEST_LINGER_BYTES: usize = 8;

const GUEST_POLLIN: i16 = 0x0001;
const GUEST_POLLOUT: i16 = 0x0004;
const GUEST_POLLERR: i16 = 0x0008;
const GUEST_POLLHUP: i16 = 0x0010;
const GUEST_POLLNVAL: i16 = 0x0020;

/// A guest-visible socket table shared by the primary instance and pthread stores.
#[derive(Clone)]
pub(crate) struct HostSockets {
    inner: Arc<Mutex<HostSocketsInner>>,
}

struct HostSocketsInner {
    next_fd: i32,
    sockets: HashMap<i32, HostSocket>,
}

#[derive(Clone, Copy)]
struct HostSocket {
    raw_socket: ws::SOCKET,
    guest_domain: i32,
    host_domain: i32,
    nonblocking: bool,
}

#[derive(Clone, Copy)]
struct NormalizedSocketType {
    ty: i32,
    close_on_exec: bool,
    nonblocking: bool,
}

enum NameKind {
    Local,
    Peer,
}

impl HostSockets {
    /// Creates an initially empty shared socket descriptor registry.
    pub(crate) fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(HostSocketsInner {
                next_fd: GUEST_FD_BASE,
                sockets: HashMap::new(),
            })),
        }
    }

    /// Inserts a Winsock handle under the next stable guest descriptor.
    fn insert(
        &self,
        raw_socket: ws::SOCKET,
        guest_domain: i32,
        host_domain: i32,
        nonblocking: bool,
    ) -> i32 {
        let mut inner = self.inner.lock().unwrap();
        let guest_fd = inner.next_fd;
        inner.next_fd = inner.next_fd.saturating_add(1);
        inner.sockets.insert(
            guest_fd,
            HostSocket {
                raw_socket,
                guest_domain,
                host_domain,
                nonblocking,
            },
        );
        guest_fd
    }

    /// Looks up a guest descriptor without transferring ownership of its handle.
    fn get(&self, guest_fd: i32) -> std::result::Result<HostSocket, i32> {
        let inner = self.inner.lock().unwrap();
        inner.sockets.get(&guest_fd).copied().ok_or(libc::EBADF)
    }

    /// Removes a guest descriptor so the caller can close its Winsock handle.
    fn remove(&self, guest_fd: i32) -> std::result::Result<HostSocket, i32> {
        let mut inner = self.inner.lock().unwrap();
        inner.sockets.remove(&guest_fd).ok_or(libc::EBADF)
    }

    /// Updates the emulated fcntl nonblocking state after `ioctlsocket` succeeds.
    fn set_nonblocking(&self, guest_fd: i32, enabled: bool) -> std::result::Result<(), i32> {
        let mut inner = self.inner.lock().unwrap();
        let socket = inner.sockets.get_mut(&guest_fd).ok_or(libc::EBADF)?;
        socket.nonblocking = enabled;
        Ok(())
    }

    /// Produces diagnostics without leaking host socket handles into the guest ABI.
    fn guest_fds(&self) -> Vec<i32> {
        let inner = self.inner.lock().unwrap();
        let mut fds = inner.sockets.keys().copied().collect::<Vec<_>>();
        fds.sort_unstable();
        fds
    }
}

impl Drop for HostSocketsInner {
    fn drop(&mut self) {
        for socket in self.sockets.values() {
            unsafe {
                ws::closesocket(socket.raw_socket);
            }
        }
    }
}

/// Registers every custom socket import expected by the MariaDB Wasm module.
pub(crate) fn add_to_linker(linker: &mut Linker<AppState>) -> Result<()> {
    linker.func_wrap(
        MODULE_NAME,
        "socket",
        |mut caller: Caller<'_, AppState>, domain: i32, ty: i32, protocol: i32| -> i32 {
            if !caller.data().network_allowed {
                return neg_errno(libc::ENETDOWN);
            }
            if let Err(errno) = ensure_winsock() {
                return neg_errno(errno);
            }
            let host_domain = normalize_socket_domain(domain);
            let socket_type = match normalize_socket_type(ty) {
                Ok(socket_type) => socket_type,
                Err(errno) => return neg_errno(errno),
            };
            let raw_socket = unsafe { ws::socket(host_domain, socket_type.ty, protocol) };
            if raw_socket == ws::INVALID_SOCKET {
                return neg_last_socket_error();
            }
            if let Err(errno) = configure_socket_type_flags(raw_socket, socket_type) {
                unsafe {
                    ws::closesocket(raw_socket);
                }
                return neg_errno(errno);
            }
            let guest_fd = caller.data_mut().sockets.insert(
                raw_socket,
                domain,
                host_domain,
                socket_type.nonblocking,
            );
            socket_trace(format_args!(
                "socket domain={domain} type={ty} protocol={protocol} -> guest_fd={guest_fd} raw_socket={raw_socket}"
            ));
            guest_fd
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "bind",
        |mut caller: Caller<'_, AppState>, fd: i32, addr_ptr: i32, addr_len: i32| -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => {
                    socket_trace(format_args!(
                        "bind bad guest_fd={fd} known={:?}",
                        caller.data().sockets.guest_fds()
                    ));
                    return neg_errno(errno);
                }
            };
            let addr = match read_guest_socket_address(
                &mut caller,
                addr_ptr,
                addr_len,
                socket.host_domain,
            ) {
                Ok(addr) => addr,
                Err(errno) => return neg_errno(errno),
            };
            let rc = socket_bind(socket.raw_socket, &addr);
            socket_trace(format_args!(
                "bind guest_fd={fd} raw_socket={} addr_len={addr_len} -> {rc}",
                socket.raw_socket
            ));
            rc
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "listen",
        |caller: Caller<'_, AppState>, fd: i32, backlog: i32| -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => {
                    socket_trace(format_args!(
                        "listen bad guest_fd={fd} known={:?}",
                        caller.data().sockets.guest_fds()
                    ));
                    return neg_errno(errno);
                }
            };
            let rc = socket_listen(socket.raw_socket, backlog);
            socket_trace(format_args!(
                "listen guest_fd={fd} raw_socket={} backlog={backlog} -> {rc}",
                socket.raw_socket
            ));
            rc
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "accept",
        |mut caller: Caller<'_, AppState>, fd: i32, addr_ptr: i32, addr_len_ptr: i32| -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => {
                    socket_trace(format_args!(
                        "accept bad guest_fd={fd} known={:?}",
                        caller.data().sockets.guest_fds()
                    ));
                    return neg_errno(errno);
                }
            };
            let (mut addr, mut addr_len) = match read_guest_output_buffer(&mut caller, addr_len_ptr)
            {
                Ok(address) => address,
                Err(errno) => return neg_errno(errno),
            };
            let accepted = unsafe {
                ws::accept(
                    socket.raw_socket,
                    addr.as_mut_ptr().cast::<ws::SOCKADDR>(),
                    &mut addr_len,
                )
            };
            if accepted == ws::INVALID_SOCKET {
                let errno = last_socket_errno();
                socket_trace(format_args!(
                    "accept guest_fd={fd} raw_socket={} -> errno={errno}",
                    socket.raw_socket
                ));
                return neg_errno(errno);
            }
            if socket.nonblocking {
                if let Err(errno) = set_socket_nonblocking(accepted, true) {
                    unsafe {
                        ws::closesocket(accepted);
                    }
                    return neg_errno(errno);
                }
            }
            if let Err(errno) = write_guest_socket_address(
                &mut caller,
                addr_ptr,
                addr_len_ptr,
                &mut addr,
                addr_len,
                socket.guest_domain,
            ) {
                unsafe {
                    ws::closesocket(accepted);
                }
                return neg_errno(errno);
            }
            let guest_fd = caller.data_mut().sockets.insert(
                accepted,
                socket.guest_domain,
                socket.host_domain,
                socket.nonblocking,
            );
            socket_trace(format_args!(
                "accept guest_fd={fd} raw_socket={} -> guest_fd={guest_fd} raw_socket={accepted}",
                socket.raw_socket
            ));
            guest_fd
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "connect",
        |mut caller: Caller<'_, AppState>, fd: i32, addr_ptr: i32, addr_len: i32| -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => return neg_errno(errno),
            };
            let addr = match read_guest_socket_address(
                &mut caller,
                addr_ptr,
                addr_len,
                socket.host_domain,
            ) {
                Ok(addr) => addr,
                Err(errno) => return neg_errno(errno),
            };
            socket_connect(socket.raw_socket, &addr)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "getsockname",
        |caller: Caller<'_, AppState>, fd: i32, addr_ptr: i32, addr_len_ptr: i32| -> i32 {
            sock_name(caller, fd, addr_ptr, addr_len_ptr, NameKind::Local)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "getpeername",
        |caller: Caller<'_, AppState>, fd: i32, addr_ptr: i32, addr_len_ptr: i32| -> i32 {
            sock_name(caller, fd, addr_ptr, addr_len_ptr, NameKind::Peer)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "setsockopt",
        |mut caller: Caller<'_, AppState>,
         fd: i32,
         level: i32,
         optname: i32,
         optval_ptr: i32,
         optlen: i32|
         -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => return neg_errno(errno),
            };
            let optval = match guest_abi::read(&mut caller, optval_ptr, optlen) {
                Ok(optval) => optval,
                Err(errno) => return neg_errno(errno),
            };
            socket_setsockopt(socket.raw_socket, level, optname, &optval)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "getsockopt",
        |mut caller: Caller<'_, AppState>,
         fd: i32,
         level: i32,
         optname: i32,
         optval_ptr: i32,
         optlen_ptr: i32|
         -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => return neg_errno(errno),
            };
            let (mut optval, mut optlen) = match read_guest_output_buffer(&mut caller, optlen_ptr) {
                Ok(buffer) => buffer,
                Err(errno) => return neg_errno(errno),
            };
            let rc = socket_getsockopt(socket.raw_socket, level, optname, &mut optval, &mut optlen);
            if rc < 0 {
                return rc;
            }
            match write_guest_buffer_and_len(&mut caller, optval_ptr, optlen_ptr, &optval, optlen) {
                Ok(()) => 0,
                Err(errno) => neg_errno(errno),
            }
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "send",
        |mut caller: Caller<'_, AppState>, fd: i32, buf_ptr: i32, len: i32, flags: i32| -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => return neg_errno(errno),
            };
            let buf = match guest_abi::read(&mut caller, buf_ptr, len) {
                Ok(buf) => buf,
                Err(errno) => return neg_errno(errno),
            };
            socket_send(socket.raw_socket, &buf, flags)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "recv",
        |mut caller: Caller<'_, AppState>, fd: i32, buf_ptr: i32, len: i32, flags: i32| -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => return neg_errno(errno),
            };
            let len = match guest_abi::checked_len(len) {
                Ok(len) => len,
                Err(errno) => return neg_errno(errno),
            };
            let mut buf = vec![0_u8; len];
            let rc = socket_recv(socket.raw_socket, &mut buf, flags);
            if rc < 0 {
                return rc;
            }
            match guest_abi::write(&mut caller, buf_ptr, &buf[..rc as usize]) {
                Ok(()) => rc,
                Err(errno) => neg_errno(errno),
            }
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "sendto",
        |mut caller: Caller<'_, AppState>,
         fd: i32,
         buf_ptr: i32,
         len: i32,
         flags: i32,
         addr_ptr: i32,
         addr_len: i32|
         -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => return neg_errno(errno),
            };
            let buf = match guest_abi::read(&mut caller, buf_ptr, len) {
                Ok(buf) => buf,
                Err(errno) => return neg_errno(errno),
            };
            let addr = match read_guest_socket_address(
                &mut caller,
                addr_ptr,
                addr_len,
                socket.host_domain,
            ) {
                Ok(addr) => addr,
                Err(errno) => return neg_errno(errno),
            };
            socket_sendto(socket.raw_socket, &buf, flags, &addr)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "recvfrom",
        |mut caller: Caller<'_, AppState>,
         fd: i32,
         buf_ptr: i32,
         len: i32,
         flags: i32,
         addr_ptr: i32,
         addr_len_ptr: i32|
         -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => return neg_errno(errno),
            };
            let len = match guest_abi::checked_len(len) {
                Ok(len) => len,
                Err(errno) => return neg_errno(errno),
            };
            let (mut addr, mut addr_len) = match read_guest_output_buffer(&mut caller, addr_len_ptr)
            {
                Ok(address) => address,
                Err(errno) => return neg_errno(errno),
            };
            let mut buf = vec![0_u8; len];
            let rc = socket_recvfrom(socket.raw_socket, &mut buf, flags, &mut addr, &mut addr_len);
            if rc < 0 {
                return rc;
            }
            if let Err(errno) = guest_abi::write(&mut caller, buf_ptr, &buf[..rc as usize]) {
                return neg_errno(errno);
            }
            match write_guest_socket_address(
                &mut caller,
                addr_ptr,
                addr_len_ptr,
                &mut addr,
                addr_len,
                socket.guest_domain,
            ) {
                Ok(()) => rc,
                Err(errno) => neg_errno(errno),
            }
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "shutdown",
        |caller: Caller<'_, AppState>, fd: i32, how: i32| -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => return neg_errno(errno),
            };
            socket_shutdown(socket.raw_socket, how)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "close",
        |mut caller: Caller<'_, AppState>, fd: i32| -> i32 {
            let socket = match caller.data_mut().sockets.remove(fd) {
                Ok(socket) => socket,
                Err(errno) => {
                    socket_trace(format_args!(
                        "close bad guest_fd={fd} known={:?}",
                        caller.data().sockets.guest_fds()
                    ));
                    return neg_errno(errno);
                }
            };
            socket_close(socket.raw_socket)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "fcntl",
        |caller: Caller<'_, AppState>, fd: i32, cmd: i32, arg: i32| -> i32 {
            let socket = match caller.data().sockets.get(fd) {
                Ok(socket) => socket,
                Err(errno) => return neg_errno(errno),
            };
            match cmd {
                GUEST_F_GETFL => {
                    if socket.nonblocking {
                        GUEST_O_NONBLOCK_POSIX
                    } else {
                        0
                    }
                }
                GUEST_F_SETFL => {
                    let enabled = arg & (GUEST_O_NONBLOCK | GUEST_O_NONBLOCK_POSIX) != 0;
                    if let Err(errno) = set_socket_nonblocking(socket.raw_socket, enabled) {
                        return neg_errno(errno);
                    }
                    match caller.data().sockets.set_nonblocking(fd, enabled) {
                        Ok(()) => 0,
                        Err(errno) => neg_errno(errno),
                    }
                }
                GUEST_F_GETFD | GUEST_F_SETFD => 0,
                _ => neg_errno(libc::EOPNOTSUPP),
            }
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "poll",
        |mut caller: Caller<'_, AppState>, fds_ptr: i32, nfds: i32, timeout: i32| -> i32 {
            let nfds = match checked_poll_count(nfds) {
                Ok(nfds) => nfds,
                Err(errno) => return neg_errno(errno),
            };
            let bytes = match guest_abi::read(&mut caller, fds_ptr, (nfds * 8) as i32) {
                Ok(bytes) => bytes,
                Err(errno) => return neg_errno(errno),
            };
            let mut host_fds = Vec::with_capacity(nfds);
            let mut host_indexes = Vec::with_capacity(nfds);
            for (index, chunk) in bytes.chunks_exact(8).enumerate() {
                let guest_fd = i32::from_le_bytes(chunk[0..4].try_into().unwrap());
                if guest_fd < 0 {
                    // POSIX defines negative entries as ignored. MariaDB uses
                    // this to temporarily disable an entry in a poll array.
                    if let Err(errno) = guest_abi::write(
                        &mut caller,
                        fds_ptr + (index as i32 * 8) + 6,
                        &0_i16.to_le_bytes(),
                    ) {
                        return neg_errno(errno);
                    }
                    continue;
                }
                let events = i16::from_le_bytes(chunk[4..6].try_into().unwrap());
                let socket = match caller.data().sockets.get(guest_fd) {
                    Ok(socket) => socket,
                    Err(errno) => {
                        socket_trace(format_args!(
                            "poll bad guest_fd={guest_fd} known={:?}",
                            caller.data().sockets.guest_fds()
                        ));
                        return neg_errno(errno);
                    }
                };
                socket_trace(format_args!(
                    "poll fd guest_fd={guest_fd} raw_socket={} events={events}",
                    socket.raw_socket
                ));
                host_fds.push(ws::WSAPOLLFD {
                    fd: socket.raw_socket,
                    events: windows_poll_events(events),
                    revents: 0,
                });
                host_indexes.push(index);
            }
            let rc = if host_fds.is_empty() {
                if timeout > 0 {
                    std::thread::sleep(std::time::Duration::from_millis(timeout as u64));
                } else if timeout < 0 {
                    std::thread::park();
                }
                0
            } else {
                unsafe { ws::WSAPoll(host_fds.as_mut_ptr(), host_fds.len() as u32, timeout) }
            };
            if rc == ws::SOCKET_ERROR {
                let errno = last_socket_errno();
                socket_trace(format_args!(
                    "poll nfds={nfds} timeout={timeout} -> errno={errno}"
                ));
                return neg_errno(errno);
            }
            socket_trace(format_args!("poll nfds={nfds} timeout={timeout} -> {rc}"));
            for (host_index, pollfd) in host_fds.iter().enumerate() {
                let index = host_indexes[host_index];
                if pollfd.revents != 0 {
                    let guest_fd =
                        i32::from_le_bytes(bytes[index * 8..index * 8 + 4].try_into().unwrap());
                    socket_trace(format_args!(
                        "poll ready guest_fd={guest_fd} raw_socket={} revents={}",
                        pollfd.fd, pollfd.revents
                    ));
                }
                let revents = guest_poll_events(pollfd.revents).to_le_bytes();
                if let Err(errno) =
                    guest_abi::write(&mut caller, fds_ptr + (index as i32 * 8) + 6, &revents)
                {
                    return neg_errno(errno);
                }
            }
            rc
        },
    )?;

    Ok(())
}

/// Performs getsockname or getpeername while restoring the guest sockaddr family.
fn sock_name(
    mut caller: Caller<'_, AppState>,
    fd: i32,
    addr_ptr: i32,
    addr_len_ptr: i32,
    kind: NameKind,
) -> i32 {
    let socket = match caller.data().sockets.get(fd) {
        Ok(socket) => socket,
        Err(errno) => return neg_errno(errno),
    };
    let (mut addr, mut addr_len) = match read_guest_output_buffer(&mut caller, addr_len_ptr) {
        Ok(address) => address,
        Err(errno) => return neg_errno(errno),
    };
    let rc = unsafe {
        match kind {
            NameKind::Local => ws::getsockname(
                socket.raw_socket,
                addr.as_mut_ptr().cast::<ws::SOCKADDR>(),
                &mut addr_len,
            ),
            NameKind::Peer => ws::getpeername(
                socket.raw_socket,
                addr.as_mut_ptr().cast::<ws::SOCKADDR>(),
                &mut addr_len,
            ),
        }
    };
    if rc == ws::SOCKET_ERROR {
        return neg_last_socket_error();
    }
    match write_guest_socket_address(
        &mut caller,
        addr_ptr,
        addr_len_ptr,
        &mut addr,
        addr_len,
        socket.guest_domain,
    ) {
        Ok(()) => 0,
        Err(errno) => neg_errno(errno),
    }
}

/// Checks a guest poll count before allocating a host poll array.
fn checked_poll_count(nfds: i32) -> std::result::Result<usize, i32> {
    let nfds = usize::try_from(nfds).map_err(|_| libc::EINVAL)?;
    if nfds > MAX_POLL_FDS {
        return Err(libc::EINVAL);
    }
    Ok(nfds)
}

/// Normalizes the two socket type spellings emitted by the WASI socket shim.
fn normalize_socket_type(ty: i32) -> std::result::Result<NormalizedSocketType, i32> {
    let flag_mask = GUEST_SOCK_CLOEXEC_ALT | GUEST_SOCK_NONBLOCK_ALT;
    let base = ty & !flag_mask;
    let flags = ty & flag_mask;
    let ty = match base {
        GUEST_SOCK_STREAM | GUEST_SOCK_STREAM_ALT => ws::SOCK_STREAM,
        GUEST_SOCK_DGRAM | GUEST_SOCK_DGRAM_ALT => ws::SOCK_DGRAM,
        _ => return Err(libc::EOPNOTSUPP),
    };
    Ok(NormalizedSocketType {
        ty,
        close_on_exec: flags & GUEST_SOCK_CLOEXEC_ALT != 0,
        nonblocking: flags & GUEST_SOCK_NONBLOCK_ALT != 0,
    })
}

/// Applies the flags that Winsock can represent at socket creation time.
fn configure_socket_type_flags(
    raw_socket: ws::SOCKET,
    socket_type: NormalizedSocketType,
) -> std::result::Result<(), i32> {
    if socket_type.nonblocking {
        set_socket_nonblocking(raw_socket, true)?;
    }
    // Rust does not inherit Winsock handles into child processes by default.
    // There is no useful Windows equivalent to the guest's close-on-exec bit.
    let _ = socket_type.close_on_exec;
    Ok(())
}

/// Maps the Wasm guest's POSIX-style address family to a Winsock family.
fn normalize_socket_domain(domain: i32) -> i32 {
    match domain {
        GUEST_AF_INET_ALT | GUEST_AF_INET => ws::AF_INET as i32,
        GUEST_AF_INET6 | 23 | 30 => ws::AF_INET6 as i32,
        _ => domain,
    }
}

/// Rewrites the leading sockaddr family bytes before a Winsock call.
fn normalize_sockaddr_for_host(addr: &mut [u8], host_domain: i32) {
    write_sockaddr_family(addr, host_domain);
}

/// Restores the guest's address family spelling after a Winsock call.
fn denormalize_sockaddr_for_guest(addr: &mut [u8], guest_domain: i32) {
    write_sockaddr_family(addr, guest_domain);
}

/// Writes a two-byte sockaddr family without assuming a specific address shape.
fn write_sockaddr_family(addr: &mut [u8], family: i32) {
    if addr.len() < 2 {
        return;
    }
    let Ok(family) = u16::try_from(family) else {
        return;
    };
    addr[..2].copy_from_slice(&family.to_ne_bytes());
}

/// Reads a little-endian u32 from guest memory.
fn read_u32(caller: &mut Caller<'_, AppState>, ptr: i32) -> std::result::Result<u32, i32> {
    let bytes = guest_abi::read(caller, ptr, 4)?;
    Ok(u32::from_le_bytes(bytes.try_into().unwrap()))
}

/// Reads and normalizes an input sockaddr owned by the Wasm guest.
fn read_guest_socket_address(
    caller: &mut Caller<'_, AppState>,
    ptr: i32,
    len: i32,
    host_domain: i32,
) -> std::result::Result<Vec<u8>, i32> {
    let mut address = guest_abi::read(caller, ptr, len)?;
    normalize_sockaddr_for_host(&mut address, host_domain);
    Ok(address)
}

/// Allocates a bounded host output buffer using the guest-provided socklen.
fn read_guest_output_buffer(
    caller: &mut Caller<'_, AppState>,
    len_ptr: i32,
) -> std::result::Result<(Vec<u8>, i32), i32> {
    let len = read_u32(caller, len_ptr)?;
    let len = i32::try_from(len).map_err(|_| libc::EINVAL)?;
    let len = guest_abi::checked_len(len)?;
    Ok((vec![0_u8; len], len as i32))
}

/// Writes a Winsock length back in the guest's fixed-width ABI representation.
fn write_u32(
    caller: &mut Caller<'_, AppState>,
    ptr: i32,
    value: i32,
) -> std::result::Result<(), i32> {
    let value = u32::try_from(value).map_err(|_| libc::EOVERFLOW)?;
    guest_abi::write(caller, ptr, &value.to_le_bytes())
}

/// Writes a returned byte buffer before publishing its resulting length.
fn write_guest_buffer_and_len(
    caller: &mut Caller<'_, AppState>,
    ptr: i32,
    len_ptr: i32,
    bytes: &[u8],
    len: i32,
) -> std::result::Result<(), i32> {
    let len = usize::try_from(len).map_err(|_| libc::EINVAL)?;
    guest_abi::write(caller, ptr, &bytes[..len])?;
    write_u32(caller, len_ptr, len as i32)
}

/// Restores a guest sockaddr family and writes the address plus length.
fn write_guest_socket_address(
    caller: &mut Caller<'_, AppState>,
    ptr: i32,
    len_ptr: i32,
    address: &mut [u8],
    len: i32,
    guest_domain: i32,
) -> std::result::Result<(), i32> {
    denormalize_sockaddr_for_guest(address, guest_domain);
    write_guest_buffer_and_len(caller, ptr, len_ptr, address, len)
}

/// Calls Winsock bind with a guest-owned normalized sockaddr.
fn socket_bind(raw_socket: ws::SOCKET, address: &[u8]) -> i32 {
    let Ok(length) = i32::try_from(address.len()) else {
        return neg_errno(libc::EOVERFLOW);
    };
    cvt_socket_i32(unsafe { ws::bind(raw_socket, address.as_ptr().cast::<ws::SOCKADDR>(), length) })
}

/// Calls Winsock listen.
fn socket_listen(raw_socket: ws::SOCKET, backlog: i32) -> i32 {
    cvt_socket_i32(unsafe { ws::listen(raw_socket, backlog) })
}

/// Calls Winsock connect with a guest-owned normalized sockaddr.
fn socket_connect(raw_socket: ws::SOCKET, address: &[u8]) -> i32 {
    let Ok(length) = i32::try_from(address.len()) else {
        return neg_errno(libc::EOVERFLOW);
    };
    cvt_socket_i32(unsafe {
        ws::connect(raw_socket, address.as_ptr().cast::<ws::SOCKADDR>(), length)
    })
}

/// Calls getsockopt after translating guest socket option constants.
fn socket_getsockopt(
    raw_socket: ws::SOCKET,
    level: i32,
    optname: i32,
    buffer: &mut [u8],
    len: &mut i32,
) -> i32 {
    let (level, optname) = map_socket_option(level, optname);
    if is_timeout_option(level, optname) {
        return getsockopt_timeout(raw_socket, level, optname, buffer, len);
    }
    if is_linger_option(level, optname) {
        return getsockopt_linger(raw_socket, level, optname, buffer, len);
    }
    cvt_socket_i32(unsafe { ws::getsockopt(raw_socket, level, optname, buffer.as_mut_ptr(), len) })
}

/// Calls setsockopt after translating guest socket option constants.
fn socket_setsockopt(raw_socket: ws::SOCKET, level: i32, optname: i32, buffer: &[u8]) -> i32 {
    let (level, optname) = map_socket_option(level, optname);
    if is_timeout_option(level, optname) {
        let milliseconds = match guest_timeval_to_milliseconds(buffer) {
            Ok(milliseconds) => milliseconds,
            Err(errno) => return neg_errno(errno),
        };
        return cvt_socket_i32(unsafe {
            ws::setsockopt(
                raw_socket,
                level,
                optname,
                milliseconds.to_le_bytes().as_ptr(),
                std::mem::size_of::<u32>() as i32,
            )
        });
    }
    if is_linger_option(level, optname) {
        let linger = match guest_linger_to_windows(buffer) {
            Ok(linger) => linger,
            Err(errno) => return neg_errno(errno),
        };
        return cvt_socket_i32(unsafe {
            ws::setsockopt(
                raw_socket,
                level,
                optname,
                linger.as_ptr(),
                linger.len() as i32,
            )
        });
    }
    let Ok(length) = i32::try_from(buffer.len()) else {
        return neg_errno(libc::EOVERFLOW);
    };
    cvt_socket_i32(unsafe { ws::setsockopt(raw_socket, level, optname, buffer.as_ptr(), length) })
}

/// Identifies the two POSIX timeval options whose Windows representation differs.
fn is_timeout_option(level: i32, optname: i32) -> bool {
    level == ws::SOL_SOCKET && (optname == ws::SO_RCVTIMEO || optname == ws::SO_SNDTIMEO)
}

/// Identifies the POSIX linger option, which uses 32-bit fields in the guest.
fn is_linger_option(level: i32, optname: i32) -> bool {
    level == ws::SOL_SOCKET && optname == ws::SO_LINGER
}

/// Reads a wasm32 POSIX timeval and rounds microseconds up to Windows milliseconds.
fn guest_timeval_to_milliseconds(buffer: &[u8]) -> std::result::Result<u32, i32> {
    if buffer.len() != GUEST_TIMEVAL_BYTES {
        return Err(libc::EINVAL);
    }
    let seconds = i32::from_le_bytes(buffer[0..4].try_into().unwrap());
    let microseconds = i32::from_le_bytes(buffer[4..8].try_into().unwrap());
    if seconds < 0 || !(0..1_000_000).contains(&microseconds) {
        return Err(libc::EINVAL);
    }
    let milliseconds = u64::try_from(seconds)
        .unwrap()
        .saturating_mul(1_000)
        .saturating_add(u64::try_from((microseconds + 999) / 1_000).unwrap());
    u32::try_from(milliseconds).map_err(|_| libc::EOVERFLOW)
}

/// Converts a Windows millisecond timeout into the wasm32 POSIX timeval layout.
fn milliseconds_to_guest_timeval(milliseconds: u32) -> std::result::Result<[u8; 8], i32> {
    let seconds = milliseconds / 1_000;
    let microseconds = (milliseconds % 1_000) * 1_000;
    let seconds = i32::try_from(seconds).map_err(|_| libc::EOVERFLOW)?;
    let microseconds = i32::try_from(microseconds).map_err(|_| libc::EOVERFLOW)?;
    let mut guest = [0_u8; GUEST_TIMEVAL_BYTES];
    guest[0..4].copy_from_slice(&seconds.to_le_bytes());
    guest[4..8].copy_from_slice(&microseconds.to_le_bytes());
    Ok(guest)
}

/// Reads Windows' millisecond timeout and publishes the guest timeval form.
fn getsockopt_timeout(
    raw_socket: ws::SOCKET,
    level: i32,
    optname: i32,
    buffer: &mut [u8],
    len: &mut i32,
) -> i32 {
    if buffer.len() < GUEST_TIMEVAL_BYTES {
        return neg_errno(libc::EINVAL);
    }
    let mut host_value = [0_u8; 4];
    let mut host_len = host_value.len() as i32;
    let rc = cvt_socket_i32(unsafe {
        ws::getsockopt(
            raw_socket,
            level,
            optname,
            host_value.as_mut_ptr(),
            &mut host_len,
        )
    });
    if rc < 0 {
        return rc;
    }
    if host_len != host_value.len() as i32 {
        return neg_errno(libc::EIO);
    }
    let value = u32::from_le_bytes(host_value);
    let guest = match milliseconds_to_guest_timeval(value) {
        Ok(guest) => guest,
        Err(errno) => return neg_errno(errno),
    };
    buffer[..GUEST_TIMEVAL_BYTES].copy_from_slice(&guest);
    *len = GUEST_TIMEVAL_BYTES as i32;
    0
}

/// Converts a wasm32 POSIX linger into the two-u16 Winsock representation.
fn guest_linger_to_windows(buffer: &[u8]) -> std::result::Result<[u8; 4], i32> {
    if buffer.len() != GUEST_LINGER_BYTES {
        return Err(libc::EINVAL);
    }
    let enabled = i32::from_le_bytes(buffer[0..4].try_into().unwrap());
    let seconds = i32::from_le_bytes(buffer[4..8].try_into().unwrap());
    if !(0..=1).contains(&enabled) || !(0..=u16::MAX as i32).contains(&seconds) {
        return Err(libc::EINVAL);
    }
    let mut windows = [0_u8; 4];
    windows[0..2].copy_from_slice(&(enabled as u16).to_le_bytes());
    windows[2..4].copy_from_slice(&(seconds as u16).to_le_bytes());
    Ok(windows)
}

/// Reads Winsock linger and expands it to the wasm32 POSIX structure.
fn getsockopt_linger(
    raw_socket: ws::SOCKET,
    level: i32,
    optname: i32,
    buffer: &mut [u8],
    len: &mut i32,
) -> i32 {
    if buffer.len() < GUEST_LINGER_BYTES {
        return neg_errno(libc::EINVAL);
    }
    let mut host_value = [0_u8; 4];
    let mut host_len = host_value.len() as i32;
    let rc = cvt_socket_i32(unsafe {
        ws::getsockopt(
            raw_socket,
            level,
            optname,
            host_value.as_mut_ptr(),
            &mut host_len,
        )
    });
    if rc < 0 {
        return rc;
    }
    if host_len != host_value.len() as i32 {
        return neg_errno(libc::EIO);
    }
    let enabled = u16::from_le_bytes(host_value[0..2].try_into().unwrap()) as i32;
    let seconds = u16::from_le_bytes(host_value[2..4].try_into().unwrap()) as i32;
    buffer[0..4].copy_from_slice(&enabled.to_le_bytes());
    buffer[4..8].copy_from_slice(&seconds.to_le_bytes());
    *len = GUEST_LINGER_BYTES as i32;
    0
}

/// Calls Winsock send with the guest's message flags.
fn socket_send(raw_socket: ws::SOCKET, buffer: &[u8], flags: i32) -> i32 {
    let Ok(length) = i32::try_from(buffer.len()) else {
        return neg_errno(libc::EOVERFLOW);
    };
    cvt_socket_i32(unsafe { ws::send(raw_socket, buffer.as_ptr(), length, flags) })
}

/// Calls Winsock recv with the guest's message flags.
fn socket_recv(raw_socket: ws::SOCKET, buffer: &mut [u8], flags: i32) -> i32 {
    let Ok(length) = i32::try_from(buffer.len()) else {
        return neg_errno(libc::EOVERFLOW);
    };
    cvt_socket_i32(unsafe { ws::recv(raw_socket, buffer.as_mut_ptr(), length, flags) })
}

/// Calls Winsock sendto with a guest-owned normalized sockaddr.
fn socket_sendto(raw_socket: ws::SOCKET, buffer: &[u8], flags: i32, address: &[u8]) -> i32 {
    let (Ok(length), Ok(address_len)) = (i32::try_from(buffer.len()), i32::try_from(address.len()))
    else {
        return neg_errno(libc::EOVERFLOW);
    };
    cvt_socket_i32(unsafe {
        ws::sendto(
            raw_socket,
            buffer.as_ptr(),
            length,
            flags,
            address.as_ptr().cast::<ws::SOCKADDR>(),
            address_len,
        )
    })
}

/// Calls Winsock recvfrom and returns the source sockaddr in the supplied buffer.
fn socket_recvfrom(
    raw_socket: ws::SOCKET,
    buffer: &mut [u8],
    flags: i32,
    address: &mut [u8],
    address_len: &mut i32,
) -> i32 {
    let Ok(length) = i32::try_from(buffer.len()) else {
        return neg_errno(libc::EOVERFLOW);
    };
    cvt_socket_i32(unsafe {
        ws::recvfrom(
            raw_socket,
            buffer.as_mut_ptr(),
            length,
            flags,
            address.as_mut_ptr().cast::<ws::SOCKADDR>(),
            address_len,
        )
    })
}

/// Calls Winsock shutdown using the POSIX-compatible shutdown direction values.
fn socket_shutdown(raw_socket: ws::SOCKET, how: i32) -> i32 {
    cvt_socket_i32(unsafe { ws::shutdown(raw_socket, how) })
}

/// Closes one Winsock handle after the guest descriptor is removed.
fn socket_close(raw_socket: ws::SOCKET) -> i32 {
    cvt_socket_i32(unsafe { ws::closesocket(raw_socket) })
}

/// Maps the guest's small POSIX option namespace to Winsock's values.
fn map_socket_option(level: i32, optname: i32) -> (i32, i32) {
    let level = match level {
        1 => ws::SOL_SOCKET,
        0 => ws::IPPROTO_IP,
        6 => ws::IPPROTO_TCP,
        41 => ws::IPPROTO_IPV6,
        value => value,
    };
    let optname = match level {
        ws::SOL_SOCKET => match optname {
            2 => ws::SO_REUSEADDR,
            3 => ws::SO_TYPE,
            4 => ws::SO_ERROR,
            7 => ws::SO_SNDBUF,
            8 => ws::SO_RCVBUF,
            9 => ws::SO_KEEPALIVE,
            13 => ws::SO_LINGER,
            20 => ws::SO_RCVTIMEO,
            21 => ws::SO_SNDTIMEO,
            30 => ws::SO_ACCEPTCONN,
            value => value,
        },
        ws::IPPROTO_IP if optname == 1 => ws::IP_TOS,
        ws::IPPROTO_IPV6 if optname == 26 => ws::IPV6_V6ONLY,
        _ => optname,
    };
    (level, optname)
}

/// Converts POSIX poll interest flags to WSAPoll's non-identical bit layout.
fn windows_poll_events(events: i16) -> i16 {
    let mut mapped = 0;
    if events & GUEST_POLLIN != 0 {
        mapped |= ws::POLLIN;
    }
    if events & GUEST_POLLOUT != 0 {
        mapped |= ws::POLLOUT;
    }
    mapped
}

/// Converts WSAPoll result flags back to the POSIX values the guest expects.
fn guest_poll_events(events: i16) -> i16 {
    let mut mapped = 0;
    if events & ws::POLLIN != 0 {
        mapped |= GUEST_POLLIN;
    }
    if events & ws::POLLOUT != 0 {
        mapped |= GUEST_POLLOUT;
    }
    if events & ws::POLLERR != 0 {
        mapped |= GUEST_POLLERR;
    }
    if events & ws::POLLHUP != 0 {
        mapped |= GUEST_POLLHUP;
    }
    if events & ws::POLLNVAL != 0 {
        mapped |= GUEST_POLLNVAL;
    }
    mapped
}

/// Configures Winsock exactly once before the first guest socket is created.
fn ensure_winsock() -> std::result::Result<(), i32> {
    static STATUS: OnceLock<i32> = OnceLock::new();
    let status = *STATUS.get_or_init(|| unsafe {
        let mut data = std::mem::zeroed::<ws::WSADATA>();
        ws::WSAStartup(0x0202, &mut data)
    });
    if status == 0 {
        Ok(())
    } else {
        Err(socket_errno_to_posix(status))
    }
}

/// Enables or disables Winsock nonblocking mode for fcntl emulation.
fn set_socket_nonblocking(raw_socket: ws::SOCKET, enabled: bool) -> std::result::Result<(), i32> {
    let mut value = u32::from(enabled);
    let rc = unsafe { ws::ioctlsocket(raw_socket, ws::FIONBIO, &mut value) };
    if rc == ws::SOCKET_ERROR {
        Err(last_socket_errno())
    } else {
        Ok(())
    }
}

/// Converts a Winsock return value into the negative-errno guest convention.
fn cvt_socket_i32(rc: i32) -> i32 {
    if rc == ws::SOCKET_ERROR {
        neg_last_socket_error()
    } else {
        rc
    }
}

/// Reads and maps Winsock's thread-local error code to a POSIX-like errno.
fn neg_last_socket_error() -> i32 {
    neg_errno(last_socket_errno())
}

/// Returns a POSIX-like errno suitable for the shared guest ABI mapper.
fn last_socket_errno() -> i32 {
    socket_errno_to_posix(unsafe { ws::WSAGetLastError() })
}

/// Maps the Winsock error namespace to the error constants used by wasi-libc.
fn socket_errno_to_posix(error: i32) -> i32 {
    match error {
        ws::WSAEACCES => libc::EACCES,
        ws::WSAEADDRINUSE => libc::EADDRINUSE,
        ws::WSAEADDRNOTAVAIL => libc::EADDRNOTAVAIL,
        ws::WSAEAFNOSUPPORT => libc::EAFNOSUPPORT,
        ws::WSAEALREADY => libc::EALREADY,
        ws::WSAEBADF => libc::EBADF,
        ws::WSAECONNABORTED => libc::ECONNABORTED,
        ws::WSAECONNREFUSED => libc::ECONNREFUSED,
        ws::WSAECONNRESET => libc::ECONNRESET,
        ws::WSAEDESTADDRREQ => libc::EDESTADDRREQ,
        ws::WSAEDQUOT => libc::ENOSPC,
        ws::WSAEFAULT => libc::EFAULT,
        ws::WSAEINPROGRESS => libc::EINPROGRESS,
        ws::WSAEINTR => libc::EINTR,
        ws::WSAEINVAL => libc::EINVAL,
        ws::WSAEISCONN => libc::EISCONN,
        ws::WSAEMFILE => libc::EMFILE,
        ws::WSAEMSGSIZE => libc::EMSGSIZE,
        ws::WSAENAMETOOLONG => libc::ENAMETOOLONG,
        ws::WSAENETDOWN => libc::ENETDOWN,
        ws::WSAENETRESET => libc::ENETRESET,
        ws::WSAENETUNREACH => libc::ENETUNREACH,
        ws::WSAENOBUFS => libc::ENOBUFS,
        ws::WSAENOPROTOOPT => libc::ENOPROTOOPT,
        ws::WSAENOTCONN => libc::ENOTCONN,
        ws::WSAENOTSOCK => libc::ENOTSOCK,
        ws::WSAEOPNOTSUPP | ws::WSAESOCKTNOSUPPORT => libc::EOPNOTSUPP,
        ws::WSAEPROTONOSUPPORT => libc::EPROTONOSUPPORT,
        ws::WSAEPROTOTYPE => libc::EPROTOTYPE,
        ws::WSAETIMEDOUT => libc::ETIMEDOUT,
        ws::WSAEWOULDBLOCK => libc::EAGAIN,
        _ => libc::EIO,
    }
}

/// Emits host socket diagnostics only when explicitly requested by a maintainer.
fn socket_trace(args: std::fmt::Arguments<'_>) {
    if std::env::var_os("WASMTIME_MARIADB_SOCKET_TRACE").is_some() {
        eprintln!("[wasmtime-mariadb:sockets] {args}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_guest_timeval_to_windows_milliseconds() {
        assert_eq!(
            guest_timeval_to_milliseconds(&[1, 0, 0, 0, 1, 0, 0, 0]),
            Ok(1_001)
        );
        assert_eq!(
            milliseconds_to_guest_timeval(1_001).unwrap(),
            [1, 0, 0, 0, 232, 3, 0, 0]
        );
    }

    #[test]
    fn rejects_invalid_guest_socket_option_layouts() {
        assert_eq!(guest_timeval_to_milliseconds(&[0; 4]), Err(libc::EINVAL));
        assert_eq!(guest_linger_to_windows(&[0; 4]), Err(libc::EINVAL));
        assert_eq!(
            guest_linger_to_windows(&[2, 0, 0, 0, 0, 0, 0, 0]),
            Err(libc::EINVAL)
        );
    }
}
