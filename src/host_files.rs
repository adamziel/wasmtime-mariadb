use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::ops::Range;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

#[cfg(unix)]
use std::os::unix::fs::FileExt;

use wasmtime::{Caller, Linker, Result};

use crate::{AppState, Cli, Preopen};

const MODULE_NAME: &str = "wasmtime_mariadb_files";
const GUEST_FD_BASE: i32 = 20_000;
const MAX_IO_LEN: usize = 16 * 1024 * 1024;
const MAX_PATH_LEN: usize = 16 * 1024;

const POSIX_O_ACCMODE: i32 = 0o3;
const POSIX_O_WRONLY: i32 = 0o1;
const POSIX_O_RDWR: i32 = 0o2;
const POSIX_O_CREAT: i32 = 0o100;
const POSIX_O_EXCL: i32 = 0o200;
const POSIX_O_TRUNC: i32 = 0o1000;
const POSIX_O_APPEND: i32 = 0o2000;
const POSIX_O_DIRECTORY: i32 = 0o200000;
const WASI_O_APPEND: i32 = 0x0001;
const WASI_O_CREAT: i32 = 0x0001 << 12;
const WASI_O_DIRECTORY: i32 = 0x0002 << 12;
const WASI_O_EXCL: i32 = 0x0004 << 12;
const WASI_O_TRUNC: i32 = 0x0008 << 12;
const WASI_O_RDONLY: i32 = 0x0400_0000;
const WASI_O_WRONLY: i32 = 0x1000_0000;
const WASI_ENOTCAPABLE: i32 = 76;

#[derive(Clone)]
pub(crate) struct HostFiles {
    inner: Arc<Mutex<HostFilesInner>>,
}

struct HostFilesInner {
    next_fd: i32,
    files: HashMap<i32, HostFile>,
    preopens: Vec<PreopenMapping>,
}

struct HostFile {
    file: File,
    path: PathBuf,
}

struct PreopenMapping {
    guest: String,
    host: PathBuf,
}

impl HostFiles {
    pub(crate) fn new(cli: &Cli) -> Result<Self> {
        let mut preopens = Vec::new();

        if !cli.no_default_preopen {
            preopens.push(PreopenMapping {
                guest: normalize_guest_path(".").unwrap_or_else(|_| ".".to_owned()),
                host: std::env::current_dir()?,
            });
        }

        for Preopen { host, guest } in &cli.preopens {
            preopens.push(PreopenMapping {
                guest: normalize_guest_path(guest).map_err(io_error_from_errno)?,
                host: host.clone(),
            });
        }

        preopens.sort_by(|left, right| right.guest.len().cmp(&left.guest.len()));

        Ok(Self {
            inner: Arc::new(Mutex::new(HostFilesInner {
                next_fd: GUEST_FD_BASE,
                files: HashMap::new(),
                preopens,
            })),
        })
    }

    fn open(&self, guest_path: &str, flags: i32, _mode: i32) -> i32 {
        let host_path = match self.resolve(guest_path) {
            Ok(path) => path,
            Err(errno) => {
                file_trace(format_args!(
                    "open path={guest_path:?} flags={flags:#x} resolve_errno={errno}"
                ));
                return neg_errno(errno);
            }
        };
        if flags & (POSIX_O_DIRECTORY | WASI_O_DIRECTORY) != 0 {
            file_trace(format_args!(
                "open path={guest_path:?} host={} flags={flags:#x} denied=O_DIRECTORY",
                host_path.display()
            ));
            return neg_errno(libc::EISDIR);
        }

        let access = flags & POSIX_O_ACCMODE;
        let wasi_read = flags & WASI_O_RDONLY != 0;
        let wasi_write = flags & WASI_O_WRONLY != 0;
        let read = wasi_read || (!wasi_write && access != POSIX_O_WRONLY);
        let write = wasi_write || access == POSIX_O_WRONLY || access == POSIX_O_RDWR;
        let create = flags & (POSIX_O_CREAT | WASI_O_CREAT) != 0;
        let excl = flags & (POSIX_O_EXCL | WASI_O_EXCL) != 0;

        let mut options = OpenOptions::new();
        options.read(read).write(write);
        if flags & (POSIX_O_APPEND | WASI_O_APPEND) != 0 {
            options.append(true);
        }
        if create && excl {
            options.create_new(true);
        } else if create {
            options.create(true);
        }
        if flags & (POSIX_O_TRUNC | WASI_O_TRUNC) != 0 {
            options.truncate(true);
        }

        let file = match options.open(&host_path) {
            Ok(file) => file,
            Err(err) => {
                let errno = io_errno(err);
                file_trace(format_args!(
                    "open path={guest_path:?} host={} flags={flags:#x} mode={_mode:#o} read={read} write={write} create={create} excl={excl} errno={errno}",
                    host_path.display()
                ));
                return neg_errno(errno);
            }
        };

        let mut inner = self.inner.lock().unwrap();
        let fd = inner.next_fd;
        inner.next_fd = inner.next_fd.saturating_add(1);
        inner.files.insert(
            fd,
            HostFile {
                file,
                path: host_path.clone(),
            },
        );
        file_trace(format_args!(
            "open path={guest_path:?} host={} flags={flags:#x} mode={_mode:#o} read={read} write={write} create={create} excl={excl} fd={fd}",
            host_path.display()
        ));
        fd
    }

    fn close(&self, fd: i32) -> i32 {
        let mut inner = self.inner.lock().unwrap();
        if inner.files.remove(&fd).is_some() {
            0
        } else {
            neg_errno(libc::EBADF)
        }
    }

    fn pread(&self, fd: i32, buf: &mut [u8], offset: u64) -> i32 {
        #[cfg(unix)]
        {
            let inner = self.inner.lock().unwrap();
            let Some(host_file) = inner.files.get(&fd) else {
                return neg_errno(libc::EBADF);
            };
            match host_file.file.read_at(buf, offset) {
                Ok(n) => {
                    file_trace(format_args!(
                        "pread fd={fd} path={} len={} offset={offset} rc={n}",
                        host_file.path.display(),
                        buf.len()
                    ));
                    i32::try_from(n).unwrap_or_else(|_| neg_errno(libc::EOVERFLOW))
                }
                Err(err) => {
                    let errno = io_errno(err);
                    file_trace(format_args!(
                        "pread fd={fd} path={} len={} offset={offset} errno={errno}",
                        host_file.path.display(),
                        buf.len()
                    ));
                    neg_errno(errno)
                }
            }
        }
        #[cfg(not(unix))]
        {
            let _ = (fd, buf, offset);
            neg_errno(libc::ENOSYS)
        }
    }

    fn read(&self, fd: i32, buf: &mut [u8]) -> i32 {
        let mut inner = self.inner.lock().unwrap();
        let Some(host_file) = inner.files.get_mut(&fd) else {
            return neg_errno(libc::EBADF);
        };
        match host_file.file.read(buf) {
            Ok(n) => {
                file_trace(format_args!(
                    "read fd={fd} path={} len={} rc={n}",
                    host_file.path.display(),
                    buf.len()
                ));
                i32::try_from(n).unwrap_or_else(|_| neg_errno(libc::EOVERFLOW))
            }
            Err(err) => {
                let errno = io_errno(err);
                file_trace(format_args!(
                    "read fd={fd} path={} len={} errno={errno}",
                    host_file.path.display(),
                    buf.len()
                ));
                neg_errno(errno)
            }
        }
    }

    fn pwrite(&self, fd: i32, buf: &[u8], offset: u64) -> i32 {
        #[cfg(unix)]
        {
            let inner = self.inner.lock().unwrap();
            let Some(host_file) = inner.files.get(&fd) else {
                return neg_errno(libc::EBADF);
            };
            match host_file.file.write_at(buf, offset) {
                Ok(n) => {
                    file_trace(format_args!(
                        "pwrite fd={fd} path={} len={} offset={offset} rc={n}",
                        host_file.path.display(),
                        buf.len()
                    ));
                    i32::try_from(n).unwrap_or_else(|_| neg_errno(libc::EOVERFLOW))
                }
                Err(err) => {
                    let errno = io_errno(err);
                    file_trace(format_args!(
                        "pwrite fd={fd} path={} len={} offset={offset} errno={errno}",
                        host_file.path.display(),
                        buf.len()
                    ));
                    neg_errno(errno)
                }
            }
        }
        #[cfg(not(unix))]
        {
            let _ = (fd, buf, offset);
            neg_errno(libc::ENOSYS)
        }
    }

    fn write(&self, fd: i32, buf: &[u8]) -> i32 {
        let mut inner = self.inner.lock().unwrap();
        let Some(host_file) = inner.files.get_mut(&fd) else {
            return neg_errno(libc::EBADF);
        };
        match host_file.file.write(buf) {
            Ok(n) => {
                file_trace(format_args!(
                    "write fd={fd} path={} len={} rc={n}",
                    host_file.path.display(),
                    buf.len()
                ));
                i32::try_from(n).unwrap_or_else(|_| neg_errno(libc::EOVERFLOW))
            }
            Err(err) => {
                let errno = io_errno(err);
                file_trace(format_args!(
                    "write fd={fd} path={} len={} errno={errno}",
                    host_file.path.display(),
                    buf.len()
                ));
                neg_errno(errno)
            }
        }
    }

    fn seek(&self, fd: i32, offset: i64, whence: i32) -> i64 {
        let mut inner = self.inner.lock().unwrap();
        let Some(host_file) = inner.files.get_mut(&fd) else {
            return i64::from(neg_errno(libc::EBADF));
        };
        let seek_from = match whence {
            libc::SEEK_SET => SeekFrom::Start(match u64::try_from(offset) {
                Ok(offset) => offset,
                Err(_) => return i64::from(neg_errno(libc::EINVAL)),
            }),
            libc::SEEK_CUR => SeekFrom::Current(offset),
            libc::SEEK_END => SeekFrom::End(offset),
            _ => return i64::from(neg_errno(libc::EINVAL)),
        };
        match host_file.file.seek(seek_from) {
            Ok(pos) => i64::try_from(pos).unwrap_or_else(|_| i64::from(neg_errno(libc::EOVERFLOW))),
            Err(err) => i64::from(neg_errno(io_errno(err))),
        }
    }

    fn truncate(&self, fd: i32, size: u64) -> i32 {
        let inner = self.inner.lock().unwrap();
        let Some(host_file) = inner.files.get(&fd) else {
            return neg_errno(libc::EBADF);
        };
        match host_file.file.set_len(size) {
            Ok(()) => {
                file_trace(format_args!(
                    "truncate fd={fd} path={} size={size} rc=0",
                    host_file.path.display()
                ));
                0
            }
            Err(err) => {
                let errno = io_errno(err);
                file_trace(format_args!(
                    "truncate fd={fd} path={} size={size} errno={errno}",
                    host_file.path.display()
                ));
                neg_errno(errno)
            }
        }
    }

    fn sync(&self, fd: i32, data_only: bool) -> i32 {
        let inner = self.inner.lock().unwrap();
        let Some(host_file) = inner.files.get(&fd) else {
            return neg_errno(libc::EBADF);
        };
        let result = if data_only {
            host_file.file.sync_data()
        } else {
            host_file.file.sync_all()
        };
        match result {
            Ok(()) => {
                file_trace(format_args!(
                    "sync fd={fd} path={} data_only={data_only} rc=0",
                    host_file.path.display()
                ));
                0
            }
            Err(err) => {
                let errno = io_errno(err);
                file_trace(format_args!(
                    "sync fd={fd} path={} data_only={data_only} errno={errno}",
                    host_file.path.display()
                ));
                neg_errno(errno)
            }
        }
    }

    fn resolve(&self, guest_path: &str) -> std::result::Result<PathBuf, i32> {
        let normalized = normalize_guest_path(guest_path)?;
        let inner = self.inner.lock().unwrap();

        for preopen in &inner.preopens {
            if preopen.guest == "." && !normalized.starts_with('/') {
                return Ok(join_suffix(&preopen.host, &normalized));
            }

            let suffix = if preopen.guest == "/" {
                normalized.strip_prefix('/').unwrap_or(&normalized)
            } else if normalized == preopen.guest {
                ""
            } else if normalized.starts_with(&preopen.guest)
                && normalized.as_bytes().get(preopen.guest.len()) == Some(&b'/')
            {
                &normalized[preopen.guest.len() + 1..]
            } else {
                continue;
            };
            return Ok(join_suffix(&preopen.host, suffix));
        }

        Err(WASI_ENOTCAPABLE)
    }
}

pub(crate) fn add_to_linker(linker: &mut Linker<AppState>) -> Result<()> {
    linker.func_wrap(
        MODULE_NAME,
        "open",
        |mut caller: Caller<'_, AppState>, path_ptr: i32, flags: i32, mode: i32| -> i32 {
            let path = match read_cstr(&mut caller, path_ptr) {
                Ok(path) => path,
                Err(errno) => return neg_errno(errno),
            };
            caller.data().files.open(&path, flags, mode)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "close",
        |caller: Caller<'_, AppState>, fd: i32| -> i32 { caller.data().files.close(fd) },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "pread",
        |mut caller: Caller<'_, AppState>, fd: i32, buf_ptr: i32, len: i32, offset: i64| -> i32 {
            let len = match checked_len(len) {
                Ok(len) => len,
                Err(errno) => return neg_errno(errno),
            };
            let mut buf = vec![0_u8; len];
            let rc = caller.data().files.pread(fd, &mut buf, offset as u64);
            if rc <= 0 {
                return rc;
            }
            match write_guest(&mut caller, buf_ptr, &buf[..rc as usize]) {
                Ok(()) => rc,
                Err(errno) => neg_errno(errno),
            }
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "read",
        |mut caller: Caller<'_, AppState>, fd: i32, buf_ptr: i32, len: i32| -> i32 {
            let len = match checked_len(len) {
                Ok(len) => len,
                Err(errno) => return neg_errno(errno),
            };
            let mut buf = vec![0_u8; len];
            let rc = caller.data().files.read(fd, &mut buf);
            if rc <= 0 {
                return rc;
            }
            match write_guest(&mut caller, buf_ptr, &buf[..rc as usize]) {
                Ok(()) => rc,
                Err(errno) => neg_errno(errno),
            }
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "pwrite",
        |mut caller: Caller<'_, AppState>, fd: i32, buf_ptr: i32, len: i32, offset: i64| -> i32 {
            let buf = match read_guest(&mut caller, buf_ptr, len) {
                Ok(buf) => buf,
                Err(errno) => return neg_errno(errno),
            };
            caller.data().files.pwrite(fd, &buf, offset as u64)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "write",
        |mut caller: Caller<'_, AppState>, fd: i32, buf_ptr: i32, len: i32| -> i32 {
            let buf = match read_guest(&mut caller, buf_ptr, len) {
                Ok(buf) => buf,
                Err(errno) => return neg_errno(errno),
            };
            caller.data().files.write(fd, &buf)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "seek",
        |caller: Caller<'_, AppState>, fd: i32, offset: i64, whence: i32| -> i64 {
            caller.data().files.seek(fd, offset, whence)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "truncate",
        |caller: Caller<'_, AppState>, fd: i32, size: i64| -> i32 {
            let size = match u64::try_from(size) {
                Ok(size) => size,
                Err(_) => return neg_errno(libc::EINVAL),
            };
            caller.data().files.truncate(fd, size)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "sync",
        |caller: Caller<'_, AppState>, fd: i32, data_only: i32| -> i32 {
            caller.data().files.sync(fd, data_only != 0)
        },
    )?;

    Ok(())
}

fn normalize_guest_path(path: &str) -> std::result::Result<String, i32> {
    if path.is_empty() {
        return Err(libc::ENOENT);
    }

    let absolute = path.starts_with('/');
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.pop().is_none() {
                    return Err(WASI_ENOTCAPABLE);
                }
            }
            part => parts.push(part),
        }
    }

    let joined = parts.join("/");
    if absolute {
        if joined.is_empty() {
            Ok("/".to_owned())
        } else {
            Ok(format!("/{joined}"))
        }
    } else if joined.is_empty() {
        Ok(".".to_owned())
    } else {
        Ok(joined)
    }
}

fn join_suffix(root: &PathBuf, suffix: &str) -> PathBuf {
    let mut path = root.clone();
    for component in suffix.split('/') {
        if !component.is_empty() && component != "." {
            path.push(component);
        }
    }
    path
}

fn read_cstr(caller: &mut Caller<'_, AppState>, ptr: i32) -> std::result::Result<String, i32> {
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

fn checked_range(ptr: i32, len: i32, memory_len: usize) -> std::result::Result<Range<usize>, i32> {
    let ptr = usize::try_from(ptr).map_err(|_| libc::EFAULT)?;
    let len = checked_len(len)?;
    let end = ptr.checked_add(len).ok_or(libc::EFAULT)?;
    if end > memory_len {
        return Err(libc::EFAULT);
    }
    Ok(ptr..end)
}

fn checked_len(len: i32) -> std::result::Result<usize, i32> {
    let len = usize::try_from(len).map_err(|_| libc::EINVAL)?;
    if len > MAX_IO_LEN {
        return Err(libc::EINVAL);
    }
    Ok(len)
}

fn read_guest(
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

fn write_guest(
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

fn io_error_from_errno(errno: i32) -> std::io::Error {
    std::io::Error::from_raw_os_error(errno)
}

fn io_errno(err: std::io::Error) -> i32 {
    err.raw_os_error().unwrap_or(libc::EIO)
}

fn neg_errno(errno: i32) -> i32 {
    -errno
}

fn file_trace(args: std::fmt::Arguments<'_>) {
    if std::env::var_os("WASMTIME_MARIADB_FILE_TRACE").is_some() {
        eprintln!("[wasmtime-mariadb:files] {args}");
    }
}
