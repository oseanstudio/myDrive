//! Locate the native macOS host without moving its saved profiles.
use super::{
    client_command, emit, field, number, random_id, rpc, string, uuid, Arguments, Result, Session,
};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    env, fs,
    io::{self, BufRead, Read, Write},
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant},
};

const GROUP: &str = "AY8UB8KTUX.blip";
const NAMESPACE: &str = "net.oseanstudio.mydrive.blip";

pub(super) fn home() -> Option<PathBuf> {
    env::home_dir().filter(|path| path.is_absolute())
}

pub(super) fn discover() -> Result<Session> {
    let home = home().ok_or("profile_unavailable")?;
    discover_in(&home, &env::temp_dir())
}

fn managed_candidates(temp: &Path) -> [PathBuf; 3] {
    [
        temp.join("mdblip/sock"),
        temp.join(NAMESPACE).join("sock"),
        Path::new("/tmp").join(NAMESPACE).join("sock"),
    ]
}

fn discover_in(home: &Path, temp: &Path) -> Result<Session> {
    let profile = home.join("Library/Application Support/myDrive/Blip");
    let managed = managed_candidates(temp);
    let override_path = fs::File::open(profile.join("desktop-socket.txt"))
        .ok()
        .and_then(|file| {
            let mut text = String::new();
            file.take(1025).read_to_string(&mut text).ok()?;
            let path = PathBuf::from(text.trim());
            (text.len() <= 1024 && path.is_absolute()).then_some(path)
        });
    let socket = override_path
        .filter(|path| rpc::connect(path).is_ok())
        .or_else(|| live_socket(managed.to_vec()))
        .or_else(|| {
            let known = [
                temp.join(GROUP).join("sock"),
                Path::new("/tmp").join(GROUP).join("sock"),
                home.join("Library/Group Containers")
                    .join(GROUP)
                    .join("Library/Caches/sock"),
                temp.join("net.blip.desktop/sock"),
                home.join("Library/Caches/net.blip.desktop/sock"),
                home.join("Library/Caches/net.blip.Blip/sock"),
                home.join("Library/Caches/net.blip.macos/sock"),
            ];
            // These endpoints belong to the official profile. Broad discovery is only a fallback.
            if let Some(socket) = known.into_iter().find(|path| rpc::connect(path).is_ok()) {
                return Some(socket);
            }
            let mut candidates = Vec::new();
            for root in [
                home.join("Library/Caches"),
                home.join("Library/Application Support"),
                temp.to_owned(),
            ] {
                if let Ok(entries) = fs::read_dir(root) {
                    for entry in entries
                        .flatten()
                        .filter(|entry| {
                            entry
                                .file_name()
                                .to_string_lossy()
                                .to_ascii_lowercase()
                                .contains("blip")
                        })
                        .take(16)
                    {
                        candidates
                            .extend([entry.path().join("sock"), entry.path().join("cache/sock")]);
                    }
                }
            }
            live_socket(candidates)
        })
        .ok_or("native_connection_unavailable")?;
    let resolved = socket
        .canonicalize()
        .map_err(|_| "native_connection_unavailable")?;
    let desktop = !managed
        .iter()
        .any(|path| path.canonicalize().is_ok_and(|path| path == resolved));
    let (inbox, custom_inbox) = received_directory(home);
    Ok(Session {
        profile,
        socket,
        inbox,
        custom_inbox,
        desktop,
    })
}

fn live_socket(mut candidates: Vec<PathBuf>) -> Option<PathBuf> {
    candidates.sort_by_key(|candidate| candidate.as_os_str().len());
    let mut live = BTreeMap::new();
    for candidate in candidates {
        if let Ok(path) = candidate.canonicalize() {
            if !live.contains_key(&path) && rpc::connect(&candidate).is_ok() {
                live.insert(path, candidate);
            }
        }
    }
    (live.len() == 1)
        .then(|| live.into_values().next())
        .flatten()
}

pub(super) fn registration_device(profile: &Path) -> Result<String> {
    let path = profile.join("registration-device.txt");
    let read = || {
        fs::read_to_string(&path)
            .ok()
            .filter(|value| uuid(value))
            .ok_or("profile_unavailable")
    };
    if path.is_file() {
        return read();
    }
    let id = random_id()?;
    let mut file = tempfile::NamedTempFile::new_in(profile).map_err(|_| "profile_unavailable")?;
    file.write_all(id.as_bytes())
        .map_err(|_| "profile_unavailable")?;
    match file.persist_noclobber(path.clone()) {
        Ok(_) => Ok(id),
        Err(_) => read(),
    }
}

fn received_directory(home: &Path) -> (PathBuf, bool) {
    let preference = home.join("Library/Application Support/myDrive/preferences.json");
    let custom = fs::read(preference)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|prefs| {
            let saved = prefs["blip_download_directory"].as_str()?;
            let path = PathBuf::from(saved);
            (path.is_absolute()
                && !saved.chars().any(char::is_control)
                && !path
                    .components()
                    .any(|part| part == std::path::Component::ParentDir))
            .then_some(path)
        });
    match custom {
        Some(path) => (path, true),
        None => (home.join("Downloads/myDrive"), false),
    }
}

fn classify_inbox_error(error: io::Error) -> &'static str {
    if error.kind() == io::ErrorKind::PermissionDenied {
        "receive_downloads_denied"
    } else {
        "receive_downloads_unavailable"
    }
}

fn check_inbox(inbox: &Path) -> Result<()> {
    if !fs::symlink_metadata(inbox).map_err(classify_inbox_error)?.is_dir() {
        return Err("receive_downloads_unavailable");
    }
    fs::read_dir(inbox).map_err(classify_inbox_error)?;
    Ok(())
}

pub(super) fn prepare_receive_root(session: &Session) -> Result<()> {
    if session.custom_inbox {
        // A custom location may be on a disconnected volume. Never recreate it.
        check_inbox(&session.inbox)
    } else {
        prepare_inbox(&session.inbox)
    }
}

pub(super) fn prepare_inbox(inbox: &Path) -> Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    let parent = inbox.parent().ok_or("receive_downloads_unavailable")?;
    fs::create_dir_all(parent).map_err(classify_inbox_error)?;
    match fs::DirBuilder::new().mode(0o700).create(inbox) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            check_inbox(inbox)?;
            super::check_plain_directory(inbox).map_err(|_| "receive_downloads_unavailable")
        }
        Err(error) => Err(classify_inbox_error(error)),
    }
}

pub(super) fn configure_receive(session: &Session) -> Result<()> {
    session.dispatch("TransferSetAutoAccept", number(1, 0))?;
    prepare_receive_root(session)?;
    session.dispatch(
        "TransferSetCustomDefaultSavePath",
        string(1, super::path_text(&session.inbox)?),
    )
}

pub(super) fn prepare() -> Result<Value> {
    let home = home().ok_or("profile_unavailable")?;
    let managed = managed_candidates(&env::temp_dir());
    let deadline = Instant::now() + Duration::from_secs(12);
    while Instant::now() < deadline {
        if let Some(socket) = live_socket(managed.to_vec()) {
            let (inbox, custom_inbox) = received_directory(&home);
            let session = Session {
                profile: home.join("Library/Application Support/myDrive/Blip"),
                socket,
                inbox,
                custom_inbox,
                desktop: false,
            };
            let agent = [
                string(101, "Mac"),
                number(102, 5),
                string(200, "macOS"),
                string(300, "net.oseanstudio.mydrive"),
                string(301, "myDrive"),
            ]
            .concat();
            session.dispatch("SetUserAgent", field(1, &agent))?;
            // Send can still work when macOS denies access to Downloads.
            let receive_configured = configure_receive(&session).is_ok();
            return Ok(json!({"ok": true, "receive_configured": receive_configured}));
        }
        thread::sleep(Duration::from_millis(150));
    }
    Err("native_connection_unavailable")
}

pub(crate) fn request(action: &str, payload: &Value) -> std::result::Result<Value, String> {
    run_request(action, payload)
        .and_then(|value| match value["error"].as_str() {
            Some("accept_not_waiting") => Err("accept_not_waiting"),
            Some("acceptance_unconfirmed") => Err("acceptance_unconfirmed"),
            _ => Ok(value),
        })
        .map_err(|error| super::error_message(error).to_owned())
}

fn run_request(action: &str, payload: &Value) -> Result<Value> {
    let session = discover()?;
    if action == "configure-receive" {
        if session.desktop {
            return Err("invalid_command");
        }
        configure_receive(&session)?;
        return Ok(json!({"ok": true}));
    }
    let args = Arguments {
        command: action.to_owned(),
        profile: PathBuf::new(),
        desktop: false,
        name: payload["name"].as_str().map(str::to_owned),
        peer: payload["peer"].as_str().map(str::to_owned),
        id: payload["id"].as_str().map(str::to_owned),
        files: payload["paths"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|value| {
                value
                    .as_str()
                    .map(PathBuf::from)
                    .filter(|path| path.is_absolute())
                    .ok_or("file_unavailable")
            })
            .collect::<Result<_>>()?,
        execute: true,
    };
    if args.files.len() > 256 {
        return Err("invalid_peer_or_selection");
    }
    client_command(
        &session,
        &args,
        Some(payload["text"].as_str().unwrap_or_default()),
        payload["owner"].as_str(),
    )
}

/// Reuse one process for background polling. All mutations use separate calls.
pub(crate) fn poll_loop() -> i32 {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let mut line = Vec::new();
    loop {
        line.clear();
        match (&mut input).take(32).read_until(b'\n', &mut line) {
            Ok(0) => return 0,
            Ok(_) if line == b"POLL\n" => {}
            _ => return 1,
        }
        let result = match discover().and_then(|session| session.snapshot()) {
            Ok(snapshot) => json!({"ok": true, "data": snapshot.poll()}),
            Err(error) => json!({
                "ok": false, "unavailable": error == "native_connection_unavailable",
                "error": super::error_message(error)
            }),
        };
        if emit(&mut output, &result).is_err() {
            return 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    const USER: &str = "11111111-1111-4111-8111-111111111111";
    const DEVICE: &str = "22222222-2222-4222-8222-222222222222";
    const ID: &str = "ABCD1234-EF56-4789-ABCD-123456789ABC";

    #[test]
    fn cancel_send_confirms_an_outgoing_transfer_by_exact_id() {
        let root = tempfile::Builder::new()
            .prefix("md-blip-")
            .tempdir_in("/tmp")
            .unwrap();
        let session = Session {
            profile: root.path().join("Blip"),
            socket: root.path().join("sock"),
            inbox: root.path().join("downloads"),
            custom_inbox: false,
            desktop: false,
        };
        let listener = UnixListener::bind(&session.socket).unwrap();
        let make_state = |phase| {
            let auth = field(
                201,
                &[
                    string(201, "fixture"),
                    string(202, USER),
                    string(204, DEVICE),
                ]
                .concat(),
            );
            let transfer = [string(100, ID), number(700, 2), number(800, phase)].concat();
            field(2, &[auth, field(600, &field(2, &transfer))].concat())
        };
        let server = thread::spawn(move || {
            for request in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut body = Vec::new();
                for _ in 0..4 {
                    let mut header = [0; 3];
                    stream.read_exact(&mut header).unwrap();
                    let size = rpc::varint(|| {
                        let mut byte = [0];
                        stream.read_exact(&mut byte).map_err(|_| "fixture_read")?;
                        Ok(byte[0])
                    })
                    .unwrap();
                    assert!(size < 4096);
                    let mut bytes = vec![0; size as usize];
                    stream.read_exact(&mut bytes).unwrap();
                    body.extend(bytes);
                }
                let response = match request {
                    1 => {
                        let event = b"TransferCancellationRequested";
                        assert!(body.windows(event.len()).any(|part| part == event));
                        let payload = string(1, ID);
                        assert!(body
                            .windows(payload.len())
                            .any(|part| part == payload.as_slice()));
                        Vec::new()
                    }
                    _ => make_state(if request == 0 { 5 } else { 9 }),
                };
                let mut reply = vec![5, 1, 1];
                rpc::encode_varint(&mut reply, response.len() as u64);
                reply.extend(response);
                stream.write_all(&reply).unwrap();
            }
        });
        let args = Arguments {
            command: "cancel".into(),
            profile: PathBuf::new(),
            desktop: false,
            name: None,
            peer: None,
            id: Some(ID.into()),
            files: Vec::new(),
            execute: true,
        };
        let owner = format!("{USER}:{DEVICE}");
        let result = client_command(&session, &args, None, Some(&owner)).unwrap();
        assert_eq!(result["native_status"], "Cancelled");
        server.join().unwrap();
    }

    #[test]
    fn blocked_downloads_subfolder_is_distinguished_from_permissions() {
        let root = tempfile::tempdir().unwrap();
        let inbox = root.path().join("Downloads/myDrive");
        prepare_inbox(&inbox).unwrap();
        fs::remove_dir(&inbox).unwrap();
        fs::write(&inbox, b"existing file").unwrap();
        assert_eq!(prepare_inbox(&inbox), Err("receive_downloads_unavailable"));
        assert_eq!(fs::read(inbox).unwrap(), b"existing file");
    }

    #[test]
    fn official_socket_is_discovered_with_a_stale_override_and_other_local_socket() {
        let fixture = tempfile::Builder::new()
            .prefix("md-blip-")
            .tempdir_in("/tmp")
            .unwrap();
        let home = fixture.path().join("home");
        let temp = fixture.path().join("tmp");
        let profile = home.join("Library/Application Support/myDrive/Blip");
        fs::create_dir_all(&profile).unwrap();
        fs::write(
            profile.join("desktop-socket.txt"),
            temp.join("stale/sock").to_str().unwrap(),
        )
        .unwrap();
        let official = temp.join(GROUP).join("sock");
        let other = temp.join("legacy-blip").join("sock");
        fs::create_dir_all(official.parent().unwrap()).unwrap();
        fs::create_dir_all(other.parent().unwrap()).unwrap();
        let _official = UnixListener::bind(&official).unwrap();
        let _other = UnixListener::bind(&other).unwrap();
        let session = discover_in(&home, &temp).unwrap();
        assert!(session.desktop);
        assert_eq!(session.socket, official);
    }

    #[test]
    fn signed_in_profile_accepts_the_exact_invitation_and_retains_received_paths() {
        let root = tempfile::Builder::new()
            .prefix("md-blip-")
            .tempdir_in("/tmp")
            .unwrap();
        let session = Session {
            profile: root.path().join("Blip"),
            socket: root.path().join("sock"),
            inbox: root.path().join("downloads"),
            custom_inbox: false,
            desktop: false,
        };
        let listener = UnixListener::bind(&session.socket).unwrap();
        let destination = session.inbox.join(ID);
        let accepted_path = destination.to_str().unwrap().to_owned();
        let auth = field(
            201,
            &[string(201, "test"), string(202, USER), string(204, DEVICE)].concat(),
        );
        let config = field(
            100,
            &[number(2, 1), string(4, session.inbox.to_str().unwrap())].concat(),
        );
        let item = field(
            1,
            &[
                string(1, "Studio.webloc"),
                field(2, &field(1, &number(1, 43))),
            ]
            .concat(),
        );
        let saved = field(
            2,
            &[
                string(1, "Studio.webloc"),
                string(2, "downloads:myDrive/Studio.webloc"),
            ]
            .concat(),
        );
        let state = move |complete, verified| {
            let archive = if complete {
                [item.clone(), saved.clone()].concat()
            } else {
                item.clone()
            };
            let peer = field(200, &[string(1, DEVICE), string(2, USER)].concat());
            let transfer = [
                string(100, ID),
                peer,
                field(400, &archive),
                number(700, 1),
                number(800, if complete { 8 } else { 3 }),
            ]
            .concat();
            field(
                2,
                &[
                    auth.clone(),
                    if verified { config.clone() } else { Vec::new() },
                    field(600, &field(2, &transfer)),
                ]
                .concat(),
            )
        };
        let server = thread::spawn(move || {
            for request in 0..7 {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut body = Vec::new();
                for _ in 0..4 {
                    let mut header = [0; 3];
                    stream.read_exact(&mut header).unwrap();
                    let size = rpc::varint(|| {
                        let mut byte = [0];
                        stream.read_exact(&mut byte).map_err(|_| "fixture_read")?;
                        Ok(byte[0])
                    })
                    .unwrap();
                    assert!(size < 4096);
                    let mut bytes = vec![0; size as usize];
                    stream.read_exact(&mut bytes).unwrap();
                    body.extend(bytes);
                }
                let response = if request == 4 {
                    assert!(body.windows(ID.len()).any(|part| part == ID.as_bytes()));
                    assert!(body
                        .windows(accepted_path.len())
                        .any(|part| part == accepted_path.as_bytes()));
                    assert!(body
                        .windows(27)
                        .any(|part| part == b"TransferAcceptanceRequested"));
                    Vec::new()
                } else {
                    assert!(body.ends_with(b"/rpc.Service/GetState"));
                    state(request >= 5, request < 2)
                };
                // Split the native reply into two frames with one message ID.
                let middle = response.len().min(64);
                let mut reply = vec![4, 1, 1, middle as u8];
                reply.extend_from_slice(&response[..middle]);
                reply.extend([5, 1, 1]);
                rpc::encode_varint(&mut reply, (response.len() - middle) as u64);
                reply.extend_from_slice(&response[middle..]);
                stream.write_all(&reply).unwrap();
            }
        });
        fs::create_dir(&session.profile).unwrap();
        let registration = session.profile.join("registration-device.txt");
        fs::write(&registration, DEVICE).unwrap();
        assert_eq!(registration_device(&session.profile).unwrap(), DEVICE);
        let before = session.snapshot().unwrap().poll();
        assert_eq!(before["status"]["user_id"], USER);
        assert_eq!(before["status"]["device_id"], DEVICE);
        assert_eq!(before["status"]["receive_policy_verified"], true);
        assert_eq!(before["transfers"][0]["link_only"], true);
        let mut args = Arguments {
            command: "accept".into(),
            profile: PathBuf::new(),
            desktop: false,
            name: None,
            peer: None,
            id: Some(ID.into()),
            files: Vec::new(),
            execute: true,
        };
        assert_eq!(
            client_command(&session, &args, None, Some("wrong owner")),
            Err("sign_in_required")
        );
        let owner = format!("{USER}:{DEVICE}");
        assert_eq!(
            client_command(&session, &args, None, Some(&owner)),
            Err("receive_policy_unconfirmed")
        );
        args.command = "accept-manual".into();
        let result = client_command(&session, &args, None, Some(&owner)).unwrap();
        assert_eq!(result["phase"], "receiving_confirmed");
        assert!(destination.is_dir());
        let after = session.snapshot().unwrap().poll();
        assert_eq!(after["transfers"][0]["transfer_id"], ID);
        let link = home().unwrap().join("Downloads/myDrive/Studio.webloc");
        assert_eq!(after["transfers"][0]["link_files"][0], json!(link));
        assert_eq!(fs::read_to_string(registration).unwrap(), DEVICE);
        server.join().unwrap();
    }
}
