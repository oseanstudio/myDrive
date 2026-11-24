use crate::{syncthing, syncthing_engine};
use serde_json::{json, Map, Value};
use std::{
    env,
    ffi::OsString,
    fs,
    path::PathBuf,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

pub const VERSION: &str = match option_env!("MYDRIVE_VERSION") {
    Some(version) => version,
    None => "0.4.22",
};

#[derive(Clone, Copy)]
pub enum Kind {
    Text,
    OptionalText,
    Paths,
}
use Kind::*;
pub struct Tool {
    pub group: &'static str,
    pub command: &'static str,
    pub description: &'static str,
    pub fields: &'static [(&'static str, Kind)],
    pub read_only: bool,
}

impl Tool {
    pub fn name(&self) -> String {
        format!("{}_{}", self.group, self.command.replace('-', "_"))
    }
}

macro_rules! tool {
    ($group:literal, $cmd:literal, $read:expr, $desc:literal $(, $name:literal: $kind:ident)*) => {
        Tool { group: $group, command: $cmd, read_only: $read, description: $desc, fields: &[$(($name, $kind)),*] }
    };
}

pub const TOOLS: &[Tool] = &[
    tool!(
        "blip",
        "status",
        true,
        "Show the connection and account state of the local Blip session."
    ),
    tool!(
        "blip",
        "devices",
        true,
        "List Blip devices with their exact recipient IDs."
    ),
    tool!(
        "blip",
        "transfers",
        true,
        "List Blip invitations and transfers, including completed received file locations."
    ),
    tool!("blip", "send", false, "Send the specified local files or folders to one exact Blip peer. The result confirms dispatch, and transfer status confirms delivery.", "peer": Text, "paths": Paths),
    tool!("blip", "receive", false, "Accept one incoming Blip invitation by its exact transfer ID into the usual receive folder.", "transfer_id": Text),
    tool!(
        "sync",
        "status",
        true,
        "Show Syncthing folders, connected devices, and current sync status."
    ),
    tool!("sync", "browse", true, "List files in a synced folder. Pass a Syncthing folder ID and an optional relative path.", "folder_id": Text, "path": OptionalText),
    tool!("sync", "pause", false, "Pause syncing for one folder ID.", "folder_id": Text),
    tool!("sync", "resume", false, "Resume syncing for one folder ID.", "folder_id": Text),
    tool!("sync", "rescan", false, "Ask Syncthing to scan a folder for changes.", "folder_id": Text),
    tool!("sync", "share-preview", true, "Check how sharing a local folder with an existing Syncthing device would work.", "local_path": Text, "device_id": Text, "label": OptionalText),
    tool!("sync", "share", false, "Share a local folder with the specified existing Syncthing device. May require acceptance there.", "local_path": Text, "device_id": Text, "label": OptionalText),
    tool!("sync", "stop", false, "Remove a folder from the sync configuration while keeping its files. Requires the current path from sync status.", "folder_id": Text, "expected_path": Text),
    tool!(
        "smb",
        "devices",
        true,
        "List this account's Tailscale devices as potential SMB hosts."
    ),
    tool!("smb", "shares", true, "List SMB shares on this Tailscale device using the locally configured SMB credentials.", "device": Text),
    tool!("smb", "browse", true, "List files in an SMB share on a Tailscale device. Paths are relative to the share.", "device": Text, "share": Text, "path": OptionalText),
];

fn help() {
    println!("myDrive {VERSION}\n\n  mydrive-cli blip serve        Keep the signed-in Blip account online headlessly\n  mydrive-cli mcp               Run the MCP server over stdio\n  mydrive-cli --version\n");
    println!("  mydrive-cli startup status|enable|disable|setup|run\n      Manage the headless boot service\n");
    for tool in TOOLS {
        let fields = tool
            .fields
            .iter()
            .map(|(name, kind)| match kind {
                Text => format!(" <{name}>"),
                OptionalText => format!(" [{name}]"),
                Paths => " <file or folder>...".into(),
            })
            .collect::<String>();
        println!(
            "  mydrive-cli {} {}{}\n      {}",
            tool.group, tool.command, fields, tool.description
        );
    }
}

pub fn cli(command: OsString, arguments: impl Iterator<Item = OsString>) -> Result<(), String> {
    let command = command
        .into_string()
        .map_err(|_| "Command must be UTF-8.")?;
    let mut args = arguments
        .map(|argument| {
            argument
                .into_string()
                .map_err(|_| "Arguments must be UTF-8.")
        })
        .collect::<Result<Vec<_>, _>>()?
        .into_iter();
    if command == "--version" && args.len() == 0 {
        println!("{VERSION}");
        return Ok(());
    }
    if matches!(command.as_str(), "--help" | "-h" | "help") {
        help();
        return Ok(());
    }
    if command == "mcp" && args.len() == 0 {
        return crate::mcp::serve();
    }
    if command == "startup" {
        return crate::startup::cli(&args.collect::<Vec<_>>());
    }
    let Some(operation) = args.next() else {
        return Err("Choose a command. Run mydrive-cli --help.".into());
    };
    if operation == "--help" {
        help();
        return Ok(());
    }
    if command == "blip" && operation == "serve" && args.len() == 0 {
        return blip_serve();
    }
    let tool = TOOLS
        .iter()
        .find(|tool| tool.group == command && tool.command == operation)
        .ok_or("Unknown command. Run mydrive-cli --help.")?;
    let mut fields = Map::new();
    for &(field, kind) in tool.fields {
        if matches!(kind, Paths) {
            fields.insert(field.into(), json!(args.by_ref().collect::<Vec<_>>()));
        } else if let Some(value) = args.next() {
            fields.insert(field.into(), json!(value));
        }
    }
    if args.len() != 0 {
        return Err("Too many arguments. Run mydrive-cli --help.".into());
    }
    println!(
        "{}",
        serde_json::to_string_pretty(&run(tool, &Value::Object(fields))?)
            .map_err(|e| e.to_string())?
    );
    Ok(())
}

pub fn run(tool: &Tool, arguments: &Value) -> Result<Value, String> {
    run_with_hosts(tool, arguments, None, &mut syncthing_engine::Owner::default())
}

pub fn run_with_hosts(
    tool: &Tool,
    arguments: &Value,
    host: Option<&mut BlipHost>,
    sync: &mut syncthing_engine::Owner,
) -> Result<Value, String> {
    let fields = arguments
        .as_object()
        .ok_or("Expected an arguments object.")?;
    for name in fields.keys() {
        if !tool.fields.iter().any(|(field, _)| *field == name) {
            return Err(format!("Unknown argument {name}."));
        }
    }
    for &(name, kind) in tool.fields {
        match (kind, fields.get(name)) {
            (OptionalText, None) => {}
            (Text | OptionalText, Some(Value::String(s)))
                if !s.trim().is_empty() && s.len() <= 32768 && !s.contains('\0') => {}
            (Paths, Some(Value::Array(paths)))
                if !paths.is_empty()
                    && paths.len() <= 256
                    && paths.iter().all(|p| {
                        p.as_str()
                            .is_some_and(|p| !p.is_empty() && p.len() <= 32768 && !p.contains('\0'))
                    }) => {}
            _ => return Err(format!("Missing or invalid {name}.")),
        }
    }
    match tool.group {
        "blip" => {
            if tool.command == "send"
                && !arguments["peer"]
                    .as_str()
                    .unwrap()
                    .split_once(':')
                    .is_some_and(|(user, device)| uuid(user) && uuid(device))
            {
                return Err("Choose the exact USER_UUID:DEVICE_UUID from blip devices.".into());
            }
            if tool.command == "receive" && !uuid(arguments["transfer_id"].as_str().unwrap()) {
                return Err("Choose the exact transfer UUID from blip transfers.".into());
            }
            if let Some(host) = host {
                host.ensure()?;
            }
            blip_action(tool.command, arguments)
        }
        "sync" => sync_action(sync, tool.command, arguments),
        "smb" => smb_action(tool.command, arguments),
        _ => Err("Unknown tool.".into()),
    }
}

pub(crate) fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, byte)| {
            if [8, 13, 18, 23].contains(&i) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

pub(crate) fn user_data() -> Result<PathBuf, String> {
    let home = || env::var_os("HOME").map(PathBuf::from);
    let base = if cfg!(windows) {
        env::var_os("LOCALAPPDATA").map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        home().map(|p| p.join("Library/Application Support"))
    } else {
        env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .or_else(|| home().map(|p| p.join(".local/share")))
    };
    base.filter(|p| p.is_absolute())
        .map(|p| p.join("myDrive"))
        .ok_or_else(|| "Could not locate myDrive's user data folder.".into())
}

fn binary_dir() -> Result<PathBuf, String> {
    env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(PathBuf::from))
        .ok_or_else(|| "Could not locate the myDrive helpers.".into())
}

fn sync_action(owner: &mut syncthing_engine::Owner, command: &str, arguments: &Value) -> Result<Value, String> {
    let data = user_data()?;
    let saved = preferences(&data);
    let path = env::var("MYDRIVE_SYNCTHING_CONFIG").ok().or_else(|| {
        [
            "SyncthingConfigPath",
            "syncthing_config_path",
            "syncthing_config",
        ]
        .iter()
        .find_map(|key| {
            saved[*key]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        })
    });
    let connection = owner.ensure(&json!({"config_path": path}), &data)?;
    let connection: syncthing::Connection =
        serde_json::from_value(connection["connection"].clone())
            .map_err(|_| "Invalid local Syncthing connection.")?;
    let mut arguments = arguments.clone();
    let action = match command {
        "status" => "snapshot",
        "rescan" => "scan",
        "share-preview" => "share.preview",
        "pause" | "resume" => {
            arguments["paused"] = json!(command == "pause");
            "pause"
        }
        other => other,
    };
    syncthing::Api::new(&connection)?.execute(action, &arguments, &data)
}

fn preferences(data: &std::path::Path) -> Value {
    fs::read(data.join("preferences.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or(Value::Null)
}

pub(crate) fn blip_background_enabled() -> bool {
    let Ok(data) = user_data() else {
        return false;
    };
    let pref = preferences(&data);
    let key = if cfg!(windows) {
        "BlipAutoConnectDesktop"
    } else if cfg!(target_os = "macos") {
        "blip_background_receiving"
    } else {
        "blip_background"
    };
    pref[key].as_bool().unwrap_or(true)
}

pub(crate) fn smb_action(command: &str, arguments: &Value) -> Result<Value, String> {
    let dir = binary_dir()?;
    let helper = if cfg!(windows) {
        dir.join("mydrive-smb-host.exe")
    } else if cfg!(target_os = "macos") && dir.ends_with("Resources") {
        dir.join("../MacOS/mydrive-smb-host")
    } else {
        dir.join("mydrive-smb-host")
    };
    let mut child = helper_command(helper)
        .arg("--browse")
        .env_remove("MYDRIVE_SMB_USERNAME")
        .env_remove("MYDRIVE_SMB_PASSWORD")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "The SMB tool is missing from this installation.")?;
    let mut request = arguments.clone();
    request["action"] = json!(command);
    if command != "devices" {
        request["username"] = json!(env::var("MYDRIVE_SMB_USERNAME").unwrap_or_default());
        request["password"] = json!(env::var("MYDRIVE_SMB_PASSWORD").unwrap_or_default());
    }
    let mut input = child
        .stdin
        .take()
        .ok_or("Could not start the SMB request.")?;
    let result = serde_json::to_writer(&mut input, &request);
    drop(input);
    let output = child
        .wait_with_output()
        .map_err(|_| "The SMB tool stopped unexpectedly.")?;
    result.map_err(|_| "Could not send the SMB request.")?;
    let reply: Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| "The SMB tool returned an unreadable response.")?;
    if let Some(error) = reply["error"].as_str() {
        return Err(error.into());
    }
    Ok(reply["data"].clone())
}

fn helper_command(executable: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut command = Command::new(executable);
    command
        .env_remove("MYDRIVE_SMB_USERNAME")
        .env_remove("MYDRIVE_SMB_PASSWORD");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

#[cfg(windows)]
fn desktop_blip_profile() -> Result<bool, String> {
    Ok(!preferences(&user_data()?)["BlipSeparateProfile"].as_bool().unwrap_or(false))
}

#[cfg(windows)]
fn blip_command(command: &str, values: &[String], host: bool) -> Result<Command, String> {
    let executable = env::current_exe().map_err(|_| "The myDrive helper is unavailable.")?;
    let mut child = helper_command(executable);
    child
        .arg("--blip-engine")
        .arg(command)
        .arg("--profile")
        .arg(user_data()?.join("Blip"));
    if !host && desktop_blip_profile()? {
        child.arg("--desktop");
    }
    child.args(values);
    Ok(child)
}

#[cfg(target_os = "macos")]
fn blip_command(command: &str, values: &[String], host: bool) -> Result<Command, String> {
    if !host {
        let executable = env::current_exe().map_err(|_| "The myDrive helper is unavailable.")?;
        let mut child = helper_command(executable);
        child.arg("--blip-engine").arg(command).args(values);
        return Ok(child);
    }
    let directory = binary_dir()?;
    let app = if directory.ends_with("Resources") {
        directory.join("../MacOS/myDrive")
    } else {
        directory.join("myDrive")
    };
    let mut child = helper_command(app);
    child.arg("--blip-cli").arg(command).args(values);
    Ok(child)
}

#[cfg(target_os = "linux")]
fn blip_command(command: &str, values: &[String], _host: bool) -> Result<Command, String> {
    let script = env::var_os("MYDRIVE_BLIP_SCRIPT")
        .ok_or("Run the Blip command through the myDrive AppImage.")?;
    let mut child = helper_command("/usr/bin/python3");
    child.args(["-B"]).arg(script).arg(command).args(values);
    Ok(child)
}

fn bridge(mut child: Command) -> Result<Value, String> {
    let output = child.stdin(Stdio::null()).output().map_err(|_| {
        "Could not start the installed Blip backend. Check the Blip setup documentation."
    })?;
    if !output.status.success() {
        #[cfg(any(windows, target_os = "macos"))]
        if let Ok(result) = serde_json::from_slice::<Value>(&output.stdout) {
            if let Some(error) = result["error"].as_str() {
                return Err(crate::blip::error_message(error).into());
            }
        }
        let reason = String::from_utf8_lossy(&output.stderr);
        let reason = reason.lines().next().unwrap_or("");
        return Err(if reason.is_empty() {
            "Blip is unavailable. Run `mydrive-cli blip serve` after signing in to Blip once."
                .into()
        } else {
            reason.chars().take(360).collect()
        });
    }
    let reply: Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| "Blip returned an unreadable response.")?;
    if reply["ok"] != true {
        return Err("Blip could not confirm the request.".into());
    }
    Ok(reply)
}

fn blip_action(command: &str, arguments: &Value) -> Result<Value, String> {
    #[cfg(windows)]
    if matches!(command, "status" | "devices" | "transfers") {
        let result = crate::blip::poll(user_data()?.join("Blip"), desktop_blip_profile()?)?;
        return Ok(result[command].clone());
    }
    let mut values = Vec::new();
    let native = match command {
        "send" => {
            values.extend([
                "--peer".into(),
                arguments["peer"].as_str().unwrap().into(),
                "--execute".into(),
                "--".into(),
            ]);
            for path in arguments["paths"].as_array().unwrap() {
                let full = fs::canonicalize(path.as_str().unwrap())
                    .map_err(|_| "A selected file or folder is unavailable.")?;
                if !full.is_file() && !full.is_dir() {
                    return Err("Choose a regular file or folder.".into());
                }
                values.push(crate::syncthing::friendly_path(&full));
            }
            "send"
        }
        "receive" => {
            values.extend([
                "--id".into(),
                arguments["transfer_id"].as_str().unwrap().into(),
                "--execute".into(),
            ]);
            "accept-manual"
        }
        _ => "poll",
    };
    let result = bridge(blip_command(native, &values, false)?)?;
    Ok(match command {
        "status" => result["status"].clone(),
        "devices" => result["devices"].clone(),
        "transfers" => result["transfers"].clone(),
        _ => result,
    })
}

fn blip_host_command() -> Result<Command, String> {
    #[cfg(windows)]
    let command = if desktop_blip_profile()? { "desktop-serve" } else { "serve" };
    #[cfg(not(windows))]
    let command = "serve";
    blip_command(command, &[], true)
}

fn blip_serve() -> Result<(), String> {
    let mut command = blip_host_command()?;
    eprintln!("Starting the Blip backend. Keep this process running while transferring files. Close stdin to stop.");
    let status = command
        .status()
        .map_err(|_| "Could not start the installed Blip backend.")?;
    if !status.success() {
        return Err("The Blip backend stopped. Check that Blip is installed, signed in, and allowed to access its local profile.".into());
    }
    Ok(())
}

#[derive(Default)]
pub struct BlipHost(Option<Child>);

impl BlipHost {
    pub(crate) fn ensure(&mut self) -> Result<(), String> {
        if blip_action("status", &Value::Null).is_ok() {
            return Ok(());
        }
        if self
            .0
            .as_mut()
            .is_some_and(|child| matches!(child.try_wait(), Ok(None)))
        {
            return Err(
                "The Blip backend is running but its local connection is unavailable.".into(),
            );
        }
        let child = blip_host_command()?
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| "Could not start the Blip backend.")?;
        self.0 = Some(child);
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if self
                .0
                .as_mut()
                .is_none_or(|child| !matches!(child.try_wait(), Ok(None)))
            {
                break;
            }
            if blip_action("status", &Value::Null).is_ok() {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(400));
        }
        self.stop();
        Err("The background Blip connection could not start. Check the installed runtime, sign-in and local data permissions.".into())
    }

    pub(crate) fn stop(&mut self) {
        let Some(mut child) = self.0.take() else {
            return;
        };
        drop(child.stdin.take());
        for _ in 0..40 {
            if !matches!(child.try_wait(), Ok(None)) {
                return;
            }
            thread::sleep(Duration::from_millis(250));
        }
        let _ = child.kill();
        let _ = child.wait();
    }
}

impl Drop for BlipHost {
    fn drop(&mut self) {
        self.stop();
    }
}
