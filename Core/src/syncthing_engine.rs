//! User-session engine lifecycle. No GUI wrapper, service installation, or config reset.
use crate::syncthing::{Api, Connection};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    env, fs,
    io::{Read, Write},
    net::TcpStream,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

const VERSION: &str = "v2.1.7";
const LIMIT: u64 = 100 * 1024 * 1024;

#[derive(Deserialize)]
struct Config {
    gui: Gui,
}
#[derive(Deserialize)]
struct Gui {
    #[serde(rename = "@enabled", default)]
    enabled: String,
    #[serde(rename = "@tls", default)]
    tls: String,
    address: String,
    apikey: String,
}

fn connection(path: &Path) -> Result<Connection, String> {
    let xml =
        fs::read_to_string(path).map_err(|_| "Cannot read the selected Syncthing config.xml.")?;
    if xml.contains("<!DOCTYPE") {
        return Err("Syncthing configuration must not contain a DTD.".into());
    }
    let c: Config =
        quick_xml::de::from_str(&xml).map_err(|_| "Cannot parse Syncthing config.xml.")?;
    if c.gui.enabled == "false" {
        return Err("Syncthing's local GUI/API is disabled. Enable it in its config.xml to connect myDrive.".into());
    }
    let address = c
        .gui
        .address
        .replacen("0.0.0.0:", "127.0.0.1:", 1)
        .replacen("[::]:", "[::1]:", 1);
    let tls = c.gui.tls == "true";
    let certificate = path.parent().unwrap().join("https-cert.pem");
    let result = Connection {
        endpoint: format!("{}://{}", if tls { "https" } else { "http" }, address),
        api_key: c.gui.apikey,
        certificate_pem: if tls {
            fs::read_to_string(certificate).unwrap_or_default()
        } else {
            String::new()
        },
    };
    Api::new(&result)?; // Validate loopback endpoint before probing or starting anything.
    Ok(result)
}

fn home() -> PathBuf {
    PathBuf::from(
        env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap_or_default(),
    )
}
fn configs() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    for name in ["STHOMEDIR", "STCONFDIR"] {
        if let Some(path) = env::var_os(name) {
            paths.push(PathBuf::from(path).join("config.xml"));
        }
    }
    if cfg!(windows) {
        for name in ["LOCALAPPDATA", "APPDATA"] {
            if let Some(path) = env::var_os(name) {
                paths.push(PathBuf::from(path).join("Syncthing/config.xml"));
            }
        }
    } else if cfg!(target_os = "macos") {
        paths.push(home().join("Library/Application Support/Syncthing/config.xml"));
    }
    if let Some(path) = env::var_os("XDG_STATE_HOME") {
        paths.push(PathBuf::from(path).join("syncthing/config.xml"));
    }
    paths.push(home().join(".local/state/syncthing/config.xml"));
    if let Some(path) = env::var_os("XDG_CONFIG_HOME") {
        paths.push(PathBuf::from(path).join("syncthing/config.xml"));
    }
    paths.push(home().join(".config/syncthing/config.xml"));
    paths
}

fn executable_name() -> &'static str {
    if cfg!(windows) {
        "syncthing.exe"
    } else {
        "syncthing"
    }
}
fn binaries(data: &Path) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if cfg!(windows) {
        if let Some(path) = env::var_os("APPDATA") {
            paths.push(PathBuf::from(path).join("SyncTrayzor/syncthing.exe"));
        }
        if let Some(path) = env::var_os("LOCALAPPDATA") {
            paths.push(PathBuf::from(&path).join("Microsoft/WinGet/Links/syncthing.exe"));
            paths.push(PathBuf::from(path).join("Programs/SyncTrayzor/syncthing.exe"));
        }
        for var in ["ProgramFiles", "ProgramFiles(x86)"] {
            if let Some(path) = env::var_os(var) {
                paths.push(PathBuf::from(&path).join("SyncTrayzor/syncthing.exe"));
                paths.push(PathBuf::from(path).join("Syncthing/syncthing.exe"));
            }
        }
        paths.push(home().join("scoop/apps/syncthing/current/syncthing.exe"));
    } else {
        for root in [PathBuf::from("/Applications"), home().join("Applications")] {
            for app in ["Syncthing.app", "syncthing.app"] {
                for inner in [
                    "Contents/Resources/syncthing/syncthing",
                    "Contents/Resources/syncthing",
                    "Contents/MacOS/syncthing",
                ] {
                    paths.push(root.join(app).join(inner));
                }
            }
        }
        for root in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            paths.push(Path::new(root).join("syncthing"));
        }
    }
    if let Some(path) = env::var_os("PATH") {
        paths.extend(env::split_paths(&path).map(|p| p.join(executable_name())));
    }
    paths.push(data.join("engine").join(executable_name()));
    paths
}

fn quiet_command(binary: &Path) -> Command {
    let mut cmd = Command::new(binary);
    cmd.env_remove("MYDRIVE_SMB_USERNAME")
        .env_remove("MYDRIVE_SMB_PASSWORD")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW, including paths/generate/tar.
    }
    cmd
}

fn package() -> Result<(&'static str, &'static str), String> {
    match (env::consts::OS, env::consts::ARCH) {
        ("windows", "x86_64") => Ok(("windows-amd64", "3ce7da770f546a8d02b65b2e7ee31f2a3b8b7c3f990ede045590cca4172ecfe1")),
        ("macos", "aarch64") => Ok(("macos-arm64", "2df075b463231a307c91da657157beaed06383a941ba7ea04d33d536e3c4af38")),
        ("macos", "x86_64") => Ok(("macos-amd64", "b8be90176d0f24daebae7b5aaddac52ebfae395df6d99f5e0e54656db00868cb")),
        _ => Err("Automatic Syncthing installation supports Windows x64 and Mac Intel/Apple Silicon. Install Syncthing for this platform first.".into()),
    }
}
fn verify(bytes: &[u8], expected: &str) -> Result<(), String> {
    if hex::encode(Sha256::digest(bytes)) != expected {
        return Err(
            "Syncthing download checksum did not match. Nothing was installed; try again.".into(),
        );
    }
    Ok(())
}
fn install(data: &Path) -> Result<PathBuf, String> {
    let (platform, digest) = package()?;
    let stem = format!("syncthing-{platform}-{VERSION}");
    let url =
        format!("https://github.com/syncthing/syncthing/releases/download/{VERSION}/{stem}.zip");
    let client = reqwest::blocking::Client::builder()
        .https_only(true)
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    client.get(url).send().and_then(|r| r.error_for_status()).map_err(|_| "Could not download the official Syncthing engine. Check your internet connection and retry.")?
        .take(LIMIT + 1).read_to_end(&mut bytes).map_err(|_| "Syncthing download was interrupted.")?;
    if bytes.len() as u64 > LIMIT {
        return Err("Syncthing download exceeded its size limit.".into());
    }
    verify(&bytes, digest)?;
    let dir = data.join("engine");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut archive = tempfile::NamedTempFile::new_in(&dir).map_err(|e| e.to_string())?;
    archive.write_all(&bytes).map_err(|e| e.to_string())?;
    archive.flush().map_err(|e| e.to_string())?;
    let output = tempfile::NamedTempFile::new_in(&dir).map_err(|e| e.to_string())?;
    // Extract one known archive member to a file descriptor; never unpack archive paths.
    let tar = if cfg!(windows) {
        PathBuf::from(env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into()))
            .join("System32/tar.exe")
    } else {
        PathBuf::from("/usr/bin/tar")
    };
    let status = quiet_command(&tar)
        .arg("-xOf")
        .arg(archive.path())
        .arg(format!("{stem}/{}", executable_name()))
        .stdout(output.as_file().try_clone().map_err(|e| e.to_string())?)
        .status()
        .map_err(|_| "Cannot extract the Syncthing package using the system archive tool.")?;
    if !status.success()
        || output
            .as_file()
            .metadata()
            .map_err(|e| e.to_string())?
            .len()
            == 0
    {
        return Err("Cannot extract the verified Syncthing package.".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        output
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o755))
            .map_err(|e| e.to_string())?;
    }
    output.as_file().sync_all().map_err(|e| e.to_string())?;
    let target = dir.join(executable_name());
    output
        .persist_noclobber(&target)
        .map_err(|e| e.to_string())?;
    Ok(target)
}

fn listening(c: &Connection) -> bool {
    let Ok(url) = url::Url::parse(&c.endpoint) else {
        return false;
    };
    url.socket_addrs(|| Some(8384)).is_ok_and(|addrs| {
        addrs
            .into_iter()
            .any(|a| TcpStream::connect_timeout(&a, Duration::from_millis(200)).is_ok())
    })
}
fn ready(path: &Path) -> Option<Connection> {
    let c = connection(path).ok()?;
    if !Api::available(&c) {
        return None;
    }
    Some(c)
}
fn response(c: Connection, path: &Path, state: &str, binary: Option<&Path>) -> Value {
    json!({"connection": c, "config_path": path, "state": state, "binary_path": binary})
}

#[cfg(windows)]
fn detached(
    binary: &Path,
    args: &[String],
    working_dir: &Path,
) -> Result<Option<std::process::Child>, String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::{Foundation::CloseHandle, System::Threading::*};
    // Redirected sidecar pipes must never be inherited by the long-lived daemon.
    // bInheritHandles=false is deliberate: Go's monitor would otherwise keep
    // a request pipe open after the core exits, deadlocking the native bridge.
    fn quote(s: &str) -> String {
        let mut out = String::from("\"");
        let mut slashes = 0;
        for c in s.chars() {
            if c == '\\' {
                slashes += 1;
                continue;
            }
            out.extend(std::iter::repeat_n(
                '\\',
                if c == '"' { slashes * 2 + 1 } else { slashes },
            ));
            slashes = 0;
            out.push(c);
        }
        out.extend(std::iter::repeat_n('\\', slashes * 2));
        out.push('"');
        out
    }
    let app: Vec<u16> = binary.as_os_str().encode_wide().chain(Some(0)).collect();
    let cwd: Vec<u16> = working_dir
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let line = std::iter::once(binary.to_string_lossy().into_owned())
        .chain(args.iter().cloned())
        .map(|a| quote(&a))
        .collect::<Vec<_>>()
        .join(" ");
    let mut line: Vec<u16> = line.encode_utf16().chain(Some(0)).collect();
    unsafe {
        let mut startup: STARTUPINFOW = std::mem::zeroed();
        startup.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        let mut info: PROCESS_INFORMATION = std::mem::zeroed();
        if CreateProcessW(
            app.as_ptr(),
            line.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP,
            std::ptr::null(),
            cwd.as_ptr(),
            &startup,
            &mut info,
        ) == 0
        {
            return Err(
                "Could not start the installed Syncthing engine. Check its executable permissions."
                    .into(),
            );
        }
        CloseHandle(info.hThread);
        CloseHandle(info.hProcess);
    }
    Ok(None)
}

#[cfg(not(windows))]
fn detached(
    binary: &Path,
    args: &[String],
    working_dir: &Path,
) -> Result<Option<std::process::Child>, String> {
    use std::os::unix::process::CommandExt;
    quiet_command(binary)
        .args(args)
        .current_dir(working_dir)
        .process_group(0)
        .spawn()
        .map(Some)
        .map_err(|_| {
            "Could not start the installed Syncthing engine. Check its executable permissions."
                .into()
        })
}

pub fn ensure(payload: &Value, data: &Path) -> Result<Value, String> {
    if !data.is_absolute() {
        return Err("An absolute myDrive data directory is required.".into());
    }
    fs::create_dir_all(data).map_err(|e| e.to_string())?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(data.join("syncthing-engine.lock"))
        .map_err(|e| e.to_string())?;
    let deadline = Instant::now() + Duration::from_secs(150);
    while lock.try_lock().is_err() {
        if Instant::now() > deadline {
            return Err("Syncthing setup is already in progress. Try again shortly.".into());
        }
        thread::sleep(Duration::from_millis(200));
    }
    let explicit = payload["config_path"].as_str().filter(|s| !s.is_empty());
    let candidates = configs();
    let path = if let Some(explicit) = explicit {
        let path = PathBuf::from(explicit);
        if !path.is_absolute() {
            return Err("Choose an absolute Syncthing config.xml path.".into());
        }
        if !path.is_file() {
            return Err(
                "The selected Syncthing config.xml is missing. Choose it again in Sync settings."
                    .into(),
            );
        }
        path
    } else {
        // Prefer an authenticated running instance among known configurations.
        for path in &candidates {
            if let Some(c) = ready(path) {
                return Ok(response(c, path, "running", None));
            }
        }
        candidates
            .iter()
            .find(|p| p.is_file())
            .cloned()
            .or_else(|| candidates.first().cloned())
            .ok_or("Cannot find the Syncthing configuration directory.")?
    };
    if let Some(c) = ready(&path) {
        return Ok(response(c, &path, "running", None));
    }
    if path.is_file() {
        let c = connection(&path)?;
        if listening(&c) {
            // A listener may be starting up or have invalid auth/TLS. Never compete with it.
            for _ in 0..20 {
                if let Some(c) = ready(&path) {
                    return Ok(response(c, &path, "running", None));
                }
                thread::sleep(Duration::from_millis(250));
            }
            return Err("Syncthing's API address is already in use, but myDrive cannot authenticate. Check the config, API key and HTTPS certificate in Sync settings.".into());
        }
    }
    let supplied = payload["binary_path"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from);
    let existing = supplied.or_else(|| binaries(data).into_iter().find(|p| p.is_file()));
    let installed = existing.is_none();
    let binary = match existing {
        Some(p) => p,
        None => install(data)?,
    };
    let dir = path
        .parent()
        .ok_or("Invalid Syncthing configuration path.")?;
    if !path.exists() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        let status = quiet_command(&binary)
            .args(["generate", "--home"])
            .arg(dir)
            .env("STNODEFAULTFOLDER", "1")
            .status()
            .map_err(|_| "Cannot generate the Syncthing configuration.")?;
        if !status.success() {
            return Err("Syncthing could not generate its configuration.".into());
        }
    }
    connection(&path)?;
    // Respect separate default database paths when the installed engine reports them.
    let mut paths_cmd = quiet_command(&binary);
    let reported = paths_cmd.arg("paths").stdout(Stdio::piped()).output().ok();
    let mut db_dir = dir.to_path_buf();
    if let Some(output) = reported {
        let text = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<_> = text.lines().collect();
        let value = |label: &str| {
            lines
                .iter()
                .position(|l| l.trim() == label)
                .and_then(|i| lines.get(i + 1))
                .map(|s| PathBuf::from(s.trim()))
        };
        if value("Configuration file:").as_deref() == Some(path.as_path()) {
            if let Some(db) = value("Database location:") {
                if let Some(parent) = db.parent() {
                    db_dir = parent.to_path_buf();
                }
            }
        }
    }
    let args = vec![
        "serve".into(),
        "--config".into(),
        dir.to_string_lossy().into_owned(),
        "--data".into(),
        db_dir.to_string_lossy().into_owned(),
        "--no-browser".into(),
        format!("--log-file={}", data.join("syncthing-engine.log").display()),
    ];
    // Windows console suppression must also reach Syncthing's monitor/worker.
    // CREATE_NO_WINDOW cannot be combined with DETACHED_PROCESS (Windows ignores it).
    #[cfg(windows)]
    let args = {
        let mut args = args;
        args.push("--no-console".into());
        args
    };
    // Use a stable app-data directory, not a removable build/installer directory.
    let mut child = detached(&binary, &args, data)?;
    for _ in 0..120 {
        if let Some(c) = ready(&path) {
            return Ok(response(
                c,
                &path,
                if installed { "installed" } else { "started" },
                Some(&binary),
            ));
        }
        if child
            .as_mut()
            .map(|child| child.try_wait())
            .transpose()
            .map_err(|e| e.to_string())?
            .flatten()
            .is_some()
        {
            // A competing wrapper may have won the native Syncthing config lock.
            if let Some(c) = ready(&path) {
                return Ok(response(c, &path, "running", None));
            }
            return Err("Syncthing stopped during startup. Check syncthing-engine.log in myDrive's data folder; no existing folders or devices were reset.".into());
        }
        thread::sleep(Duration::from_millis(250));
    }
    Err(
        "Syncthing is still starting. Refresh shortly; the background engine was left running."
            .into(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn checksum_rejects_modified_download() {
        let digest = hex::encode(Sha256::digest(b"official archive"));
        assert!(verify(b"official archive", &digest).is_ok());
        assert!(verify(b"modified archive", &digest).is_err());
    }
    #[test]
    #[ignore = "Downloads the official package; run explicitly with network access"]
    fn official_install_is_verified_executable_and_never_overwrites() {
        let dir = tempfile::tempdir().unwrap();
        let binary = install(dir.path()).unwrap();
        assert!(quiet_command(&binary)
            .arg("--version")
            .status()
            .unwrap()
            .success());
        let before = fs::read(&binary).unwrap();
        assert!(install(dir.path()).is_err());
        assert_eq!(fs::read(binary).unwrap(), before);
    }
    #[test]
    fn config_preserves_key_and_rejects_remote_or_disabled_api() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.xml");
        for (addr, enabled, valid) in [
            ("0.0.0.0:8384", "true", true),
            ("[::]:8384", "true", true),
            ("example.com:8384", "true", false),
            ("127.0.0.1:8384", "false", false),
        ] {
            fs::write(&path, format!("<configuration><gui enabled=\"{enabled}\"><address>{addr}</address><apikey>secret-fixture</apikey></gui></configuration>")).unwrap();
            let c = connection(&path);
            assert_eq!(c.is_ok(), valid);
            if let Ok(c) = c {
                assert_eq!(c.api_key, "secret-fixture");
            }
        }
    }
}
