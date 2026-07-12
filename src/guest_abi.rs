//! Shared glue for the MariaDB-specific core-Wasm imports.
//!
//! The MariaDB guest is a threaded Preview 1 module. Its file and socket
//! shims use raw guest pointers and WASI Preview 1 errno values, so the host
//! bridges need one carefully bounded way to copy guest memory and report
//! errors. Keep that code here instead of growing two subtly different ABIs.

use std::ops::Range;

use wasmtime::Caller;

use crate::AppState;

const MAX_IO_LEN: usize = 16 * 1024 * 1024;
const MAX_PATH_LEN: usize = 16 * 1024;

/// WASI Preview 1's capability error is not a host errno.
pub(crate) const ERRNO_NOTCAPABLE: i32 = 76;

/// Validates and converts a guest byte count used by an I/O bridge call.
pub(crate) fn checked_len(len: i32) -> std::result::Result<usize, i32> {
    let len = usize::try_from(len).map_err(|_| libc::EINVAL)?;
    if len > MAX_IO_LEN {
        return Err(libc::EINVAL);
    }
    Ok(len)
}

/// Validates a guest memory range before copying through a host bridge.
pub(crate) fn checked_range(
    ptr: i32,
    len: i32,
    memory_len: usize,
) -> std::result::Result<Range<usize>, i32> {
    let ptr = usize::try_from(ptr).map_err(|_| libc::EFAULT)?;
    let len = checked_len(len)?;
    let end = ptr.checked_add(len).ok_or(libc::EFAULT)?;
    if end > memory_len {
        return Err(libc::EFAULT);
    }
    Ok(ptr..end)
}

/// Copies a NUL-terminated UTF-8 path from guest memory.
pub(crate) fn read_cstr(
    caller: &mut Caller<'_, AppState>,
    ptr: i32,
) -> std::result::Result<String, i32> {
    let start = usize::try_from(ptr).map_err(|_| libc::EFAULT)?;
    let export = caller.get_export("memory").ok_or(libc::EFAULT)?;

    if let Some(mem) = export.clone().into_memory() {
        let data = mem.data(&mut *caller);
        if start >= data.len() {
            return Err(libc::EFAULT);
        }
        let max_end = start.saturating_add(MAX_PATH_LEN).min(data.len());
        let Some(end) = data[start..max_end].iter().position(|byte| *byte == 0) else {
            return Err(libc::ENAMETOOLONG);
        };
        return std::str::from_utf8(&data[start..start + end])
            .map(str::to_owned)
            .map_err(|_| libc::EINVAL);
    }

    if let Some(mem) = export.into_shared_memory() {
        let data = mem.data();
        if start >= data.len() {
            return Err(libc::EFAULT);
        }
        let max_end = start.saturating_add(MAX_PATH_LEN).min(data.len());
        let mut bytes = Vec::new();
        for cell in &data[start..max_end] {
            let byte = unsafe { *cell.get() };
            if byte == 0 {
                return String::from_utf8(bytes).map_err(|_| libc::EINVAL);
            }
            bytes.push(byte);
        }
        return Err(libc::ENAMETOOLONG);
    }

    Err(libc::EFAULT)
}

/// Copies a bounded byte slice from either ordinary or shared guest memory.
pub(crate) fn read(
    caller: &mut Caller<'_, AppState>,
    ptr: i32,
    len: i32,
) -> std::result::Result<Vec<u8>, i32> {
    let export = caller.get_export("memory").ok_or(libc::EFAULT)?;

    if let Some(mem) = export.clone().into_memory() {
        let data = mem.data(&mut *caller);
        let range = checked_range(ptr, len, data.len())?;
        return Ok(data[range].to_vec());
    }

    if let Some(mem) = export.into_shared_memory() {
        let data = mem.data();
        let range = checked_range(ptr, len, data.len())?;
        let mut bytes = Vec::with_capacity(range.len());
        for cell in &data[range] {
            bytes.push(unsafe { *cell.get() });
        }
        return Ok(bytes);
    }

    Err(libc::EFAULT)
}

/// Copies bytes into either ordinary or shared guest memory.
pub(crate) fn write(
    caller: &mut Caller<'_, AppState>,
    ptr: i32,
    bytes: &[u8],
) -> std::result::Result<(), i32> {
    let export = caller.get_export("memory").ok_or(libc::EFAULT)?;

    if let Some(mem) = export.clone().into_memory() {
        let data = mem.data_mut(&mut *caller);
        let range = checked_range(
            ptr,
            i32::try_from(bytes.len()).map_err(|_| libc::EINVAL)?,
            data.len(),
        )?;
        data[range].copy_from_slice(bytes);
        return Ok(());
    }

    if let Some(mem) = export.into_shared_memory() {
        let data = mem.data();
        let range = checked_range(
            ptr,
            i32::try_from(bytes.len()).map_err(|_| libc::EINVAL)?,
            data.len(),
        )?;
        for (cell, byte) in data[range].iter().zip(bytes) {
            unsafe {
                *cell.get() = *byte;
            }
        }
        return Ok(());
    }

    Err(libc::EFAULT)
}

/// Converts a host errno to the numeric ABI used by WASI Preview 1 libc.
pub(crate) fn errno_for_guest(errno: i32) -> i32 {
    match errno {
        libc::EACCES => 2,
        libc::EADDRINUSE => 3,
        libc::EADDRNOTAVAIL => 4,
        libc::EAFNOSUPPORT => 5,
        errno if errno == libc::EAGAIN || errno == libc::EWOULDBLOCK => 6,
        libc::EALREADY => 7,
        libc::EBADF => 8,
        libc::EBUSY => 10,
        libc::ECONNABORTED => 13,
        libc::ECONNREFUSED => 14,
        libc::ECONNRESET => 15,
        libc::EDESTADDRREQ => 17,
        libc::EEXIST => 20,
        libc::EFAULT => 21,
        libc::EFBIG => 22,
        libc::EINPROGRESS => 26,
        libc::EINTR => 27,
        libc::EINVAL => 28,
        libc::EIO => 29,
        libc::EISCONN => 30,
        libc::EISDIR => 31,
        libc::ELOOP => 32,
        libc::EMFILE => 33,
        libc::EMSGSIZE => 35,
        libc::ENAMETOOLONG => 37,
        libc::ENETDOWN => 38,
        libc::ENETRESET => 39,
        libc::ENETUNREACH => 40,
        libc::ENFILE => 41,
        libc::ENOBUFS => 42,
        libc::ENODEV => 43,
        libc::ENOENT => 44,
        libc::ENOMEM => 48,
        libc::ENOPROTOOPT => 50,
        libc::ENOSPC | libc::EDQUOT => 51,
        libc::ENOSYS => 52,
        libc::ENOTCONN => 53,
        libc::ENOTDIR => 54,
        libc::ENOTEMPTY => 55,
        libc::ENOTSOCK => 57,
        errno if errno == libc::ENOTSUP || errno == libc::EOPNOTSUPP => 58,
        libc::ENXIO => 60,
        libc::EOVERFLOW => 61,
        libc::EPERM => 63,
        libc::EPIPE => 64,
        libc::EPROTONOSUPPORT => 66,
        libc::EPROTOTYPE => 67,
        libc::EROFS => 69,
        libc::ESPIPE => 70,
        libc::ETIMEDOUT => 73,
        libc::ETXTBSY => 74,
        libc::EXDEV => 75,
        _ => errno,
    }
}

/// Returns the last host errno, using I/O as the only portable fallback.
pub(crate) fn last_errno() -> i32 {
    std::io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(libc::EIO)
}

/// Produces the negative errno convention used by the MariaDB C shims.
pub(crate) fn neg_errno(errno: i32) -> i32 {
    -errno_for_guest(errno)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_file_errors_to_wasi_errno() {
        assert_eq!(errno_for_guest(libc::EBADF), 8);
        assert_eq!(errno_for_guest(libc::EEXIST), 20);
        assert_eq!(errno_for_guest(libc::ENOENT), 44);
        assert_eq!(errno_for_guest(libc::ENOTDIR), 54);
        assert_eq!(errno_for_guest(libc::ENOSPC), 51);
        assert_eq!(errno_for_guest(libc::EDQUOT), 51);
    }

    #[test]
    fn maps_socket_errors_to_wasi_errno() {
        assert_eq!(errno_for_guest(libc::EAGAIN), 6);
        assert_eq!(errno_for_guest(libc::EWOULDBLOCK), 6);
        assert_eq!(errno_for_guest(libc::ECONNRESET), 15);
        assert_eq!(errno_for_guest(libc::ENOTCONN), 53);
        assert_eq!(errno_for_guest(libc::EOPNOTSUPP), 58);
    }

    #[test]
    fn rejects_invalid_guest_ranges() {
        assert_eq!(checked_range(-1, 1, 32), Err(libc::EFAULT));
        assert_eq!(checked_range(31, 2, 32), Err(libc::EFAULT));
        assert_eq!(checked_len(-1), Err(libc::EINVAL));
        assert_eq!(checked_len((MAX_IO_LEN + 1) as i32), Err(libc::EINVAL));
    }
}
