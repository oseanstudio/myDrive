//! Local store-and-forward journal. Blip authenticates each transport hop.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const PREFIX: &str = "mydrive-relay-v1.";
const PROBE_WINDOW: u64 = 35;
const MAX_INBOX: usize = 256;
type Result<T> = std::result::Result<T, String>;

fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

fn id() -> Result<String> {
    let mut bytes = [0; 16];
    getrandom::fill(&mut bytes).map_err(|_| "Cannot create a transfer identifier")?;
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
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

fn peer_parts(peer: &str) -> Option<(&str, &str)> {
    let (account, device) = peer.split_once(':')?;
    (uuid(account) && uuid(device)).then_some((account, device))
}

fn eq(left: &str, right: &str) -> bool {
    left.eq_ignore_ascii_case(right)
}

#[derive(Clone, Debug)]
struct Packet {
    kind: String,
    job: String,
    origin: String,
    target: String,
}

impl Packet {
    fn read(name: &str) -> Option<Self> {
        let parts: Vec<_> = name.strip_prefix(PREFIX)?.split('.').collect();
        if parts.len() != 4
            || !["probe", "ready", "data", "stored"].contains(&parts[0])
            || !parts[1..].iter().all(|p| uuid(p))
            || eq(parts[2], parts[3])
        {
            return None;
        }
        Some(Self {
            kind: parts[0].into(),
            job: parts[1].into(),
            origin: parts[2].into(),
            target: parts[3].into(),
        })
    }

    fn name(&self, kind: &str) -> String {
        format!(
            "{PREFIX}{kind}.{}.{}.{}",
            self.job, self.origin, self.target
        )
    }
}

#[derive(Deserialize)]
struct Device {
    peer: String,
    online: Option<bool>,
    #[serde(default)]
    history: bool,
}

#[derive(Deserialize)]
struct Item {
    name: String,
    path: PathBuf,
    is_directory: bool,
}

#[derive(Deserialize)]
struct Transfer {
    transfer_id: String,
    peer: String,
    direction: String,
    status: String,
    completed: bool,
    has_error: bool,
    #[serde(default)]
    dismissed: bool,
    #[serde(default)]
    item_names: Vec<String>,
    #[serde(default)]
    received_items: Vec<Item>,
    #[serde(default)]
    total_bytes: u64,
}

impl Transfer {
    fn finished(&self) -> bool {
        self.completed && self.status == "Completed" && !self.has_error
    }
    fn marker(&self) -> Option<Packet> {
        if self.item_names.len() != 1 || !uuid(&self.transfer_id) {
            return None;
        }
        Packet::read(&self.item_names[0])
    }
}

#[derive(Deserialize)]
struct Snapshot {
    #[serde(rename = "self")]
    own: String,
    inbox: PathBuf,
    #[serde(default)]
    downloads: Option<PathBuf>,
    devices: Vec<Device>,
    transfers: Vec<Transfer>,
}

#[derive(Deserialize)]
struct Stage {
    #[serde(rename = "self")]
    own: String,
    target: String,
    relay: String,
    #[serde(default)]
    alternatives: Vec<String>,
    paths: Vec<PathBuf>,
}

#[derive(Serialize, Deserialize)]
struct Job {
    target: String,
    relay: String,
    envelope: PathBuf,
    phase: String,
    dispatched: String,
    since: u64,
    #[serde(default)]
    custody: bool,
    #[serde(default)]
    alternatives: Vec<String>,
    #[serde(default)]
    queued_label: Option<String>,
}

#[derive(Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
enum Action {
    Accept {
        id: String,
    },
    Send {
        id: String,
        peer: String,
        paths: Vec<PathBuf>,
    },
    Deliver {
        id: String,
        peer: String,
        paths: Vec<PathBuf>,
    },
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn io(error: std::io::Error) -> String {
    format!("Relay storage: {error}")
}

fn real_entry(path: &Path) -> Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path).map_err(io)?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err("Relay cannot use redirected files or folders.".into());
        }
    }
    if metadata.is_symlink() || !(metadata.is_dir() || metadata.is_file()) {
        return Err("Relay can only store regular files and folders.".into());
    }
    Ok(metadata)
}

fn checked(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() {
        return Err("Expected an absolute local relay path.".into());
    }
    for parent in path.ancestors() {
        real_entry(parent)?;
    }
    fs::canonicalize(path).map_err(io)
}

fn copy(source: &Path, target: &Path, depth: usize) -> Result<()> {
    if depth > 128 {
        return Err("Relay folder nesting is too deep.".into());
    }
    let entry = real_entry(source)?;
    if entry.is_dir() {
        fs::create_dir(target).map_err(io)?;
        for entry in fs::read_dir(source).map_err(io)? {
            let entry = entry.map_err(io)?;
            copy(&entry.path(), &target.join(entry.file_name()), depth + 1)?;
        }
    } else {
        // Reserve the name exclusively, including on case-insensitive filesystems.
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(target)
            .map_err(io)?;
        std::io::copy(&mut fs::File::open(source).map_err(io)?, &mut output).map_err(io)?;
        output.sync_all().map_err(io)?;
    }
    Ok(())
}

fn storage(data: &Path, own: &str) -> Result<PathBuf> {
    let (account, device) = peer_parts(own).ok_or("Relay requires a signed-in device.")?;
    let root = data
        .join("Blip")
        .join("relay-v1")
        .join(account.to_ascii_lowercase())
        .join(device.to_ascii_lowercase());
    fs::create_dir_all(&root).map_err(io)?;
    checked(&root)?;
    Ok(root)
}

fn job_lock(root: &Path) -> Result<fs::File> {
    let lock = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(root.join("jobs.lock"))
        .map_err(io)?;
    lock.lock().map_err(io)?;
    Ok(lock)
}

fn discard_job(root: &Path, directory: &Path) -> Result<()> {
    checked(directory)?;
    let discarded = tempfile::tempdir_in(root).map_err(io)?;
    fs::rename(directory, discarded.path().join("job")).map_err(io)?;
    Ok(())
}

fn put(path: &Path, value: &impl Serialize) -> Result<()> {
    let parent = path.parent().ok_or("Missing relay storage parent")?;
    let mut tmp = tempfile::NamedTempFile::new_in(parent).map_err(io)?;
    serde_json::to_writer(&mut tmp, value).map_err(|e| e.to_string())?;
    tmp.flush().map_err(io)?;
    tmp.as_file().sync_all().map_err(io)?;
    tmp.persist(path).map_err(|e| io(e.error))?;
    Ok(())
}

fn get<T: for<'a> Deserialize<'a>>(path: &Path) -> Result<T> {
    let file = fs::File::open(path).map_err(io)?;
    serde_json::from_reader(file)
        .map_err(|_| "Saved relay state is unreadable. Its files have been kept.".into())
}

fn stage(data: &Path, req: Stage) -> Result<Value> {
    let (account, origin) = peer_parts(&req.own).ok_or("Relay requires a signed-in device.")?;
    let (target_account, target) = peer_parts(&req.target).ok_or("Invalid relay destination")?;
    let (relay_account, relay) = peer_parts(&req.relay).ok_or("Invalid relay device")?;
    if !eq(account, target_account)
        || !eq(account, relay_account)
        || eq(origin, target)
        || eq(relay, target)
        || eq(relay, origin)
        || req.paths.is_empty()
        || req.paths.len() > 256
    {
        return Err(
            "Choose a different device on the same Blip account to relay the transfer.".into(),
        );
    }
    let root = storage(data, &req.own)?;
    let packet = Packet {
        kind: "data".into(),
        job: id()?,
        origin: origin.into(),
        target: target.into(),
    };
    let staging = tempfile::tempdir_in(&root).map_err(io)?;
    let envelope = staging.path().join(packet.name("data"));
    fs::create_dir(&envelope).map_err(io)?;
    let mut originals = Vec::with_capacity(req.paths.len());
    for path in &req.paths {
        let source = checked(path)?;
        let name = path
            .file_name()
            .ok_or("Choose a file or folder, rather than a drive root.")?;
        if envelope.starts_with(path) || envelope.starts_with(&source) {
            return Err("Cannot relay the myDrive outbox or a parent folder.".into());
        }
        copy(&source, &envelope.join(name), 0)?;
        originals.push(source);
    }
    let final_root = root.join(&packet.job);
    let queued_label = if originals.len() == 1 {
        originals[0]
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("File or folder")
            .chars()
            .filter(|c| !c.is_control())
            .take(160)
            .collect()
    } else {
        format!("{} items", originals.len())
    };
    let alternatives = req
        .alternatives
        .into_iter()
        .take(8)
        .filter(|candidate| {
            peer_parts(candidate).is_some_and(|(a, p)| {
                eq(account, a) && !eq(p, origin) && !eq(p, target) && !eq(p, relay)
            })
        })
        .collect();
    put(
        &staging.path().join("job.json"),
        &Job {
            target: req.target.clone(),
            relay: req.relay,
            envelope: final_root.join(packet.name("data")),
            phase: "probe".into(),
            dispatched: String::new(),
            since: now(),
            custody: false,
            alternatives,
            queued_label: Some(queued_label),
        },
    )?;
    let _lock = job_lock(&root)?;
    fs::rename(staging.path(), final_root).map_err(io)?;
    let _ =
        crate::blip::activity::record(data, &req.own, &req.target, &packet.job, &originals, true);
    Ok(json!({"id": packet.job}))
}

fn outgoing<'a>(req: &'a Snapshot, id: &str, peer: &str) -> Option<&'a Transfer> {
    req.transfers
        .iter()
        .find(|t| t.direction == "Outgoing" && t.transfer_id == id && eq(&t.peer, peer))
}

fn online(req: &Snapshot, peer: &str) -> bool {
    req.devices
        .iter()
        .any(|d| !d.history && eq(&d.peer, peer) && d.online == Some(true))
}

fn children(folder: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for entry in fs::read_dir(folder).map_err(io)? {
        let path = entry.map_err(io)?.path();
        real_entry(&path)?;
        paths.push(path);
        if paths.len() > 256 {
            return Err("Too many top-level relay files.".into());
        }
    }
    paths.sort();
    Ok(paths)
}

fn check_tree(path: &Path, depth: usize) -> Result<()> {
    if depth > 128 {
        return Err("Relay folder nesting is too deep.".into());
    }
    if real_entry(path)?.is_dir() {
        for entry in fs::read_dir(path).map_err(io)? {
            check_tree(&entry.map_err(io)?.path(), depth + 1)?;
        }
    }
    Ok(())
}

fn send(job: &mut Job, record: &Path, peer: String, paths: Vec<PathBuf>) -> Result<Action> {
    job.dispatched = id()?;
    job.since = now();
    if job.phase != "probe" {
        job.queued_label = None;
    }
    put(record, job)?;
    Ok(Action::Send {
        id: job.dispatched.clone(),
        peer,
        paths,
    })
}

fn owned_packet(req: &Snapshot, transfer: &Transfer, packet: &Packet) -> Result<Option<PathBuf>> {
    let [item] = transfer.received_items.as_slice() else {
        return Ok(None);
    };
    if !item.is_directory || item.name != packet.name(&packet.kind) {
        return Ok(None);
    }
    let expected = req.inbox.join(&transfer.transfer_id).join(&item.name);
    if item.path.file_name() != expected.file_name() {
        return Ok(None);
    }
    if expected.exists() && !item.path.exists() {
        checked(&expected)?;
        return Ok(Some(expected));
    }
    if !item.path.exists() {
        return Ok(None);
    }
    let actual = checked(&item.path)?;
    if expected.exists() {
        return Ok((actual == checked(&expected)?).then_some(expected));
    }
    // Native auto-accept can place our packet under Downloads before myDrive
    // sees the invite. Only move the exact reserved folder from that tree.
    let Some(downloads) = req.downloads.as_ref() else {
        return Ok(None);
    };
    if !downloads.is_dir() || !actual.starts_with(checked(downloads)?) {
        return Ok(None);
    }
    check_tree(&actual, 0)?;
    let parent = expected.parent().ok_or("Invalid relay receive path")?;
    fs::create_dir_all(parent).map_err(io)?;
    checked(parent)?;
    fs::rename(&actual, &expected).map_err(io)?;
    Ok(Some(expected))
}

fn receive(
    req: &Snapshot,
    root: &Path,
    account: &str,
    device: &str,
    can_accept_new: bool,
) -> Result<Option<Action>> {
    for t in &req.transfers {
        if t.direction != "Incoming" || t.has_error || t.dismissed {
            continue;
        }
        let Some(packet) = t.marker() else { continue };
        let Some((remote_account, remote)) = peer_parts(&t.peer) else {
            continue;
        };
        if !eq(account, remote_account) || eq(remote, device) {
            continue;
        }
        let job_dir = root.join(&packet.job);
        let record = job_dir.join("job.json");
        let ack = root.join(format!("seen-{}", t.transfer_id));
        let done = root.join(format!("handled-{}", t.transfer_id));
        let delivered = root.join(format!("delivered-{}", packet.job.to_ascii_lowercase()));
        if done.exists()
            || packet.kind == "data" && eq(device, &packet.target) && delivered.exists()
        {
            continue;
        }
        let authoritative = match packet.kind.as_str() {
            "probe" => {
                eq(remote, &packet.origin) && !eq(device, &packet.target) && t.total_bytes == 0
            }
            "ready" | "stored" => {
                eq(device, &packet.origin) && t.total_bytes == 0 && record.exists() && {
                    let job: Job = get(&record)?;
                    (packet.kind == "ready" && job.phase == "probe"
                        || packet.kind == "stored" && job.phase == "handoff")
                        && eq(&job.relay, &t.peer)
                        && peer_parts(&job.target)
                            .is_some_and(|(_, target)| eq(target, &packet.target))
                }
            }
            "data" => {
                (eq(device, &packet.target)
                    || eq(remote, &packet.origin) && root.join(packet.name("ready")).is_dir())
                    && !eq(device, &packet.origin)
            }
            _ => false,
        };
        if !authoritative {
            continue;
        }
        if t.status == "Invited" && !ack.exists() && can_accept_new {
            put(&ack, &t.peer)?;
            return Ok(Some(Action::Accept {
                id: t.transfer_id.clone(),
            }));
        }
        if !t.finished() {
            continue;
        }
        if ack.exists() {
            let claimed: String = get(&ack)?;
            if !eq(&claimed, &t.peer) {
                continue;
            }
        }
        let Some(envelope) = owned_packet(req, t, &packet)? else {
            continue;
        };
        match packet.kind.as_str() {
            "probe" => {
                if !children(&envelope)?.is_empty() {
                    continue;
                }
                let ready = root.join(packet.name("ready"));
                fs::create_dir_all(&ready).map_err(io)?;
                // Remove the received control packet before responding. Duplicate
                // offers have independent native IDs and cannot transfer user data.
                fs::remove_dir(&envelope).map_err(io)?;
                put(&done, &true)?;
                let _ = fs::remove_file(&ack);
                return Ok(Some(Action::Send {
                    id: id()?,
                    peer: t.peer.clone(),
                    paths: vec![ready],
                }));
            }
            "ready" => {
                if !children(&envelope)?.is_empty() {
                    continue;
                }
                let mut job: Job = get(&record)?;
                job.phase = "handoff".into();
                job.dispatched.clear();
                job.since = now();
                put(&record, &job)?;
                fs::remove_dir(&envelope).map_err(io)?;
                let _ = fs::remove_file(&ack);
            }
            "stored" => {
                if !children(&envelope)?.is_empty() {
                    continue;
                }
                let mut job: Job = get(&record)?;
                job.custody = true;
                put(&record, &job)?;
                fs::remove_dir(&envelope).map_err(io)?;
                let _ = fs::remove_file(&ack);
            }
            "data" if eq(device, &packet.target) => {
                let paths = children(&envelope)?;
                if paths.is_empty() {
                    continue;
                }
                // Deduplicate by parcel ID across retries and app restarts.
                put(&delivered, &true)?;
                let _ = fs::remove_file(ack);
                return Ok(Some(Action::Deliver {
                    id: t.transfer_id.clone(),
                    peer: t.peer.clone(),
                    paths,
                }));
            }
            "data" if !record.exists() => {
                check_tree(&envelope, 0)?;
                fs::create_dir_all(&job_dir).map_err(io)?;
                let target = req.devices.iter().find(|d| {
                    !d.history
                        && peer_parts(&d.peer)
                            .is_some_and(|(a, p)| eq(a, account) && eq(p, &packet.target))
                });
                let peer = target
                    .map(|d| d.peer.clone())
                    .unwrap_or_else(|| format!("{account}:{}", packet.target));
                put(
                    &record,
                    &Job {
                        target: peer,
                        relay: t.peer.clone(),
                        envelope,
                        phase: "forward".into(),
                        dispatched: String::new(),
                        since: now(),
                        custody: false,
                        alternatives: vec![],
                        queued_label: None,
                    },
                )?;
                put(&done, &true)?;
                let _ = fs::remove_file(&ack);
            }
            _ => {}
        }
    }
    Ok(None)
}

fn advance(req: &Snapshot, root: &Path, data: &Path) -> Result<Option<Action>> {
    for dir in fs::read_dir(root).map_err(io)? {
        let dir = dir.map_err(io)?;
        if !dir.file_name().to_str().is_some_and(uuid) {
            continue;
        }
        let record = dir.path().join("job.json");
        if !record.exists() {
            continue;
        }
        let mut job: Job = get(&record)?;
        if now() < job.since {
            continue;
        }
        let Some(packet) = job
            .envelope
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(Packet::read)
        else {
            continue;
        };
        let envelope = job.envelope.clone();
        let target = job.target.clone();
        let relay = job.relay.clone();
        let peer = if job.phase == "handoff" || job.phase == "probe" {
            &relay
        } else {
            &target
        };
        if job.phase == "probe" {
            if online(req, &target) || now().saturating_sub(job.since) >= PROBE_WINDOW {
                if !online(req, &target) {
                    if let Some(index) = job
                        .alternatives
                        .iter()
                        .position(|candidate| online(req, candidate))
                    {
                        job.relay = job.alternatives.remove(index);
                        job.dispatched.clear();
                        job.since = now();
                        put(&record, &job)?;
                        continue;
                    }
                }
                job.phase = "direct".into();
                job.dispatched.clear();
                put(&record, &job)?;
            } else if job.dispatched.is_empty() && online(req, &relay) {
                let probe = dir.path().join(packet.name("probe"));
                fs::create_dir_all(&probe).map_err(io)?;
                return send(&mut job, &record, relay, vec![probe]).map(Some);
            } else {
                continue;
            }
        }
        if !job.dispatched.is_empty() {
            if (job.phase != "handoff" || job.custody)
                && outgoing(req, &job.dispatched, peer).is_some_and(Transfer::finished)
            {
                // Only remove our staged packet, or the unique incoming packet
                // inside the receiver directory myDrive created for this job.
                let local = dir.path().join(packet.name("data"));
                let owned = envelope == local
                    || envelope.parent().and_then(Path::parent) == Some(req.inbox.as_path())
                        && envelope
                            .parent()
                            .and_then(Path::file_name)
                            .and_then(|s| s.to_str())
                            .is_some_and(uuid);
                if owned && envelope.exists() {
                    checked(&envelope)?;
                    fs::remove_dir_all(&envelope).map_err(io)?;
                }
                if job.phase != "forward" {
                    let status = if job.phase == "handoff" {
                        "Handed to relay"
                    } else {
                        "Delivered"
                    };
                    let _ =
                        crate::blip::activity::result(data, &req.own, &packet.job, status, None);
                }
                fs::remove_file(record).map_err(io)?;
                let _ = fs::remove_dir(dir.path().join(packet.name("probe")));
                let _ = fs::remove_dir(dir.path().join(packet.name("stored")));
                let _ = fs::remove_dir(root.join(packet.name("ready")));
                let _ = fs::remove_dir(dir.path());
            } else if outgoing(req, &job.dispatched, peer).is_some_and(|t| t.status == "Cancelled")
            {
                if job.phase == "direct" {
                    discard_job(root, &dir.path())?;
                    let _ = crate::blip::activity::result(
                        data,
                        &req.own,
                        &packet.job,
                        "Cancelled",
                        None,
                    );
                    continue;
                }
                job.dispatched.clear();
                job.since = now().saturating_add(30);
                put(&record, &job)?;
            }
            continue;
        }
        if job.phase == "forward" && !job.custody {
            let stored = dir.path().join(packet.name("stored"));
            fs::create_dir_all(&stored).map_err(io)?;
            job.custody = true;
            put(&record, &job)?;
            return Ok(Some(Action::Send {
                id: id()?,
                peer: relay,
                paths: vec![stored],
            }));
        }
        if job.phase == "handoff" && online(req, &relay) {
            return send(&mut job, &record, relay, vec![envelope]).map(Some);
        }
        if job.phase == "handoff" && now().saturating_sub(job.since) >= PROBE_WINDOW {
            job.phase = "probe".into();
            put(&record, &job)?;
            continue;
        }
        if job.phase == "direct" || job.phase == "forward" && online(req, &target) {
            let paths = if job.phase == "direct" {
                children(&envelope)?
            } else {
                vec![envelope]
            };
            return send(&mut job, &record, target, paths).map(Some);
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ACCOUNT: &str = "11111111-1111-4111-8111-111111111111";
    const A: &str = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa";
    const B: &str = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb";
    const C: &str = "cccccccc-cccc-4ccc-cccc-cccccccccccc";

    fn peer(device: &str) -> String {
        format!("{ACCOUNT}:{device}")
    }

    fn tick(root: &Path, who: &str, up: &[&str], transfers: Vec<Value>) -> Value {
        let devices: Vec<_> = [A, B, C]
            .into_iter()
            .map(|d| json!({"peer":peer(d), "online":up.contains(&d)}))
            .collect();
        run("tick", &json!({"self":peer(who), "inbox":root.join("inbox"), "downloads":root.join("stock-downloads"), "devices":devices, "transfers":transfers}), root).unwrap()
    }

    fn transfer(
        command: &Value,
        remote: String,
        direction: &str,
        status: &str,
        item: Option<&Path>,
    ) -> Value {
        let source = PathBuf::from(command["paths"][0].as_str().unwrap());
        json!({"transfer_id":command["id"], "peer":remote, "direction":direction, "status":status, "completed":status == "Completed",
               "has_error":false, "item_names":[source.file_name().unwrap().to_str().unwrap()],
               "received_items": item.map(|p| json!({"name": p.file_name().unwrap().to_str().unwrap(), "path":p, "is_directory":true})).into_iter().collect::<Vec<_>>()})
    }

    fn arrive(
        receiver: &Path,
        receiver_id: &str,
        sender: &str,
        command: &Value,
        up: &[&str],
    ) -> PathBuf {
        let invitation = transfer(command, peer(sender), "Incoming", "Invited", None);
        let accepted = tick(receiver, receiver_id, up, vec![invitation.clone()]);
        assert_eq!(accepted["command"]["action"], "accept");
        assert!(tick(receiver, receiver_id, up, vec![invitation])["command"].is_null());
        let source = PathBuf::from(command["paths"][0].as_str().unwrap());
        let parent = receiver.join("inbox").join(command["id"].as_str().unwrap());
        fs::create_dir_all(&parent).unwrap();
        let received = parent.join(source.file_name().unwrap());
        copy(&source, &received, 0).unwrap();
        received
    }

    #[test]
    fn cancelling_a_queued_send_keeps_the_original_and_prevents_dispatch() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        let file = root.join("project.txt");
        fs::write(&file, b"original").unwrap();
        let staged = run(
            "stage",
            &json!({
                "self": peer(A), "target": peer(C), "relay": peer(B), "paths": [file],
            }),
            root,
        )
        .unwrap();
        let id = &staged["id"];
        let pending = tick(root, A, &[A, B], vec![]);
        assert_eq!(pending["queued"][0]["id"], *id);
        assert_eq!(pending["queued"][0]["label"], "project.txt");
        assert!(run("cancel", &json!({"self": peer(B), "id": id}), root).is_err());
        assert_eq!(
            run("cancel", &json!({"self": peer(A), "id": id}), root).unwrap()["cancelled"],
            true
        );
        let next = tick(root, A, &[A, B, C], vec![]);
        assert!(next["command"].is_null());
        assert_eq!(next["waiting"], 0);
        assert_eq!(fs::read(file).unwrap(), b"original");
    }

    #[test]
    fn offline_device_delivery_survives_restarts_and_cleans_only_confirmed_relay_copy() {
        let temp = tempfile::tempdir().unwrap();
        let base = fs::canonicalize(temp.path()).unwrap();
        let origin = base.join("origin");
        let relay = base.join("relay");
        let target = base.join("target");
        let input = base.join("test.url");
        let link_two = base.join("another.url");
        let project = base.join("project");
        fs::create_dir_all(project.join("assets").join("nested")).unwrap();
        fs::write(project.join("assets/nested/file.txt"), b"nested contents").unwrap();
        fs::write(
            &link_two,
            b"[InternetShortcut]\nURL=https://other.example.test",
        )
        .unwrap();
        fs::write(&input, b"[InternetShortcut]\nURL=https://example.test").unwrap();
        stage(
            &origin,
            Stage {
                own: peer(A),
                target: peer(C),
                relay: peer(B),
                paths: vec![input.clone(), link_two.clone(), project],
                alternatives: vec![],
            },
        )
        .unwrap();

        let probe = tick(&origin, A, &[A, B], vec![])["command"].clone();
        assert_eq!(probe["peer"], peer(B));
        let p = arrive(&relay, B, A, &probe, &[A, B]);
        let ready = tick(
            &relay,
            B,
            &[A, B],
            vec![transfer(&probe, peer(A), "Incoming", "Completed", Some(&p))],
        )["command"]
            .clone();
        let r = arrive(&origin, A, B, &ready, &[A, B]);
        let handoff = tick(
            &origin,
            A,
            &[A, B],
            vec![transfer(&ready, peer(B), "Incoming", "Completed", Some(&r))],
        )["command"]
            .clone();
        assert_eq!(handoff["peer"], peer(B));
        let held = arrive(&relay, B, A, &handoff, &[A, B]);
        let stored = tick(
            &relay,
            B,
            &[A, B],
            vec![transfer(
                &handoff,
                peer(A),
                "Incoming",
                "Completed",
                Some(&held),
            )],
        )["command"]
            .clone();
        let s = arrive(&origin, A, B, &stored, &[A, B]);
        let first_hop = transfer(&handoff, peer(B), "Outgoing", "Completed", None);
        tick(
            &origin,
            A,
            &[A, B],
            vec![
                transfer(&stored, peer(B), "Incoming", "Completed", Some(&s)),
                first_hop,
            ],
        );
        assert!(input.is_file() && held.is_dir());

        // A is now offline. Each tick reloads the journal from disk.
        assert!(tick(&relay, B, &[B], vec![])["command"].is_null());
        let forward = tick(&relay, B, &[B, C], vec![])["command"].clone();
        assert_eq!(forward["peer"], peer(C));
        let incoming = arrive(&target, C, B, &forward, &[B, C]);
        let complete = transfer(&forward, peer(B), "Incoming", "Completed", Some(&incoming));
        let delivered = tick(&target, C, &[B, C], vec![complete.clone()]);
        assert_eq!(delivered["command"]["action"], "deliver");
        assert_eq!(delivered["command"]["paths"].as_array().unwrap().len(), 3);
        assert!(tick(&target, C, &[B, C], vec![complete])["command"].is_null());
        tick(
            &relay,
            B,
            &[B, C],
            vec![transfer(&forward, peer(C), "Outgoing", "Active", None)],
        );
        assert!(held.is_dir());
        tick(
            &relay,
            B,
            &[B, C],
            vec![transfer(&forward, peer(C), "Outgoing", "Completed", None)],
        );
        assert!(!held.exists());
        assert_eq!(
            fs::read(incoming.join("test.url")).unwrap(),
            fs::read(input).unwrap()
        );
        assert_eq!(
            fs::read(incoming.join("another.url")).unwrap(),
            fs::read(link_two).unwrap()
        );
        assert_eq!(
            fs::read(incoming.join("project/assets/nested/file.txt")).unwrap(),
            b"nested contents"
        );
    }

    #[test]
    fn foreign_account_and_unconfirmed_peer_cannot_receive_payload() {
        let temp = tempfile::tempdir().unwrap();
        let base = fs::canonicalize(temp.path()).unwrap();
        let input = base.join("file.txt");
        fs::write(&input, b"fixture").unwrap();
        let origin = base.join("origin");
        stage(
            &origin,
            Stage {
                own: peer(A),
                target: peer(C),
                relay: peer(B),
                paths: vec![input],
                alternatives: vec![],
            },
        )
        .unwrap();
        let probe = tick(&origin, A, &[A, B], vec![])["command"].clone();
        let remote = peer(A).replace(ACCOUNT, "22222222-2222-4222-8222-222222222222");
        let foreign = transfer(&probe, remote, "Incoming", "Invited", None);
        assert!(tick(&base.join("relay"), B, &[A, B], vec![foreign])["command"].is_null());
        // A stock Blip client could receive a probe, but only a compatible
        // relay can send the ready packet required to unlock the real payload.
        let completion = transfer(&probe, peer(B), "Outgoing", "Completed", None);
        assert!(tick(&origin, A, &[A, B], vec![completion])["command"].is_null());
    }

    #[test]
    fn multiple_native_autoaccepted_jobs_forward_independently() {
        let temp = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(temp.path()).unwrap();
        let receiver = root.join("receiver");
        let queue = storage(&receiver, &peer(B)).unwrap();
        let stock = receiver.join("stock-downloads");
        fs::create_dir_all(&stock).unwrap();
        let mut original_locations = Vec::new();
        for label in ["first.txt", "second.url"] {
            let packet = Packet {
                kind: "data".into(),
                job: id().unwrap(),
                target: C.into(),
                origin: A.into(),
            };
            fs::create_dir(queue.join(packet.name("ready"))).unwrap();
            let received = stock.join(packet.name("data"));
            fs::create_dir(&received).unwrap();
            fs::write(received.join(label), label.as_bytes()).unwrap();
            let incoming = json!({"id":id().unwrap(),"paths":[received]});
            original_locations.push(
                receiver
                    .join("inbox")
                    .join(incoming["id"].as_str().unwrap())
                    .join(packet.name("data")),
            );
            let done = transfer(&incoming, peer(A), "Incoming", "Completed", Some(&received));
            let result = tick(&receiver, B, &[A, B], vec![done]);
            assert_eq!(result["command"]["peer"], peer(A)); // custody acknowledgement
            assert!(!received.exists());
        }
        assert_eq!(tick(&receiver, B, &[B], vec![])["waiting"], 2);
        assert!(original_locations.iter().all(|path| path.is_dir()));
        let first = tick(&receiver, B, &[B, C], vec![])["command"].clone();
        let second = tick(&receiver, B, &[B, C], vec![])["command"].clone();
        assert_eq!(first["peer"], peer(C));
        assert_eq!(second["peer"], peer(C));
        assert_ne!(first["paths"], second["paths"]);
        let complete_first = transfer(&first, peer(C), "Outgoing", "Completed", None);
        assert_eq!(
            tick(&receiver, B, &[B, C], vec![complete_first])["waiting"],
            1
        );
        assert_eq!(original_locations.iter().filter(|p| p.exists()).count(), 1);
        let complete_second = transfer(&second, peer(C), "Outgoing", "Completed", None);
        assert_eq!(
            tick(&receiver, B, &[B, C], vec![complete_second])["waiting"],
            0
        );
        assert!(original_locations.iter().all(|path| !path.exists()));
    }
}

pub fn run(action: &str, payload: &Value, data: &Path) -> Result<Value> {
    match action {
        "stage" => stage(
            data,
            serde_json::from_value(payload.clone()).map_err(|_| "Invalid relay selection")?,
        ),
        "cancel" => {
            let owner = payload["self"]
                .as_str()
                .ok_or("Relay requires a signed-in device.")?;
            let id = payload["id"]
                .as_str()
                .filter(|id| uuid(id))
                .ok_or("Invalid relay transfer.")?;
            let root = storage(data, owner)?;
            let _lock = job_lock(&root)?;
            let directory = root.join(id);
            let job: Job = get(&directory.join("job.json"))
                .map_err(|_| "This relay transfer is no longer queued.")?;
            if job.queued_label.is_none() {
                return Err(
                    "This transfer has already been sent to a device. Refresh to check its status."
                        .into(),
                );
            }
            discard_job(&root, &directory)?;
            let _ = crate::blip::activity::result(data, owner, id, "Cancelled", None);
            Ok(json!({"cancelled": true}))
        }
        "tick" => {
            let req: Snapshot =
                serde_json::from_value(payload.clone()).map_err(|_| "Invalid relay snapshot")?;
            let (account, device) =
                peer_parts(&req.own).ok_or("Relay requires a signed-in device.")?;
            if req.transfers.len() > 20_000 {
                return Err("Relay transfer history exceeds its limit.".into());
            }
            let root = storage(data, &req.own)?;
            let _lock = job_lock(&root)?;
            let pending = fs::read_dir(&root)
                .map_err(io)?
                .filter_map(std::result::Result::ok)
                .filter(|entry| {
                    entry
                        .file_name()
                        .to_str()
                        .is_some_and(|name| name.starts_with("seen-") || uuid(name))
                })
                .take(MAX_INBOX + 1)
                .count();
            let action = receive(&req, &root, account, device, pending <= MAX_INBOX)?;
            let action = if action.is_some() {
                action
            } else {
                advance(&req, &root, data)?
            };
            let mut waiting = 0;
            let mut queued = Vec::new();
            for dir in fs::read_dir(&root).map_err(io)?.flatten() {
                let file = dir.file_name();
                let Some(id) = file.to_str().filter(|id| uuid(id)) else {
                    continue;
                };
                let record = dir.path().join("job.json");
                if !record.is_file() {
                    continue;
                }
                waiting += 1;
                if let Ok(job) = get::<Job>(&record) {
                    if let Some(label) = job.queued_label {
                        queued.push(json!({"id": id, "peer": job.target, "label": label}));
                    }
                }
            }
            Ok(json!({"command": action, "waiting": waiting, "queued": queued}))
        }
        _ => Err("Unknown relay action.".into()),
    }
}
