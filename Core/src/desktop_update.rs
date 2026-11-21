use crate::updates;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    env, fs,
    path::{Path, PathBuf},
};

const STAGE_PREFIX: &str = ".mydrive-update-";
const PLAN_NAME: &str = "plan.json";
const STARTED_MARKER: &str = "install-started";
const ERROR_NAME: &str = "desktop-update-error.txt";
const HELPER_NAME: &str = if cfg!(windows) {
    "updater.exe"
} else {
    "updater"
};
const WAIT_SECONDS: u32 = 60;

#[derive(Deserialize)]
struct Request {
    version: String,
    target_version: String,
    app_path: PathBuf,
    pid: u32,
}

#[derive(Deserialize)]
struct PreparedRequest {
    plan_path: PathBuf,
    app_path: PathBuf,
    pid: u32,
}

#[derive(Deserialize, Serialize)]
struct Plan {
    app: PathBuf,
    data_dir: PathBuf,
    pid: u32,
}

struct InstallError {
    message: String,
    preserve_backup: bool,
}

impl From<String> for InstallError {
    fn from(message: String) -> Self {
        Self {
            message,
            preserve_backup: false,
        }
    }
}

pub fn prepare(payload: Value, data_dir: &Path, defer_install: bool) -> Result<PathBuf, String> {
    let request: Request =
        serde_json::from_value(payload).map_err(|_| "Invalid update request.")?;
    if !(1..=i32::MAX as u32).contains(&request.pid)
        || !request.app_path.is_absolute()
        || !data_dir.is_absolute()
    {
        return Err("Could not locate the running app for this update.".into());
    }
    platform::check_location(&request.app_path)?;
    let update = updates::check(&request.version)?
        .filter(|update| update.version == request.target_version)
        .ok_or("The available release changed. Check for updates again.")?;
    fs::create_dir_all(data_dir).map_err(|_| "Could not prepare the update working folder.")?;
    let staging = tempfile::Builder::new()
        .prefix(STAGE_PREFIX)
        .tempdir_in(staging_parent(&request.app_path)?)
        .map_err(|_| {
            "myDrive cannot update in this location. Move it to a writable folder and try again."
        })?;
    let package = staging.path().join(updates::asset_name()?);
    updates::download(&update, &package)?;
    platform::stage(&package, &request.app_path, &update.version)?;

    let helper = staging.path().join(HELPER_NAME);
    fs::copy(
        env::current_exe().map_err(|_| "Could not locate the update helper.")?,
        &helper,
    )
    .map_err(|_| "Could not stage the update helper.")?;
    let plan = Plan {
        app: request.app_path,
        data_dir: data_dir.into(),
        pid: request.pid,
    };
    let plan_path = staging.path().join(PLAN_NAME);
    fs::write(
        &plan_path,
        serde_json::to_vec(&plan).map_err(|_| "Could not prepare to restart myDrive.")?,
    )
    .map_err(|_| "Could not prepare to restart myDrive.")?;
    if defer_install && !platform::process_is_running(request.pid) {
        return Err("myDrive closed while the update was downloading.".into());
    }
    if !defer_install {
        platform::start_helper(&helper, &plan_path, staging.path())
            .map_err(|_| "Could not start the update helper.")?;
    }
    let _ = staging.keep();
    Ok(plan_path)
}

fn staging_parent(app: &Path) -> Result<PathBuf, String> {
    if cfg!(windows) {
        Ok(env::temp_dir())
    } else {
        app.parent()
            .map(Path::to_owned)
            .ok_or_else(|| "Could not locate the app’s folder.".into())
    }
}

fn prepared_path(request: &PreparedRequest, data_dir: &Path) -> Result<PathBuf, String> {
    let invalid = || "Could not locate the prepared update for this app.".to_string();
    let path = &request.plan_path;
    let staging = stage_directory(path)
        .filter(|_| path.is_absolute())
        .ok_or_else(invalid)?;
    let metadata = fs::symlink_metadata(staging).map_err(|_| invalid())?;
    let parent = staging
        .parent()
        .ok_or_else(invalid)?
        .canonicalize()
        .map_err(|_| invalid())?;
    let expected_parent = staging_parent(&request.app_path)?
        .canonicalize()
        .map_err(|_| invalid())?;
    if !metadata.file_type().is_dir() || parent != expected_parent {
        return Err(invalid());
    }
    let plan: Plan =
        serde_json::from_slice(&fs::read(path).map_err(|_| invalid())?).map_err(|_| invalid())?;
    if !request.app_path.is_absolute()
        || !data_dir.is_absolute()
        || plan.app != request.app_path
        || plan.data_dir != data_dir
        || plan.pid != request.pid
    {
        return Err(invalid());
    }
    Ok(staging.to_owned())
}

pub fn use_prepared(payload: Value, data_dir: &Path, install: bool) -> Result<(), String> {
    let request: PreparedRequest =
        serde_json::from_value(payload).map_err(|_| "Invalid update request.")?;
    let staging = prepared_path(&request, data_dir)?;
    let marker = staging.join(STARTED_MARKER);
    if install {
        platform::check_location(&request.app_path)?;
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&marker)
            .map_err(|_| "Could not claim the prepared update for installation.")?;
        if platform::start_helper(&staging.join(HELPER_NAME), &request.plan_path, &staging).is_err()
        {
            let _ = fs::remove_file(&marker);
            return Err("Could not start the update helper.".into());
        }
    } else if !marker.exists() {
        platform::cleanup(&staging);
    }
    Ok(())
}

pub fn take_error(data_dir: &Path) -> Option<String> {
    if !data_dir.is_absolute() {
        return None;
    }
    let file = data_dir.join(ERROR_NAME);
    let error = fs::read_to_string(&file).ok()?;
    let _ = fs::remove_file(file);
    Some(error)
}

fn stage_directory(plan_path: &Path) -> Option<&Path> {
    if plan_path.file_name().and_then(|name| name.to_str()) != Some(PLAN_NAME) {
        return None;
    }
    plan_path.parent().filter(|path| {
        path.file_name()
            .is_some_and(|name| name.to_string_lossy().starts_with(STAGE_PREFIX))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn prepared_update_is_bound_to_the_running_installation() {
        let app_dir = tempfile::tempdir().unwrap();
        let app = app_dir.path().join("myDrive");
        let data = app_dir.path().join("data");
        let staging = tempfile::Builder::new()
            .prefix(STAGE_PREFIX)
            .tempdir_in(staging_parent(&app).unwrap())
            .unwrap();
        let path = staging.path().join(PLAN_NAME);
        let pid = std::process::id();
        let plan = Plan {
            app: app.clone(),
            data_dir: data.clone(),
            pid,
        };
        fs::write(&path, serde_json::to_vec(&plan).unwrap()).unwrap();

        let request = |pid| json!({"plan_path":path,"app_path":app,"pid":pid});
        assert!(use_prepared(request(pid + 1), &data, false).is_err());
        assert!(use_prepared(request(pid), &app_dir.path().join("other-data"), false).is_err());
        assert!(path.exists());
        use_prepared(request(pid), &data, false).unwrap();
        assert!(!path.exists());
        assert!(app_dir.path().exists());
    }
}

pub fn finish(plan_path: &Path) {
    let Some(staging) = stage_directory(plan_path) else {
        return;
    };
    let Ok(content) = fs::read(plan_path) else {
        return;
    };
    let Ok(plan) = serde_json::from_slice::<Plan>(&content) else {
        return;
    };
    let mut preserve_backup = false;
    if platform::wait_for_exit(plan.pid) {
        if let Err(error) = platform::install_and_restart(staging, &plan.app) {
            preserve_backup = error.preserve_backup;
            let _ = fs::write(plan.data_dir.join(ERROR_NAME), error.message);
            let _ = platform::restart(&plan.app);
        }
    } else {
        let _ = fs::write(
            plan.data_dir.join(ERROR_NAME),
            "myDrive did not close in time. Quit and reopen it, then try the update again.",
        );
    }
    if !preserve_backup {
        platform::cleanup(staging);
    }
}

#[cfg(windows)]
mod platform {
    use super::*;
    use std::{
        ffi::{OsStr, OsString},
        os::windows::ffi::OsStrExt,
        process::Command,
        ptr::null,
    };
    use windows_sys::Win32::{
        Foundation::{
            CloseHandle, GetLastError, ERROR_INVALID_PARAMETER, WAIT_OBJECT_0, WAIT_TIMEOUT,
        },
        System::Threading::{
            CreateProcessW, OpenProcess, WaitForSingleObject, CREATE_NO_WINDOW,
            PROCESS_INFORMATION, PROCESS_SYNCHRONIZE, STARTUPINFOW,
        },
    };

    pub fn check_location(app: &Path) -> Result<(), String> {
        if app.is_file()
            && app
                .file_name()
                .is_some_and(|name| name.eq_ignore_ascii_case("myDrive.exe"))
        {
            Ok(())
        } else {
            Err("Install myDrive with the Windows installer before updating.".into())
        }
    }

    pub fn stage(_package: &Path, _app: &Path, _version: &str) -> Result<(), String> {
        Ok(())
    }

    pub fn start_helper(helper: &Path, plan: &Path, directory: &Path) -> std::io::Result<()> {
        let wide = |value: &OsStr| value.encode_wide().chain([0]).collect::<Vec<_>>();
        let executable = wide(helper.as_os_str());
        let working_directory = wide(directory.as_os_str());
        let mut command = OsString::from("\"");
        command.push(helper.as_os_str());
        command.push("\" --finish-desktop-update \"");
        command.push(plan.as_os_str());
        command.push("\"");
        let mut arguments = wide(&command);
        let startup = STARTUPINFOW {
            cb: std::mem::size_of::<STARTUPINFOW>() as u32,
            ..Default::default()
        };
        let mut process = PROCESS_INFORMATION::default();
        // The UI waits for EOF on the core response before it can quit.
        // The updater must never inherit that pipe or keep the UI waiting.
        let started = unsafe {
            CreateProcessW(
                executable.as_ptr(),
                arguments.as_mut_ptr(),
                null(),
                null(),
                0,
                CREATE_NO_WINDOW,
                null(),
                working_directory.as_ptr(),
                &startup,
                &mut process,
            )
        };
        if started == 0 {
            return Err(std::io::Error::last_os_error());
        }
        unsafe {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
        }
        Ok(())
    }

    pub fn wait_for_exit(pid: u32) -> bool {
        // The app owns this PID. A terminated process may already have been reaped.
        unsafe {
            let process = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid);
            if process.is_null() {
                return GetLastError() == ERROR_INVALID_PARAMETER;
            }
            let result = WaitForSingleObject(process, WAIT_SECONDS * 1000);
            CloseHandle(process);
            result == WAIT_OBJECT_0
        }
    }

    pub fn process_is_running(pid: u32) -> bool {
        unsafe {
            let process = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid);
            if process.is_null() {
                return false;
            }
            let result = WaitForSingleObject(process, 0);
            CloseHandle(process);
            result == WAIT_TIMEOUT
        }
    }

    pub fn install_and_restart(staging: &Path, app: &Path) -> Result<(), InstallError> {
        let mut directory = std::ffi::OsString::from("/DIR=");
        directory.push(
            app.parent()
                .ok_or_else(|| "Could not locate the installation folder.".to_string())?,
        );
        let installer = staging.join(updates::asset_name()?);
        let restart_startup = crate::startup::pause_for_update();
        let exit = Command::new(installer)
            .args([
                "/VERYSILENT",
                "/SUPPRESSMSGBOXES",
                "/NORESTART",
                "/RESTARTEXITCODE=3010",
                "/NORESTARTAPPLICATIONS",
                "/NOFORCECLOSEAPPLICATIONS",
            ])
            .arg(directory)
            .status();
        if restart_startup {
            crate::startup::resume_after_update();
        }
        let exit = exit.map_err(|_| "Windows could not run the myDrive installer.".to_string())?;
        if !exit.success() {
            return Err("The Windows installer could not finish the update."
                .to_string()
                .into());
        }
        restart(app).map_err(Into::into)
    }

    pub fn restart(app: &Path) -> Result<(), String> {
        Command::new(app)
            .current_dir(
                app.parent()
                    .ok_or("Could not locate the installation folder.")?,
            )
            .spawn()
            .map(|_| ())
            .map_err(|_| "Windows could not reopen myDrive.".into())
    }

    pub fn cleanup(staging: &Path) {
        if let Ok(name) = updates::asset_name() {
            let _ = fs::remove_file(staging.join(name));
        }
        let _ = fs::remove_file(staging.join(PLAN_NAME));
        let _ = fs::remove_file(staging.join(STARTED_MARKER));
        let _ = fs::remove_file(staging.join(HELPER_NAME));
        let _ = fs::remove_dir(staging);
    }
}

#[cfg(unix)]
mod platform {
    use super::*;
    use std::{
        process::{Command, Stdio},
        thread,
        time::{Duration, Instant},
    };
    const REPLACEMENT: &str = if cfg!(target_os = "macos") {
        "replacement.app"
    } else {
        "replacement"
    };

    pub fn start_helper(helper: &Path, plan: &Path, directory: &Path) -> std::io::Result<()> {
        Command::new(helper)
            .arg("--finish-desktop-update")
            .arg(plan)
            .current_dir(directory)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map(|_| ())
    }

    pub fn wait_for_exit(pid: u32) -> bool {
        let deadline = Instant::now() + Duration::from_secs(WAIT_SECONDS.into());
        while Instant::now() < deadline {
            if !process_is_running(pid) {
                return true;
            }
            thread::sleep(Duration::from_millis(250));
        }
        false
    }

    pub fn process_is_running(pid: u32) -> bool {
        (unsafe { libc::kill(pid as i32, 0) == 0 })
            || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
    }

    pub fn install_and_restart(staging: &Path, app: &Path) -> Result<(), InstallError> {
        platform_swap::replace(staging, app)?;
        if let Err(error) = restart(app) {
            return match platform_swap::restore(staging, app) {
                Ok(()) => Err(error.into()),
                Err(_) => Err(InstallError {
                    message: "myDrive could not reopen the update. A backup is in its installation folder.".into(),
                    preserve_backup: true,
                }),
            };
        }
        Ok(())
    }

    pub fn cleanup(staging: &Path) {
        let _ = fs::remove_dir_all(staging);
    }

    #[cfg(target_os = "linux")]
    mod platform_swap {
        use super::*;
        use std::{io::Read, os::unix::fs::PermissionsExt};

        fn appimage(path: &Path) -> bool {
            let mut header = [0; 11];
            fs::File::open(path)
                .and_then(|mut file| file.read_exact(&mut header))
                .is_ok()
                && &header[..4] == b"\x7fELF"
                && &header[8..] == b"AI\x02"
        }

        pub fn check_location(app: &Path) -> Result<(), String> {
            if appimage(app) {
                Ok(())
            } else {
                Err("Open myDrive from its AppImage before updating.".into())
            }
        }

        pub fn stage(package: &Path, app: &Path, _version: &str) -> Result<(), String> {
            if !appimage(package) {
                return Err("The downloaded package is not a myDrive AppImage.".into());
            }
            let permissions = fs::metadata(app)
                .map_err(|_| "Could not read the current AppImage permissions.")?
                .permissions();
            fs::set_permissions(
                package,
                fs::Permissions::from_mode(permissions.mode() & 0o777),
            )
            .and_then(|()| fs::rename(package, package.with_file_name(REPLACEMENT)))
            .map_err(|_| "Could not prepare the new AppImage.".into())
        }

        pub fn replace(staging: &Path, app: &Path) -> Result<(), String> {
            let backup = staging.join("previous");
            fs::hard_link(app, &backup)
                .or_else(|_| fs::copy(app, &backup).map(|_| ()))
                .and_then(|()| fs::rename(staging.join(REPLACEMENT), app))
                .map_err(|_| "Could not replace the AppImage in its current folder.".into())
        }

        pub fn restore(staging: &Path, app: &Path) -> std::io::Result<()> {
            fs::rename(staging.join("previous"), app)
        }

        pub fn restart(app: &Path) -> Result<(), String> {
            Command::new(app)
                .current_dir(
                    app.parent()
                        .ok_or("Could not locate the AppImage folder.")?,
                )
                .env_remove("APPIMAGE")
                .env_remove("APPDIR")
                .env_remove("ARGV0")
                .env_remove("OWD")
                .spawn()
                .map(|_| ())
                .map_err(|_| "Linux could not reopen the updated AppImage.".into())
        }
    }

    #[cfg(target_os = "macos")]
    mod platform_swap {
        use super::*;
        use std::{ffi::CString, os::unix::ffi::OsStrExt};

        fn plist(app: &Path, key: &str) -> Option<String> {
            let output = Command::new("/usr/libexec/PlistBuddy")
                .args(["-c", &format!("Print :{key}")])
                .arg(app.join("Contents/Info.plist"))
                .output()
                .ok()?;
            output
                .status
                .success()
                .then(|| String::from_utf8_lossy(&output.stdout).trim().into())
        }

        pub fn check_location(app: &Path) -> Result<(), String> {
            if app.extension().and_then(|value| value.to_str()) == Some("app")
                && plist(app, "CFBundleIdentifier").as_deref() == Some("io.mydrive.MyDrive")
            {
                Ok(())
            } else {
                Err("Move myDrive to Applications before updating.".into())
            }
        }

        pub fn stage(package: &Path, _app: &Path, version: &str) -> Result<(), String> {
            let mount = package.with_file_name("image");
            let replacement = package.with_file_name(REPLACEMENT);
            fs::create_dir(&mount)
                .map_err(|_| "Could not prepare to open the update disk image.")?;
            let mounted = Command::new("/usr/bin/hdiutil")
                .args([
                    "attach",
                    "-readonly",
                    "-nobrowse",
                    "-noautoopen",
                    "-mountpoint",
                ])
                .arg(&mount)
                .arg(package)
                .stdin(Stdio::null())
                .output()
                .is_ok_and(|output| output.status.success());
            if !mounted {
                return Err("macOS could not open the update disk image.".into());
            }
            let bundle = mount.join("myDrive.app");
            let correct_bundle = check_location(&bundle).is_ok()
                && plist(&bundle, "CFBundleShortVersionString").as_deref() == Some(version);
            let copied = correct_bundle
                && Command::new("/usr/bin/ditto")
                    .arg(&bundle)
                    .arg(&replacement)
                    .output()
                    .is_ok_and(|output| output.status.success());
            // Always detach before the parent can close or the stage can be cleaned up.
            let detached = Command::new("/usr/bin/hdiutil")
                .arg("detach")
                .arg(&mount)
                .output()
                .is_ok_and(|output| output.status.success());
            if !detached {
                return Err("macOS could not close the update disk image.".into());
            }
            let verified = copied
                && Command::new("/usr/bin/codesign")
                    .args(["--verify", "--deep", "--strict"])
                    .arg(&replacement)
                    .output()
                    .is_ok_and(|output| output.status.success());
            if !verified {
                return Err("macOS could not verify the myDrive app in this update.".into());
            }
            Ok(())
        }

        pub fn replace(staging: &Path, app: &Path) -> Result<(), String> {
            restore(staging, app)
                .map_err(|_| "macOS could not replace myDrive in this folder.".into())
        }

        pub fn restore(staging: &Path, app: &Path) -> std::io::Result<()> {
            let replacement = CString::new(staging.join(REPLACEMENT).as_os_str().as_bytes())?;
            let app = CString::new(app.as_os_str().as_bytes())?;
            let result = unsafe {
                libc::renameatx_np(
                    libc::AT_FDCWD,
                    replacement.as_ptr(),
                    libc::AT_FDCWD,
                    app.as_ptr(),
                    libc::RENAME_SWAP,
                )
            };
            if result == 0 {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        }

        pub fn restart(app: &Path) -> Result<(), String> {
            if Command::new("/usr/bin/open")
                .arg(app)
                .status()
                .is_ok_and(|status| status.success())
            {
                Ok(())
            } else {
                Err("macOS could not reopen myDrive.".into())
            }
        }
    }

    pub use platform_swap::{check_location, restart, stage};

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        #[ignore = "Requires the desktop package built by this workflow"]
        fn stages_and_restores_the_packaged_update() {
            let source = PathBuf::from(env::var_os("MYDRIVE_UPDATE_FIXTURE_PACKAGE").unwrap());
            let version = env::var("MYDRIVE_UPDATE_FIXTURE_VERSION").unwrap();
            let root = tempfile::tempdir().unwrap();
            let staging = tempfile::tempdir_in(root.path()).unwrap();
            let package = staging.path().join(updates::asset_name().unwrap());
            fs::copy(&source, &package).unwrap();
            let app = if cfg!(target_os = "macos") {
                let app = root.path().join("myDrive.app");
                fs::create_dir(&app).unwrap();
                fs::write(app.join("previous-version"), b"previous build").unwrap();
                app
            } else {
                let app = root.path().join("myDrive.AppImage");
                fs::write(&app, b"\x7fELF\0\0\0\0AI\x02previous build").unwrap();
                app
            };
            stage(&package, &app, &version).unwrap();
            platform_swap::replace(staging.path(), &app).unwrap();
            if cfg!(target_os = "macos") {
                assert!(app.join("Contents/MacOS/myDrive").is_file());
            } else {
                assert_eq!(
                    fs::metadata(&app).unwrap().len(),
                    fs::metadata(source).unwrap().len()
                );
            }
            platform_swap::restore(staging.path(), &app).unwrap();
            if cfg!(target_os = "macos") {
                assert_eq!(
                    fs::read(app.join("previous-version")).unwrap(),
                    b"previous build"
                );
            } else {
                assert_eq!(
                    fs::read(app).unwrap(),
                    b"\x7fELF\0\0\0\0AI\x02previous build"
                );
            }
        }
    }
}
