mod automation;
mod blip_recents;
mod client;
mod cloud;
mod desktop_update;
mod model;
mod mcp;
mod relay;
mod s3;
mod sftp;
mod smb_copy;
mod smb_health;
mod startup;
mod storage;
mod syncthing;
mod syncthing_engine;
mod updates;
mod webdav;
#[cfg(windows)]
#[path = "../../Windows/Network/smb.rs"]
mod windows_smb;
#[cfg(any(windows, target_os = "linux", target_os = "macos"))]
mod blip;
#[cfg(test)]
mod wire_tests;
use client::{FileClient, LocalClient};
use model::*;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    io::{self, Read},
    path::Path,
};

#[derive(Deserialize)]
struct Request {
    action: String,
    #[serde(default)]
    data_dir: String,
    bookmark: Option<Bookmark>,
    #[serde(default)]
    bookmarks: Vec<Bookmark>,
    #[serde(default)]
    credentials: Credentials,
    #[serde(default)]
    path: String,
    #[serde(default)]
    destination: String,
    #[serde(default)]
    local_path: String,
    #[serde(default)]
    is_dir: bool,
    #[serde(default)]
    syncthing: syncthing::Connection,
    #[serde(default)]
    payload: Value,
}
fn execute(r: Request) -> Result<Value, String> {
    #[cfg(target_os = "macos")]
    if let Some(action) = r.action.strip_prefix("blip.native.") {
        return blip::mac::request(action, &r.payload);
    }
    if let Some(action) = r.action.strip_prefix("blip.recents.") {
        return blip_recents::run(action, Path::new(&r.data_dir), &r.payload);
    }
    #[cfg(any(windows, target_os = "linux"))]
    if let Some(action) = r.action.strip_prefix("blip.downloads.") {
        return blip::downloads::run(action, Path::new(&r.data_dir), &r.payload);
    }
    if let Some(action) = r.action.strip_prefix("relay.") {
        return relay::run(action, &r.payload, Path::new(&r.data_dir));
    }
    if let Some(action) = r.action.strip_prefix("cloud.") {
        return cloud::execute(action, Path::new(&r.data_dir), &r.payload);
    }
    if r.action == "smb.connect" {
        #[cfg(windows)]
        {
            let b = r.bookmark.as_ref().ok_or("Choose an SMB connection.")?;
            windows_smb::connect(b, &r.credentials)?;
            return Ok(json!(null));
        }
        #[cfg(not(windows))]
        {
            return Err("SMB sessions are managed by this platform's native mount adapter.".into());
        }
    }
    if let Some(action) = r.action.strip_prefix("syncthing.") {
        return syncthing::Api::new(&r.syncthing)?.execute(
            action,
            &r.payload,
            Path::new(&r.data_dir),
        );
    }
    match r.action.as_str() {
        "version" => return Ok(json!({"name":"myDrive","version":env!("CARGO_PKG_VERSION")})),
        "smb.devices" => return automation::smb_action("devices", &json!({})),
        "smb.health" => return smb_health::check(r.payload),
        "startup.status" => return startup::status(),
        "startup.enable" | "startup.disable" => {
            startup::set_enabled(r.action == "startup.enable")?;
            return startup::status();
        }
        "startup.setup" => {
            startup::setup(None)?;
            return startup::status();
        }
        "update.check" => {
            let installed = r.payload["version"].as_str().ok_or("Missing app version.")?;
            return Ok(json!(updates::check(installed)?));
        }
        "update.install" => {
            return desktop_update::prepare(r.payload, Path::new(&r.data_dir), false).map(|_| Value::Null);
        }
        "update.stage" => {
            let plan = desktop_update::prepare(r.payload, Path::new(&r.data_dir), true)?;
            return Ok(json!({"plan_path":plan}));
        }
        "update.apply" | "update.discard" => {
            desktop_update::use_prepared(r.payload, Path::new(&r.data_dir), r.action == "update.apply")?;
            return Ok(Value::Null);
        }
        "update.error" => return Ok(json!(desktop_update::take_error(Path::new(&r.data_dir)))),
        "bookmarks.load" => return Ok(json!(storage::load(Path::new(&r.data_dir))?)),
        "bookmarks.save" => {
            storage::save(Path::new(&r.data_dir), &r.bookmarks)?;
            return Ok(json!(null));
        }
        _ => {}
    }
    let b = r.bookmark.ok_or("A connection is required.")?;
    b.validate()?;
    let path = clean_path(&r.path)?;
    if b.protocol == Protocol::Smb
        && !r.data_dir.is_empty()
        && matches!(r.action.as_str(), "upload" | "download")
    {
        if path.is_empty() {
            return Err("Select a file inside the SMB share.".into());
        }
        let upload = r.action == "upload";
        let remote = LocalClient::new(&b)?.resolve(&path, upload)?;
        let local = Path::new(&r.local_path);
        let (source, destination) = if upload {
            (local, remote.as_path())
        } else {
            (remote.as_path(), local)
        };
        smb_copy::copy(source, destination, Path::new(&r.data_dir), &b.id)?;
        return Ok(json!(null));
    }
    let mut client: Box<dyn FileClient> = match b.protocol {
        Protocol::Local | Protocol::Smb => Box::new(LocalClient::new(&b)?),
        Protocol::Webdav => Box::new(webdav::WebDav::new(&b, &r.credentials)?),
        Protocol::Sftp => Box::new(sftp::SftpClient::new(&b, &r.credentials)?),
        Protocol::S3 => Box::new(s3::S3Client::new(&b, &r.credentials)?),
    };
    match r.action.as_str() {
        "list" | "test" => {
            let mut files = client.list(&path)?;
            files.sort_by(|a, b| {
                b.is_dir
                    .cmp(&a.is_dir)
                    .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            });
            Ok(json!(files))
        }
        "download" => {
            let target = Path::new(&r.local_path);
            if target.exists() {
                return Err(
                    "The download destination already exists. Choose a different filename.".into(),
                );
            }
            let mut temp =
                tempfile::NamedTempFile::new_in(target.parent().ok_or("Invalid download folder")?)
                    .map_err(|e| e.to_string())?;
            client.download(&path, temp.path())?;
            temp.as_file_mut().sync_all().map_err(|e| e.to_string())?;
            temp.persist_noclobber(target).map_err(|e| e.to_string())?;
            Ok(json!(null))
        }
        "upload" => {
            client.upload(Path::new(&r.local_path), &path)?;
            Ok(json!(null))
        }
        "mkdir" => {
            client.mkdir(&path)?;
            Ok(json!(null))
        }
        "delete" => {
            client.delete(&path, r.is_dir)?;
            Ok(json!(null))
        }
        "rename" => {
            client.rename(&path, &clean_path(&r.destination)?)?;
            Ok(json!(null))
        }
        _ => Err("Unknown core action.".into()),
    }
}
fn main() {
    let mut arguments = std::env::args_os().skip(1);
    if let Some(command) = arguments.next() {
        #[cfg(target_os = "macos")]
        if command == "--blip-mac-poll" {
            std::process::exit(blip::mac::poll_loop());
        }
        #[cfg(any(windows, target_os = "linux", target_os = "macos"))]
        if command == "--blip-engine" || (cfg!(windows) && command == "--windows-blip") {
            std::process::exit(blip::run(arguments));
        }
        if command == "--cloud-worker" {
            let Some(root) = arguments.next() else { return };
            let Some(job) = arguments.next().and_then(|value| value.into_string().ok()) else { return };
            let Some(run) = arguments.next().and_then(|value| value.into_string().ok()) else { return };
            if !Path::new(&root).is_absolute() || cloud::worker(Path::new(&root), &job, &run).is_err() {
                std::process::exit(1);
            }
            return;
        }
        if command == "--syncthing-owner" {
            if let Err(error) = syncthing_engine::serve() {
                eprintln!("{error}");
            }
            return;
        }
        if command == "--smb-health-probe" {
            std::process::exit(smb_health::probe_worker(arguments));
        }
        if command == "--finish-desktop-update" {
            if let Some(plan) = arguments.next() {
                desktop_update::finish(Path::new(&plan));
            }
            return;
        }
        if let Err(error) = automation::cli(command, arguments) {
            eprintln!("{error}");
            std::process::exit(1);
        }
        return;
    }
    if std::env::current_exe().ok().and_then(|path| path.file_stem().map(|name| name.eq_ignore_ascii_case("mydrive-cli"))) == Some(true) {
        let _ = automation::cli("--help".into(), std::iter::empty());
        return;
    }
    // One JSON request on stdin. Credentials never appear in process arguments or output.
    let mut input = String::new();
    if let Err(e) = io::stdin().take(8 * 1024 * 1024).read_to_string(&mut input) {
        println!("{}", json!({"ok":false,"error":e.to_string()}));
        return;
    }
    let result = serde_json::from_str::<Request>(&input)
        .map_err(|e| format!("Invalid request: {e}"))
        .and_then(execute);
    println!(
        "{}",
        match result {
            Ok(value) => json!({"ok":true,"data":value}),
            Err(error) => json!({"ok":false,"error":error}),
        }
    );
}
