use sha2::{Digest, Sha256};
use std::ffi::{c_char, CString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Seek, SeekFrom};
use std::os::fd::AsRawFd;
use std::os::unix::{ffi::OsStrExt, fs::OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::ptr;

const ENGINE: &str = "libblip-jni.so";
const SHA256: &str = "4125334ab2cef75a056b7bd542f736374c3f036be4c04ef12818ed4492476335";
type Start = unsafe extern "C" fn(i32, *const c_char, *const c_char, *const c_char, *const c_char);
type Stop = unsafe extern "C" fn();

pub(super) struct Host {
    stop: Stop,
    _paths: [CString; 3],
    _lock: File,
}

impl Host {
    pub(super) fn start(
        library: &Path,
        cache: &Path,
        state: &Path,
        server: &str,
        lock: &Path,
    ) -> Result<Self, &'static str> {
        let lock = OpenOptions::new()
            .create(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(0o600)
            .open(lock)
            .map_err(|_| "profile_unavailable")?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("host_already_running");
        }
        if let Some(parent) = cache.parent() {
            if parent == super::state::runtime_dir() {
                super::create_plain_directory(parent.parent().ok_or("profile_unavailable")?)?;
                super::create_plain_directory(parent)?;
            } else {
                fs::create_dir_all(parent).map_err(|_| "profile_unavailable")?;
            }
        }
        super::create_plain_directory(cache)?;
        super::create_plain_directory(state)?;
        let paths = [
            CString::new(cache.as_os_str().as_bytes()).map_err(|_| "profile_unavailable")?,
            CString::new(state.as_os_str().as_bytes()).map_err(|_| "profile_unavailable")?,
            CString::new(server).map_err(|_| "profile_unavailable")?,
        ];
        let file = verified(library)?;
        let descriptor = CString::new(format!("/proc/self/fd/{}", file.as_raw_fd())).unwrap();
        // This renderer-independent helper owns the vendor process lifetime.
        let stop = unsafe {
            let module = libc::dlopen(descriptor.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL);
            if module.is_null() {
                return Err("native_engine_load_failed");
            }
            let start = libc::dlsym(module, c"libblip_host".as_ptr());
            let stop = libc::dlsym(module, c"libblip_host_stop".as_ptr());
            if start.is_null() || stop.is_null() {
                return Err("native_engine_unsupported");
            }
            let start: Start = std::mem::transmute(start);
            let stop: Stop = std::mem::transmute(stop);
            start(
                1,
                paths[0].as_ptr(),
                paths[1].as_ptr(),
                paths[2].as_ptr(),
                ptr::null(),
            );
            stop
        };
        Ok(Self {
            stop,
            _paths: paths,
            _lock: lock,
        })
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        unsafe { (self.stop)() };
    }
}

fn cached(local: &Path) -> PathBuf {
    local.join("myDrive/Blip/runtime-1.2.8").join(ENGINE)
}

fn verified(path: &Path) -> Result<File, &'static str> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| "native_engine_missing")?;
    let stats = file.metadata().map_err(|_| "native_engine_unreadable")?;
    if !stats.is_file() || !(1..=64 * 1024 * 1024).contains(&stats.len()) {
        return Err("native_engine_unsupported");
    }
    let mut hash = Sha256::new();
    io::copy(&mut file, &mut hash).map_err(|_| "native_engine_unreadable")?;
    if hex::encode(hash.finalize()) != SHA256 {
        return Err("native_engine_unsupported");
    }
    file.seek(SeekFrom::Start(0))
        .map_err(|_| "native_engine_unreadable")?;
    Ok(file)
}

pub(super) fn library(local: &Path) -> Result<PathBuf, &'static str> {
    let target = cached(local);
    if verified(&target).is_ok() {
        return Ok(target);
    }
    if let Some(path) = std::env::var_os("MYDRIVE_BLIP_LIBRARY") {
        return import_library(local, Path::new(&path));
    }
    Err("native_engine_missing")
}

pub(super) fn import_library(local: &Path, path: &Path) -> Result<PathBuf, &'static str> {
    if !path.is_absolute() {
        return Err("native_engine_missing");
    }
    let mut source = verified(path)?;
    let target = cached(local);
    if verified(&target).is_ok() {
        return Ok(target);
    }
    let parent = target.parent().ok_or("profile_unavailable")?;
    fs::create_dir_all(parent.parent().ok_or("profile_unavailable")?)
        .map_err(|_| "profile_unavailable")?;
    super::create_plain_directory(parent)?;
    let mut output = tempfile::NamedTempFile::new_in(parent).map_err(|_| "profile_unavailable")?;
    io::copy(&mut source, &mut output).map_err(|_| "native_engine_unreadable")?;
    output
        .as_file()
        .sync_all()
        .map_err(|_| "native_engine_unreadable")?;
    if output.persist(&target).is_err() && verified(&target).is_err() {
        return Err("profile_unavailable");
    }
    Ok(target)
}
