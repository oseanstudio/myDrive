use super::rpc::{self, Proto, Result};
use crate::automation::uuid;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::{Component, Path, PathBuf};
#[cfg(windows)]
use std::{ffi::OsString, os::windows::ffi::OsStringExt, path::Prefix, ptr};
#[cfg(windows)]
use windows_sys::core::GUID;
#[cfg(windows)]
use windows_sys::Win32::System::Com::CoTaskMemFree;
#[cfg(windows)]
use windows_sys::Win32::UI::Shell::{
    FOLDERID_Documents, FOLDERID_Downloads, FOLDERID_LocalAppData, SHGetKnownFolderPath,
};

#[cfg(windows)]
pub(super) fn local() -> Result<PathBuf> {
    known_folder(&FOLDERID_LocalAppData).ok_or("profile_unavailable")
}

#[cfg(windows)]
fn known_folder(id: &GUID) -> Option<PathBuf> {
    let mut result = ptr::null_mut();
    unsafe {
        let status = SHGetKnownFolderPath(id, 0, ptr::null_mut(), &mut result);
        let folder = if status >= 0 && !result.is_null() {
            let length = (0..).find(|offset| *result.add(*offset) == 0)?;
            Some(PathBuf::from(OsString::from_wide(
                std::slice::from_raw_parts(result, length),
            )))
        } else {
            None
        };
        CoTaskMemFree(result.cast());
        folder
    }
}

#[cfg(target_os = "linux")]
pub(super) fn local() -> Result<PathBuf> {
    crate::automation::user_data()
        .ok()
        .and_then(|path| path.parent().map(Path::to_owned))
        .ok_or("profile_unavailable")
}

#[cfg(target_os = "linux")]
fn home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
}

#[cfg(target_os = "linux")]
pub(super) fn xdg_path(variable: &str, fallback: &str) -> PathBuf {
    std::env::var_os(variable)
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| home().map(|path| path.join(fallback)))
        .unwrap_or_default()
}

#[cfg(target_os = "linux")]
pub(super) fn runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| PathBuf::from(format!("/tmp/mydrive-{}", unsafe { libc::geteuid() })))
        .join("mydrive-blip")
}

#[cfg(target_os = "linux")]
fn user_directory(key: &str, fallback: &str) -> Option<PathBuf> {
    let home = home()?;
    let configured =
        std::fs::read_to_string(xdg_path("XDG_CONFIG_HOME", ".config").join("user-dirs.dirs"))
            .ok()
            .and_then(|settings| {
                settings.lines().find_map(|line| {
                    let (name, value) = line.split_once('=')?;
                    let value = value.trim();
                    if name.trim() != key {
                        return None;
                    }
                    let value = value.strip_prefix('"')?.strip_suffix('"')?;
                    if let Some(relative) = value.strip_prefix("$HOME/") {
                        return join_relative(&home, relative);
                    }
                    let path = PathBuf::from(value);
                    path.is_absolute().then_some(path)
                })
            });
    configured.or_else(|| Some(home.join(fallback)))
}

pub(super) fn peer_id(value: &str) -> Option<(&str, &str)> {
    value
        .split_once(':')
        .filter(|(user, device)| uuid(user) && uuid(device))
}

pub(super) fn email(value: &str) -> bool {
    value.len() <= 254
        && !value.chars().any(|c| c.is_whitespace() || c.is_control())
        && value.split_once('@').is_some_and(|(local, domain)| {
            !local.is_empty()
                && !domain.contains('@')
                && domain
                    .split_once('.')
                    .is_some_and(|(host, suffix)| !host.is_empty() && !suffix.is_empty())
        })
}

pub(super) fn safe_text(value: &str, limit: usize) -> bool {
    !value.trim().is_empty()
        && value.chars().count() <= limit
        && !value.chars().any(char::is_control)
}

pub(super) fn registered_device_name(value: &str) -> bool {
    safe_text(value, 160)
        && ![
            "myDrive on Mac",
            "myDrive on macOS",
            "myDrive on Windows",
            "myDrive on Linux",
        ]
        .iter()
        .any(|placeholder| value.eq_ignore_ascii_case(placeholder))
}

pub(super) struct Snapshot {
    pub status: Value,
    pub devices: Vec<Value>,
    pub transfers: Vec<Value>,
    pub app_id_missing: bool,
    pub registration_failed: bool,
}

pub(super) fn search_result(
    payload: &[u8],
    id: &str,
    query: &str,
) -> Result<Option<(u64, Vec<(String, String)>)>> {
    let envelope = Proto::parse(payload)?;
    let state = envelope.message(2)?;
    for entry in state.messages(800) {
        let entry = entry?;
        if entry.text(1) != id {
            continue;
        }
        let result = entry.message(2)?;
        if result.text(1) != query {
            return Ok(None);
        }
        let mut peers = Vec::new();
        for entry in result.messages(3).chain(result.messages(4)) {
            let peer = entry?;
            let user = peer.text(1);
            let device = peer.text(2);
            if uuid(user) && (device.is_empty() || uuid(device)) {
                peers.push((user.to_lowercase(), device.to_lowercase()));
            }
        }
        return Ok(Some((result.number(2), peers)));
    }
    Ok(None)
}

pub(super) fn matches_result(peer: &str, results: &[(String, String)]) -> bool {
    peer_id(peer).is_some_and(|(user, device)| {
        results.iter().any(|(u, d)| {
            u.eq_ignore_ascii_case(user) && (d.is_empty() || d.eq_ignore_ascii_case(device))
        })
    })
}

#[cfg(test)]
#[test]
fn lookup_uses_only_the_current_query_and_matching_people_or_devices() {
    use super::rpc::{field, number, string};
    let person = "6c434111-4674-453a-a194-15d3cba26547";
    let other = "19931140-4a2e-48c5-a362-190fb2bee500";
    let device = "eced1da8-2269-44ae-9a56-a3681ab924a2";
    let body = [
        string(1, "fixture"),
        number(2, 3),
        field(3, &string(1, person)),
        field(4, &[string(1, other), string(2, device)].concat()),
    ]
    .concat();
    let state = field(800, &[string(1, "id"), field(2, &body)].concat());
    let response = field(2, &state);
    assert!(search_result(&response, "id", "previous")
        .unwrap()
        .is_none());
    assert!(search_result(&response, "other", "fixture")
        .unwrap()
        .is_none());
    let (status, matches) = search_result(&response, "id", "fixture").unwrap().unwrap();
    assert_eq!(status, 3);
    assert!(matches_result(&format!("{person}:{device}"), &matches));
    assert!(matches_result(&format!("{other}:{device}"), &matches));
    assert!(!matches_result(&format!("{other}:{other}"), &matches));
}

impl Snapshot {
    pub(super) fn read(socket: &Path, desktop: bool, inbox: &Path) -> Result<Self> {
        Self::decode(
            &rpc::call(socket, "/rpc.Service/GetState", &[])?,
            desktop,
            inbox,
        )
    }

    pub(super) fn decode(payload: &[u8], desktop: bool, inbox: &Path) -> Result<Self> {
        let envelope = Proto::parse(payload)?;
        let state = Proto::parse(envelope.bytes(2).ok_or("invalid_native_response")?)?;
        let auth = state.message(201)?;
        let authenticated = auth.bytes(201).is_some_and(|token| !token.is_empty());
        let (user, device) = (auth.text(202), auth.text(204));
        if authenticated && (!uuid(user) || !uuid(device)) {
            return Err("invalid_native_response");
        }
        let agent = state.message(50)?;
        let config = state.message(100)?;
        let registration = state.message(200)?;
        let auto_accept_disabled = config.number(2) != 0;
        let receive_path_configured = Path::new(config.text(4)) == inbox;
        let registration_name = match registration.number(1) {
            1 => "SENDING_CODE",
            2 => "CODE_SENT",
            3 => "REGISTERING",
            _ => "NOT_STARTED",
        };
        #[cfg(windows)]
        let paths = LocalPaths {
            downloads: known_folder(&FOLDERID_Downloads),
            documents: known_folder(&FOLDERID_Documents),
        };
        #[cfg(target_os = "linux")]
        let paths = LocalPaths {
            downloads: user_directory("XDG_DOWNLOAD_DIR", "Downloads"),
            documents: user_directory("XDG_DOCUMENTS_DIR", "Documents"),
        };
        #[cfg(target_os = "macos")]
        let paths = LocalPaths {
            downloads: super::mac::home().map(|home| home.join("Downloads")),
            documents: super::mac::home().map(|home| home.join("Documents")),
        };
        let mut devices = BTreeMap::new();
        let mut own_device_name = None;
        let mut names = HashMap::new();
        for entry in state.message(500)?.messages(1) {
            let person = entry?.message(2)?;
            let person_id = person.text(8);
            if !uuid(person_id) {
                continue;
            }
            let contact = person.text(1);
            let contact = if email(contact) { contact } else { "" };
            let name = person.text(2).trim();
            let name = if safe_text(name, 100) { name } else { "" };
            names.insert(person_id, (contact, name));
            for entry in person.messages(7) {
                let peer = entry?.message(2)?;
                let peer_id = peer.text(1);
                if !uuid(peer_id) {
                    continue;
                }
                let destination = format!("{person_id}:{peer_id}");
                let kind = match peer.number(2) {
                    2 => "Phone",
                    3 => "Tablet",
                    4 => "Laptop",
                    5 => "Desktop",
                    _ => "Device",
                };
                let device_name = peer.text(3).trim();
                let name_known = registered_device_name(device_name);
                if person_id.eq_ignore_ascii_case(user) && peer_id.eq_ignore_ascii_case(device) {
                    own_device_name = Some(name_known);
                }
                let mut row = json!({
                    "peer": destination, "name": if name_known { device_name } else { kind },
                    "kind": kind, "contact": contact, "user_name": name, "history": false,
                    "name_known": name_known, "can_relay": matches!(kind, "Desktop" | "Laptop"),
                });
                if let Some(reach) = peer.bytes(4) {
                    row["online"] = json!(Proto::parse(reach)?.number(1) != 0);
                }
                devices.insert(destination, row);
            }
        }
        let mut transfers = Vec::new();
        for entry in state.messages(600) {
            let transfer = entry?.message(2)?;
            let id = transfer.text(100);
            if !uuid(id) {
                continue;
            }
            let peer = transfer.message(200)?;
            let peer = format!("{}:{}", peer.text(1), peer.text(2));
            let direction = match transfer.number(700) {
                1 => "Incoming",
                2 => "Outgoing",
                _ => "UnknownDirection",
            };
            let status = match transfer.number(800) {
                1 => "Created",
                2 => "InviteRequested",
                3 => "Invited",
                4 => "Pending",
                5 => "Active",
                6 => "Paused",
                7 => "ResumeRequested",
                8 => "Completed",
                9 => "Cancelled",
                _ => "UnknownStatus",
            };
            let completed = status == "Completed";
            let dismissed = transfer.number(1000) != 0;
            let has_error = transfer.has(600) || transfer.has(601);
            let mut contents = Contents::default();
            if !has_error {
                if let Some(metadata) = transfer.bytes(400) {
                    contents =
                        paths.contents(metadata, direction == "Incoming", completed, dismissed)?;
                }
            }
            if direction == "Incoming" {
                if let Some((sender, _)) = peer_id(&peer) {
                    let (contact, name) = names.get(sender).copied().unwrap_or_default();
                    devices.entry(peer.clone()).or_insert_with(|| {
                        json!({
                            "peer": peer, "name": "Previous device", "contact": contact,
                            "user_name": name, "history": true, "name_known": false,
                        })
                    });
                }
            }
            transfers.push(json!({
                "transfer_id": id, "peer": peer, "direction": direction, "status": status,
                "updated_at": transfer.message(1300)?.number(1),
                "completed": completed, "has_error": has_error, "dismissed": dismissed,
                "progress": i64::try_from(transfer.number(1100)).unwrap_or_default(),
                "total_bytes": contents.total, "item_names": contents.names,
                "received_items": contents.files, "link_files": contents.links, "link_only": contents.link_only,
            }));
        }
        Ok(Self {
            status: json!({
                "ok": true, "headless": true, "desktop_session": desktop, "authenticated": authenticated,
                "user_id": if authenticated { user } else { "" },
                "device_id": if authenticated { device } else { "" },
                "current_device_named": own_device_name,
                "registration": registration_name, "downloads_directory": paths.downloads,
                "native_auto_accept_disabled": auto_accept_disabled,
                "receive_path_configured": receive_path_configured,
                "receive_policy_verified": authenticated && auto_accept_disabled && receive_path_configured,
                "transfer_count": transfers.len(),
            }),
            devices: devices.into_values().collect(),
            transfers,
            app_id_missing: agent.text(300).is_empty(),
            registration_failed: registration.has(999),
        })
    }

    pub(super) fn transfer(&self, id: &str) -> Option<&Value> {
        // Blip keys some invitations by an uppercase UUID. Use the exact wire spelling.
        self.transfers.iter().find(|item| item["transfer_id"] == id)
    }

    pub(super) fn poll(self) -> Value {
        json!({"ok": true, "status": self.status, "devices": self.devices, "transfers": self.transfers})
    }
}

#[derive(Default)]
struct Contents {
    names: Vec<String>,
    files: Vec<Value>,
    links: Vec<PathBuf>,
    total: i64,
    link_only: bool,
}

struct LocalPaths {
    downloads: Option<PathBuf>,
    documents: Option<PathBuf>,
}

impl LocalPaths {
    fn decode(&self, value: &str) -> Option<PathBuf> {
        if value.chars().any(char::is_control) {
            return None;
        }
        let path = if let Some(suffix) = value.strip_prefix("downloads://") {
            join_relative(self.downloads.as_deref()?, suffix)?
        } else if let Some(suffix) = value.strip_prefix("documents://") {
            join_relative(self.documents.as_deref()?, suffix)?
        } else if value.starts_with("file:") {
            url::Url::parse(value).ok()?.to_file_path().ok()?
        } else {
            #[cfg(target_os = "macos")]
            if let Some((alias, suffix)) = value.split_once(':') {
                let directory = match alias {
                    "downloads" => Some("Downloads"),
                    "documents" => Some("Documents"),
                    "desktop" => Some("Desktop"),
                    "pictures" => Some("Pictures"),
                    "music" => Some("Music"),
                    "movies" => Some("Movies"),
                    _ => None,
                };
                if let Some(directory) = directory {
                    if suffix.contains('\\') {
                        return None;
                    }
                    return join_relative(
                        &super::mac::home()?.join(directory),
                        suffix.trim_start_matches('/'),
                    );
                }
            }
            PathBuf::from(value)
        };
        #[cfg(windows)]
        let allowed = matches!(path.components().next(), Some(Component::Prefix(prefix))
            if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_)));
        #[cfg(unix)]
        let allowed = true;
        (allowed
            && path.is_absolute()
            && !path
                .components()
                .any(|part| matches!(part, Component::ParentDir)))
        .then_some(path)
    }

    fn contents(
        &self,
        bytes: &[u8],
        incoming: bool,
        completed: bool,
        dismissed: bool,
    ) -> Result<Contents> {
        let metadata = Proto::parse(bytes)?;
        let mut locations = HashMap::new();
        if incoming && completed {
            for item in metadata.messages(2) {
                let item = item?;
                locations.insert(item.text(1), item.text(2));
            }
        }
        let mut out = Contents::default();
        let mut link_count = 0;
        let mut item_count = 0;
        for item in metadata.messages(1) {
            let item = item?;
            let path = item.text(1);
            let kind = item.message(2)?;
            let file = kind.bytes(1).is_some() && !kind.has(2) && !kind.has(3) && !kind.has(4);
            let folder = kind.bytes(2).is_some() && !kind.has(1) && !kind.has(3) && !kind.has(4);
            let size = i64::try_from(kind.message(1)?.number(1)).unwrap_or_default();
            out.total = out.total.saturating_add(size);
            item_count += 1;
            let root =
                !path.contains(['/', '\\']) && !matches!(path, "." | "..") && safe_text(path, 512);
            if !root {
                continue;
            }
            if out.names.len() < 3 {
                out.names.push(path.chars().take(160).collect());
            }
            let lower = path.to_ascii_lowercase();
            let shortcut = file && (lower.ends_with(".url") || lower.ends_with(".webloc"));
            if shortcut && (1..=65_536).contains(&size) {
                link_count += 1;
            }
            if incoming && completed && (file || folder) && out.files.len() < 256 {
                if let Some(location) = locations
                    .get(path)
                    .and_then(|location| self.decode(location))
                {
                    if shortcut && !dismissed {
                        out.links.push(location.clone());
                    }
                    out.files.push(json!({"name": path, "path": location, "is_directory": folder, "size": size}));
                }
            }
        }
        out.link_only =
            incoming && !dismissed && (1..=16).contains(&item_count) && item_count == link_count;
        Ok(out)
    }
}

fn join_relative(root: &Path, suffix: &str) -> Option<PathBuf> {
    let path = Path::new(suffix);
    path.components()
        .all(|part| matches!(part, Component::Normal(_)))
        .then(|| root.join(path))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::blip::rpc::{field, number, string};

    #[test]
    fn distinguishes_registered_computer_names_from_placeholders() {
        let user = "11111111-1111-4111-8111-111111111111";
        let device = "22222222-2222-4222-8222-222222222222";
        let snapshot = |name: &str, username: &str| {
            let auth = field(
                201,
                &[
                    string(201, "fixture"),
                    string(202, user),
                    string(204, device),
                ]
                .concat(),
            );
            let computer = [string(1, device), number(2, 5), string(3, name)].concat();
            let person = [
                string(1, "fixture@example.test"),
                string(2, username),
                string(8, user),
                field(7, &field(2, &computer)),
            ]
            .concat();
            let users = field(500, &field(1, &field(2, &person)));
            Snapshot::decode(
                &field(2, &[auth, users].concat()),
                false,
                Path::new("fixture"),
            )
            .unwrap()
        };
        let generic = snapshot("myDrive on Mac", "");
        assert_eq!(generic.status["current_device_named"], false);
        assert_eq!(generic.devices[0]["name_known"], false);
        assert_eq!(generic.devices[0]["user_name"], "");
        assert_eq!(generic.devices[0]["contact"], "fixture@example.test");
        let named = snapshot("Mac", "Fixture username");
        assert_eq!(named.status["current_device_named"], true);
        assert_eq!(named.devices[0]["name"], "Mac");
        assert_eq!(named.devices[0]["user_name"], "Fixture username");
    }

    #[test]
    fn finished_root_shortcuts_keep_paths_and_exact_invitation_ids() {
        let id = "ABCD1234-EF56-4789-ABCD-123456789ABC";
        let user = "11111111-1111-4111-8111-111111111111";
        let device = "22222222-2222-4222-8222-222222222222";
        let path = if cfg!(windows) {
            r"C:\Downloads\Studio link.url"
        } else {
            "/home/test/Downloads/Studio link.url"
        };
        let root = "Studio link.url";
        let file = field(1, &number(1, 43));
        let item = field(1, &[string(1, root), field(2, &file)].concat());
        let location = field(2, &[string(1, root), string(2, path)].concat());
        let archive = field(400, &[item, location].concat());
        let peer = field(200, &[string(1, user), string(2, device)].concat());
        let fixture = |status| {
            let transfer = [
                string(100, id),
                peer.clone(),
                archive.clone(),
                number(700, 1),
                number(800, status),
            ]
            .concat();
            let transfer = field(600, &[string(1, id), field(2, &transfer)].concat());
            Snapshot::decode(
                &field(2, &transfer),
                true,
                Path::new(r"C:\myDrive\downloads"),
            )
            .unwrap()
        };
        let invited = fixture(3);
        assert!(invited.transfer(&id.to_lowercase()).is_none());
        assert_eq!(invited.transfer(id).unwrap()["link_only"], true);
        assert_eq!(invited.transfer(id).unwrap()["link_files"], json!([]));
        let completed = fixture(8);
        assert_eq!(completed.transfer(id).unwrap()["link_files"], json!([path]));
        assert_eq!(
            completed.transfer(id).unwrap()["received_items"][0]["size"],
            43
        );
    }
}
