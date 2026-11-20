use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    ffi::OsString,
    fs,
    io::ErrorKind,
    net::{TcpStream, ToSocketAddrs},
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const FALLBACK: u64 = 90;
const EVENT_GAP: u64 = 2;
const MAX_BATCH: usize = 8;
const DEADLINE: Duration = Duration::from_secs(3);
const UNAVAILABLE: &str = "unavailable";

#[derive(Deserialize)]
struct Request {
    trigger: String,
    targets: Vec<Target>,
    #[serde(default)]
    previous: HashMap<String, State>,
}

#[derive(Deserialize)]
struct Target {
    id: String,
    probe: Probe,
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
enum Probe {
    Path(String),
    Host(String),
}

#[derive(Clone, Deserialize, Serialize)]
struct State {
    probe: Probe,
    status: String,
    checked_at: u64,
    failures: u8,
}

impl State {
    fn due_in(&self, now: u64, event: bool) -> u64 {
        if self.checked_at > now {
            return 0;
        }
        let interval = if event {
            EVENT_GAP
        } else if self.failures == 0 {
            FALLBACK
        } else {
            (60 << u32::from(self.failures.saturating_sub(1).min(4))).min(900)
        };
        interval.saturating_sub(now - self.checked_at)
    }
}

pub fn check(payload: Value) -> Result<Value, String> {
    let request: Request = serde_json::from_value(payload).map_err(|e| e.to_string())?;
    let event = matches!(
        request.trigger.as_str(),
        "view" | "wake" | "network" | "mount"
    );
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs();
    // Drop stale entries when a bookmark is removed or its address changes.
    let mut states: HashMap<_, _> = request
        .targets
        .iter()
        .filter_map(|target| {
            let state = request.previous.get(&target.id)?;
            (state.probe == target.probe).then(|| (target.id.clone(), state.clone()))
        })
        .collect();
    let mut due: Vec<_> = request
        .targets
        .iter()
        .filter(|target| {
            states
                .get(&target.id)
                .is_none_or(|s| s.due_in(now, event) == 0)
        })
        .collect();
    due.sort_by_key(|target| states.get(&target.id).map(|s| s.checked_at));
    let mut seen = HashSet::new();
    let batch: Vec<_> = due
        .iter()
        .filter(|target| seen.insert(&target.probe))
        .take(MAX_BATCH)
        .map(|target| &target.probe)
        .collect();
    let results = run_probes(batch)?;
    let mut pending = false;
    for target in due {
        if let Some(&status) = results.get(&target.probe) {
            let failures = if status == UNAVAILABLE || status == "access_denied" {
                states
                    .get(&target.id)
                    .map_or(1, |s| s.failures.saturating_add(1))
            } else {
                0
            };
            states.insert(
                target.id.clone(),
                State {
                    probe: target.probe.clone(),
                    status: status.into(),
                    checked_at: now,
                    failures,
                },
            );
        } else {
            pending = true;
        }
    }
    let next = if pending {
        1
    } else {
        states
            .values()
            .map(|state| state.due_in(now, false))
            .min()
            .unwrap_or(FALLBACK)
    };
    Ok(json!({"states": states, "next_seconds": next.clamp(1, FALLBACK)}))
}

fn run_probes(probes: Vec<&Probe>) -> Result<HashMap<&Probe, &'static str>, String> {
    if probes.is_empty() {
        return Ok(HashMap::new());
    }
    let executable = std::env::current_exe().map_err(|e| e.to_string())?;
    let mut results = HashMap::new();
    let mut workers: Vec<(&Probe, Child)> = Vec::new();
    let deadline = Instant::now() + DEADLINE;
    for probe in probes {
        let (kind, value) = match probe {
            Probe::Path(path) => ("path", path),
            Probe::Host(host) => ("host", host),
        };
        let mut command = Command::new(&executable);
        command
            .args(["--smb-health-probe", kind, value])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        match command.spawn() {
            Ok(child) => workers.push((probe, child)),
            Err(_) => {
                results.insert(probe, UNAVAILABLE);
            }
        }
    }
    while !workers.is_empty() {
        workers.retain_mut(|(probe, child)| {
            match child.try_wait() {
                Ok(Some(exit)) => {
                    let status = match exit.code() {
                        Some(0) if matches!(probe, Probe::Path(_)) => "connected",
                        Some(0) => "server_reachable",
                        Some(2) => "access_denied",
                        _ => UNAVAILABLE,
                    };
                    results.insert(*probe, status);
                    false
                }
                Ok(None) if Instant::now() < deadline => true,
                _ => {
                    // An SMB filesystem call may be stuck in the kernel.
                    // Do not wait indefinitely for the killed worker to exit.
                    let _ = child.kill();
                    let _ = child.try_wait();
                    results.insert(*probe, UNAVAILABLE);
                    false
                }
            }
        });
        if !workers.is_empty() {
            thread::sleep(Duration::from_millis(20));
        }
    }
    Ok(results)
}

pub fn probe_worker(mut args: impl Iterator<Item = OsString>) -> i32 {
    let (Some(kind), Some(value)) = (args.next(), args.next()) else {
        return 1;
    };
    if kind == "path" {
        return probe_path(Path::new(&value));
    }
    if kind == "host" {
        if let Some(host) = value.to_str() {
            let host = host.trim_start_matches('[').trim_end_matches(']');
            if let Ok(addresses) = (host, 445).to_socket_addrs() {
                for address in addresses {
                    if TcpStream::connect_timeout(&address, Duration::from_millis(650)).is_ok() {
                        return 0;
                    }
                }
            }
        }
    }
    1
}

fn probe_path(path: &Path) -> i32 {
    if !path.is_absolute() {
        return 1;
    }
    match fs::metadata(path) {
        Ok(metadata) if metadata.is_dir() => 0,
        Err(error) if error.kind() == ErrorKind::PermissionDenied => 2,
        _ => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn healthy_checks_are_infrequent_and_failures_back_off() {
        let mut state = State {
            probe: Probe::Host("nas".into()),
            status: "server_reachable".into(),
            checked_at: 1000,
            failures: 0,
        };
        assert_eq!(state.due_in(1012, false), 78);
        assert_eq!(state.due_in(1001, true), 1);
        state.failures = 2;
        assert_eq!(state.due_in(1012, false), 108);
        assert_eq!(state.due_in(1012, true), 0);
        state.failures = u8::MAX;
        assert_eq!(state.due_in(1000, false), 900);
        assert_eq!(state.due_in(999, false), 0);
    }

    #[test]
    fn path_probe_checks_only_the_root_directory() {
        let root = tempfile::tempdir().unwrap();
        let item = root.path().join("a file");
        fs::write(&item, "data").unwrap();
        assert_eq!(probe_path(root.path()), 0);
        assert_eq!(probe_path(&item), 1);
        assert_eq!(probe_path(&root.path().join("absent")), 1);
    }
}
