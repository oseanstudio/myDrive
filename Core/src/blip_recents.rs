use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs, io::Write, path::Path};

const MAX_RECIPIENTS: usize = 24;

#[derive(Deserialize, Serialize)]
struct Recipient {
    peer: String,
    label: String,
}

fn is_peer(peer: &str) -> bool {
    peer.split_once(':').is_some_and(|(user, device)| {
        crate::automation::uuid(user) && crate::automation::uuid(device)
    })
}

fn recipient(value: &Value) -> Option<Recipient> {
    let peer = value["peer"].as_str()?.to_ascii_lowercase();
    if !is_peer(&peer) {
        return None;
    }
    let label: String = value["label"]
        .as_str()?
        .trim()
        .chars()
        .filter(|c| !c.is_control())
        .take(240)
        .collect();
    if label.is_empty() {
        return None;
    }
    Some(Recipient { peer, label })
}

pub fn run(action: &str, data: &Path, payload: &Value) -> Result<Value, String> {
    let owner = payload["owner"]
        .as_str()
        .filter(|p| is_peer(p))
        .ok_or("Connect Blip to see recent recipients.")?
        .to_ascii_lowercase();
    let account = owner.split_once(':').unwrap().0;
    if !data.is_absolute() {
        return Err("Could not locate myDrive's data folder.".into());
    }
    let directory = data.join("Blip");
    fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(directory.join("recent-recipients.lock"))
        .map_err(|e| e.to_string())?;
    lock.lock().map_err(|e| e.to_string())?;
    let path = directory.join("recent-recipients.json");
    let mut accounts: BTreeMap<String, Vec<Recipient>> = match fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|_| "The saved recent recipients could not be read.")?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
        Err(e) => return Err(e.to_string()),
    };
    let first_use = !accounts.contains_key(account);
    let history = accounts.entry(account.to_owned()).or_default();
    if first_use {
        for candidate in payload["seed"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(recipient)
        {
            if candidate.peer != owner && !history.iter().any(|r| r.peer == candidate.peer) {
                history.push(candidate);
            }
            if history.len() == MAX_RECIPIENTS {
                break;
            }
        }
    }
    match action {
        "list" => {}
        "remember" => {
            let saved = recipient(&payload["recipient"])
                .filter(|p| p.peer != owner)
                .ok_or("Choose a valid Blip recipient.")?;
            history.retain(|r| r.peer != saved.peer);
            history.insert(0, saved);
            history.truncate(MAX_RECIPIENTS);
        }
        "remove" => {
            let target = payload["target"]
                .as_str()
                .unwrap_or_default()
                .to_ascii_lowercase();
            if is_peer(&target) {
                history.retain(|r| r.peer != target);
            } else if crate::automation::uuid(&target) && target != account {
                history.retain(|r| r.peer.split_once(':').map(|(user, _)| user) != Some(&target));
            } else {
                return Err("Choose a valid recent recipient.".into());
            }
        }
        _ => return Err("Unknown Blip recipient action.".into()),
    }
    let result = json!(history
        .iter()
        .filter(|r| r.peer != owner)
        .collect::<Vec<_>>());
    if first_use || action != "list" {
        let mut staged = tempfile::NamedTempFile::new_in(&directory).map_err(|e| e.to_string())?;
        serde_json::to_writer(&mut staged, &accounts).map_err(|e| e.to_string())?;
        staged.flush().map_err(|e| e.to_string())?;
        staged.persist(&path).map_err(|e| e.to_string())?;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removed_recents_stay_removed_and_other_accounts_stay_separate() {
        let directory = tempfile::tempdir().unwrap();
        let account = "6c434111-4674-453a-a194-15d3cba26547";
        let another = "19931140-4a2e-48c5-a362-190fb2bee500";
        let device = "eced1da8-2269-44ae-9a56-a3681ab924a2";
        let owner = format!("{account}:{device}");
        let recipient = format!("{another}:{device}");
        let peer2 = format!("{another}:8c99008b-5351-4baa-92d1-1adef47e2fd5");
        let seed = json!([{"peer":recipient,"label":"Fixture desktop"},{"peer":peer2,"label":"Fixture laptop"}]);
        let operation = |action, value| run(action, directory.path(), &value).unwrap();
        assert_eq!(operation("list", json!({"owner":owner,"seed":seed})), seed);
        assert_eq!(
            operation("remove", json!({"owner":owner,"target":recipient})),
            json!([seed[1]])
        );
        assert_eq!(
            operation("list", json!({"owner":owner,"seed":seed})),
            json!([seed[1]])
        );
        assert_eq!(operation("list", json!({"owner":recipient})), json!([]));
        assert_eq!(
            operation("remember", json!({"owner":owner,"recipient":seed[0]})),
            seed
        );
        assert_eq!(
            operation("remove", json!({"owner":owner,"target":another})),
            json!([])
        );
        assert_eq!(
            operation("list", json!({"owner":owner,"seed":seed})),
            json!([])
        );
    }
}
