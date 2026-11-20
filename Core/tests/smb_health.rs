use serde_json::{json, Value};
use std::{
    io::Write,
    process::{Command, Stdio},
};

fn check(trigger: &str, targets: &Value, previous: &Value) -> Value {
    let mut core = Command::new(env!("CARGO_BIN_EXE_mydrive-core"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    core.stdin
        .take()
        .unwrap()
        .write_all(
            json!({
                "action": "smb.health",
                "payload": { "trigger": trigger, "targets": targets, "previous": previous }
            })
            .to_string()
            .as_bytes(),
        )
        .unwrap();
    let output = core.wait_with_output().unwrap();
    assert!(output.status.success());
    let reply: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    reply["data"].clone()
}

#[test]
fn shared_request_uses_cached_results_and_rechecks_after_a_network_event() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().join("SMB fixture");
    std::fs::create_dir(&root).unwrap();
    let targets = json!([
        {"id": "primary", "probe": {"kind": "path", "value": root}},
        {"id": "alias", "probe": {"kind": "path", "value": root}}
    ]);
    let first = check("view", &targets, &json!({}));
    let mut states = first["states"].clone();
    assert_eq!(states["primary"]["status"], "connected");
    assert_eq!(states["primary"], states["alias"]);
    assert_eq!(first["next_seconds"], 90);

    std::fs::remove_dir(&root).unwrap();
    assert_eq!(check("periodic", &targets, &states)["states"], states);
    let old = states["primary"]["checked_at"].as_u64().unwrap() - 10;
    states["primary"]["checked_at"] = json!(old);
    states["alias"]["checked_at"] = json!(old);
    let one_target = json!([targets[0]]);
    let offline = check("network", &one_target, &states);
    assert_eq!(offline["states"]["primary"]["status"], "unavailable");
    assert!(offline["states"].get("alias").is_none());
    assert_eq!(offline["next_seconds"], 60);
}

#[test]
fn a_wake_refresh_carries_remaining_checks_into_the_next_batch() {
    let directory = tempfile::tempdir().unwrap();
    let checked_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        - 10;
    let mut previous = json!({});
    let targets = (0..9)
        .map(|index| {
            let id = format!("share-{index}");
            let probe = json!({"kind": "path", "value": directory.path().join(&id)});
            previous[&id] = json!({
                "probe": probe, "status": "connected", "checked_at": checked_at, "failures": 0
            });
            json!({"id": id, "probe": probe})
        })
        .collect::<Vec<_>>();
    let targets = json!(targets);
    let first = check("wake", &targets, &previous);
    assert_eq!(first["next_seconds"], 1);
    assert_eq!(first["states"]["share-8"]["status"], "connected");
    let next = check("periodic", &targets, &first["states"]);
    assert_eq!(next["states"]["share-8"]["status"], "unavailable");
}
