use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs, io,
    path::{Path, PathBuf},
};

const FILE: &str = "blip-download-settings.json";

#[derive(Default, Deserialize, Serialize)]
struct Settings {
    path: Option<PathBuf>,
    #[serde(default)]
    previous: Vec<PathBuf>,
}

fn read(root: &Path) -> Result<Settings, String> {
    match fs::read(root.join(FILE)) {
        Ok(data) => serde_json::from_slice(&data)
            .map_err(|_| "Blip's download folder setting could not be read.".into()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Settings::default()),
        Err(_) => Err("Blip's download folder setting could not be read.".into()),
    }
}

fn default_path(root: &Path) -> PathBuf {
    root.join("Blip").join("downloads")
}

pub(super) fn inbox(root: &Path) -> Result<PathBuf, &'static str> {
    read(root)
        .map(|settings| settings.path.unwrap_or_else(|| default_path(root)))
        .map_err(|_| "receive_downloads_unavailable")
}

pub(crate) fn run(action: &str, root: &Path, payload: &Value) -> Result<Value, String> {
    if !root.is_absolute() {
        return Err("Choose a local myDrive profile.".into());
    }
    let mut settings = read(root)?;
    let default = default_path(root);
    if action == "set" {
        let next = if payload["path"].is_null() {
            None
        } else {
            let path = Path::new(
                payload["path"]
                    .as_str()
                    .ok_or("Choose a download folder.")?,
            );
            if !path.is_absolute()
                || path
                    .to_str()
                    .is_none_or(|path| path.chars().any(char::is_control))
            {
                return Err("Choose an absolute local folder for Blip downloads.".into());
            }
            let resolved = path
                .canonicalize()
                .map_err(|_| "The selected download folder is unavailable.")?;
            if !resolved.is_dir() || tempfile::NamedTempFile::new_in(&resolved).is_err() {
                return Err("Choose a writable folder for Blip downloads.".into());
            }
            let canonical = PathBuf::from(crate::syncthing::friendly_path(&resolved));
            #[cfg(windows)]
            if canonical.as_os_str().to_string_lossy().starts_with(r"\\") {
                return Err("Choose a local drive for Blip downloads.".into());
            }
            super::check_plain_directory(&canonical)
                .map_err(|_| "Choose a writable download folder owned by your account.")?;
            (canonical != default).then_some(canonical)
        };
        if next != settings.path {
            let previous = settings.path.take().unwrap_or_else(|| default.clone());
            let next_folder = next.as_ref().unwrap_or(&default);
            settings
                .previous
                .retain(|path| path != &previous && path != next_folder);
            settings.previous.push(previous);
            if settings.previous.len() > 12 {
                settings.previous.remove(0);
            }
            settings.path = next;
            fs::create_dir_all(root).map_err(|error| error.to_string())?;
            let mut file =
                tempfile::NamedTempFile::new_in(root).map_err(|error| error.to_string())?;
            serde_json::to_writer(&mut file, &settings).map_err(|error| error.to_string())?;
            file.persist(root.join(FILE))
                .map_err(|error| error.to_string())?;
        }
    } else if action != "get" {
        return Err("Unknown download folder action.".into());
    }
    Ok(json!({ "path": settings.path.as_ref().unwrap_or(&default),
        "custom": settings.path.is_some(), "previous_inboxes": settings.previous }))
}

#[cfg(test)]
#[test]
fn chooses_a_writable_folder_and_remembers_old_destinations() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("myDrive");
    let selected = temp.path().join("Other Downloads");
    fs::create_dir(&selected).unwrap();
    let saved = run("set", &root, &json!({"path": selected})).unwrap();
    assert_eq!(saved["custom"], true);
    assert_eq!(
        inbox(&root).unwrap(),
        PathBuf::from(saved["path"].as_str().unwrap())
    );
    assert_eq!(saved["previous_inboxes"], json!([default_path(&root)]));
    let reset = run("set", &root, &json!({"path": null})).unwrap();
    assert_eq!(reset["custom"], false);
    assert_eq!(reset["previous_inboxes"], json!([saved["path"]]));
}
