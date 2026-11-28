use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

type Result<T> = std::result::Result<T, String>;
const VERSION: &str = "v1.76.0";
const VERSIONS: &str = "myDrive Versions";

#[derive(Default, Deserialize, Serialize)]
struct State {
    accounts: Vec<Account>,
    jobs: Vec<Job>,
}

#[derive(Clone, Deserialize, Serialize)]
struct Account {
    id: String,
    name: String,
    provider: String,
}

#[derive(Deserialize, Serialize)]
struct Job {
    id: String,
    account: String,
    source: PathBuf,
    folder: String,
    interval: i64,
    paused: bool,
}

#[derive(Default, Deserialize, Serialize)]
struct Report {
    run: String,
    phase: String,
    at: i64,
    bytes: u64,
    total: u64,
    files: u64,
    message: String,
}

fn now() -> i64 {
    chrono::Utc::now().timestamp()
}
fn storage_error(error: std::io::Error) -> String {
    format!("Cloud Drives storage: {error}")
}

fn id() -> Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| "Could not create a Cloud Drives identifier.")?;
    Ok(hex::encode(bytes))
}

fn valid_id(value: &str) -> Result<&str> {
    if value.len() == 32 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(value)
    } else {
        Err("Choose an available Cloud Drives item.".into())
    }
}

fn string<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    payload[field]
        .as_str()
        .ok_or_else(|| format!("Missing Cloud Drives field: {field}."))
}

fn relative(path: &str) -> Result<&str> {
    if path.len() > 4096
        || path.contains('\\')
        || path.chars().any(char::is_control)
        || (!path.is_empty() && path.split('/').any(|part| matches!(part, "" | "." | "..")))
    {
        return Err("Choose a valid cloud folder or file.".into());
    }
    Ok(path)
}

fn absolute(path: &str) -> Result<PathBuf> {
    let output = PathBuf::from(path);
    if !output.is_absolute() || path.chars().any(char::is_control) {
        return Err("Choose an absolute local path.".into());
    }
    Ok(output)
}

fn overlap(a: &str, b: &str) -> bool {
    let a = a.to_lowercase();
    let b = b.to_lowercase();
    a == b
        || a.strip_prefix(&b).is_some_and(|s| s.starts_with('/'))
        || b.strip_prefix(&a).is_some_and(|s| s.starts_with('/'))
}

fn read<T: for<'de> Deserialize<'de> + Default>(path: &Path) -> Result<T> {
    match fs::read(path) {
        Ok(data) => serde_json::from_slice(&data)
            .map_err(|_| "Saved Cloud Drives data is unreadable. Its files have been kept.".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(T::default()),
        Err(error) => Err(storage_error(error)),
    }
}

fn write(path: &Path, value: &impl Serialize) -> Result<()> {
    let mut staged =
        tempfile::NamedTempFile::new_in(path.parent().ok_or("Invalid Cloud Drives storage.")?)
            .map_err(storage_error)?;
    serde_json::to_writer(staged.as_file_mut(), value)
        .map_err(|_| "Could not save Cloud Drives data.")?;
    staged.as_file().sync_all().map_err(storage_error)?;
    staged
        .persist(path)
        .map_err(|error| storage_error(error.error))?;
    Ok(())
}

fn private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path).map_err(storage_error)?;
    let info = fs::symlink_metadata(path).map_err(storage_error)?;
    if !info.is_dir() || info.is_symlink() {
        return Err("Cloud Drives requires a local application data folder.".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if info.permissions().mode() & 0o777 != 0o700 {
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(storage_error)?;
        }
    }
    Ok(())
}

fn lock_file(path: &Path) -> Result<File> {
    OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path)
        .map_err(storage_error)
}

fn state(root: &Path) -> Result<State> {
    read(&root.join("state.json"))
}
fn save(root: &Path, state: &State) -> Result<()> {
    write(&root.join("state.json"), state)
}

fn config(root: &Path, account: &str) -> Result<PathBuf> {
    Ok(root
        .join("accounts")
        .join(valid_id(account)?)
        .join("rclone.conf"))
}

fn account_lock(root: &Path, account: &str) -> Result<File> {
    let lock = lock_file(&config(root, account)?.with_extension("lock"))?;
    lock.try_lock()
        .map_err(|_| "This cloud account is busy. Try again when its current job finishes.")?;
    Ok(lock)
}

fn command(path: &Path) -> Command {
    let mut child = Command::new(path);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        child.creation_flags(0x08000000);
    }
    child.stdin(Stdio::null());
    child
}

fn executable(root: &Path) -> PathBuf {
    root.join(VERSION).join(if cfg!(windows) {
        "rclone.exe"
    } else {
        "rclone"
    })
}

fn platform() -> Result<(&'static str, &'static str)> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("windows", "x86_64") => Ok((
            "windows-amd64",
            "8b4fd2737ade4e70c057ef4a49deb7cffe94b0fb9d7587c189d149823f21a1dc",
        )),
        ("macos", "aarch64") => Ok((
            "osx-arm64",
            "e72dc90b70f4947a7b72b61bde4a4fbba5777b2874fb448951ffdde67ebd0ab7",
        )),
        ("macos", "x86_64") => Ok((
            "osx-amd64",
            "4f5835733d52b818340f97b1fc0348a70461534d123363a183ca2b660219595a",
        )),
        ("linux", "x86_64") => Ok((
            "linux-amd64",
            "b00f00b3266c3764413afe599d3ec316f6f43b3e0ea8a0bc1d186d2133e46df7",
        )),
        _ => Err("There is no Cloud Drives helper for this build.".into()),
    }
}

fn provision(root: &Path) -> Result<()> {
    let path = executable(root);
    if path.is_file() {
        return Ok(());
    }
    let lock = lock_file(&root.join("install.lock"))?;
    lock.lock().map_err(storage_error)?;
    if path.is_file() {
        return Ok(());
    }
    let (platform, checksum) = platform()?;
    let directory = path.parent().unwrap();
    private_dir(directory)?;
    let stem = format!("rclone-{VERSION}-{platform}");
    let url = format!("https://github.com/rclone/rclone/releases/download/{VERSION}/{stem}.zip");
    let client = reqwest::blocking::Client::builder()
        .https_only(true)
        .timeout(Duration::from_secs(180))
        .build()
        .map_err(|_| "Could not start the rclone download.")?;
    let mut response = client
        .get(url)
        .send()
        .and_then(|r| r.error_for_status())
        .map_err(|_| {
            "Could not download the verified rclone helper. Check your connection and retry."
        })?;
    let archive = tempfile::NamedTempFile::new_in(directory).map_err(storage_error)?;
    let mut output = archive.as_file();
    let mut digest = Sha256::new();
    let mut buffer = [0; 65536];
    let mut size = 0;
    loop {
        let count = response
            .read(&mut buffer)
            .map_err(|_| "The rclone download was interrupted.")?;
        if count == 0 {
            break;
        }
        size += count;
        if size > 80 * 1024 * 1024 {
            return Err("The rclone package exceeded its size limit.".into());
        }
        digest.update(&buffer[..count]);
        output.write_all(&buffer[..count]).map_err(storage_error)?;
    }
    if hex::encode(digest.finalize()) != checksum {
        return Err("The rclone package checksum did not match.".into());
    }
    let staged = tempfile::NamedTempFile::new_in(directory).map_err(storage_error)?;
    let member = format!("{stem}/{}", path.file_name().unwrap().to_string_lossy());
    let mut unpack = if cfg!(target_os = "linux") {
        let mut python = command(Path::new("/usr/bin/python3"));
        python.args(["-I", "-c", "import shutil,sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); f=z.open(sys.argv[2]); shutil.copyfileobj(f,sys.stdout.buffer)"])
            .arg(archive.path()).arg(&member);
        python
    } else {
        let tar = if cfg!(windows) {
            PathBuf::from(std::env::var_os("SystemRoot").unwrap_or_else(|| r"C:\Windows".into()))
                .join("System32/tar.exe")
        } else {
            PathBuf::from("/usr/bin/tar")
        };
        let mut tar = command(&tar);
        tar.arg("-xOf").arg(archive.path()).arg(&member);
        tar
    };
    let success = unpack
        .stdout(staged.as_file().try_clone().map_err(storage_error)?)
        .stderr(Stdio::null())
        .status()
        .map_err(|_| "Could not extract the verified rclone helper.")?
        .success();
    if !success || staged.as_file().metadata().map_err(storage_error)?.len() == 0 {
        return Err("Could not extract the verified rclone helper.".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        staged
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o700))
            .map_err(storage_error)?;
    }
    staged.as_file().sync_all().map_err(storage_error)?;
    staged
        .persist_noclobber(path)
        .map_err(|e| storage_error(e.error))?;
    Ok(())
}

fn rclone(root: &Path, file: &Path) -> Result<Command> {
    let binary = executable(root);
    if !binary.is_file() {
        return Err(
            "The Cloud Drives helper is missing. Reconnect a cloud account to restore it.".into(),
        );
    }
    let mut child = command(&binary);
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_uppercase()
            .starts_with("RCLONE_")
        {
            child.env_remove(key);
        }
    }
    child.arg("--config").arg(file).args([
        "--ask-password=false",
        "--contimeout",
        "15s",
        "--timeout",
        "90s",
    ]);
    Ok(child)
}

fn remote(path: &str) -> String {
    format!("mydrive:{path}")
}

fn short_run(mut child: Command, error: &str) -> Result<()> {
    if child
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|_| error)?
        .success()
    {
        Ok(())
    } else {
        Err(error.into())
    }
}

fn browser_sign_in(root: &Path, path: &Path) -> Result<()> {
    let error = "Cloud sign-in could not finish. Complete sign-in in the browser and try again.";
    let mut next: Option<(String, String)> = None;
    for _ in 0..12 {
        let mut auth = rclone(root, path)?;
        auth.args(["config", "update", "mydrive", "--non-interactive"]);
        if let Some((state, answer)) = &next {
            auth.args(["--continue", "--state", state, "--result", answer]);
        }
        let reply = auth.output().map_err(|_| error)?;
        if !reply.status.success() {
            return Err(error.into());
        }
        let response: Value = serde_json::from_slice(&reply.stdout).map_err(|_| error)?;
        if response["Error"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
        {
            return Err(error.into());
        }
        let state = response["State"].as_str().unwrap_or_default();
        if state.is_empty() {
            return Ok(());
        }
        let option = &response["Option"];
        let answer = match option["Name"].as_str() {
            Some("config_refresh_token" | "config_is_local" | "config_drive_ok") => "true",
            Some("config_change_team_drive") => "false",
            Some("config_type") => "onedrive",
            Some("config_driveid") => option["Default"]
                .as_str()
                .filter(|v| !v.is_empty())
                .ok_or(error)?,
            _ => return Err(error.into()),
        };
        next = Some((state.to_owned(), answer.to_owned()));
    }
    Err(error.into())
}

fn sign_in(root: &Path, saved: &State, payload: &Value) -> Result<Value> {
    let reconnect = payload["account"].as_str();
    let account = if let Some(existing) = reconnect {
        saved
            .accounts
            .iter()
            .find(|a| a.id == existing)
            .cloned()
            .ok_or("Choose a saved cloud account.")?
    } else {
        let provider = string(payload, "provider")?;
        if !matches!(provider, "dropbox" | "onedrive" | "drive") {
            return Err("Choose a supported cloud provider.".into());
        }
        let name = string(payload, "name")?.trim();
        if name.is_empty() || name.chars().count() > 80 || name.chars().any(char::is_control) {
            return Err("Enter an account label of up to 80 characters.".into());
        }
        Account {
            id: id()?,
            name: name.into(),
            provider: provider.into(),
        }
    };
    provision(root)?;
    let auth_lock = lock_file(&root.join("sign-in.lock"))?;
    auth_lock
        .try_lock()
        .map_err(|_| "Finish the cloud sign-in already open in your browser.")?;
    let path = config(root, &account.id)?;
    private_dir(&root.join("accounts"))?;
    private_dir(path.parent().unwrap())?;
    let _account = account_lock(root, &account.id)?;
    let stage = tempfile::tempdir_in(path.parent().unwrap()).map_err(storage_error)?;
    let temp_config = stage.path().join("rclone.conf");
    if reconnect.is_some() {
        fs::copy(&path, &temp_config).map_err(storage_error)?;
    } else {
        let mut draft = format!("[mydrive]\ntype = {}\n", account.provider);
        if account.provider == "drive" {
            let credential = |key| {
                payload[key]
                    .as_str()
                    .map(str::trim)
                    .filter(|v| {
                        !v.is_empty()
                            && v.len() <= 512
                            && v.bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
                    })
                    .ok_or("Enter a Google Drive desktop client ID and client secret.")
            };
            let identity = credential("client_id")?;
            let secret = credential("client_secret")?;
            draft.push_str(&format!(
                "client_id = {identity}\nclient_secret = {secret}\n"
            ));
        } else if account.provider == "onedrive" {
            draft.push_str("disable_site_permission = true\n");
        }
        // The OAuth client credentials stay in a private file and never become command arguments.
        fs::write(&temp_config, draft).map_err(storage_error)?;
    }
    browser_sign_in(root, &temp_config)?;
    let mut verify = rclone(root, &temp_config)?;
    verify.args([
        "lsjson",
        "mydrive:",
        "--dirs-only",
        "--no-modtime",
        "--no-mimetype",
        "--retries",
        "1",
    ]);
    short_run(
        verify,
        "The cloud account could not be opened. Check your provider access and sign in again.",
    )?;
    let mut new_config =
        tempfile::NamedTempFile::new_in(path.parent().unwrap()).map_err(storage_error)?;
    std::io::copy(
        &mut File::open(&temp_config).map_err(storage_error)?,
        &mut new_config,
    )
    .map_err(storage_error)?;
    let lock = lock_file(&root.join("state.lock"))?;
    lock.lock().map_err(storage_error)?;
    let mut saved = state(root)?;
    if reconnect.is_none() {
        if saved.accounts.len() >= 32 {
            return Err("Up to 32 cloud accounts are supported.".into());
        }
        saved.accounts.push(account.clone());
    } else if !saved.accounts.iter().any(|a| a.id == account.id) {
        return Err("This cloud account was disconnected during sign-in.".into());
    }
    new_config
        .persist(&path)
        .map_err(|error| storage_error(error.error))?;
    if reconnect.is_none() {
        save(root, &saved)?;
    }
    Ok(json!(account))
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Listed {
    name: String,
    is_dir: bool,
    size: i64,
}

fn browse(root: &Path, account: &Account, folder: &str) -> Result<Value> {
    let _lock = account_lock(root, &account.id)?;
    let mut cmd = rclone(root, &config(root, &account.id)?)?;
    let mut child = cmd
        .args([
            "lsjson",
            &remote(folder),
            "--no-modtime",
            "--no-mimetype",
            "--retries",
            "1",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(storage_error)?;
    let limit = 16 * 1024 * 1024;
    let mut bytes = Vec::new();
    if child
        .stdout
        .take()
        .unwrap()
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .is_err()
        || bytes.len() as u64 > limit
    {
        let _ = child.kill();
        let _ = child.wait();
        return Err("This cloud folder has too many entries to display.".into());
    }
    let status = child.wait().map_err(storage_error)?;
    if status.code() == Some(3) && folder.starts_with(&format!("{VERSIONS}/")) {
        return Ok(json!({"entries":[],"truncated":false}));
    }
    if !status.success() {
        return Err(
            "Could not open this cloud folder. Check the connection or reconnect the account."
                .into(),
        );
    }
    let mut items: Vec<Listed> = serde_json::from_slice(&bytes)
        .map_err(|_| "The cloud provider returned an unreadable folder.")?;
    items.sort_by_cached_key(|item| (!item.is_dir, item.name.to_lowercase()));
    let truncated = items.len() > 4000;
    let entries: Vec<_> = items.into_iter().filter(|entry| !entry.name.is_empty() && !entry.name.contains('/') &&
        relative(&entry.name).is_ok()).take(4000).map(|entry| json!({
        "name": entry.name, "folder": entry.is_dir, "size": entry.size,
        "path": if folder.is_empty() { entry.name.clone() } else { format!("{folder}/{}", entry.name) },
    })).collect();
    Ok(json!({"entries":entries,"truncated":truncated}))
}

fn download(root: &Path, account: &Account, source: &str, destination: PathBuf) -> Result<Value> {
    if source.is_empty() || destination.exists() {
        return Err("Choose a new local filename for this download.".into());
    }
    let _lock = account_lock(root, &account.id)?;
    let directory = destination
        .parent()
        .ok_or("Choose a local download folder.")?;
    let stage = tempfile::tempdir_in(directory).map_err(storage_error)?;
    let pending = stage.path().join("download");
    let mut cmd = rclone(root, &config(root, &account.id)?)?;
    cmd.args(["copyto", &remote(source)]).arg(&pending);
    short_run(
        cmd,
        "The cloud download did not finish. Check your connection and try again.",
    )?;
    fs::hard_link(&pending, &destination).map_err(|_| {
        "Could not save the download to this folder without replacing an existing file."
    })?;
    Ok(json!(destination))
}

fn report_path(root: &Path, job: &str) -> PathBuf {
    root.join("jobs").join(format!("{job}.json"))
}
fn job_lock(root: &Path, job: &str) -> Result<File> {
    lock_file(&root.join("jobs").join(format!("{job}.lock")))
}

fn report(root: &Path, job: &Job) -> Result<Report> {
    let mut report: Report = read(&report_path(root, &job.id))?;
    if (report.phase == "running" || report.phase == "queued" && now() - report.at > 30)
        && job_lock(root, &job.id)?.try_lock().is_ok()
    {
        report.phase = "failed".into();
        report.message = "Interrupted. Run again to continue the backup.".into();
    }
    Ok(report)
}

fn start(root: &Path, job: &Job, scheduled: bool) -> Result<Value> {
    let lock = job_lock(root, &job.id)?;
    if lock.try_lock().is_err() {
        return Ok(json!({"started":false}));
    }
    let path = report_path(root, &job.id);
    let previous: Report = read(&path)?;
    if previous.phase == "queued" && now() - previous.at < 30
        || scheduled && (job.paused || job.interval <= 0 || now() - previous.at < job.interval * 60)
    {
        return Ok(json!({"started":false}));
    }
    let run = id()?;
    let mut queued = Report {
        run: run.clone(),
        phase: "queued".into(),
        at: now(),
        ..Report::default()
    };
    write(&path, &queued)?;
    let program = std::env::current_exe().map_err(storage_error)?;
    if command(&program)
        .arg("--cloud-worker")
        .arg(root)
        .args([&job.id, &run])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_err()
    {
        queued.phase = "failed".into();
        queued.message = "Could not start the backup worker.".into();
        write(&path, &queued)?;
        return Err(queued.message);
    }
    Ok(json!({"started":true}))
}

fn backup(root: &Path, job: &Job, path: &Path, report: &mut Report) -> Result<()> {
    let account_lock = lock_file(&config(root, &job.account)?.with_extension("lock"))?;
    account_lock.lock().map_err(storage_error)?;
    let source = job
        .source
        .canonicalize()
        .map_err(|_| "The local folder is unavailable. Reconnect its drive and run again.")?;
    if !source.is_dir() || source != job.source {
        return Err("The local backup folder has moved. Choose its new location.".into());
    }
    let stamp = chrono::Utc::now().format("%Y-%m-%d_%H-%M-%S").to_string();
    let history = remote(&format!("{VERSIONS}/{}/{stamp}-{}", job.id, report.run));
    let mut cmd = rclone(root, &config(root, &job.account)?)?;
    let mut child = cmd
        .arg("copy")
        .arg(source)
        .arg(remote(&job.folder))
        .args([
            "--backup-dir",
            &history,
            "--transfers",
            "2",
            "--checkers",
            "4",
            "--use-json-log",
            "--stats",
            "2s",
            "--stats-log-level",
            "NOTICE",
            "--exclude",
            "**/.DS_Store",
            "--exclude",
            "**/Thumbs.db",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(storage_error)?;
    let mut auth_error = false;
    for line in BufReader::new(child.stderr.take().unwrap())
        .lines()
        .map_while(std::result::Result::ok)
    {
        if let Ok(event) = serde_json::from_str::<Value>(&line) {
            if let Some(stats) = event.get("stats") {
                report.bytes = stats["bytes"].as_u64().unwrap_or_default();
                report.total = stats["totalBytes"].as_u64().unwrap_or_default();
                report.files = stats["transfers"].as_u64().unwrap_or_default();
                let _ = write(path, report);
            }
            if let Some(message) = event["msg"].as_str() {
                let lower = message.to_ascii_lowercase();
                auth_error |= lower.contains("invalid_grant")
                    || lower.contains("unauthorized")
                    || lower.contains("invalid access token");
            }
        }
    }
    if child.wait().map_err(storage_error)?.success() {
        Ok(())
    } else if auth_error {
        Err("Sign in to the cloud account again, then retry the backup.".into())
    } else {
        Err(
            "Backup interrupted. Check the connection and run again to retry unfinished files."
                .into(),
        )
    }
}

pub fn worker(root: &Path, job_id: &str, run_id: &str) -> Result<()> {
    valid_id(job_id)?;
    valid_id(run_id)?;
    let lock = job_lock(root, job_id)?;
    lock.lock().map_err(storage_error)?;
    let state = state(root)?;
    let job = state
        .jobs
        .iter()
        .find(|job| job.id == job_id)
        .ok_or("Backup job was removed.")?;
    let path = report_path(root, job_id);
    let mut report: Report = read(&path)?;
    if report.run != run_id || report.phase != "queued" {
        return Ok(());
    }
    report.phase = "running".into();
    write(&path, &report)?;
    match backup(root, job, &path, &mut report) {
        Ok(()) => report.phase = "complete".into(),
        Err(error) => {
            report.phase = "failed".into();
            report.message = error;
        }
    }
    write(&path, &report)
}

fn local_folder(root: &Path, input: &str) -> Result<PathBuf> {
    let path = absolute(input)?
        .canonicalize()
        .map_err(|_| "Choose an existing local backup folder.")?;
    let app_data = root
        .parent()
        .unwrap()
        .canonicalize()
        .map_err(storage_error)?;
    let nested = path.starts_with(&app_data)
        || app_data.starts_with(&path)
        || cfg!(windows)
            && overlap(
                &path.to_string_lossy().replace('\\', "/"),
                &app_data.to_string_lossy().replace('\\', "/"),
            );
    if !path.is_dir() || nested {
        return Err("Choose a local folder outside myDrive’s application data.".into());
    }
    Ok(path)
}

pub fn execute(action: &str, data: &Path, payload: &Value) -> Result<Value> {
    if !data.is_absolute() {
        return Err("Cloud Drives needs a local application data folder.".into());
    }
    let root = data.join("cloud");
    if matches!(action, "status" | "tick") && !root.exists() {
        return Ok(json!({"accounts":[],"jobs":[]}));
    }
    private_dir(&root)?;
    private_dir(&root.join("jobs"))?;
    let saved = state(&root)?;
    match action {
        "status" => {
            let jobs = saved
                .jobs
                .iter()
                .map(|job| Ok(json!({"job":job,"report":report(&root, job)?})))
                .collect::<Result<Vec<_>>>()?;
            Ok(json!({"accounts":saved.accounts,"jobs":jobs}))
        }
        "setup" => {
            provision(&root)?;
            Ok(json!({"version": VERSION}))
        }
        "connect" => sign_in(&root, &saved, payload),
        "browse" | "download" => {
            let account_id = string(payload, "account")?;
            let account = saved
                .accounts
                .iter()
                .find(|entry| entry.id == account_id)
                .ok_or("Choose a saved cloud account.")?;
            let path = relative(string(payload, "path")?)?;
            if action == "browse" {
                browse(&root, account, path)
            } else {
                download(
                    &root,
                    account,
                    path,
                    absolute(string(payload, "destination")?)?,
                )
            }
        }
        "run" => {
            let id = valid_id(string(payload, "job")?)?;
            let job = saved
                .jobs
                .iter()
                .find(|job| job.id == id)
                .ok_or("Choose a backup job.")?;
            start(&root, job, false)
        }
        "tick" => {
            for job in saved
                .jobs
                .iter()
                .filter(|job| job.interval > 0 && !job.paused)
            {
                if start(&root, job, true)?["started"] == true {
                    break;
                }
            }
            Ok(Value::Null)
        }
        "add" | "pause" | "remove" | "disconnect" => {
            let lock = lock_file(&root.join("state.lock"))?;
            lock.lock().map_err(storage_error)?;
            let mut saved = state(&root)?;
            match action {
                "add" => {
                    let account = valid_id(string(payload, "account")?)?;
                    if !saved.accounts.iter().any(|entry| entry.id == account) {
                        return Err("Choose a saved cloud account.".into());
                    }
                    let folder = relative(string(payload, "path")?)?;
                    if folder.is_empty() || overlap(folder, VERSIONS) {
                        return Err("Choose a cloud subfolder for the backup.".into());
                    }
                    if saved
                        .jobs
                        .iter()
                        .any(|job| job.account == account && overlap(&job.folder, folder))
                    {
                        return Err("Another backup already uses this cloud folder or an overlapping folder.".into());
                    }
                    let interval = payload["interval"]
                        .as_i64()
                        .filter(|v| [0, 60, 1440].contains(v))
                        .ok_or("Choose a backup schedule.")?;
                    let source = local_folder(&root, string(payload, "source")?)?;
                    saved.jobs.push(Job {
                        id: id()?,
                        account: account.into(),
                        source,
                        folder: folder.into(),
                        interval,
                        paused: false,
                    });
                }
                "pause" | "remove" => {
                    let id = valid_id(string(payload, "job")?)?;
                    let index = saved
                        .jobs
                        .iter()
                        .position(|job| job.id == id)
                        .ok_or("Choose a backup job.")?;
                    if action == "pause" {
                        saved.jobs[index].paused = payload["paused"]
                            .as_bool()
                            .ok_or("Missing backup pause state.")?;
                    } else {
                        let job = job_lock(&root, id)?;
                        job.try_lock().map_err(|_| {
                            "Wait for the current backup before removing its schedule."
                        })?;
                        saved.jobs.remove(index);
                        save(&root, &saved)?;
                        return Ok(Value::Null);
                    }
                }
                "disconnect" => {
                    let id = valid_id(string(payload, "account")?)?;
                    if saved.jobs.iter().any(|job| job.account == id) {
                        return Err(
                            "Remove this account’s backup schedules before disconnecting.".into(),
                        );
                    }
                    let _account = account_lock(&root, id)?;
                    let path = config(&root, id)?;
                    fs::remove_file(path).map_err(storage_error)?;
                    saved.accounts.retain(|account| account.id != id);
                }
                _ => unreachable!(),
            }
            save(&root, &saved)?;
            Ok(Value::Null)
        }
        _ => Err("Unknown Cloud Drives action.".into()),
    }
}
