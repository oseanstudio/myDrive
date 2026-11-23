use super::{random_id, state, uuid, Arguments, Result, Session, Snapshot};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    time::SystemTime,
};

#[derive(Deserialize, Serialize)]
struct FileStamp {
    path: PathBuf,
    size: u64,
    modified: SystemTime,
}

impl FileStamp {
    fn read(path: &Path) -> Option<Self> {
        let metadata = fs::symlink_metadata(path).ok()?;
        metadata.is_file().then_some(())?;
        Some(Self {
            path: path.to_owned(),
            size: metadata.len(),
            modified: metadata.modified().ok()?,
        })
    }

    fn unchanged(&self) -> bool {
        fs::canonicalize(&self.path).is_ok_and(|path| path == self.path)
            && Self::read(&self.path)
                .is_some_and(|file| file.size == self.size && file.modified == self.modified)
    }
}

#[derive(Deserialize, Serialize)]
struct Entry {
    owner: String,
    peer: String,
    id: String,
    kind: String,
    name: String,
    at: i64,
    status: String,
    error: String,
    retried: bool,
    relay: bool,
    files: Vec<FileStamp>,
}

struct Journal {
    file: PathBuf,
    _lock: fs::File,
    entries: Vec<Entry>,
}

impl Journal {
    fn open(data: &Path) -> Result<Self> {
        if !data.is_absolute() {
            return Err("activity_unavailable");
        }
        let directory = data.join("Blip");
        fs::create_dir_all(&directory).map_err(|_| "activity_unavailable")?;
        let file = directory.join("send-activity.json");
        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(directory.join("send-activity.lock"))
            .map_err(|_| "activity_unavailable")?;
        lock.lock().map_err(|_| "activity_unavailable")?;
        let entries = match fs::read(&file) {
            Ok(content) => serde_json::from_slice(&content).map_err(|_| "activity_unavailable")?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(_) => return Err("activity_unavailable"),
        };
        Ok(Self {
            file,
            _lock: lock,
            entries,
        })
    }

    fn save(&self) -> Result<()> {
        let directory = self.file.parent().ok_or("activity_unavailable")?;
        let mut staged =
            tempfile::NamedTempFile::new_in(directory).map_err(|_| "activity_unavailable")?;
        serde_json::to_writer(&mut staged, &self.entries).map_err(|_| "activity_unavailable")?;
        staged
            .as_file()
            .sync_all()
            .map_err(|_| "activity_unavailable")?;
        staged
            .persist(&self.file)
            .map_err(|_| "activity_unavailable")?;
        Ok(())
    }
}

pub(super) fn owner(snapshot: &Snapshot) -> String {
    let status = &snapshot.status;
    format!(
        "{}:{}",
        status["user_id"].as_str().unwrap_or_default(),
        status["device_id"].as_str().unwrap_or_default()
    )
}

fn journal() -> Result<Journal> {
    let data = crate::automation::user_data().map_err(|_| "activity_unavailable")?;
    Journal::open(&data)
}

pub(crate) fn record(
    data: &Path,
    owner: &str,
    peer: &str,
    id: &str,
    paths: &[PathBuf],
    relay: bool,
) -> Result<()> {
    if paths.is_empty() {
        return Err("invalid_file");
    }
    let mut journal = Journal::open(data)?;
    if journal
        .entries
        .iter()
        .any(|entry| entry.owner.eq_ignore_ascii_case(owner) && entry.id.eq_ignore_ascii_case(id))
    {
        return Err("transfer_id_exists");
    }
    let name = |path: &Path| {
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("Item")
            .chars()
            .filter(|c| !c.is_control())
            .take(160)
            .collect::<String>()
    };
    let kind = if paths.len() == 1
        && paths[0]
            .file_name()
            .is_some_and(|name| name == "Clipboard text.txt")
        && data
            .join("Blip/outbox")
            .canonicalize()
            .is_ok_and(|outbox| paths[0].starts_with(outbox))
    {
        "Text"
    } else if paths.iter().all(|path| {
        path.is_file()
            && path
                .extension()
                .and_then(|x| x.to_str())
                .is_some_and(|ext| {
                    ext.eq_ignore_ascii_case("url") || ext.eq_ignore_ascii_case("webloc")
                })
    }) {
        "Link"
    } else if paths.iter().any(|path| path.is_dir()) {
        "Folder"
    } else {
        "File"
    };
    let files = if relay {
        Vec::new()
    } else {
        paths
            .iter()
            .map(|path| FileStamp::read(path))
            .collect::<Option<Vec<_>>>()
            .unwrap_or_default()
    };
    journal.entries.insert(
        0,
        Entry {
            owner: owner.into(),
            peer: peer.into(),
            id: id.into(),
            kind: kind.into(),
            name: if paths.len() == 1 {
                name(&paths[0])
            } else {
                format!("{} items", paths.len())
            },
            at: chrono::Utc::now().timestamp(),
            status: if relay {
                "Queued for relay"
            } else {
                "Waiting for Blip"
            }
            .into(),
            error: String::new(),
            retried: false,
            relay,
            files,
        },
    );
    journal.entries.truncate(100);
    journal.save()
}

pub(crate) fn result(
    data: &Path,
    owner: &str,
    id: &str,
    status: &str,
    error: Option<&str>,
) -> Result<()> {
    let mut journal = Journal::open(data)?;
    if let Some(entry) = journal
        .entries
        .iter_mut()
        .find(|entry| entry.id == id && entry.owner.eq_ignore_ascii_case(owner))
    {
        entry.status = status.into();
        entry.error = error.unwrap_or_default().into();
        journal.save()?;
    }
    Ok(())
}

fn native<'a>(entry: &Entry, snapshot: &'a Snapshot) -> Option<&'a Value> {
    snapshot.transfer(&entry.id).filter(|row| {
        row["direction"] == "Outgoing"
            && row["peer"]
                .as_str()
                .is_some_and(|peer| peer.eq_ignore_ascii_case(&entry.peer))
    })
}

fn retryable(entry: &Entry, snapshot: &Snapshot) -> bool {
    !entry.retried
        && !entry.relay
        && !entry.files.is_empty()
        && native(entry, snapshot)
            .is_some_and(|row| row["status"] == "Cancelled" && row["completed"] != true)
        && snapshot.devices.iter().any(|device| {
            device["history"] == false
                && device["peer"]
                    .as_str()
                    .is_some_and(|peer| peer.eq_ignore_ascii_case(&entry.peer))
        })
        && entry.files.iter().all(FileStamp::unchanged)
}

pub(super) fn list(snapshot: &Snapshot) -> Result<Value> {
    let owner = owner(snapshot);
    let mut journal = journal()?;
    let mut changed = false;
    let mut rows = Vec::new();
    for entry in journal
        .entries
        .iter_mut()
        .filter(|entry| entry.owner.eq_ignore_ascii_case(&owner))
        .take(40)
    {
        if !entry.relay {
            if let Some(wire) = native(entry, snapshot) {
                let status = match wire["status"].as_str() {
                    Some("Completed")
                        if wire["completed"] == true && wire["has_error"] == false =>
                    {
                        "Delivered"
                    }
                    Some("Cancelled") => "Cancelled",
                    _ if wire["has_error"] == true => "Transfer error",
                    Some("Paused" | "ResumeRequested") => "Paused",
                    Some("Active" | "Pending") => "Sending",
                    _ => "Waiting for recipient",
                };
                let reason = if wire["has_error"] == true {
                    "Blip reported an error for this transfer."
                } else {
                    ""
                };
                if entry.status != status || entry.error != reason {
                    entry.status = status.into();
                    entry.error = reason.into();
                    changed = true;
                }
            }
        }
        let name = snapshot
            .devices
            .iter()
            .find(|device| {
                device["peer"]
                    .as_str()
                    .is_some_and(|p| p.eq_ignore_ascii_case(&entry.peer))
            })
            .and_then(|device| device["name"].as_str())
            .unwrap_or("Device");
        rows.push(json!({
            "id": entry.id, "kind": entry.kind, "name": entry.name, "recipient": name, "at": entry.at,
            "status": if entry.retried { "Retried" } else { &entry.status },
            "detail": entry.error, "can_retry": retryable(entry, snapshot)
        }));
    }
    if changed {
        journal.save()?;
    }
    Ok(json!({"ok": true, "entries": rows}))
}

pub(super) fn retry(session: &Session, args: &Arguments, snapshot: Snapshot) -> Result<Value> {
    let id = args
        .id
        .as_deref()
        .filter(|id| uuid(id) && args.execute)
        .ok_or("invalid_transfer_id")?;
    let owner = owner(&snapshot);
    if state::peer_id(&owner).is_none() {
        return Err("sign_in_required");
    }
    let mut journal = journal()?;
    let entry = journal
        .entries
        .iter_mut()
        .find(|entry| entry.id == id && entry.owner.eq_ignore_ascii_case(&owner))
        .filter(|entry| retryable(entry, &snapshot))
        .ok_or("activity_retry_unavailable")?;
    let retry = Arguments {
        command: "send".into(),
        profile: args.profile.clone(),
        desktop: args.desktop,
        name: None,
        peer: Some(entry.peer.clone()),
        id: Some(random_id()?),
        files: entry.files.iter().map(|file| file.path.clone()).collect(),
        execute: true,
    };
    entry.retried = true;
    journal.save()?;
    drop(journal);
    session.send(&retry, snapshot)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_requires_a_cancelled_transfer_to_the_same_device_and_unchanged_files() {
        let data = tempfile::tempdir().unwrap();
        let file = data.path().join("fixture.txt");
        fs::write(&file, "fixture").unwrap();
        let file = file.canonicalize().unwrap();
        record(
            data.path(),
            "same:sender",
            "same:receiver",
            "transfer",
            &[file.clone()],
            false,
        )
        .unwrap();
        let journal = Journal::open(data.path()).unwrap();
        let entry = &journal.entries[0];
        let mut snapshot = Snapshot {
            status: json!({"user_id":"same","device_id":"sender"}),
            devices: vec![json!({"peer":"same:receiver","history":false})],
            transfers: vec![
                json!({"transfer_id":"transfer","direction":"Outgoing","peer":"same:receiver","status":"Active","completed":false}),
            ],
            app_id_missing: false,
            registration_failed: false,
        };
        assert!(!retryable(entry, &snapshot));
        snapshot.transfers[0]["status"] = json!("Cancelled");
        snapshot.transfers[0]["peer"] = json!("same:another-device");
        assert!(!retryable(entry, &snapshot));
        snapshot.transfers[0]["peer"] = json!("same:receiver");
        assert!(retryable(entry, &snapshot));
        fs::write(file, "a changed file").unwrap();
        assert!(!retryable(entry, &snapshot));
    }
}
