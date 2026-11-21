use sha2::{Digest, Sha256};
use std::ffi::{c_char, c_void, CString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Seek, SeekFrom};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::ffi::OsStringExt;
use std::os::windows::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::ptr;
use windows_sys::Win32::Storage::Packaging::Appx::{
    GetPackagePathByFullName, GetPackagesByPackageFamily,
};
use windows_sys::Win32::System::LibraryLoader::{
    GetProcAddress, LoadLibraryExW, LOAD_LIBRARY_SEARCH_SYSTEM32,
};

const PACKAGE_FAMILY: &str = "BlipStudioInc.BlipApp_eydxbjyejh39j";

// Only this version of the vendor engine has the hosting ABI verified below.
const SUPPORTED_HASH: &str = "9672adea988ecc2236c232f764432a9a580852174f23a2e636780057c0c07ee2";
type JniEnvironment = *const *const *const c_void;
type Start = unsafe extern "system" fn(
    JniEnvironment,
    *const c_void,
    u8,
    *const c_char,
    *const c_char,
    *const c_char,
);
type Stop = unsafe extern "system" fn(JniEnvironment, *const c_void);

pub(super) struct Host {
    stop: Stop,
    _strings: [CString; 3],
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
            .share_mode(0)
            .open(lock)
            .map_err(|_| "host_already_running")?;
        super::create_plain_directory(cache)?;
        super::create_plain_directory(state)?;
        let strings = [
            path_string(cache)?,
            path_string(state)?,
            CString::new(server).map_err(|_| "profile_unavailable")?,
        ];
        let library = fs::canonicalize(library).map_err(|_| "native_engine_missing")?;
        // Keep the verified file open without write/delete sharing during LoadLibrary.
        let _engine = verified_library(&library)?;
        let wide: Vec<u16> = library.as_os_str().encode_wide().chain([0]).collect();
        // The DLL owns native threads. Its module stays loaded until this helper process exits.
        let (start, stop): (Start, Stop) = unsafe {
            let module =
                LoadLibraryExW(wide.as_ptr(), ptr::null_mut(), LOAD_LIBRARY_SEARCH_SYSTEM32);
            if module.is_null() {
                return Err("native_engine_load_failed");
            }
            let start = GetProcAddress(
                module,
                c"Java_net_blip_libblip_LibBlip_00024Companion_startHosting"
                    .as_ptr()
                    .cast(),
            )
            .ok_or("native_engine_unsupported")?;
            let stop = GetProcAddress(
                module,
                c"Java_net_blip_libblip_LibBlip_00024Companion_stopHosting"
                    .as_ptr()
                    .cast(),
            )
            .ok_or("native_engine_unsupported")?;
            (std::mem::transmute(start), std::mem::transmute(stop))
        };
        // The pinned export only obtains/releases these three UTF-8 strings before
        // calling the native host. Supply those JNI slots without creating a VM.
        let mut functions = [ptr::null::<c_void>(); 171];
        functions[169] = get_string as *const c_void;
        functions[170] = release_string as *const c_void;
        unsafe {
            start(
                &functions.as_ptr(),
                ptr::null(),
                1,
                strings[0].as_ptr(),
                strings[1].as_ptr(),
                strings[2].as_ptr(),
            );
        }
        Ok(Self {
            stop,
            _strings: strings,
            _lock: lock,
        })
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        // The pinned stop export does not dereference the JNI environment.
        unsafe { (self.stop)(ptr::null(), ptr::null()) };
    }
}

unsafe extern "system" fn get_string(
    _: JniEnvironment,
    value: *const c_char,
    copied: *mut u8,
) -> *const c_char {
    if !copied.is_null() {
        unsafe { *copied = 0 };
    }
    value
}

unsafe extern "system" fn release_string(_: JniEnvironment, _: *const c_char, _: *const c_char) {}

fn path_string(path: &Path) -> Result<CString, &'static str> {
    CString::new(path.to_str().ok_or("profile_unavailable")?).map_err(|_| "profile_unavailable")
}

pub(super) fn library(local: &Path) -> Result<PathBuf, &'static str> {
    let cached = cached_library(local);
    if verified_library(&cached).is_ok() {
        return Ok(cached);
    }
    let studio = local.join("OseanStudio");
    let configured: Option<serde_json::Value> = fs::read(studio.join("storage.json"))
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok());
    let legacy_runtime = std::env::var_os("OSEAN_STUDIO_DATA")
        .map(PathBuf::from)
        .or_else(|| {
            configured
                .as_ref()?
                .get("root")?
                .as_str()
                .map(PathBuf::from)
        })
        .unwrap_or(studio)
        .join("Runtimes/myDrive Blip");
    let candidates = [
        std::env::var_os("MYDRIVE_BLIP_DLL").map(PathBuf::from),
        std::env::var_os("MYDRIVE_BLIP_RUNTIME")
            .map(|root| PathBuf::from(root).join("blip/bin/blip-jni.dll")),
        Some(legacy_runtime.join("blip/bin/blip-jni.dll")),
        Some(local.join("Programs/Blip/bin/blip-jni.dll")),
    ];
    let mut error = "native_engine_missing";
    for path in candidates
        .into_iter()
        .flatten()
        .chain(installed_package_libraries())
        .filter(|path| path.is_absolute() && path.is_file())
    {
        match import_library(local, &path) {
            Ok(path) => return Ok(path),
            Err(reason) => error = reason,
        }
    }
    Err(error)
}

fn cached_library(local: &Path) -> PathBuf {
    local.join("myDrive/Blip/runtime-1.2.8/blip-jni.dll")
}

fn verified_library(path: &Path) -> Result<File, &'static str> {
    let mut engine = OpenOptions::new()
        .read(true)
        .share_mode(1)
        .open(path)
        .map_err(|_| "native_engine_missing")?;
    let attributes = engine.metadata().map_err(|_| "native_engine_unreadable")?;
    if !attributes.is_file() || !(1..=64 * 1024 * 1024).contains(&attributes.len()) {
        return Err("native_engine_unsupported");
    }
    let mut hash = Sha256::new();
    io::copy(&mut engine, &mut hash).map_err(|_| "native_engine_unreadable")?;
    if hex::encode(hash.finalize()) != SUPPORTED_HASH {
        return Err("native_engine_unsupported");
    }
    engine
        .seek(SeekFrom::Start(0))
        .map_err(|_| "native_engine_unreadable")?;
    Ok(engine)
}

pub(super) fn import_library(local: &Path, path: &Path) -> Result<PathBuf, &'static str> {
    if !path.is_absolute() {
        return Err("native_engine_missing");
    }
    let mut source = verified_library(path)?;
    let cached = cached_library(local);
    if verified_library(&cached).is_ok() {
        return Ok(cached);
    }
    let directory = cached.parent().ok_or("profile_unavailable")?;
    fs::create_dir_all(directory).map_err(|_| "profile_unavailable")?;
    super::check_plain_directory(directory)?;
    let mut output =
        tempfile::NamedTempFile::new_in(directory).map_err(|_| "profile_unavailable")?;
    io::copy(&mut source, &mut output).map_err(|_| "native_engine_unreadable")?;
    output
        .as_file()
        .sync_all()
        .map_err(|_| "native_engine_unreadable")?;
    if output.persist(&cached).is_err() && verified_library(&cached).is_err() {
        return Err("profile_unavailable");
    }
    Ok(cached)
}

fn installed_package_libraries() -> impl Iterator<Item = PathBuf> {
    let family: Vec<u16> = PACKAGE_FAMILY.encode_utf16().chain([0]).collect();
    let mut count = 0;
    let mut length = 0;
    let mut paths = Vec::new();
    unsafe {
        GetPackagesByPackageFamily(
            family.as_ptr(),
            &mut count,
            ptr::null_mut(),
            &mut length,
            ptr::null_mut(),
        );
        if (1..=16).contains(&count) && (1..=8192).contains(&length) {
            let mut names = vec![ptr::null_mut(); count as usize];
            let mut buffer = vec![0; length as usize];
            let status = GetPackagesByPackageFamily(
                family.as_ptr(),
                &mut count,
                names.as_mut_ptr(),
                &mut length,
                buffer.as_mut_ptr(),
            );
            if status == 0 {
                for name in names.into_iter().filter(|name| !name.is_null()) {
                    let mut length = 0;
                    GetPackagePathByFullName(name, &mut length, ptr::null_mut());
                    if !(2..=32768).contains(&length) {
                        continue;
                    }
                    let mut path = vec![0; length as usize];
                    if GetPackagePathByFullName(name, &mut length, path.as_mut_ptr()) == 0 {
                        let length = path
                            .iter()
                            .position(|part| *part == 0)
                            .unwrap_or(path.len());
                        let root = PathBuf::from(std::ffi::OsString::from_wide(&path[..length]));
                        paths.extend(
                            [
                                "bin/blip-jni.dll",
                                "app/bin/blip-jni.dll",
                                "Blip/bin/blip-jni.dll",
                            ]
                            .into_iter()
                            .map(|path| root.join(path)),
                        );
                    }
                }
            }
        }
    }
    paths.into_iter()
}
