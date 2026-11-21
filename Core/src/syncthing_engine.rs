//! User-session engine lifecycle. No GUI wrapper, service installation, or config reset.
use crate::syncthing::{Api, Connection};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    env, fs,
    io::{self, BufRead, Read, Write},
    net::TcpStream,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
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
        ("windows", "x86_64") => Ok((
            "windows-amd64",
            "3ce7da770f546a8d02b65b2e7ee31f2a3b8b7c3f990ede045590cca4172ecfe1",
        )),
        ("macos", "aarch64") => Ok((
            "macos-arm64",
            "2df075b463231a307c91da657157beaed06383a941ba7ea04d33d536e3c4af38",
        )),
        ("macos", "x86_64") => Ok((
            "macos-amd64",
            "b8be90176d0f24daebae7b5aaddac52ebfae395df6d99f5e0e54656db00868cb",
        )),
        ("linux", "x86_64") => Ok((
            "linux-amd64",
            "2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142",
        )),
        ("linux", "aarch64") => Ok((
            "linux-arm64",
            "48e456690cd2b97e7d26b02b5ac35f62a3b36172267b144cfeaf02c993ab955c",
        )),
        _ => Err("This myDrive build has no Syncthing engine for this architecture.".into()),
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
    let extension = if cfg!(target_os = "linux") {
        "tar.gz"
    } else {
        "zip"
    };
    let url = format!(
        "https://github.com/syncthing/syncthing/releases/download/{VERSION}/{stem}.{extension}"
    );
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

/// Lives as long as the desktop app or the active headless session.
#[derive(Default)]
pub struct Owner {
    owned: Option<OwnedEngine>,
    selected: Option<PathBuf>,
    closed: Option<Arc<AtomicBool>>,
}

struct OwnedEngine {
    child: Child,
    config: PathBuf,
    binary: PathBuf,
    connected: bool,
    #[cfg(windows)]
    _job: windows_job::Job,
}

#[cfg(windows)]
mod windows_job {
    use std::{io, mem::size_of, os::windows::io::AsRawHandle, process::Child, ptr};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, HANDLE},
        System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
    };

    pub struct Job(HANDLE);

    impl Job {
        pub fn new() -> io::Result<Self> {
            let handle = unsafe { CreateJobObjectW(ptr::null(), ptr::null()) };
            if handle.is_null() {
                return Err(io::Error::last_os_error());
            }
            let job = Self(handle);
            let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let result = unsafe {
                SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                    size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                )
            };
            if result == 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(job)
        }

        pub fn attach(&self, child: &Child) -> io::Result<()> {
            if unsafe { AssignProcessToJobObject(self.0, child.as_raw_handle()) } == 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        }
    }

    impl Drop for Job {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

impl Drop for OwnedEngine {
    fn drop(&mut self) {
        if !matches!(self.child.try_wait(), Ok(None)) {
            return;
        }
        #[cfg(unix)]
        unsafe {
            // An unreaped child PID stays reserved until try_wait or wait reaps it.
            libc::kill(self.child.id() as libc::pid_t, libc::SIGTERM);
        }
        #[cfg(windows)]
        if self.connected {
            if let Ok(connection) = connection(&self.config) {
                Api::shutdown_owned(&connection);
            }
        }
        let deadline = Instant::now() + Duration::from_secs(4);
        while Instant::now() < deadline {
            if !matches!(self.child.try_wait(), Ok(None)) {
                return;
            }
            thread::sleep(Duration::from_millis(50));
        }
        // The Syncthing monitor and worker share a private group on Unix.
        #[cfg(unix)]
        unsafe {
            libc::kill(-(self.child.id() as libc::pid_t), libc::SIGKILL);
        }
        #[cfg(windows)]
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub fn serve() -> io::Result<()> {
    let (sender, receiver) = mpsc::sync_channel(1);
    let closed = Arc::new(AtomicBool::new(false));
    let finished = Arc::clone(&closed);
    thread::spawn(move || {
        let mut input = io::stdin().lock();
        loop {
            let mut line = Vec::new();
            match (&mut input)
                .take(1024 * 1024 + 1)
                .read_until(b'\n', &mut line)
            {
                Ok(count) if (1..=1024 * 1024).contains(&count) => {}
                _ => break,
            }
            if sender.send(serde_json::from_slice::<Value>(&line)).is_err() {
                break;
            }
        }
        finished.store(true, Ordering::Release);
    });
    let mut owner = Owner {
        closed: Some(closed),
        ..Owner::default()
    };
    let mut last_request: Option<Value> = None;
    let mut output = io::stdout().lock();
    loop {
        let result = match receiver.recv_timeout(Duration::from_secs(30)) {
            Ok(Ok(request)) => {
                let result = owner.handle(&request);
                last_request = Some(request);
                result
            }
            Ok(Err(_)) => Err("Invalid Syncthing request.".to_owned()),
            Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // Owned engines need only a process check. An attached external
                // instance needs a loopback probe to detect when it closes.
                if let Some(request) = &last_request {
                    let alive = owner
                        .owned
                        .as_mut()
                        .is_some_and(|engine| matches!(engine.child.try_wait(), Ok(None)));
                    if !alive {
                        let _ = owner.handle(request);
                    }
                }
                continue;
            }
        };
        let response = match result {
            Ok(data) => json!({"ok": true, "data": data}),
            Err(error) => json!({"ok": false, "error": error}),
        };
        writeln!(output, "{response}")?;
        output.flush()?;
    }
}

impl Owner {
    fn handle(&mut self, request: &Value) -> Result<Value, String> {
        self.ensure(
            &request["payload"],
            Path::new(request["data_dir"].as_str().unwrap_or_default()),
        )
    }

    fn check_open(&self) -> Result<(), String> {
        if self
            .closed
            .as_ref()
            .is_some_and(|closed| closed.load(Ordering::Acquire))
        {
            return Err("myDrive is closing.".into());
        }
        Ok(())
    }

    pub fn ensure(&mut self, payload: &Value, data: &Path) -> Result<Value, String> {
        self.check_open()?;
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
            self.check_open()?;
            if Instant::now() > deadline {
                return Err("Syncthing setup is already in progress. Try again shortly.".into());
            }
            thread::sleep(Duration::from_millis(200));
        }
        let explicit = payload["config_path"].as_str().filter(|s| !s.is_empty());
        let candidates = configs();
        let path = if let Some(explicit) = explicit {
            let path = PathBuf::from(explicit);
            if !path.is_absolute() || path.file_name().is_none_or(|n| n != "config.xml") {
                return Err("Choose an absolute Syncthing config.xml path.".into());
            }
            if !path.is_file() {
                return Err("The selected Syncthing config.xml is missing. Choose it again in Sync settings.".into());
            }
            path
        } else if let Some(path) = self.selected.as_ref().filter(|p| p.is_file()) {
            // Keep using the same profile when the official app closes.
            path.clone()
        } else {
            candidates
                .iter()
                .find(|p| ready(p).is_some())
                .or_else(|| candidates.iter().find(|p| p.is_file()))
                .cloned()
                .or_else(|| candidates.into_iter().find(|p| p.is_absolute()))
                .ok_or("Cannot find the Syncthing configuration directory.")?
        };
        self.selected = Some(path.clone());
        if let Some(engine) = &mut self.owned {
            if engine.config != path || !matches!(engine.child.try_wait(), Ok(None)) {
                self.owned = None;
            }
        }
        if let Some(c) = ready(&path) {
            return Ok(response(
                c,
                &path,
                "running",
                self.owned.as_ref().map(|e| e.binary.as_path()),
            ));
        }
        if self.owned.is_some() {
            return Err("Syncthing is running but its local API is temporarily unavailable. Try again shortly.".into());
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
        let cached = data.join("engine").join(executable_name());
        let existing = supplied.or_else(|| cached.is_file().then_some(cached));
        let installed = existing.is_none();
        let binary = match existing {
            Some(p) => p,
            None => install(data)?,
        };
        self.check_open()?;
        let dir = path
            .parent()
            .ok_or("Invalid Syncthing configuration path.")?;
        if !path.exists() {
            fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            let status = quiet_command(&binary)
                .args(["generate", "--home"])
                .arg(dir)
                .env_remove("STHOMEDIR")
                .env_remove("STCONFDIR")
                .env_remove("STDATADIR")
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
        self.check_open()?;
        let mut command = quiet_command(&binary);
        let log = fs::File::create(data.join("syncthing-engine.log")).map_err(|e| e.to_string())?;
        let errors = log.try_clone().map_err(|e| e.to_string())?;
        command
            .arg("serve")
            .arg("--config")
            .arg(dir)
            .arg("--data")
            .arg(&db_dir)
            .args(["--no-browser", "--no-restart", "--no-upgrade"])
            .args(["--log-file=-", "--log-level=warn"])
            .stdout(log)
            .stderr(errors)
            .env_remove("STHOMEDIR")
            .env_remove("STCONFDIR")
            .env_remove("STDATADIR")
            .env_remove("STGUIADDRESS")
            .env_remove("STGUIAPIKEY")
            .env_remove("STMONITORED")
            .current_dir(data);
        #[cfg(windows)]
        command.arg("--no-console");
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        #[cfg(windows)]
        let job = windows_job::Job::new()
            .map_err(|e| format!("Could not create the Syncthing process group: {e}"))?;
        let child = command.spawn().map_err(|_| {
            "Could not start the myDrive Syncthing engine. Check its executable permissions."
        })?;
        let mut engine = OwnedEngine {
            child,
            config: path.clone(),
            binary,
            connected: false,
            #[cfg(windows)]
            _job: job,
        };
        #[cfg(windows)]
        engine
            ._job
            .attach(&engine.child)
            .map_err(|e| format!("Could not supervise the Syncthing process: {e}"))?;
        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline {
            if engine
                .child
                .try_wait()
                .map_err(|e| e.to_string())?
                .is_some()
            {
                // An external instance may have won Syncthing's native configuration lock.
                if let Some(c) = ready(&path) {
                    return Ok(response(c, &path, "running", None));
                }
                return Err("Syncthing stopped during startup. Check syncthing-engine.log in myDrive’s data folder.".into());
            }
            if let Some(c) = ready(&path) {
                if matches!(engine.child.try_wait(), Ok(None)) {
                    engine.connected = true;
                    let result = response(
                        c,
                        &path,
                        if installed { "installed" } else { "started" },
                        Some(&engine.binary),
                    );
                    self.owned = Some(engine);
                    return Ok(result);
                }
            }
            self.check_open()?;
            thread::sleep(Duration::from_millis(250));
        }
        Err("Syncthing did not become ready. Refresh Sync to retry.".into())
    }
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
