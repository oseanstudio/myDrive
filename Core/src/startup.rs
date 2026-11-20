use serde_json::{json, Value};
#[cfg(unix)]
use std::path::Path;
use std::{
    env, fs,
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

pub fn cli(args: &[String]) -> Result<(), String> {
    match args {
        [op] if op == "run" => return run(),
        [op] if op == "setup" => setup(None)?,
        #[cfg(windows)]
        [op, user] if op == "setup" => {
            setup(Some(user))?;
            println!("The startup task is ready.");
            return Ok(());
        }
        [op] if op == "enable" || op == "disable" => set_enabled(op == "enable")?,
        [op] if op == "status" => {}
        _ => return Err("Usage: mydrive-cli startup status|enable|disable|setup|run".into()),
    }
    println!("{}", status()?);
    Ok(())
}

fn enabled() -> Result<bool, String> {
    let file = super::automation::user_data()?.join("startup.json");
    preference(&file)
}

fn preference(file: &std::path::Path) -> Result<bool, String> {
    match fs::read(file) {
        Ok(maybe) => serde_json::from_slice::<bool>(&maybe)
            .map_err(|_| "Startup preference is unreadable.".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Err(_) => Err("Startup preference is unavailable.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_defaults_on_and_keeps_an_explicit_opt_out() {
        let fixture = tempfile::tempdir().unwrap();
        let file = fixture.path().join("startup.json");
        assert_eq!(preference(&file), Ok(true));
        fs::write(&file, b"false\n").unwrap();
        assert_eq!(preference(&file), Ok(false));
        fs::write(&file, b"invalid").unwrap();
        assert!(preference(&file).is_err());
        assert_eq!(fs::read(file).unwrap(), b"invalid");
    }
}

pub fn set_enabled(value: bool) -> Result<(), String> {
    let data = super::automation::user_data()?;
    fs::create_dir_all(&data).map_err(|e| e.to_string())?;
    let mut file = tempfile::NamedTempFile::new_in(&data).map_err(|e| e.to_string())?;
    writeln!(file, "{value}").map_err(|e| e.to_string())?;
    file.persist(data.join("startup.json"))
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn status() -> Result<Value, String> {
    Ok(json!({"enabled":enabled()?,"configured":platform::configured()}))
}

pub fn setup(account: Option<&str>) -> Result<(), String> {
    platform::setup(account)
}

#[cfg(windows)]
pub fn pause_for_update() -> bool {
    if !platform::configured() {
        return false;
    }
    platform::task_command("/End");
    enabled().unwrap_or(false)
}

#[cfg(windows)]
pub fn resume_after_update() {
    if enabled().unwrap_or(false) {
        platform::task_command("/Run");
    }
}

fn run() -> Result<(), String> {
    let mut blip = super::automation::BlipHost::default();
    let launch_path = env::var_os("APPIMAGE")
        .map(PathBuf::from)
        .or_else(|| env::current_exe().ok());
    let stamp = || {
        launch_path
            .as_ref()
            .and_then(|path| fs::metadata(path).ok())
            .and_then(|file| file.modified().ok().map(|time| (time, file.len())))
    };
    let started = stamp();
    let mut next_sync = Instant::now();
    let mut next_blip = Instant::now();
    while enabled()? {
        if started.is_some() && stamp().is_some_and(|current| Some(current) != started) {
            return Err("myDrive was updated. Restarting its startup service.".into());
        }
        let now = Instant::now();
        if now >= next_sync {
            if super::automation::sync_action("status", &json!({})).is_err() {
                eprintln!("Syncthing is unavailable. myDrive will retry.");
            }
            next_sync = Instant::now() + Duration::from_secs(60);
        }
        if now >= next_blip {
            if !super::automation::blip_background_enabled() {
                blip.stop();
            } else if blip.ensure().is_err() {
                eprintln!("Blip is unavailable. myDrive will retry.");
            }
            next_blip = Instant::now() + Duration::from_secs(30);
        }
        thread::sleep(Duration::from_secs(5));
    }
    Ok(())
}

fn cli_path() -> Result<PathBuf, String> {
    let path =
        env::current_exe().map_err(|_| "Could not locate the installed command line tool.")?;
    let directory = path
        .parent()
        .ok_or("Could not locate the installation folder.")?;
    let cli = if cfg!(windows) {
        directory.join("mydrive-cli.exe")
    } else if directory.ends_with("Resources") {
        directory.join("../MacOS/mydrive-cli")
    } else {
        directory.join("mydrive-cli")
    };
    if cli.is_file() {
        Ok(cli)
    } else {
        Err("Use the installed myDrive package to set up startup.".into())
    }
}

fn quiet(mut command: Command) -> Option<std::process::Output> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
    }
    command.stdin(Stdio::null()).output().ok()
}

#[cfg(any(windows, target_os = "macos"))]
fn xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(windows)]
mod platform {
    use super::*;
    use sha2::{Digest, Sha256};

    fn user() -> Option<String> {
        let output = quiet(Command::new("whoami.exe"))?;
        if !output.status.success() {
            return None;
        }
        Some(String::from_utf8_lossy(&output.stdout).trim().into())
    }

    fn task(account: &str) -> String {
        let hash = hex::encode(Sha256::digest(account.to_lowercase().as_bytes()));
        format!("myDrive Startup {}", &hash[..12])
    }

    pub fn configured() -> bool {
        user().is_some_and(|account| {
            let mut command = Command::new("schtasks.exe");
            command.args(["/Query", "/TN", &task(&account), "/XML"]);
            quiet(command).is_some_and(|reply| {
                if !reply.status.success() {
                    return false;
                }
                let document = String::from_utf8_lossy(&reply.stdout).replace('\0', "");
                document.contains("<BootTrigger>") && !document.contains("<Enabled>false</Enabled>")
            })
        })
    }

    pub(super) fn task_command(action: &str) {
        if let Some(account) = user() {
            let mut command = Command::new("schtasks.exe");
            command.args([action, "/TN", &task(&account)]);
            let _ = quiet(command);
        }
    }

    pub fn setup(account: Option<&str>) -> Result<(), String> {
        let account = account
            .map(str::to_owned)
            .or_else(user)
            .ok_or("Could not find the Windows account.")?;
        if account.len() > 256 || !account.contains('\\') || account.chars().any(char::is_control) {
            return Err("Choose a Windows user account with a password.".into());
        }
        let exe = cli_path()?;
        let document = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Start myDrive's headless services at boot.</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled><Delay>PT20S</Delay></BootTrigger></Triggers>
  <Principals><Principal id="myDrive"><UserId>{}</UserId><LogonType>Password</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure><Interval>PT1M</Interval><Count>10</Count></RestartOnFailure></Settings>
  <Actions Context="myDrive"><Exec><Command>{}</Command><Arguments>startup run</Arguments></Exec></Actions>
</Task>"#,
            xml(&account),
            xml(&exe.to_string_lossy())
        );
        let mut configuration = tempfile::Builder::new()
            .suffix(".xml")
            .tempfile()
            .map_err(|e| e.to_string())?;
        configuration
            .write_all(document.as_bytes())
            .map_err(|e| e.to_string())?;
        eprintln!("Windows Task Scheduler will request the password for {account}.");
        let result = Command::new("schtasks.exe")
            .args(["/Create", "/F", "/TN", &task(&account), "/XML"])
            .arg(configuration.path())
            .args(["/RU", &account, "/RP", "*"])
            .status()
            .map_err(|_| "Could not start Windows Task Scheduler.")?;
        if !result.success() {
            return Err("Task Scheduler could not register startup. Run setup as an administrator using a Windows account password.".into());
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;

    fn label() -> String {
        format!("io.mydrive.startup.{}", unsafe { libc::getuid() })
    }
    fn path() -> PathBuf {
        PathBuf::from(format!("/Library/LaunchDaemons/{}.plist", label()))
    }

    pub fn configured() -> bool {
        path().is_file()
    }

    pub fn setup(_account: Option<&str>) -> Result<(), String> {
        if unsafe { libc::getuid() } == 0 {
            return Err("Set up myDrive from your desktop account.".into());
        }
        let mut identity = Command::new("/usr/bin/id");
        identity.arg("-un");
        let output = quiet(identity)
            .filter(|result| result.status.success())
            .ok_or("Could not identify your macOS account.")?;
        let account = String::from_utf8_lossy(&output.stdout);
        let account = account.trim();
        let executable = cli_path()?;
        let home = env::var("HOME").map_err(|_| "Could not find the home folder.")?;
        if !Path::new(&home).is_absolute() || account.is_empty() {
            return Err("Could not locate your macOS profile.".into());
        }
        let plist = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{}</string>
<key>UserName</key><string>{}</string>
<key>ProgramArguments</key><array><string>{}</string><string>startup</string><string>run</string></array>
<key>EnvironmentVariables</key><dict><key>HOME</key><string>{}</string></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>AssociatedBundleIdentifiers</key><array><string>io.mydrive.MyDrive</string></array>
</dict></plist>"#,
            label(),
            xml(account),
            xml(&executable.to_string_lossy()),
            xml(&home)
        );
        let script = r#"on run argv
set outFile to quoted form of item 2 of argv
set jobName to quoted form of item 3 of argv
set setupCommand to "umask 022; /usr/bin/printf %s " & (quoted form of item 1 of argv) & " > " & outFile & " && /usr/sbin/chown root:wheel " & outFile & " && /bin/chmod 644 " & outFile & " && (/bin/launchctl bootout " & jobName & " >/dev/null 2>&1 || true) && /bin/launchctl enable " & jobName & " && /bin/launchctl bootstrap system " & outFile
do shell script setupCommand with administrator privileges
end run"#;
        let mut command = Command::new("/usr/bin/osascript");
        command
            .args(["-e", script, "--", &plist])
            .arg(path())
            .arg(format!("system/{}", label()));
        if !quiet(command).is_some_and(|response| response.status.success()) {
            return Err("macOS could not register startup. Approve administrator access and use myDrive from Applications.".into());
        }
        Ok(())
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    const UNIT: &str = "mydrive-startup.service";

    fn system(program: &str, arguments: &[&str]) -> Option<std::process::Output> {
        let mut command = Command::new(program);
        command.args(arguments);
        quiet(command)
    }

    pub fn configured() -> bool {
        let uid = unsafe { libc::getuid() }.to_string();
        system("systemctl", &["--user", "is-enabled", UNIT])
            .is_some_and(|result| result.status.success())
            && system("loginctl", &["show-user", &uid, "-p", "Linger", "--value"]).is_some_and(
                |result| {
                    result.status.success()
                        && String::from_utf8_lossy(&result.stdout).trim() == "yes"
                },
            )
    }

    pub fn setup(_account: Option<&str>) -> Result<(), String> {
        let uid = unsafe { libc::getuid() };
        if uid == 0 {
            return Err("Set up myDrive from your desktop account.".into());
        }
        let image =
            env::var("APPIMAGE").map_err(|_| "Run startup setup from the installed AppImage.")?;
        if !Path::new(&image).is_absolute()
            || !Path::new(&image).is_file()
            || image.chars().any(char::is_control)
        {
            return Err("Set up startup from an AppImage at its permanent path.".into());
        }
        let home = env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or("Could not find your home folder.")?;
        let config = env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .unwrap_or_else(|| home.join(".config"));
        let directory = config.join("systemd/user");
        fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        let executable = image
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('%', "%%")
            .replace('$', "$$");
        let unit = format!("[Unit]\nDescription=myDrive headless startup\n\n[Service]\nType=simple\nExecStart=\"{executable}\" --cli startup run\nEnvironment=APPIMAGE_EXTRACT_AND_RUN=1\nRestart=on-failure\nRestartSec=20\n\n[Install]\nWantedBy=default.target\n");
        let mut file = tempfile::NamedTempFile::new_in(&directory).map_err(|e| e.to_string())?;
        file.write_all(unit.as_bytes()).map_err(|e| e.to_string())?;
        file.persist(directory.join(UNIT))
            .map_err(|e| e.to_string())?;
        if !system("loginctl", &["enable-linger", &uid.to_string()])
            .is_some_and(|result| result.status.success())
        {
            return Err(
                "Linux needs permission to keep your systemd user service active before sign-in."
                    .into(),
            );
        }
        for args in [
            &["--user", "daemon-reload"][..],
            &["--user", "enable", "--now", UNIT][..],
        ] {
            if !system("systemctl", args).is_some_and(|result| result.status.success()) {
                return Err("Could not enable the systemd user service.".into());
            }
        }
        Ok(())
    }
}
