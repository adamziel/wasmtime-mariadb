use std::collections::HashMap;
use std::fs::{File, Metadata, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

#[cfg(unix)]
use std::os::unix::fs::{FileExt, MetadataExt};

#[cfg(windows)]
use std::os::windows::fs::FileExt as WindowsFileExt;

#[cfg(unix)]
use rustix::fs::{FlockOperation, fcntl_lock};

#[cfg(windows)]
use fs4::{FileExt as Fs4FileExt, TryLockError};

use wasmtime::{Caller, Linker, Result};

use crate::{
    AppState, Cli, Preopen,
    guest_abi::{self, neg_errno},
};

const MODULE_NAME: &str = "wasmtime_mariadb_files";
const GUEST_FD_BASE: i32 = 20_000;

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

struct HostFileStat {
    size: i64,
    blocks: i64,
    block_size: i64,
    dev: i64,
    mode: i32,
    atime: i64,
    mtime: i64,
    ctime: i64,
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

        preopens.sort_by_key(|preopen| std::cmp::Reverse(preopen.guest.len()));

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

    #[cfg(any(unix, windows))]
    fn pread(&self, fd: i32, buf: &mut [u8], offset: u64) -> i32 {
        let inner = self.inner.lock().unwrap();
        let Some(host_file) = inner.files.get(&fd) else {
            return neg_errno(libc::EBADF);
        };
        match positioned_read(&host_file.file, buf, offset) {
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

    #[cfg(any(unix, windows))]
    fn pwrite(&self, fd: i32, buf: &[u8], offset: u64) -> i32 {
        let inner = self.inner.lock().unwrap();
        let Some(host_file) = inner.files.get(&fd) else {
            return neg_errno(libc::EBADF);
        };
        match positioned_write(&host_file.file, buf, offset) {
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

    #[cfg(any(unix, windows))]
    fn lock_exclusive(&self, fd: i32) -> i32 {
        let inner = self.inner.lock().unwrap();
        let Some(host_file) = inner.files.get(&fd) else {
            return neg_errno(libc::EBADF);
        };

        #[cfg(unix)]
        match fcntl_lock(&host_file.file, FlockOperation::NonBlockingLockExclusive) {
            Ok(()) => {
                file_trace(format_args!(
                    "lock_exclusive fd={fd} path={} rc=0",
                    host_file.path.display()
                ));
                0
            }
            Err(err) => {
                let errno = err.raw_os_error();
                file_trace(format_args!(
                    "lock_exclusive fd={fd} path={} errno={errno}",
                    host_file.path.display()
                ));
                neg_errno(errno)
            }
        }

        #[cfg(windows)]
        match Fs4FileExt::try_lock(&host_file.file) {
            Ok(()) => {
                file_trace(format_args!(
                    "lock_exclusive fd={fd} path={} rc=0",
                    host_file.path.display()
                ));
                0
            }
            Err(TryLockError::WouldBlock) => {
                file_trace(format_args!(
                    "lock_exclusive fd={fd} path={} errno={}",
                    host_file.path.display(),
                    libc::EAGAIN
                ));
                neg_errno(libc::EAGAIN)
            }
            Err(TryLockError::Error(err)) => {
                let errno = io_errno(err);
                file_trace(format_args!(
                    "lock_exclusive fd={fd} path={} errno={errno}",
                    host_file.path.display()
                ));
                neg_errno(errno)
            }
        }
    }

    #[cfg(any(unix, windows))]
    fn fstat(&self, fd: i32) -> std::result::Result<HostFileStat, i32> {
        let inner = self.inner.lock().unwrap();
        let Some(host_file) = inner.files.get(&fd) else {
            return Err(libc::EBADF);
        };
        stat_from_metadata(host_file.file.metadata().map_err(io_errno)?)
    }

    #[cfg(any(unix, windows))]
    fn stat(&self, guest_path: &str) -> std::result::Result<HostFileStat, i32> {
        let host_path = self.resolve(guest_path)?;
        stat_from_metadata(std::fs::metadata(&host_path).map_err(io_errno)?)
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

        Err(guest_abi::ERRNO_NOTCAPABLE)
    }
}

#[cfg(any(unix, windows))]
pub(crate) fn add_to_linker(linker: &mut Linker<AppState>) -> Result<()> {
    linker.func_wrap(
        MODULE_NAME,
        "open",
        |mut caller: Caller<'_, AppState>, path_ptr: i32, flags: i32, mode: i32| -> i32 {
            let path = match guest_abi::read_cstr(&mut caller, path_ptr) {
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
            let len = match guest_abi::checked_len(len) {
                Ok(len) => len,
                Err(errno) => return neg_errno(errno),
            };
            let mut buf = vec![0_u8; len];
            let rc = caller.data().files.pread(fd, &mut buf, offset as u64);
            if rc <= 0 {
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
        "read",
        |mut caller: Caller<'_, AppState>, fd: i32, buf_ptr: i32, len: i32| -> i32 {
            let len = match guest_abi::checked_len(len) {
                Ok(len) => len,
                Err(errno) => return neg_errno(errno),
            };
            let mut buf = vec![0_u8; len];
            let rc = caller.data().files.read(fd, &mut buf);
            if rc <= 0 {
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
        "pwrite",
        |mut caller: Caller<'_, AppState>, fd: i32, buf_ptr: i32, len: i32, offset: i64| -> i32 {
            let buf = match guest_abi::read(&mut caller, buf_ptr, len) {
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
            let buf = match guest_abi::read(&mut caller, buf_ptr, len) {
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

    linker.func_wrap(
        MODULE_NAME,
        "lock_exclusive",
        |caller: Caller<'_, AppState>, fd: i32| -> i32 { caller.data().files.lock_exclusive(fd) },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "fstat",
        |mut caller: Caller<'_, AppState>,
         fd: i32,
         size_ptr: i32,
         blocks_ptr: i32,
         block_size_ptr: i32,
         dev_ptr: i32,
         mode_ptr: i32,
         atime_ptr: i32,
         mtime_ptr: i32,
         ctime_ptr: i32|
         -> i32 {
            let stat = match caller.data().files.fstat(fd) {
                Ok(stat) => stat,
                Err(errno) => return neg_errno(errno),
            };
            write_file_stat(
                &mut caller,
                stat,
                [
                    size_ptr,
                    blocks_ptr,
                    block_size_ptr,
                    dev_ptr,
                    mode_ptr,
                    atime_ptr,
                    mtime_ptr,
                    ctime_ptr,
                ],
            )
            .map_or_else(neg_errno, |_| 0)
        },
    )?;

    linker.func_wrap(
        MODULE_NAME,
        "stat",
        |mut caller: Caller<'_, AppState>,
         path_ptr: i32,
         size_ptr: i32,
         blocks_ptr: i32,
         block_size_ptr: i32,
         dev_ptr: i32,
         mode_ptr: i32,
         atime_ptr: i32,
         mtime_ptr: i32,
         ctime_ptr: i32|
         -> i32 {
            let path = match guest_abi::read_cstr(&mut caller, path_ptr) {
                Ok(path) => path,
                Err(errno) => return neg_errno(errno),
            };
            let stat = match caller.data().files.stat(&path) {
                Ok(stat) => stat,
                Err(errno) => {
                    file_trace(format_args!("stat path={path:?} errno={errno}"));
                    return neg_errno(errno);
                }
            };
            write_file_stat(
                &mut caller,
                stat,
                [
                    size_ptr,
                    blocks_ptr,
                    block_size_ptr,
                    dev_ptr,
                    mode_ptr,
                    atime_ptr,
                    mtime_ptr,
                    ctime_ptr,
                ],
            )
            .map_or_else(neg_errno, |_| 0)
        },
    )?;

    Ok(())
}

#[cfg(not(any(unix, windows)))]
pub(crate) fn add_to_linker(_linker: &mut Linker<AppState>) -> Result<()> {
    // The fixture can still instantiate on unsupported hosts.
    Ok(())
}

#[cfg(unix)]
fn stat_from_metadata(metadata: Metadata) -> std::result::Result<HostFileStat, i32> {
    Ok(HostFileStat {
        size: i64::try_from(metadata.size()).map_err(|_| libc::EOVERFLOW)?,
        blocks: i64::try_from(metadata.blocks()).map_err(|_| libc::EOVERFLOW)?,
        block_size: i64::try_from(metadata.blksize()).map_err(|_| libc::EOVERFLOW)?,
        dev: i64::try_from(metadata.dev()).map_err(|_| libc::EOVERFLOW)?,
        mode: i32::try_from(metadata.mode()).map_err(|_| libc::EOVERFLOW)?,
        atime: metadata.atime(),
        mtime: metadata.mtime(),
        ctime: metadata.ctime(),
    })
}

#[cfg(windows)]
fn stat_from_metadata(metadata: Metadata) -> std::result::Result<HostFileStat, i32> {
    let size = i64::try_from(metadata.len()).map_err(|_| libc::EOVERFLOW)?;
    let blocks = size.saturating_add(4095) / 4096;
    let mode = if metadata.is_dir() {
        libc::S_IFDIR | libc::S_IREAD | libc::S_IWRITE
    } else {
        libc::S_IFREG | libc::S_IREAD | libc::S_IWRITE
    };
    Ok(HostFileStat {
        size,
        blocks,
        block_size: 4096,
        dev: 0,
        mode,
        atime: system_time_seconds(metadata.accessed()),
        mtime: system_time_seconds(metadata.modified()),
        ctime: system_time_seconds(metadata.created()),
    })
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
                    return Err(guest_abi::ERRNO_NOTCAPABLE);
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

fn join_suffix(root: &Path, suffix: &str) -> PathBuf {
    let mut path = root.to_path_buf();
    for component in suffix.split('/') {
        if !component.is_empty() && component != "." {
            path.push(component);
        }
    }
    path
}

#[cfg(any(unix, windows))]
fn write_file_stat(
    caller: &mut Caller<'_, AppState>,
    stat: HostFileStat,
    [size, blocks, block_size, dev, mode, atime, mtime, ctime]: [i32; 8],
) -> std::result::Result<(), i32> {
    for (ptr, value) in [
        (size, stat.size),
        (blocks, stat.blocks),
        (block_size, stat.block_size),
        (dev, stat.dev),
    ] {
        guest_abi::write(caller, ptr, &value.to_le_bytes())?;
    }
    guest_abi::write(caller, mode, &stat.mode.to_le_bytes())?;
    for (ptr, value) in [
        (atime, stat.atime),
        (mtime, stat.mtime),
        (ctime, stat.ctime),
    ] {
        guest_abi::write(caller, ptr, &value.to_le_bytes())?;
    }
    Ok(())
}

/// Reads at an explicit offset without changing MariaDB's shared file cursor.
#[cfg(unix)]
fn positioned_read(file: &File, buf: &mut [u8], offset: u64) -> std::io::Result<usize> {
    file.read_at(buf, offset)
}

/// Uses Windows' positional read operation for the same guest ABI contract.
#[cfg(windows)]
fn positioned_read(file: &File, buf: &mut [u8], offset: u64) -> std::io::Result<usize> {
    file.seek_read(buf, offset)
}

/// Writes at an explicit offset without changing MariaDB's shared file cursor.
#[cfg(unix)]
fn positioned_write(file: &File, buf: &[u8], offset: u64) -> std::io::Result<usize> {
    file.write_at(buf, offset)
}

/// Uses Windows' positional write operation for the same guest ABI contract.
#[cfg(windows)]
fn positioned_write(file: &File, buf: &[u8], offset: u64) -> std::io::Result<usize> {
    file.seek_write(buf, offset)
}

/// Converts optional Windows metadata timestamps into the guest's Unix seconds.
#[cfg(windows)]
fn system_time_seconds(value: std::io::Result<std::time::SystemTime>) -> i64 {
    value
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .and_then(|duration| i64::try_from(duration.as_secs()).ok())
        .unwrap_or(0)
}

fn io_error_from_errno(errno: i32) -> std::io::Error {
    #[cfg(unix)]
    {
        return std::io::Error::from_raw_os_error(errno);
    }

    #[cfg(windows)]
    {
        let kind = match errno {
            libc::EACCES | libc::EPERM => std::io::ErrorKind::PermissionDenied,
            libc::EAGAIN | libc::EWOULDBLOCK => std::io::ErrorKind::WouldBlock,
            libc::EEXIST => std::io::ErrorKind::AlreadyExists,
            libc::EINVAL => std::io::ErrorKind::InvalidInput,
            libc::ENOENT => std::io::ErrorKind::NotFound,
            libc::ENOSPC => std::io::ErrorKind::StorageFull,
            _ => std::io::ErrorKind::Other,
        };
        return std::io::Error::from(kind);
    }

    #[allow(unreachable_code)]
    std::io::Error::from_raw_os_error(errno)
}

fn io_errno(err: std::io::Error) -> i32 {
    #[cfg(unix)]
    {
        return err.raw_os_error().unwrap_or(libc::EIO);
    }

    #[cfg(windows)]
    {
        return match err.kind() {
            std::io::ErrorKind::NotFound => libc::ENOENT,
            std::io::ErrorKind::PermissionDenied => libc::EACCES,
            std::io::ErrorKind::ConnectionRefused => libc::ECONNREFUSED,
            std::io::ErrorKind::ConnectionReset => libc::ECONNRESET,
            std::io::ErrorKind::ConnectionAborted => libc::ECONNABORTED,
            std::io::ErrorKind::NotConnected => libc::ENOTCONN,
            std::io::ErrorKind::AddrInUse => libc::EADDRINUSE,
            std::io::ErrorKind::AddrNotAvailable => libc::EADDRNOTAVAIL,
            std::io::ErrorKind::BrokenPipe => libc::EPIPE,
            std::io::ErrorKind::AlreadyExists => libc::EEXIST,
            std::io::ErrorKind::WouldBlock => libc::EAGAIN,
            std::io::ErrorKind::InvalidInput | std::io::ErrorKind::InvalidData => libc::EINVAL,
            std::io::ErrorKind::TimedOut => libc::ETIMEDOUT,
            std::io::ErrorKind::WriteZero | std::io::ErrorKind::StorageFull => libc::ENOSPC,
            _ => libc::EIO,
        };
    }

    #[allow(unreachable_code)]
    err.raw_os_error().unwrap_or(libc::EIO)
}

fn file_trace(args: std::fmt::Arguments<'_>) {
    if std::env::var_os("WASMTIME_MARIADB_FILE_TRACE").is_some() {
        eprintln!("[wasmtime-mariadb:files] {args}");
    }
}
