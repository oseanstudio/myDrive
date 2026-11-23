use super::Api;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Deserialize, Serialize)]
struct Pause {
    device: String,
    folder: String,
    path: String,
    until: i64,
}

struct Store {
    path: PathBuf,
    _lock: fs::File,
    pauses: Vec<Pause>,
}

impl Store {
    fn open(data: &Path) -> Result<Self, String> {
        if !data.is_absolute() {
            return Err("An application data directory is required for scheduled pauses.".into());
        }
        fs::create_dir_all(data).map_err(|e| e.to_string())?;
        let path = data.join("sync-pauses.json");
        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(data.join("sync-pauses.lock"))
            .map_err(|e| e.to_string())?;
        lock.lock().map_err(|e| e.to_string())?;
        let pauses = match fs::read(&path) {
            Ok(content) => serde_json::from_slice(&content)
                .map_err(|_| "Saved sync pauses could not be read.")?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(error.to_string()),
        };
        Ok(Self {
            path,
            _lock: lock,
            pauses,
        })
    }

    fn save(&self) -> Result<(), String> {
        let directory = self.path.parent().ok_or("Invalid sync pause storage.")?;
        let mut file = tempfile::NamedTempFile::new_in(directory).map_err(|e| e.to_string())?;
        serde_json::to_writer(&mut file, &self.pauses).map_err(|e| e.to_string())?;
        file.as_file().sync_all().map_err(|e| e.to_string())?;
        file.persist(&self.path).map_err(|e| e.to_string())?;
        Ok(())
    }
}

fn local_device(status: &Value) -> Result<&str, String> {
    status["myID"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| "Syncthing did not identify this device.".into())
}

fn patch(api: &Api, folder: &str, paused: bool) -> Result<(), String> {
    api.call(
        "PATCH",
        &["rest", "config", "folders", folder],
        &[],
        Some(&json!({"paused": paused})),
    )?;
    Ok(())
}

pub(super) fn change(
    api: &Api,
    data: &Path,
    id: &str,
    action: &str,
    input: &Value,
) -> Result<Value, String> {
    let until = if action == "pause_until" {
        let now = Utc::now().timestamp();
        Some(
            input["until"]
                .as_i64()
                .filter(|end| (now + 1..=now + 31 * 86400).contains(end))
                .ok_or("Choose a future time within the next 31 days.")?,
        )
    } else {
        None
    };
    let paused = until.is_some() || input["paused"].as_bool().ok_or("Pause state is missing.")?;
    if until.is_none() && !data.is_absolute() {
        api.folder(id)?;
        patch(api, id, paused)?;
        return Ok(json!({"paused": paused}));
    }

    let mut store = Store::open(data)?;
    if until.is_none() && store.pauses.is_empty() {
        api.folder(id)?;
        patch(api, id, paused)?;
        return Ok(json!({"paused": paused}));
    }
    let status = api.get(&["rest", "system", "status"], &[])?;
    let device = local_device(&status)?;
    let folder = api.folder(id)?;
    let path = folder["path"]
        .as_str()
        .filter(|path| !path.is_empty())
        .ok_or("The folder path is missing.")?;
    let owned = store
        .pauses
        .iter()
        .any(|entry| entry.device == device && entry.folder == id && entry.path == path);
    let length = store.pauses.len();
    if let Some(until) = until {
        if folder["paused"] == true && !owned {
            return Err("Resume the manually paused folder before scheduling a pause.".into());
        }
        if input["expected_path"].as_str() != Some(path) {
            return Err("The folder location changed. Refresh before scheduling a pause.".into());
        }
        store
            .pauses
            .retain(|entry| entry.device != device || entry.folder != id);
        store.pauses.push(Pause {
            device: device.into(),
            folder: id.into(),
            path: path.into(),
            until,
        });
        // Persist the deadline before pausing, so an interrupted request can still be recovered.
        store.save()?;
        patch(api, id, true)?;
    } else {
        store
            .pauses
            .retain(|entry| entry.device != device || entry.folder != id);
        if length != store.pauses.len() {
            store.save()?;
        }
        patch(api, id, paused)?;
    }
    Ok(json!({"paused": paused, "paused_until":until}))
}

pub(super) fn reconcile(
    api: &Api,
    data: &Path,
    status: &Value,
    folders: &mut Value,
) -> Result<(), String> {
    if !data.is_absolute() || !data.join("sync-pauses.json").exists() {
        return Ok(());
    }
    let device = local_device(status)?;
    let mut store = Store::open(data)?;
    let now = Utc::now().timestamp();
    let rows = folders
        .as_array_mut()
        .ok_or("Unexpected Syncthing folder list.")?;
    let mut remaining = Vec::new();
    let mut failure = None;
    for entry in store.pauses.iter() {
        if entry.device != device {
            remaining.push(entry.clone());
            continue;
        }
        let Some(row) = rows
            .iter_mut()
            .find(|row| row["id"] == entry.folder && row["path"] == entry.path)
        else {
            continue;
        };
        if entry.until > now && row["paused"] == true {
            row["paused_until"] = json!(entry.until);
            remaining.push(entry.clone());
            continue;
        }
        // The snapshot can predate a concurrent pause. Confirm the current configuration before resuming.
        let result = api.folder(&entry.folder).and_then(|current| {
            if current["path"] != entry.path || current["paused"] != true {
                return Ok(false);
            }
            if entry.until > now {
                row["paused"] = json!(true);
                return Ok(true);
            }
            patch(api, &entry.folder, false)?;
            row["paused"] = json!(false);
            Ok(false)
        });
        match result {
            Ok(false) => {}
            Ok(true) => {
                row["paused_until"] = json!(entry.until);
                remaining.push(entry.clone());
            }
            Err(error) => {
                row["paused_until"] = json!(entry.until);
                remaining.push(entry.clone());
                failure.get_or_insert(error);
            }
        }
    }
    if remaining.len() != store.pauses.len() {
        store.pauses = remaining;
        store.save()?;
    }
    failure.map_or(Ok(()), Err)
}
