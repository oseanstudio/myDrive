#[cfg(windows)]
#[path = "blip/host_windows.rs"]
mod host;
#[cfg(target_os = "linux")]
#[path = "blip/host_linux.rs"]
mod host;
#[cfg(target_os = "macos")]
pub(crate) mod mac;
mod rpc;
mod state;

use crate::automation::uuid;
use rpc::{field, number, string, Result};
use serde_json::{json, Value};
use state::Snapshot;
#[cfg(not(target_os = "macos"))]
use std::collections::{BTreeSet, HashSet};
use std::ffi::OsString;
use std::fs;
#[cfg(not(target_os = "macos"))]
use std::fs::OpenOptions;
#[cfg(not(target_os = "macos"))]
use std::io::BufRead;
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
#[cfg(windows)]
use std::os::windows::fs::MetadataExt;
#[cfg(windows)]
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::path::{Path, PathBuf};
#[cfg(not(target_os = "macos"))]
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};
#[cfg(windows)]
use windows_sys::Win32::Foundation::{DuplicateHandle, DUPLICATE_SAME_ACCESS};
#[cfg(windows)]
use windows_sys::Win32::System::Console::{
    GetStdHandle, SetStdHandle, STD_ERROR_HANDLE, STD_OUTPUT_HANDLE,
};
#[cfg(windows)]
use windows_sys::Win32::System::Threading::GetCurrentProcess;

#[cfg(not(target_os = "macos"))]
const SERVER: &str = "https://prod.blip.net";
#[cfg(not(target_os = "macos"))]
const PLATFORM: &str = if cfg!(windows) { "Windows" } else { "Linux" };
#[cfg(not(target_os = "macos"))]
const PROFILE_MARKER: &str = "mydrive-profile.json";
const RECIPIENT_SEARCH: &str = "6971d326-6e6d-4915-aed7-581eafa9b26d";

struct Arguments {
    command: String,
    profile: PathBuf,
    desktop: bool,
    peer: Option<String>,
    id: Option<String>,
    name: Option<String>,
    files: Vec<PathBuf>,
    execute: bool,
}

impl Arguments {
    fn parse(mut args: impl Iterator<Item = OsString>) -> Result<Self> {
        let command = args
            .next()
            .and_then(|arg| arg.into_string().ok())
            .ok_or("invalid_command")?;
        let mut result = Self {
            command,
            profile: PathBuf::new(),
            desktop: false,
            peer: None,
            id: None,
            name: None,
            files: Vec::new(),
            execute: false,
        };
        while let Some(option) = args.next() {
            match option.to_str() {
                Some("--") => {
                    result.files = args.map(PathBuf::from).take(257).collect();
                    break;
                }
                Some("--profile") if result.profile.as_os_str().is_empty() => {
                    result.profile = args.next().map(PathBuf::from).ok_or("invalid_command")?;
                }
                Some("--desktop") if !result.desktop => result.desktop = true,
                Some("--execute") if !result.execute => result.execute = true,
                Some("--peer") if result.peer.is_none() => result.peer = Some(text_arg(&mut args)?),
                Some("--id") if result.id.is_none() => result.id = Some(text_arg(&mut args)?),
                Some("--name") if result.name.is_none() => result.name = Some(text_arg(&mut args)?),
                _ => return Err("invalid_command"),
            }
        }
        if (!cfg!(target_os = "macos") && !result.profile.is_absolute()) || result.files.len() > 256
        {
            return Err("invalid_command");
        }
        Ok(result)
    }
}

fn text_arg(args: &mut impl Iterator<Item = OsString>) -> Result<String> {
    args.next()
        .and_then(|value| value.into_string().ok())
        .ok_or("invalid_command")
}

struct Session {
    profile: PathBuf,
    #[cfg(not(target_os = "macos"))]
    cache: PathBuf,
    #[cfg(not(target_os = "macos"))]
    state: PathBuf,
    #[cfg(not(target_os = "macos"))]
    lock: PathBuf,
    socket: PathBuf,
    inbox: PathBuf,
    desktop: bool,
}

impl Session {
    #[cfg(not(target_os = "macos"))]
    fn new(local: &Path, profile: PathBuf, desktop: bool) -> Self {
        #[cfg(windows)]
        let (cache, state, lock) = if desktop {
            (
                local.join("Temp/net.blip.desktop"),
                local.join("net.blip.desktop"),
                "desktop-host.lock",
            )
        } else {
            (profile.join("cache"), profile.join("state"), "host.lock")
        };
        #[cfg(target_os = "linux")]
        let (cache, state, lock) = if desktop {
            (
                state::xdg_path("XDG_CACHE_HOME", ".cache").join("net.blip.desktop"),
                local.join("net.blip.desktop"),
                "desktop-host.lock",
            )
        } else {
            (
                state::runtime_dir().join("standalone"),
                profile.join("state"),
                "host.lock",
            )
        };
        #[cfg(windows)]
        let inbox = profile.join("downloads");
        #[cfg(target_os = "linux")]
        let inbox = local.join("myDrive/Blip/downloads");
        Self {
            inbox,
            socket: cache.join("sock"),
            lock: profile.join(lock),
            profile,
            cache,
            state,
            desktop,
        }
    }

    fn snapshot(&self) -> Result<Snapshot> {
        Snapshot::read(&self.socket, self.desktop, &self.inbox)
    }

    fn dispatch(&self, event: &str, payload: Vec<u8>) -> Result<()> {
        let name = format!("type.googleapis.com/event.{event}");
        let any = [string(1, &name), field(2, &payload)].concat();
        rpc::call(&self.socket, "/rpc.Service/Dispatch", &field(1, &any)).map(|_| ())
    }

    fn search(&self, owner: &Value, input: Option<&str>) -> Result<Value> {
        let query = input_value(input, 1024, "invalid_search")?;
        let query = query.trim();
        if !state::safe_text(query, 254) || query.len() > 1024 {
            return Err("invalid_search");
        }
        self.dispatch("AbandonSearch", string(1, RECIPIENT_SEARCH))?;
        self.dispatch(
            "Search",
            [string(1, RECIPIENT_SEARCH), string(2, query)].concat(),
        )?;
        let deadline = Instant::now() + Duration::from_secs(7);
        while Instant::now() < deadline {
            let payload = rpc::call(&self.socket, "/rpc.Service/GetState", &[])?;
            if let Some((status, peers)) = state::search_result(&payload, RECIPIENT_SEARCH, query)?
            {
                if status == 2 {
                    return Err("search_unavailable");
                }
                // Empty/offline results are valid. Retain the native selection so
                // an exact result is still available when the file picker closes.
                if status == 3 {
                    let snapshot = Snapshot::decode(&payload, self.desktop, &self.inbox)?;
                    if snapshot.status["user_id"] != owner["user_id"]
                        || snapshot.status["device_id"] != owner["device_id"]
                    {
                        return Err("sign_in_required");
                    }
                    let devices: Vec<_> = snapshot
                        .devices
                        .into_iter()
                        .filter(|device| {
                            device["history"] == false
                                && device["peer"]
                                    .as_str()
                                    .is_some_and(|peer| state::matches_result(peer, &peers))
                        })
                        .collect();
                    return Ok(json!({"ok": true, "devices": devices}));
                }
            }
            thread::sleep(Duration::from_millis(300));
        }
        Err("search_unavailable")
    }

    #[cfg(not(target_os = "macos"))]
    fn start(&self, library: &Path) -> Result<Option<host::Host>> {
        let host = match host::Host::start(library, &self.cache, &self.state, SERVER, &self.lock) {
            Ok(host) => Some(host),
            Err("host_already_running") => None,
            Err(error) => return Err(error),
        };
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if self.snapshot().is_ok() {
                return Ok(host);
            }
            thread::sleep(Duration::from_millis(150));
        }
        Err("native_connection_unavailable")
    }

    #[cfg(not(target_os = "macos"))]
    fn serve(&self, library: &Path, output: &mut impl Write) -> Result<()> {
        let mut host = self.start(library)?;
        let mut policy = SeparatePolicy::default();
        if !self.desktop && host.is_some() {
            #[cfg(target_os = "linux")]
            fs::create_dir_all(self.inbox.parent().ok_or("profile_unavailable")?)
                .map_err(|_| "profile_unavailable")?;
            create_plain_directory(&self.inbox)?;
            self.dispatch("TransferSetAutoAccept", number(1, 0))?;
            self.dispatch(
                "TransferSetCustomDefaultSavePath",
                string(1, path_text(&self.inbox)?),
            )?;
        }
        self.configure(host.is_some(), &mut policy)?;
        emit(
            output,
            &json!({
                "ok": true, "event": "host_ready", "desktop_session": self.desktop,
                "background": true, "poll_pipe": true,
            }),
        )?;
        let (commands, control) = mpsc::sync_channel::<String>(4);
        // A CLI parent closes stdin to stop; the tray sends STOP explicitly.
        thread::spawn(move || {
            let mut input = io::stdin().lock();
            loop {
                let mut line = String::new();
                match input.by_ref().take(128).read_line(&mut line) {
                    Ok(1..) if line.ends_with('\n') && commands.send(line).is_ok() => {}
                    _ => break,
                }
            }
        });
        let maintenance_interval = Duration::from_secs(2);
        let mut next_maintenance = Instant::now() + maintenance_interval;
        loop {
            let message = if self.desktop && host.is_some() {
                control
                    .recv()
                    .map_err(|_| mpsc::RecvTimeoutError::Disconnected)
            } else {
                control.recv_timeout(next_maintenance.saturating_duration_since(Instant::now()))
            };
            match message {
                Ok(line) if line.trim_end() == "STOP" => break,
                Ok(line) => {
                    let Some(id) = line.trim_end().strip_prefix("POLL ").filter(|id| {
                        id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_hexdigit())
                    }) else {
                        continue;
                    };
                    let mut result = match self.snapshot() {
                        Ok(snapshot) => snapshot.poll(),
                        Err(error) => json!({"ok": false, "error": error}),
                    };
                    result["event"] = json!("poll_result");
                    result["request_id"] = json!(id);
                    emit(output, &result)?;
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
            if Instant::now() >= next_maintenance {
                next_maintenance = Instant::now() + maintenance_interval;
                if !self.desktop && host.is_some() {
                    if let Err(error) = self.configure(true, &mut policy) {
                        if error == "receive_policy_unconfirmed" {
                            emit(output, &json!({"ok": false, "event": error}))?;
                        }
                        return Err(error);
                    }
                } else if host.is_none() && rpc::connect(&self.socket).is_err() {
                    host = self.start(library)?;
                    self.configure(host.is_some(), &mut policy)?;
                }
            }
        }
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    fn configure(&self, owner: bool, policy: &mut SeparatePolicy) -> Result<()> {
        if !owner {
            return Ok(());
        }
        let snapshot = self.snapshot()?;
        if snapshot.app_id_missing {
            let agent = [
                string(101, PLATFORM),
                number(102, 5),
                string(200, PLATFORM),
                string(
                    300,
                    if self.desktop {
                        "net.blip.desktop"
                    } else {
                        "mydrive.blip.poc"
                    },
                ),
                string(301, if self.desktop { "Blip" } else { "myDrive" }),
                string(302, "1.2.8"),
                string(304, "1"),
            ]
            .concat();
            self.dispatch("SetUserAgent", field(1, &agent))?;
        }
        if self.desktop {
            return Ok(());
        }
        let verified = snapshot.status["receive_policy_verified"] == true;
        if snapshot.status["authenticated"] != true || verified {
            policy.verification_deadline = None;
        }
        if snapshot.status["authenticated"] == true && !verified {
            if let Some(deadline) = policy.verification_deadline {
                if Instant::now() >= deadline {
                    return Err("receive_policy_unconfirmed");
                }
                return Ok(());
            }
            self.dispatch("TransferSetAutoAccept", number(1, 0))?;
            self.dispatch(
                "TransferSetCustomDefaultSavePath",
                string(1, path_text(&self.inbox)?),
            )?;
            policy.verification_deadline = Some(Instant::now() + Duration::from_secs(5));
        }
        if verified {
            let trusted = trusted_peers(&self.profile)?;
            policy
                .accepted
                .retain(|id| snapshot.transfer(id).is_some_and(waiting));
            for transfer in snapshot.transfers.iter().filter(|item| waiting(item)) {
                let peer = transfer["peer"].as_str().unwrap_or_default();
                let id = transfer["transfer_id"].as_str().unwrap_or_default();
                if trusted.contains(peer) && !policy.accepted.contains(id) {
                    self.request_acceptance(id)?;
                    policy.accepted.insert(id.into());
                }
            }
        }
        Ok(())
    }

    fn request_acceptance(&self, id: &str) -> Result<()> {
        if !uuid(id) {
            return Err("invalid_transfer_id");
        }
        #[cfg(target_os = "macos")]
        mac::prepare_inbox(&self.inbox)?;
        #[cfg(not(target_os = "macos"))]
        create_plain_directory(&self.inbox)?;
        let destination = self.inbox.join(id);
        create_plain_directory(&destination)?;
        self.dispatch(
            "TransferAcceptanceRequested",
            [string(1, id), string(2, path_text(&destination)?)].concat(),
        )
    }

    fn accept(&self, args: &Arguments, initial: Snapshot) -> Result<Value> {
        let id = args
            .id
            .as_deref()
            .filter(|id| uuid(id) && args.execute)
            .ok_or("invalid_transfer_id")?;
        let mut last = "Missing".to_owned();
        if let Some(item) = initial.transfer(id) {
            last = item["status"]
                .as_str()
                .unwrap_or("UnknownStatus")
                .to_owned();
            if receiving(item) {
                return Ok(
                    json!({"ok": true, "phase": "already_receiving", "native_status": last, "completed": last == "Completed"}),
                );
            }
            if waiting(item) {
                if !self.desktop && initial.status["receive_policy_verified"] != true {
                    return Err("receive_policy_unconfirmed");
                }
                self.request_acceptance(id)?;
                let deadline = Instant::now() + Duration::from_secs(5);
                while Instant::now() < deadline {
                    let latest = self.snapshot()?;
                    if let Some(item) = latest.transfer(id) {
                        last = item["status"]
                            .as_str()
                            .unwrap_or("UnknownStatus")
                            .to_owned();
                        if receiving(item) {
                            return Ok(
                                json!({"ok": true, "phase": "receiving_confirmed", "native_status": last, "completed": last == "Completed"}),
                            );
                        }
                        if item["has_error"] == true || last == "Cancelled" {
                            break;
                        }
                    }
                    thread::sleep(Duration::from_millis(125));
                }
                return Ok(
                    json!({"ok": false, "phase": "acceptance_unconfirmed", "error": "acceptance_unconfirmed", "native_status": last}),
                );
            }
        }
        Ok(json!({"ok": false, "error": "accept_not_waiting", "native_status": last}))
    }

    fn send(&self, args: &Arguments, snapshot: Snapshot) -> Result<Value> {
        let peer = args.peer.as_deref().ok_or("invalid_peer")?;
        let exact = snapshot
            .devices
            .iter()
            .find_map(|item| {
                let exact = item["peer"].as_str()?;
                (item["history"] == false && exact.eq_ignore_ascii_case(peer)).then_some(exact)
            })
            .ok_or("invalid_peer_or_selection")?;
        let (user, device) = state::peer_id(exact).ok_or("invalid_peer")?;
        if !args.execute
            || args.files.is_empty()
            || (snapshot.status["user_id"] == user && snapshot.status["device_id"] == device)
        {
            return Err("invalid_peer_or_selection");
        }
        let id = match args.id.as_deref() {
            Some(id) if uuid(id) => id.to_owned(),
            Some(_) => return Err("invalid_transfer_id"),
            None => random_id()?,
        };
        if snapshot.transfers.iter().any(|item| {
            item["transfer_id"]
                .as_str()
                .is_some_and(|existing| existing.eq_ignore_ascii_case(&id))
        }) {
            return Err("transfer_id_exists");
        }
        let base = string(1, &id);
        let route = [
            base.clone(),
            field(2, &[string(1, user), string(2, device)].concat()),
        ]
        .concat();
        let mut content = base;
        for path in &args.files {
            let path = fs::canonicalize(path).map_err(|_| "file_unavailable")?;
            if !path.is_file() && !path.is_dir() {
                return Err("file_unavailable");
            }
            content.extend(string(2, &crate::syncthing::friendly_path(&path)));
        }
        self.dispatch("TransferCreateRequested", route.clone())?;
        self.dispatch("TransferAddContentRequested", content)?;
        self.dispatch("TransferInviteRequested", route)?;
        Ok(
            json!({"ok": true, "phase": "dispatch_requested", "transfer_id": id, "completed": false}),
        )
    }

    fn registration(&self, verify: bool, initial: Snapshot, input: Option<&str>) -> Result<Value> {
        if self.desktop || initial.status["authenticated"] == true {
            return Err("invalid_command");
        }
        #[cfg(not(target_os = "macos"))]
        let marker = profile_marker(&self.profile)?;
        #[cfg(not(target_os = "macos"))]
        let name = marker["name"]
            .as_str()
            .filter(|name| state::safe_text(name, 160))
            .ok_or("profile_unavailable")?;
        #[cfg(target_os = "macos")]
        let name = "myDrive on Mac";
        let input = input_value(input, 256, "invalid_sign_in_input")?;
        let input = input.trim();
        if verify {
            if !(4..=16).contains(&input.len())
                || !input
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            {
                return Err("invalid_sign_in_input");
            }
            #[cfg(not(target_os = "macos"))]
            let id = marker["deviceId"]
                .as_str()
                .filter(|id| uuid(id))
                .ok_or("profile_unavailable")?;
            #[cfg(target_os = "macos")]
            let id = mac::registration_device(&self.profile)?;
            self.dispatch(
                "RegistrationRequested",
                [
                    string(1, input),
                    string(2, id.as_ref()),
                    string(3, name),
                    number(4, 5),
                ]
                .concat(),
            )?;
        } else {
            if !state::email(input) {
                return Err("invalid_sign_in_input");
            }
            self.dispatch(
                "SendRegistrationCodeRequested",
                [string(1, input), string(2, name)].concat(),
            )?;
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            let snapshot = self.snapshot()?;
            if verify && snapshot.status["authenticated"] == true {
                #[cfg(target_os = "macos")]
                let _ = mac::configure_receive(self);
                return Ok(snapshot.status);
            }
            if snapshot.registration_failed {
                return Err("registration_failed");
            }
            if !verify && snapshot.status["registration"] == "CODE_SENT" {
                return Ok(json!({"ok": true, "phase": "code_sent"}));
            }
            thread::sleep(Duration::from_millis(150));
        }
        Err("registration_unconfirmed")
    }
}

fn input_value(input: Option<&str>, max: usize, error: &'static str) -> Result<String> {
    let mut value = String::new();
    if let Some(input) = input {
        value.push_str(input);
    } else {
        io::stdin()
            .take((max + 1) as u64)
            .read_to_string(&mut value)
            .map_err(|_| error)?;
    }
    if value.len() > max {
        return Err(error);
    }
    Ok(value)
}

#[cfg(not(target_os = "macos"))]
#[derive(Default)]
struct SeparatePolicy {
    verification_deadline: Option<Instant>,
    accepted: HashSet<String>,
}

fn waiting(item: &Value) -> bool {
    eligible(item) && item["status"] == "Invited"
}

fn receiving(item: &Value) -> bool {
    eligible(item)
        && matches!(
            item["status"].as_str(),
            Some("Pending" | "Active" | "Completed")
        )
}

fn eligible(item: &Value) -> bool {
    item["direction"] == "Incoming" && item["has_error"] == false && item["dismissed"] == false
}

fn path_text(path: &Path) -> Result<&str> {
    path.to_str().ok_or("profile_unavailable")
}

fn create_plain_directory(path: &Path) -> Result<()> {
    let builder = &mut fs::DirBuilder::new();
    #[cfg(unix)]
    builder.mode(0o700);
    match builder.create(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => check_plain_directory(path),
        Err(_) => Err("profile_unavailable"),
    }
}

fn check_plain_directory(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|_| "profile_unavailable")?;
    #[cfg(windows)]
    let plain = metadata.file_attributes() & 0x400 == 0;
    #[cfg(unix)]
    let plain = metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o022 == 0;
    if metadata.is_dir() && plain {
        Ok(())
    } else {
        Err("profile_unavailable")
    }
}

fn random_id() -> Result<String> {
    let mut bytes = [0; 16];
    getrandom::fill(&mut bytes).map_err(|_| "identifier_unavailable")?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = hex::encode(bytes);
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

#[cfg(not(target_os = "macos"))]
fn profile_marker(profile: &Path) -> Result<Value> {
    check_plain_directory(profile)?;
    let contents = fs::read(profile.join(PROFILE_MARKER)).map_err(|_| "profile_unavailable")?;
    let marker: Value = serde_json::from_slice(&contents).map_err(|_| "profile_unavailable")?;
    if marker["version"] != 1 {
        return Err("profile_unavailable");
    }
    Ok(marker)
}

#[cfg(not(target_os = "macos"))]
fn prepare(profile: &Path, name: Option<&str>) -> Result<Value> {
    if profile.join(PROFILE_MARKER).is_file() {
        profile_marker(profile)?;
    } else {
        let parent = profile.parent().ok_or("profile_unavailable")?;
        fs::create_dir_all(parent).map_err(|_| "profile_unavailable")?;
        create_plain_directory(profile)?;
        for folder in ["cache", "state"] {
            let path = profile.join(folder);
            create_plain_directory(&path)?;
            if fs::read_dir(path)
                .map_err(|_| "profile_unavailable")?
                .next()
                .is_some()
            {
                return Err("profile_unavailable");
            }
        }
        create_plain_directory(&profile.join("downloads"))?;
        let marker =
            json!({"version": 1, "name": name.unwrap_or("myDrive"), "deviceId": random_id()?});
        let mut file =
            tempfile::NamedTempFile::new_in(profile).map_err(|_| "profile_unavailable")?;
        emit(&mut file, &marker)?;
        file.persist_noclobber(profile.join(PROFILE_MARKER))
            .map_err(|_| "profile_unavailable")?;
    }
    Ok(json!({"ok": true}))
}

#[cfg(not(target_os = "macos"))]
fn trusted_peers(profile: &Path) -> Result<BTreeSet<String>> {
    let path = profile.join("trusted-peers.txt");
    match fs::read_to_string(&path) {
        Ok(text) if text.len() <= 80_000 => Ok(text
            .lines()
            .filter(|line| state::peer_id(line).is_some())
            .map(str::to_owned)
            .collect()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(BTreeSet::new()),
        _ => Err("profile_unavailable"),
    }
}

fn emit(output: &mut impl Write, result: &Value) -> Result<()> {
    serde_json::to_writer(&mut *output, result).map_err(|_| "reply_unavailable")?;
    output
        .write_all(b"\n")
        .and_then(|()| output.flush())
        .map_err(|_| "reply_unavailable")
}

#[cfg(not(target_os = "macos"))]
fn command(args: &Arguments) -> Result<Value> {
    let local = state::local()?;
    let desktop = args.desktop || args.command == "desktop-serve";
    let session = Session::new(&local, args.profile.clone(), desktop);
    match args.command.as_str() {
        "doctor" => {
            host::library(&local)?;
            return Ok(json!({"ok": true, "native": true}));
        }
        "import-engine" if args.files.len() == 1 => {
            host::import_library(&local, &args.files[0])?;
            return Ok(json!({"ok": true, "native": true}));
        }
        "init" if !desktop => return prepare(&args.profile, args.name.as_deref()),
        "serve" | "desktop-serve" => {
            if desktop && !session.state.join("state.dat").is_file() {
                return Err("desktop_profile_missing");
            }
            if desktop {
                fs::create_dir_all(&session.profile).map_err(|_| "profile_unavailable")?;
            } else {
                profile_marker(&session.profile)?;
            }
            check_plain_directory(&session.profile)?;
            let library = host::library(&local)?;
            // Go has its own native logger. Keep its output off the machine-readable channel.
            let (mut pipe, _quiet) = HostOutput::quiet()?;
            session.serve(&library, &mut pipe)?;
            return Ok(json!({"ok": true}));
        }
        "trust" if !desktop => {
            profile_marker(&session.profile)?;
            let peer = args
                .peer
                .as_deref()
                .filter(|peer| state::peer_id(peer).is_some())
                .ok_or("invalid_peer")?;
            let mut peers = trusted_peers(&session.profile)?;
            peers.insert(peer.into());
            fs::write(
                session.profile.join("trusted-peers.txt"),
                peers.into_iter().collect::<Vec<_>>().join("\n"),
            )
            .map_err(|_| "profile_unavailable")?;
            return Ok(json!({"ok": true}));
        }
        _ => {}
    }
    client_command(&session, args, None, None)
}

fn client_command(
    session: &Session,
    args: &Arguments,
    input: Option<&str>,
    owner: Option<&str>,
) -> Result<Value> {
    let snapshot = session.snapshot()?;
    let authenticated = snapshot.status["authenticated"] == true;
    if let Some(owner) = owner {
        let status = &snapshot.status;
        let current = format!(
            "{}:{}",
            status["user_id"].as_str().unwrap_or_default(),
            status["device_id"].as_str().unwrap_or_default()
        );
        if !authenticated || !owner.eq_ignore_ascii_case(&current) {
            return Err("sign_in_required");
        }
    }
    let result = match args.command.as_str() {
        "poll" => snapshot.poll(),
        "status" => snapshot.status,
        "devices" => json!({"ok": true, "devices": snapshot.devices}),
        "transfers" => json!({"ok": true, "transfers": snapshot.transfers}),
        "send" if authenticated => session.send(args, snapshot)?,
        "accept" if authenticated => session.accept(args, snapshot)?,
        "search" if authenticated => session.search(&snapshot.status, input)?,
        "search-clear" if authenticated => {
            session.dispatch("AbandonSearch", string(1, RECIPIENT_SEARCH))?;
            json!({"ok": true})
        }
        "login" => session.registration(false, snapshot, input)?,
        "verify" => session.registration(true, snapshot, input)?,
        "send" | "accept" | "search" | "search-clear" => return Err("sign_in_required"),
        _ => return Err("invalid_command"),
    };
    Ok(result)
}

#[cfg(target_os = "macos")]
fn command(args: &Arguments) -> Result<Value> {
    if args.command == "prepare" {
        return mac::prepare();
    }
    client_command(&mac::discover()?, args, None, None)
}

#[cfg(windows)]
struct HostOutput {
    original_out: windows_sys::Win32::Foundation::HANDLE,
    original_err: windows_sys::Win32::Foundation::HANDLE,
    _null: fs::File,
}

#[cfg(windows)]
impl HostOutput {
    fn quiet() -> Result<(fs::File, Self)> {
        unsafe {
            let original_out = GetStdHandle(STD_OUTPUT_HANDLE);
            let original_err = GetStdHandle(STD_ERROR_HANDLE);
            let process = GetCurrentProcess();
            let mut handle = std::ptr::null_mut();
            if DuplicateHandle(
                process,
                original_out,
                process,
                &mut handle,
                0,
                0,
                DUPLICATE_SAME_ACCESS,
            ) == 0
            {
                return Err("reply_unavailable");
            }
            let output = fs::File::from_raw_handle(handle);
            let null = OpenOptions::new()
                .write(true)
                .open("NUL")
                .map_err(|_| "reply_unavailable")?;
            let quiet = Self {
                original_out,
                original_err,
                _null: null,
            };
            if SetStdHandle(STD_OUTPUT_HANDLE, quiet._null.as_raw_handle()) == 0
                || SetStdHandle(STD_ERROR_HANDLE, quiet._null.as_raw_handle()) == 0
            {
                return Err("reply_unavailable");
            }
            Ok((output, quiet))
        }
    }
}

#[cfg(windows)]
impl Drop for HostOutput {
    fn drop(&mut self) {
        unsafe {
            SetStdHandle(STD_OUTPUT_HANDLE, self.original_out);
            SetStdHandle(STD_ERROR_HANDLE, self.original_err);
        }
    }
}

#[cfg(target_os = "linux")]
struct HostOutput {
    saved: [std::os::fd::OwnedFd; 2],
}

#[cfg(target_os = "linux")]
impl HostOutput {
    fn quiet() -> Result<(fs::File, Self)> {
        use std::os::fd::{AsRawFd, FromRawFd};
        fn duplicate(fd: i32) -> Result<std::os::fd::OwnedFd> {
            let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
            if copy < 0 {
                return Err("reply_unavailable");
            }
            Ok(unsafe { std::os::fd::OwnedFd::from_raw_fd(copy) })
        }
        let output = fs::File::from(duplicate(1)?);
        let saved = Self {
            saved: [duplicate(1)?, duplicate(2)?],
        };
        let null = OpenOptions::new()
            .write(true)
            .open("/dev/null")
            .map_err(|_| "reply_unavailable")?;
        if unsafe { libc::dup2(null.as_raw_fd(), 1) } < 0
            || unsafe { libc::dup2(null.as_raw_fd(), 2) } < 0
        {
            return Err("reply_unavailable");
        }
        Ok((output, saved))
    }
}

#[cfg(target_os = "linux")]
impl Drop for HostOutput {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        unsafe {
            libc::dup2(self.saved[0].as_raw_fd(), 1);
            libc::dup2(self.saved[1].as_raw_fd(), 2);
        }
    }
}

pub(crate) fn run(arguments: impl Iterator<Item = OsString>) -> i32 {
    let mut output = io::stdout();
    let result = Arguments::parse(arguments)
        .and_then(|args| command(&args))
        .unwrap_or_else(|error| json!({"ok": false, "error": error}));
    if emit(&mut output, &result).is_ok() && result["ok"] == true {
        0
    } else {
        1
    }
}

#[cfg(windows)]
pub(crate) fn poll(profile: PathBuf, desktop: bool) -> std::result::Result<Value, String> {
    state::local()
        .and_then(|local| Session::new(&local, profile, desktop).snapshot())
        .map(Snapshot::poll)
        .map_err(|_| "The local Blip connection is unavailable.".into())
}

#[cfg(any(windows, target_os = "macos"))]
pub(crate) fn error_message(error: &str) -> &'static str {
    match error {
        "native_engine_missing" => {
            "Install a compatible Blip engine to use myDrive's Windows Blip helper."
        }
        "native_engine_unsupported" => {
            "The installed Blip engine does not match this version of myDrive."
        }
        "desktop_profile_missing" => {
            "Sign in to the official Blip app once to reuse this computer's account."
        }
        "sign_in_required" => "The Blip device is signed out.",
        "native_connection_unavailable" => "The local Blip connection is unavailable.",
        "invalid_native_response" => "Blip returned a response myDrive could not read.",
        "native_response_too_large" => "Blip’s local response was too large to read.",
        "native_request_rejected" => "The local Blip engine rejected the request.",
        "profile_unavailable" => "myDrive could not access the Blip profile or receiving folder.",
        "receive_policy_unconfirmed" => "Blip has not confirmed the receiving settings yet.",
        "invalid_search" => "Enter a name or email address to search Blip.",
        "search_unavailable" => "Blip could not complete the search. Try again.",
        "host_already_running" => "The Blip profile is already running.",
        "accept_not_waiting" => {
            "This incoming transfer is no longer waiting. Refresh the transfer list."
        }
        "acceptance_unconfirmed" => {
            "Blip has not confirmed acceptance. Check transfers before trying again."
        }
        "invalid_peer_or_selection" => {
            "Select an exact available Blip device and existing files or folders."
        }
        _ => "Blip could not confirm the request. Refresh transfers before retrying.",
    }
}

#[cfg(all(test, not(target_os = "macos")))]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::thread;
    use std::time::{Duration, Instant};

    #[test]
    #[ignore = "Requires the approved local Blip library"]
    fn private_host_starts_without_java() {
        let variable = if cfg!(windows) {
            "MYDRIVE_BLIP_DLL"
        } else {
            "MYDRIVE_BLIP_LIBRARY"
        };
        let library = PathBuf::from(std::env::var_os(variable).expect("engine path"));
        let profile = tempfile::Builder::new().prefix("mdb-").tempdir().unwrap();
        let library = host::import_library(profile.path(), &library).unwrap();
        assert!(library.starts_with(profile.path()));
        let cache = profile.path().join("c");
        let state = profile.path().join("s");
        let socket = cache.join("sock");
        let host = host::Host::start(
            &library,
            &cache,
            &state,
            "https://127.0.0.1:9",
            &profile.path().join("host.lock"),
        )
        .unwrap();
        let start = Instant::now();
        let payload = loop {
            match rpc::call(&socket, "/rpc.Service/GetState", &[]) {
                Ok(payload) => break payload,
                Err(error) if start.elapsed() > Duration::from_secs(10) => panic!("{error}"),
                _ => thread::sleep(Duration::from_millis(100)),
            }
        };
        let envelope = rpc::Proto::parse(&payload).unwrap();
        assert!(envelope.has(2));
        let session = Session::new(profile.path(), profile.path().to_owned(), false);
        let session = Session { socket, ..session };
        assert_eq!(session.snapshot().unwrap().status["authenticated"], false);
        let agent = string(300, "mydrive.test");
        session.dispatch("SetUserAgent", field(1, &agent)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while session.snapshot().unwrap().app_id_missing {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(50));
        }
        drop(host);
        assert!(rpc::connect(&session.socket).is_err());
    }
}
