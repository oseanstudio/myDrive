//! REST adapter shared by the native shells and the background engine manager.
use reqwest::{blocking::Client, Method};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{fs, io::Read, path::Path, time::Duration};
use url::Url;

mod schedule;

#[derive(Clone, Deserialize, Serialize, Default)]
pub struct Connection {
    pub endpoint: String,
    pub api_key: String,
    #[serde(default)]
    pub certificate_pem: String,
}
#[derive(Clone)]
pub struct Api {
    client: Client,
    base: Url,
    key: String,
}
impl Api {
    pub fn new(c: &Connection) -> Result<Self, String> {
        Self::with_timeout(c, Duration::from_secs(15))
    }
    pub fn available(c: &Connection) -> bool {
        Self::with_timeout(c, Duration::from_millis(750)).is_ok_and(|api| api.ping().is_ok())
    }
    #[cfg(windows)]
    pub(crate) fn shutdown_owned(c: &Connection) {
        if let Ok(api) = Self::with_timeout(c, Duration::from_millis(750)) {
            let _ = api.call("POST", &["rest", "system", "shutdown"], &[], None);
        }
    }
    fn with_timeout(c: &Connection, timeout: Duration) -> Result<Self, String> {
        let base =
            Url::parse(&c.endpoint).map_err(|_| "Enter a valid local Syncthing API address.")?;
        let local = base.host_str().is_some_and(|h| {
            h.eq_ignore_ascii_case("localhost")
                || h.trim_matches(['[', ']'])
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|ip| ip.is_loopback())
        });
        if !local
            || !["http", "https"].contains(&base.scheme())
            || !base.username().is_empty()
            || base.password().is_some()
            || base.query().is_some()
            || base.fragment().is_some()
            || base.path() != "/"
        {
            return Err("Syncthing connections must use a loopback HTTP(S) address without credentials or a URL path.".into());
        }
        if c.api_key.trim().is_empty() {
            return Err("Syncthing's API key is missing. Choose its local config.xml or enter the API key in Settings.".into());
        }
        let mut builder = Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(timeout.min(Duration::from_secs(4)))
            .timeout(timeout);
        if !c.certificate_pem.is_empty() {
            builder = builder.add_root_certificate(
                reqwest::Certificate::from_pem(c.certificate_pem.as_bytes())
                    .map_err(|_| "Cannot read the local Syncthing HTTPS certificate.")?,
            );
        }
        Ok(Self {
            client: builder.build().map_err(|e| e.to_string())?,
            base,
            key: c.api_key.clone(),
        })
    }
    fn call(
        &self,
        verb: &str,
        segments: &[&str],
        query: &[(&str, &str)],
        body: Option<&Value>,
    ) -> Result<Value, String> {
        let mut url = self.base.clone();
        {
            let mut path = url.path_segments_mut().map_err(|_| "Invalid API URL")?;
            path.clear();
            path.extend(segments);
        }
        url.query_pairs_mut().extend_pairs(query.iter().copied());
        let mut request = self
            .client
            .request(
                Method::from_bytes(verb.as_bytes()).map_err(|e| e.to_string())?,
                url,
            )
            .header("X-API-Key", &self.key);
        if let Some(body) = body {
            request = request.json(body);
        }
        let response = request.send().map_err(|e| {
            if e.is_connect() {
                "Syncthing is not reachable. Refresh to reconnect or restart the background engine."
                    .to_string()
            } else if e.is_timeout() {
                "Syncthing did not respond in time. Try again when its scan completes.".to_string()
            } else {
                "Cannot contact the local Syncthing API. Check the address and HTTPS certificate."
                    .to_string()
            }
        })?;
        let status = response.status();
        if !status.is_success() {
            if status.is_server_error() && segments == ["rest", "db", "scan"] {
                // The scan endpoint returns a short plain-text reason with HTTP 500.
                let mut reason = String::new();
                let _ = response.take(2048).read_to_string(&mut reason);
                return Err(scan_failure(&reason, status.as_u16()));
            }
            return Err(match status.as_u16() {
                401 | 403 => {
                    "Syncthing rejected the API key. Reconnect using its current local config.xml."
                        .into()
                }
                404 => "The requested Syncthing folder or API resource no longer exists.".into(),
                _ => format!(
                    "Syncthing returned HTTP {}. Check its folder errors before retrying.",
                    status.as_u16()
                ),
            });
        }
        let text = response
            .text()
            .map_err(|_| "Cannot read Syncthing's response.")?;
        if text.trim().is_empty() {
            Ok(Value::Null)
        } else {
            serde_json::from_str(&text)
                .map_err(|_| "Syncthing returned an unexpected response format.".into())
        }
    }
    fn get(&self, segments: &[&str], query: &[(&str, &str)]) -> Result<Value, String> {
        self.call("GET", segments, query, None)
    }
    pub fn ping(&self) -> Result<Value, String> {
        self.get(&["rest", "system", "ping"], &[])
    }
    fn folder(&self, id: &str) -> Result<Value, String> {
        if id.is_empty() {
            return Err("Choose a Syncthing folder.".into());
        }
        self.get(&["rest", "config", "folders", id], &[])
    }

    fn folder_errors(&self, id: &str, preview: bool) -> Result<Value, String> {
        if id.is_empty() {
            return Err("Choose a Syncthing folder.".into());
        }
        let mut query = vec![("folder", id)];
        if preview {
            query.extend([("page", "1"), ("perpage", "1")]);
        }
        let mut result = match self.get(&["rest", "folder", "errors"], &query) {
            Ok(result) => result,
            Err(error) => {
                let folder = self.folder(id).map_err(|_| error.clone())?;
                let reason = unavailable_sync_root(&folder).ok_or(error)?;
                json!({"errors": [{"path": folder["path"], "error": reason}]})
            }
        };
        let rows = if result.is_array() {
            result.as_array_mut()
        } else {
            result.get_mut("errors").and_then(Value::as_array_mut)
        };
        for row in rows.into_iter().flatten() {
            if let Some(advice) = row["error"].as_str().and_then(folder_error_advice) {
                row["advice"] = json!(advice);
            }
        }
        Ok(result)
    }

    fn folder_attention(&self, data: &Value) -> Result<Value, String> {
        let ids = data["folder_ids"]
            .as_array()
            .ok_or("Select the folders that need attention.")?;
        let mut report = serde_json::Map::new();
        for chunk in ids.chunks(4) {
            std::thread::scope(|scope| {
                let workers: Vec<_> = chunk
                    .iter()
                    .filter_map(Value::as_str)
                    .filter(|id| !id.is_empty() && !report.contains_key(*id))
                    .map(|id| (id, scope.spawn(move || self.folder_errors(id, true))))
                    .collect();
                for (id, worker) in workers {
                    let details = match worker.join() {
                        Ok(Ok(response)) => {
                            let errors = response
                                .as_array()
                                .or_else(|| response["errors"].as_array());
                            json!({"errors": errors})
                        }
                        Ok(Err(error)) => json!({"failure": error}),
                        Err(_) => json!({"failure": "Could not load the folder errors."}),
                    };
                    report.insert(id.to_string(), details);
                }
            });
        }
        Ok(Value::Object(report))
    }

    fn snapshot_with_schedule(&self, data_dir: &Path) -> Result<Value, String> {
        let version = self.get(&["rest", "system", "version"], &[])?;
        let system = self.get(&["rest", "system", "status"], &[])?;
        let mut folders = self.get(&["rest", "config", "folders"], &[])?;
        let scheduled = schedule::reconcile(self, data_dir, &system, &mut folders);
        let configured = self.get(&["rest", "config", "devices"], &[])?;
        let connections = self
            .get(&["rest", "system", "connections"], &[])
            .unwrap_or(json!({}));
        let errors = self
            .get(&["rest", "system", "error"], &[])
            .unwrap_or(json!({"errors":[]}));
        let mut results = Vec::new();
        // Bound concurrency. Large installations must not spawn a thread per folder.
        for chunk in folders
            .as_array()
            .ok_or("Unexpected Syncthing folder list.")?
            .chunks(4)
        {
            let group = std::thread::scope(|scope| {
                chunk
                    .iter()
                    .map(|folder| {
                        scope.spawn(move || {
                            let id = folder["id"].as_str().unwrap_or("");
                            let status = self.get(&["rest", "db", "status"], &[("folder", id)]);
                            let mut result = pick(
                                folder,
                                &[
                                    "id",
                                    "label",
                                    "path",
                                    "type",
                                    "paused",
                                    "versioning",
                                    "rescanIntervalS",
                                    "fsWatcherEnabled",
                                ],
                            );
                            if let Some(until) = folder["paused_until"].as_i64() {
                                result["paused_until"] = json!(until);
                            }
                            result["device_count"] =
                                json!(folder["devices"].as_array().map_or(0, Vec::len));
                            result["device_ids"] = json!(folder["devices"]
                                .as_array()
                                .map(|items| items
                                    .iter()
                                    .filter_map(|d| d["deviceID"].as_str())
                                    .collect::<Vec<_>>())
                                .unwrap_or_default());
                            match status {
                                Ok(s) => {
                                    if let Some(error) =
                                        s["error"].as_str().filter(|e| !e.is_empty())
                                    {
                                        result["error"] = json!(error);
                                    } else if s["state"] == "error" {
                                        result["error"] = json!("Syncthing could not sync this folder.");
                                    }
                                    result["status"] = pick(
                                        &s,
                                        &[
                                            "state",
                                            "stateChanged",
                                            "globalBytes",
                                            "globalFiles",
                                            "globalDirectories",
                                            "localBytes",
                                            "localFiles",
                                            "inSyncBytes",
                                            "inSyncFiles",
                                            "needBytes",
                                            "needFiles",
                                            "needDeletes",
                                            "pullErrors",
                                            "receiveOnlyChangedFiles",
                                            "errors",
                                        ],
                                    )
                                }
                                Err(e) => result["error"] = json!(e),
                            }
                            if let Some((can_relocate, advice)) = result["error"]
                                .as_str()
                                .map(|error| (missing_sync_root(error), folder_error_advice(error)))
                            {
                                if can_relocate {
                                    result["can_relocate"] = json!(true);
                                }
                                if let Some(advice) = advice {
                                    result["error_advice"] = json!(advice);
                                }
                            }
                            result
                        })
                    })
                    .collect::<Vec<_>>()
                    .into_iter()
                    .map(|t| {
                        t.join()
                            .unwrap_or(json!({"error":"Folder status worker failed."}))
                    })
                    .collect::<Vec<_>>()
            });
            results.extend(group);
        }
        let devices = configured
            .as_array()
            .unwrap_or(&Vec::new())
            .iter()
            .map(|d| {
                let id = d["deviceID"].as_str().unwrap_or("");
                let mut item = pick(d, &["deviceID", "name", "paused"]);
                item["is_local"] = json!(system["myID"].as_str() == Some(id));
                item["connection"] = pick(
                    &connections["connections"][id],
                    &[
                        "connected",
                        "inBytesTotal",
                        "outBytesTotal",
                        "clientVersion",
                        "type",
                        "startedAt",
                    ],
                );
                item
            })
            .collect::<Vec<_>>();
        Ok(
            json!({"version":version["version"],"os":version["os"],"uptime":system["uptime"],"folders":results,"devices":devices,"traffic":pick(&connections["total"],&["at","inBytesTotal","outBytesTotal"]),"errors":errors["errors"],"scheduled_pause_error":scheduled.err()}),
        )
    }

    fn device_progress(&self, id: &str) -> Result<Value, String> {
        let folder = self.folder(id)?;
        let local = self.get(&["rest", "system", "status"], &[])?;
        let devices = self.get(&["rest", "config", "devices"], &[])?;
        let connections = self.get(&["rest", "system", "connections"], &[])?;
        let members = folder["devices"].as_array().ok_or("Unexpected folder device list.")?;
        let mut rows = Vec::new();
        for group in members.chunks(4) {
            std::thread::scope(|scope| {
                let workers = group.iter().filter_map(|device| {
                    let peer = device["deviceID"].as_str()?;
                    if local["myID"].as_str() == Some(peer) { return None; }
                    let configured = devices.as_array().and_then(|ds| ds.iter().find(|d| d["deviceID"] == peer));
                    let name = configured.and_then(|d| d["name"].as_str()).filter(|s| !s.trim().is_empty())
                        .map(str::to_owned).unwrap_or_else(|| peer.chars().take(7).collect());
                    let stopped = configured.is_some_and(|d| d["paused"] == true) || folder["paused"] == true;
                    let online = connections["connections"][peer]["connected"] == true;
                    Some(scope.spawn(move || {
                        let mut row = json!({"device_id": peer, "name": name});
                        let state = if stopped { "Paused" } else if !online { "Offline" } else {
                            match self.get(&["rest", "db", "completion"], &[("folder", id), ("device", peer)]) {
                                Ok(result) => match result["remoteState"].as_str() {
                                    Some("paused") => "Paused",
                                    Some("notSharing") => "Waiting for acceptance",
                                    Some("unknown") => "Progress unavailable",
                                    _ => {
                                        row["remaining_bytes"] = result["needBytes"].clone();
                                        row["remaining_items"] = result["needItems"].clone();
                                        row["remaining_deletes"] = result["needDeletes"].clone();
                                        row["percent"] = result["completion"].clone();
                                        if result["needBytes"] == 0 && result["needItems"] == 0 && result["needDeletes"] == 0 {
                                            "Up to date"
                                        } else if result["completion"].as_f64().is_some() { "Syncing" } else { "Progress unavailable" }
                                    }
                                },
                                Err(error) => { row["error"] = json!(error); "Progress unavailable" }
                            }
                        };
                        row["state"] = json!(state);
                        row
                    }))
                }).collect::<Vec<_>>();
                rows.extend(workers.into_iter().filter_map(|worker| worker.join().ok()));
            });
        }
        Ok(json!({"devices":rows}))
    }
    pub fn browse(&self, id: &str, path: &str) -> Result<Value, String> {
        let folder = self.folder(id)?;
        let path = crate::model::clean_path(path)?;
        let remote = self.get(
            &["rest", "db", "browse"],
            &[("folder", id), ("prefix", &path), ("levels", "0")],
        )?;
        let lines = self.ignores(id)?;
        let rules = parse_managed(&lines)?;
        let on_demand = on_demand_mode(&lines)?;
        let mut entries = std::collections::BTreeMap::<String, Value>::new();
        let mut local_limit_reached = false;
        if let Some(items) = remote.as_array() {
            for item in items {
                let Some(name) = item["name"].as_str() else {
                    continue;
                };
                if name.contains('/') || crate::model::clean_path(name).is_err() {
                    continue;
                }
                entries.insert(name.to_string(),json!({"name":name,"path":crate::model::child(&path,name),"is_dir":item["type"].as_str()==Some("FILE_INFO_TYPE_DIRECTORY"),"size":item["size"],"modified":item["modTime"],"remote":true,"local":false}));
            }
        }
        // Include local ignored files, which may be absent from the global model.
        let case_names = browser_case_names(&entries);
        let root = Path::new(
            folder["path"]
                .as_str()
                .ok_or("Syncthing did not return a folder path.")?,
        );
        if let (Ok(canonical_root), Ok(canonical_dir)) =
            (root.canonicalize(), root.join(&path).canonicalize())
        {
            if !canonical_dir.starts_with(&canonical_root) {
                return Err("A symbolic link points outside the synced folder.".into());
            }
            if let Ok(items) = fs::read_dir(&canonical_dir) {
                for (index, item) in items.flatten().enumerate() {
                    if index >= 10000 {
                        local_limit_reached = true;
                        break;
                    }
                    let name = item.file_name().to_string_lossy().to_string();
                    if [".stfolder", ".stignore", ".stversions"].contains(&name.as_str())
                        || name.starts_with(".syncthing.")
                        || name.starts_with("~syncthing~")
                    {
                        continue;
                    }
                    if crate::model::clean_path(&name).is_err() {
                        continue;
                    }
                    let metadata = item.file_type().map_err(|e| e.to_string())?;
                    if metadata.is_symlink() {
                        continue;
                    }
                    let key = local_browser_key(&entries, &case_names, &canonical_dir, &name);
                    let entry=entries.entry(key).or_insert_with(||json!({"name":name,"path":crate::model::child(&path,&name),"is_dir":metadata.is_dir(),"size":item.metadata().map(|m|m.len()).unwrap_or(0),"remote":false}));
                    entry["local"] = json!(true);
                }
            }
        }
        let by_path: std::collections::HashMap<_, _> =
            rules.iter().map(|rule| (rule.path.as_str(), rule)).collect();
        let mut entries = entries
            .into_values()
            .map(|mut entry| {
                if let Some(original) = entry["name"].as_str().and_then(alternative_name) {
                    entry["alternative_for"] = json!(original);
                }
                let path = entry["path"].as_str().unwrap_or("");
                let direct = by_path.get(path);
                entry["selection"] = json!(match direct {
                    Some(rule) if rule.sync => "sync",
                    Some(_) => "exclude",
                    None => "existing",
                });
                let path = entry["path"].as_str().unwrap_or("");
                let mut ancestor = path;
                let mut effective = by_path.get(path).copied();
                while effective.is_none() {
                    let Some((parent, _)) = ancestor.rsplit_once('/') else { break };
                    ancestor = parent;
                    effective = by_path.get(parent).copied().filter(|rule| rule.is_dir);
                }
                entry["pinned"] = json!(on_demand && effective.is_some_and(|rule| rule.sync));
                entry
            })
            .collect::<Vec<_>>();
        entries.sort_by(|a, b| {
            b["is_dir"]
                .as_bool()
                .cmp(&a["is_dir"].as_bool())
                .then(a["name"].as_str().cmp(&b["name"].as_str()))
        });
        Ok(
            json!({"entries":entries,"rules":rules,"ignore":lines,"on_demand":on_demand,"path":path,"local_limit_reached":local_limit_reached,"folder":pick(&folder,&["id","label","path","type"])}),
        )
    }
    pub fn ignores(&self, id: &str) -> Result<Vec<String>, String> {
        let data = self.get(&["rest", "db", "ignores"], &[("folder", id)])?;
        serde_json::from_value(data["ignore"].clone())
            .map_err(|_| "Syncthing did not return valid ignore rules.".into())
    }
    /// Bounded event poll for the shell's recent-updates feed. A missing or
    /// zero `since` returns the daemon's latest buffered events; later polls
    /// pass the previous cursor. The long-poll timeout stays inside the
    /// client's 15-second request ceiling.
    pub fn events(&self, since: u64, timeout_s: u64) -> Result<Value, String> {
        let since_param = since.to_string();
        let timeout_param = timeout_s.clamp(1, 10).to_string();
        let mut query: Vec<(&str, &str)> = vec![(
            "events",
            "ItemFinished,StateChanged,DeviceConnected,DeviceDisconnected,FolderErrors,FolderSummary",
        )];
        if since > 0 {
            query.push(("since", &since_param));
        }
        query.push(("timeout", &timeout_param));
        let data = self.get(&["rest", "events"], &query)?;
        let list = data.as_array().cloned().unwrap_or_default();
        let last_id = list
            .iter()
            .filter_map(|event| event["id"].as_u64())
            .max()
            .unwrap_or(since);
        Ok(json!({"events":list,"last_id":last_id}))
    }
    pub fn execute(&self, action: &str, data: &Value, data_dir: &Path) -> Result<Value, String> {
        let id = data["folder_id"].as_str().unwrap_or("");
        match action {
            "share.preview" | "share" => self.share(data, action == "share", data_dir),
            "snapshot" => self.snapshot_with_schedule(data_dir),
            "device_progress" => self.device_progress(id),
            "attention" => self.folder_attention(data),
            "relocate" => self.relocate(id, data),
            "browse" => self.browse(id, data["path"].as_str().unwrap_or("")),
            "ignores" => {
                self.folder(id)?;
                Ok(json!({"ignore":self.ignores(id)?}))
            }
            "pause" | "pause_until" => schedule::change(self, data_dir, id, action, data),
            "stop" => {
                let folder = self.folder(id)?;
                let path = folder["path"]
                    .as_str()
                    .ok_or("The sync folder path is missing.")?;
                if data["expected_path"].as_str() != Some(path) {
                    return Err(
                        "The folder configuration changed. Refresh before stopping syncing.".into(),
                    );
                }
                if data_dir.as_os_str().is_empty() {
                    return Err("An application data directory is required to back up the sync configuration.".into());
                }
                let mut saved = folder.clone();
                // Folder encryption credentials must not be copied into a plain JSON backup.
                if let Some(devices) = saved["devices"].as_array_mut() {
                    for device in devices {
                        if let Some(fields) = device.as_object_mut() {
                            fields.remove("encryptionPassword");
                        }
                    }
                }
                let directory = data_dir.join("syncthing-backups");
                fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
                let backup = directory.join(format!(
                    "stop-{}-{}.json",
                    hex::encode(sha2::Sha256::digest(id.as_bytes())),
                    chrono::Utc::now().format("%Y%m%dT%H%M%S%.9f")
                ));
                let mut output = fs::OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(&backup)
                    .map_err(|e| format!("Cannot back up this folder's sync configuration: {e}"))?;
                serde_json::to_writer_pretty(&mut output,&json!({"folder":saved,"ignore":self.ignores(id).ok(),"encryption_credentials_omitted":true})).map_err(|e| e.to_string())?;
                output.sync_all().map_err(|e| e.to_string())?;
                if self.folder(id)? != folder {
                    return Err("The folder configuration changed while preparing to stop. Refresh and try again.".into());
                }
                self.call("DELETE", &["rest", "config", "folders", id], &[], None)?;
                let remaining = self.get(&["rest", "config", "folders"], &[])?;
                if remaining
                    .as_array()
                    .is_none_or(|all| all.iter().any(|f| f["id"].as_str() == Some(id)))
                {
                    return Err("The folder is still configured in Syncthing. Refresh to check whether syncing stopped.".into());
                }
                Ok(
                    json!({"stopped":true,"folder_id":id,"path":path,"backup":friendly_path(&backup),"files_kept":true}),
                )
            }
            "scan" => {
                let folder = self.folder(id)?;
                if let Some(reason) = unavailable_sync_root(&folder) {
                    return Err(scan_failure(reason, 500));
                }
                self.call("POST", &["rest", "db", "scan"], &[("folder", id)], None)?;
                Ok(Value::Null)
            }
            "errors" => self.folder_errors(id, false),
            "events" => {
                let since = data["since"].as_u64().unwrap_or(0);
                let timeout_s = data["timeout_s"].as_u64().unwrap_or(5);
                self.events(since, timeout_s)
            }
            "need" => {
                self.folder(id)?;
                let raw = self.get(
                    &["rest", "db", "need"],
                    &[("folder", id), ("page", "1"), ("perpage", "50")],
                )?;
                // /rest/db/need wraps each bucket as {"items": [...], ...};
                // the shells expect bare arrays of file rows, so unwrap them.
                let mut buckets = serde_json::Map::new();
                for section in ["progress", "queued", "rest"] {
                    let value = match raw.get(section) {
                        Some(Value::Object(bucket)) => bucket
                            .get("items")
                            .cloned()
                            .filter(Value::is_array)
                            .unwrap_or_else(|| Value::Array(Vec::new())),
                        other => other.cloned().unwrap_or(Value::Null),
                    };
                    buckets.insert(section.to_string(), value);
                }
                Ok(Value::Object(buckets))
            }
            "versions" => {
                self.folder(id)?;
                self.get(&["rest", "folder", "versions"], &[("folder", id)])
            }
            "protect" => {
                let folder = self.folder(id)?;
                let mut versioning = folder["versioning"].clone();
                if versioning["type"].as_str().unwrap_or("").is_empty() {
                    versioning = json!({"type":"simple","params":{"keep":"20","cleanoutDays":"0"},"cleanupIntervalS":3600,"fsPath":"","fsType":"basic"});
                }
                self.call(
                    "PATCH",
                    &["rest", "config", "folders", id],
                    &[],
                    Some(&json!({"versioning":versioning,"maxConflicts":-1})),
                )?;
                Ok(json!({"versioning":versioning,"max_conflicts":-1}))
            }
            "local_file" => self.open_local_file(id, data, data_dir),
            "restore" => {
                let folder = self.folder(id)?;
                let path = crate::model::clean_path(
                    data["path"]
                        .as_str()
                        .ok_or("Choose a saved file version.")?,
                )?;
                let time = data["version_time"]
                    .as_str()
                    .ok_or("Choose a version timestamp.")?;
                let versions = self.get(&["rest", "folder", "versions"], &[("folder", id)])?;
                if !versions[&path]
                    .as_array()
                    .is_some_and(|all| all.iter().any(|v| v["versionTime"].as_str() == Some(time)))
                {
                    return Err(
                        "That saved version is no longer available. Refresh version history."
                            .into(),
                    );
                }
                // Syncthing simple/staggered archives use second-resolution names.
                // Restoring in the same second would archive the current file over
                // the very version being restored. Cross that boundary first.
                if chrono::DateTime::parse_from_rfc3339(time)
                    .is_ok_and(|t| t.timestamp() == chrono::Utc::now().timestamp())
                {
                    std::thread::sleep(Duration::from_millis(1100));
                }
                let root = Path::new(folder["path"].as_str().ok_or("Missing sync root.")?)
                    .canonicalize()
                    .map_err(|e| e.to_string())?;
                let target = root.join(&path);
                let mut backup = None;
                if target.exists() {
                    let target = target.canonicalize().map_err(|e| e.to_string())?;
                    if !target.starts_with(&root) || !target.is_file() {
                        return Err("Cannot restore outside the sync root.".into());
                    }
                    let metadata = fs::metadata(&target).map_err(|e| e.to_string())?;
                    let directory = data_dir.join("syncthing-restore-backups");
                    fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
                    let backup_directory = directory.join(format!(
                        "{}-{}",
                        chrono::Utc::now().format("%Y%m%dT%H%M%S%.9f"),
                        hex::encode(sha2::Sha256::digest(format!("{id}/{path}").as_bytes()))
                    ));
                    fs::create_dir(&backup_directory).map_err(|e| e.to_string())?;
                    let output = backup_directory.join(
                        target
                            .file_name()
                            .ok_or("The current file name is unavailable.")?,
                    );
                    fs::copy(&target, &output).map_err(|e| {
                        format!("Cannot protect the current file before restore: {e}")
                    })?;
                    let after = fs::metadata(&target).map_err(|e| e.to_string())?;
                    if metadata.len() != after.len()
                        || metadata.modified().ok() != after.modified().ok()
                    {
                        return Err("The current file changed while preparing restore. Close its editor and try again.".into());
                    }
                    backup = Some(output.to_string_lossy().to_string());
                } else if !target
                    .parent()
                    .and_then(|p| p.canonicalize().ok())
                    .is_some_and(|parent| parent.starts_with(&root))
                {
                    return Err("The restore destination is outside the sync folder or its parent is unavailable.".into());
                }
                let response = self.call(
                    "POST",
                    &["rest", "folder", "versions"],
                    &[("folder", id)],
                    Some(&json!({path.clone():time})),
                )?;
                if let Some(error) = response.get(&path).and_then(Value::as_str) {
                    return Err(format!("Syncthing could not restore this version: {error}"));
                }
                self.call(
                    "POST",
                    &["rest", "db", "scan"],
                    &[("folder", id), ("sub", &path)],
                    None,
                )?;
                Ok(json!({"restored":true,"backup":backup}))
            }
            "selection.preview" | "selection.apply" | "selection.mode" => {
                let expected: Vec<String> = serde_json::from_value(data["expected_ignore"].clone())
                    .map_err(|_| "Reload the folder before editing its selection.")?;
                let rules = if action == "selection.mode" {
                    parse_managed(&expected)?
                } else {
                    serde_json::from_value(data["rules"].clone())
                        .map_err(|_| "Invalid selection rules.")?
                };
                let mode = if action == "selection.mode" {
                    data["on_demand"].as_bool().ok_or("Choose a download mode.")?
                } else {
                    on_demand_mode(&expected)?
                };
                self.update_selection(id, &expected, &rules, mode, data_dir, action == "selection.preview")
            }
            _ => Err("Unknown Syncthing action.".into()),
        }
    }
    fn update_selection(
        &self,
        id: &str,
        expected: &[String],
        rules: &[SelectionRule],
        mode: bool,
        data_dir: &Path,
        preview: bool,
    ) -> Result<Value, String> {
        let folder = self.folder(id)?;
        if mode && matches!(folder["type"].as_str(), Some("sendonly" | "receiveencrypted")) {
            return Err("Download when needed requires a folder that can receive ordinary files.".into());
        }
        let directory = data_dir.join("syncthing-backups");
        fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        let key = hex::encode(sha2::Sha256::digest(id.as_bytes()));
        let lock = fs::OpenOptions::new().read(true).write(true).create(true).truncate(false)
            .open(directory.join(format!("{key}.lock"))).map_err(|e| e.to_string())?;
        lock.try_lock().map_err(|_| "Another myDrive operation is changing these selections. Refresh and try again.")?;
        let current = self.ignores(id)?;
        if current != expected {
            return Err("Ignore rules changed. Reload the folder before applying your selection.".into());
        }
        let os = self.get(&["rest", "system", "version"], &[])?;
        let updated = render_rules_for_mode(&current, rules, os["os"].as_str() == Some("windows"), mode)?;
        if preview || updated == current {
            return Ok(json!({"ignore":updated,"rules":rules,"on_demand":mode}));
        }
        let backup = directory.join(format!("{key}-{}.json", chrono::Utc::now().format("%Y%m%dT%H%M%S%.9f")));
        fs::write(&backup, serde_json::to_vec_pretty(&json!({"folder_id":id,"ignore":current}))
            .map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        if self.ignores(id)? != expected || self.folder(id)?["path"] != folder["path"] {
            return Err("The folder changed while preparing the update. No selection was changed.".into());
        }
        self.call("POST", &["rest", "db", "ignores"], &[("folder", id)], Some(&json!({"ignore":updated})))?;
        if self.ignores(id)? != updated {
            return Err("Syncthing did not confirm the new selection. Refresh the folder.".into());
        }
        Ok(json!({"ignore":updated,"rules":rules,"on_demand":mode,"backup":backup.to_string_lossy()}))
    }

    fn open_local_file(&self, id: &str, data: &Value, data_dir: &Path) -> Result<Value, String> {
        let path = crate::model::clean_path(data["path"].as_str().ok_or("Choose a file.")?)?;
        if path.is_empty() { return Err("Choose a file.".into()); }
        let folder = self.folder(id)?;
        let root = Path::new(folder["path"].as_str().ok_or("The sync folder path is missing.")?)
            .canonicalize().map_err(|_| "The local sync folder is unavailable.")?;
        let target = root.join(&path);
        if let Some(path) = openable_sync_file(&root, &target)? {
            return Ok(json!({"pending":false,"path":path}));
        }
        if folder["paused"].as_bool() == Some(true) {
            return Err("Resume this folder to download its files.".into());
        }
        let current = self.ignores(id)?;
        if on_demand_mode(&current)? {
            let catalog = self.get(&["rest", "db", "file"], &[("folder", id), ("file", &path)])?;
            if catalog["global"]["type"].as_str() != Some("FILE_INFO_TYPE_FILE")
                || catalog["global"]["deleted"].as_bool() == Some(true)
                || catalog["global"]["invalid"].as_bool() == Some(true) {
                return Err("A device has not announced a downloadable version of this file.".into());
            }
            let mut rules = parse_managed(&current)?;
            set_download_rule(&mut rules, &path);
            self.update_selection(id, &current, &rules, true, data_dir, false)?;
        }
        self.call("POST", &["rest", "db", "prio"], &[("folder", id), ("file", &path)], None)?;
        let seconds = data["wait_seconds"].as_u64().unwrap_or(0).min(8);
        let deadline = std::time::Instant::now() + Duration::from_secs(seconds);
        while std::time::Instant::now() < deadline {
            if let Some(path) = openable_sync_file(&root, &target)? {
                return Ok(json!({"pending":false,"path":path}));
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        Ok(json!({"pending":true}))
    }

    fn relocate(&self, id: &str, data: &Value) -> Result<Value, String> {
        let folder = self.folder(id)?;
        let old = folder["path"].as_str().ok_or("The configured folder has no path.")?;
        if data["expected_path"].as_str() != Some(old) {
            return Err("The folder location changed. Refresh and choose its new location again.".into());
        }
        if !matches!(folder["filesystemType"].as_str(), None | Some("" | "basic")) {
            return Err("Choose a local folder managed by Syncthing's basic filesystem.".into());
        }
        let selected = Path::new(data["local_path"].as_str().ok_or("Choose the moved folder.")?);
        let root = selected.canonicalize().map_err(|_| "The moved folder is unavailable.")?;
        if !selected.is_absolute() || !root.is_dir() || root.parent().is_none() {
            return Err("Choose the moved folder on this computer.".into());
        }
        let previous_root = configured_share_path(old)?;
        if previous_root == root {
            return Err("Choose the folder's new location.".into());
        }
        let marker = sync_marker(&folder);
        validate_moved_root(&previous_root, &root, marker)?;
        let folders = self.get(&["rest", "config", "folders"], &[])?;
        let mut proposed = folders.clone();
        let current = proposed.as_array_mut()
            .and_then(|rows| rows.iter_mut().find(|row| row["id"] == id))
            .filter(|row| **row == folder)
            .ok_or("The folder configuration changed. Refresh and try again.")?;
        let destination = friendly_path(&root);
        current["path"] = json!(destination);
        let system = self.get(&["rest", "system", "status"], &[])?;
        let local = system["myID"].as_str().ok_or("Cannot identify the local Syncthing device.")?;
        // Reuse the same duplicate and nested-device checks as adding a share.
        plan_share(&root, &proposed, local, local)?;
        if self.get(&["rest", "config", "folders"], &[])? != folders {
            return Err("The sync configuration changed. Refresh and try again.".into());
        }
        validate_moved_root(&previous_root, &root, marker)?;
        self.call("PATCH", &["rest", "config", "folders", id], &[], Some(&json!({"path":destination})))?;
        let actual = self.folder(id)?;
        let saved = actual["path"].as_str().and_then(|path| configured_share_path(path).ok());
        if saved.as_deref() != Some(root.as_path()) {
            return Err("Syncthing did not confirm the new folder location. Refresh to see the saved path.".into());
        }
        Ok(json!({"folder_id": id, "path": destination, "paused": actual["paused"]}))
    }

    fn share(&self, data: &Value, apply: bool, data_dir: &Path) -> Result<Value, String> {
        let input = data["local_path"]
            .as_str()
            .ok_or("Choose a local folder to sync.")?;
        let root = Path::new(input)
            .canonicalize()
            .map_err(|_| "The selected folder does not exist or cannot be opened.")?;
        if !root.is_dir() {
            return Err("Choose a folder, then select individual files inside it.".into());
        }
        if root.parent().is_none() {
            return Err("Choose a specific folder instead of an entire disk.".into());
        }
        let target = data["device_id"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("Choose one of your existing Syncthing devices.")?;
        let devices = self.get(&["rest", "config", "devices"], &[])?;
        let device = devices
            .as_array()
            .and_then(|all| all.iter().find(|d| d["deviceID"].as_str() == Some(target)))
            .ok_or("That device is no longer configured in Syncthing.")?;
        let system = self.get(&["rest", "system", "status"], &[])?;
        let local_id = system["myID"]
            .as_str()
            .ok_or("Cannot identify the local Syncthing device.")?;
        if target == local_id {
            return Err("Choose another device; this is the local computer.".into());
        }
        if device["untrusted"].as_bool().unwrap_or(false) {
            return Err("This device requires encrypted sharing. Configure its encryption password in Syncthing before sharing from myDrive.".into());
        }
        let folders = self.get(&["rest", "config", "folders"], &[])?;
        let (existing, overlaps) = plan_share(&root, &folders, local_id, target)?;
        let generated_id = format!(
            "mydrive-{}",
            &hex::encode(sha2::Sha256::digest(root.to_string_lossy().as_bytes()))[..16]
        );
        if existing.is_none()
            && folders
                .as_array()
                .is_some_and(|all| all.iter().any(|f| f["id"].as_str() == Some(&generated_id)))
        {
            return Err("A different Syncthing folder already uses the generated ID. Choose it from the sync list or use Syncthing's own folder editor.".into());
        }
        let created = existing.is_none();
        let mut folder = match existing {
            Some(f) => f,
            None => self.get(&["rest", "config", "defaults", "folder"], &[])?,
        };
        let id = if created {
            generated_id
        } else {
            folder["id"]
                .as_str()
                .ok_or("Missing Syncthing folder ID.")?
                .to_string()
        };
        let default_label = root
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "myDrive folder".into());
        let label = data["label"]
            .as_str()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(&default_label);
        let result = json!({"folder_id":id,"path":friendly_path(&root),"label":label,"device_name":device["name"],"created":created,"offered":apply,"nested":!overlaps.is_empty(),"overlapping_folders":overlaps,"remote_acceptance":"The other device may need to accept the folder in Syncthing."});
        if !apply {
            return Ok(result);
        }
        let mut shared = if created {
            Vec::new()
        } else {
            folder["devices"].as_array().cloned().unwrap_or_default()
        };
        for device_id in [local_id, target] {
            if !shared
                .iter()
                .any(|d| d["deviceID"].as_str() == Some(device_id))
            {
                shared
                    .push(json!({"deviceID":device_id,"encryptionPassword":"","introducedBy":""}));
            }
        }
        if self.get(&["rest", "config", "folders"], &[])? != folders {
            return Err("Sync folders changed while preparing this share. Refresh and try again; no sync settings were changed.".into());
        }
        fs::create_dir_all(data_dir.join("syncthing-backups")).map_err(|e| e.to_string())?;
        fs::write(data_dir.join("syncthing-backups").join(format!("share-{}-{}.json",hex::encode(sha2::Sha256::digest(id.as_bytes())),chrono::Utc::now().format("%Y%m%dT%H%M%S%.9f"))),serde_json::to_vec_pretty(&json!({"folder_id":id,"path":folder["path"],"paused":folder["paused"],"device_ids":folder["devices"].as_array().map(|d|d.iter().map(|v|v["deviceID"].clone()).collect::<Vec<_>>()),"created":created})).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
        if created {
            folder["id"] = json!(id);
            folder["label"] = json!(label);
            folder["path"] = json!(friendly_path(&root));
            folder["devices"] = json!(shared);
            folder["paused"] = json!(true);
            folder["type"] = json!("sendreceive");
            folder["maxConflicts"] = json!(-1);
            folder["fsWatcherEnabled"] = json!(true);
            if folder["versioning"]["type"]
                .as_str()
                .unwrap_or("")
                .is_empty()
            {
                folder["versioning"] = json!({"type":"simple","params":{"keep":"20","cleanoutDays":"0"},"cleanupIntervalS":3600,"fsPath":"","fsType":"basic"});
            }
            self.call("POST", &["rest", "config", "folders"], &[], Some(&folder))?;
            if data["skip_build"].as_bool().unwrap_or(false) {
                let rules = [
                    ".tools",
                    "build",
                    "Core/target",
                    "node_modules",
                    "**/bin",
                    "**/obj",
                    "__pycache__",
                ]
                .iter()
                .map(|path| SelectionRule {
                    path: (*path).to_string(),
                    sync: false,
                    is_dir: true,
                })
                .collect::<Vec<_>>();
                // Intentional globs for bin/obj are not literal file selections.
                let mut ignore = vec![
                    "// myDrive project defaults: skip generated build, SDK and cache directories"
                        .to_string(),
                ];
                for rule in rules {
                    ignore.push(if rule.path.starts_with("**/") {
                        rule.path
                    } else {
                        format!("/{}", rule.path)
                    });
                }
                self.call("POST",&["rest","db","ignores"],&[("folder",&id)],Some(&json!({"ignore":ignore}))).map_err(|e|format!("The new folder was left paused because its exclusions could not be saved. {e}"))?;
            }
        } else {
            self.call(
                "PATCH",
                &["rest", "config", "folders", &id],
                &[],
                Some(&json!({"devices":shared})),
            )?;
        }
        self.call(
            "PATCH",
            &["rest", "config", "folders", &id],
            &[],
            Some(&json!({"paused":false})),
        )?;
        Ok(result)
    }
}

fn missing_sync_root(error: &str) -> bool {
    let lower = error.to_ascii_lowercase();
    lower.contains("folder path missing") || lower.contains("folder marker missing")
}

fn sync_marker(folder: &Value) -> &str {
    folder["markerName"].as_str().filter(|name| !name.is_empty()).unwrap_or(".stfolder")
}

fn valid_sync_marker(marker: &str) -> bool {
    let mut components = Path::new(marker).components();
    matches!(components.next(), Some(std::path::Component::Normal(_))) && components.next().is_none()
}

fn unavailable_sync_root(folder: &Value) -> Option<&'static str> {
    use std::io::ErrorKind;
    if !matches!(folder["filesystemType"].as_str(), None | Some("" | "basic")) {
        return None;
    }
    let path = absolute_configured_path(folder["path"].as_str()?).ok()?;
    match fs::metadata(&path) {
        Err(error) if matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory) => {
            return Some("Folder path missing.");
        }
        Ok(folder) if !folder.is_dir() => return Some("Folder path missing."),
        Ok(_) => {}
        Err(_) => return None,
    }
    let marker = sync_marker(folder);
    if valid_sync_marker(marker)
        && fs::symlink_metadata(path.join(marker)).is_err_and(|error| error.kind() == ErrorKind::NotFound)
    {
        return Some("Folder marker missing.");
    }
    None
}

fn scan_failure(reason: &str, status: u16) -> String {
    if missing_sync_root(reason) {
        return "Syncthing cannot find the current folder or its marker. Choose new location… if it moved, or reconnect its drive.".into();
    }
    let reason = reason.to_ascii_lowercase();
    if reason.contains("folder is paused") || reason.contains("folder paused") {
        return "This sync folder is paused. Resume it before rescanning.".into();
    }
    if let Some(advice) = folder_error_advice(&reason) {
        return format!("Syncthing could not rescan the folder. {advice}");
    }
    format!("Syncthing could not rescan the folder (HTTP {status}). Open Folder errors for details.")
}

fn validate_moved_root(old: &Path, new: &Path, marker: &str) -> Result<(), String> {
    use std::io::ErrorKind;
    if !valid_sync_marker(marker) {
        return Err("The sync folder has an unsupported marker name.".into());
    }
    match fs::symlink_metadata(old.join(marker)) {
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        _ => return Err("The original folder is still available or cannot be verified. Refresh before changing its location.".into()),
    }
    let found = fs::symlink_metadata(new.join(marker))
        .map_err(|_| format!("Choose the original moved folder, including its hidden {marker} marker."))?;
    if !(found.is_dir() || found.is_file()) || found.file_type().is_symlink() {
        return Err("The selected folder has an invalid Syncthing marker.".into());
    }
    Ok(())
}

// A local hub may relay parent A to device B and child C to device D. Never
// create two overlapping roots shared with the same remote: that can loop edits.
fn plan_share(
    root: &Path,
    folders: &Value,
    local: &str,
    target: &str,
) -> Result<(Option<Value>, Vec<Value>), String> {
    let all = folders
        .as_array()
        .ok_or("Invalid Syncthing folders response.")?;
    let mut roots = Vec::new();
    for folder in all {
        let path = folder["path"].as_str().ok_or(
            "A configured sync folder has no path. Repair it in Syncthing before sharing.",
        )?;
        roots.push((folder, configured_share_path(path)?));
    }
    let matches: Vec<_> = roots.iter().filter(|(_, path)| path == root).collect();
    if matches.len() > 1 {
        return Err("More than one sync folder uses this path. Resolve the duplicate roots in Syncthing before sharing.".into());
    }
    let existing = matches.first().map(|(folder, _)| (*folder).clone());
    let mut proposed = std::collections::BTreeSet::from([target]);
    if let Some(folder) = &existing {
        for device in folder["devices"]
            .as_array()
            .ok_or("Cannot verify this folder's shared devices.")?
        {
            proposed.insert(
                device["deviceID"]
                    .as_str()
                    .ok_or("A shared device has no ID.")?,
            );
        }
    }
    proposed.remove(local);
    let mut overlaps = Vec::new();
    for (folder, path) in roots {
        if path == root || !(root.starts_with(&path) || path.starts_with(root)) {
            continue;
        }
        let members = folder["devices"]
            .as_array()
            .ok_or("Cannot verify the overlapping folder's shared devices.")?;
        if members.iter().any(|device| {
            device["deviceID"]
                .as_str()
                .is_none_or(|id| id != local && proposed.contains(id))
        }) {
            return Err(format!("This folder and '{}' would both sync with the same device. Choose a device that does not already sync the overlapping folder. Its existing sync stays unchanged.",folder["label"].as_str().filter(|s|!s.is_empty()).unwrap_or("another folder")));
        }
        overlaps.push(json!({"folder_id":folder["id"],"label":folder["label"],"relationship":if root.starts_with(&path){"parent"}else{"child"}}));
    }
    Ok((existing, overlaps))
}

// Resolve aliases even when the last components are temporarily missing.
// Missing/offline configured paths must not silently bypass overlap checks.
fn absolute_configured_path(value: &str) -> Result<std::path::PathBuf, String> {
    let path =
        if value == "~" || value.starts_with("~/") || (cfg!(windows) && value.starts_with("~\\")) {
            let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                .ok_or("Cannot resolve a configured home-relative sync path.")?;
            Path::new(&home).join(value.get(2..).unwrap_or(""))
        } else {
            std::path::PathBuf::from(value)
        };
    if !path.is_absolute() {
        return Err(
            "A configured sync path is not absolute. Repair it in Syncthing before sharing.".into(),
        );
    }
    Ok(path)
}

fn configured_share_path(value: &str) -> Result<std::path::PathBuf, String> {
    let mut ancestor = absolute_configured_path(value)?;
    let mut missing = Vec::new();
    loop {
        match ancestor.canonicalize() {
            Ok(mut resolved)=>{for part in missing.iter().rev(){resolved.push(part)};return Ok(resolved)}
            Err(error) if error.kind()==std::io::ErrorKind::NotFound=>{
                let Some(std::path::Component::Normal(part))=ancestor.components().next_back() else {return Err("A configured sync path cannot be checked. Make it available before sharing an overlapping folder.".into())};
                missing.push(part.to_os_string());ancestor.pop();
            }
            Err(_)=>return Err("A configured sync path cannot be checked. Make it available before sharing an overlapping folder.".into()),
        }
    }
}
pub(crate) fn friendly_path(path: &Path) -> String {
    let path = path.to_string_lossy();
    if cfg!(windows) {
        if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
            return format!(r"\\{rest}");
        }
        if let Some(rest) = path.strip_prefix(r"\\?\") {
            return rest.to_string();
        }
    }
    path.to_string()
}
// Keep exact remote names. Fold a local spelling only when the filesystem
// resolves it to the same actual path, including on case-sensitive Mac volumes.
fn local_browser_key(
    entries: &std::collections::BTreeMap<String, Value>,
    case_names: &std::collections::BTreeMap<String, Vec<String>>,
    dir: &Path,
    name: &str,
) -> String {
    if entries.contains_key(name) {
        return name.to_string();
    }
    let folded = name.to_lowercase();
    let local = dir.join(name).canonicalize().ok();
    for key in case_names.get(&folded).into_iter().flatten() {
        if local.is_some() && dir.join(key).canonicalize().ok() == local {
            return key.clone();
        }
    }
    name.to_string()
}

fn browser_case_names(
    entries: &std::collections::BTreeMap<String, Value>,
) -> std::collections::BTreeMap<String, Vec<String>> {
    let mut names: std::collections::BTreeMap<String, Vec<String>> =
        std::collections::BTreeMap::new();
    for name in entries.keys() {
        names
            .entry(name.to_lowercase())
            .or_default()
            .push(name.clone());
    }
    names
}

fn alternative_name(name: &str) -> Option<String> {
    let (base, suffix) = name.split_once(".sync-conflict-")?;
    let mut parts = suffix.splitn(3, '-');
    let date = parts.next()?;
    let time = parts.next()?;
    let device = parts.next()?;
    if base.is_empty()
        || date.len() != 8
        || time.len() != 6
        || !date.bytes().all(|b| b.is_ascii_digit())
        || !time.bytes().all(|b| b.is_ascii_digit())
        || device.is_empty()
    {
        return None;
    }
    Some(match device.rsplit_once('.') {
        Some((_, extension)) => format!("{base}.{extension}"),
        None => base.to_string(),
    })
}
use sha2::Digest;
fn folder_error_advice(error: &str) -> Option<&'static str> {
    let error = error.to_lowercase();
    let contains = |terms: &[&str]| terms.iter().any(|term| error.contains(term));
    if contains(&[
        "no space left",
        "disk full",
        "not enough free space",
        "insufficient space",
    ]) {
        Some("Free space on the drive, then rescan.")
    } else if missing_sync_root(&error) {
        Some("If the folder moved, choose its new location. If its drive is offline, reconnect it and rescan.")
    } else if contains(&["no such file or directory", "path not found"]) {
        Some("Make sure the original folder and its drive are available, then rescan.")
    } else if contains(&[
        "permission denied",
        "access is denied",
        "operation not permitted",
        "read-only file system",
    ]) {
        Some("Check that your account can access the folder, then rescan.")
    } else if contains(&[
        "file is in use",
        "used by another process",
        "sharing violation",
        "resource busy",
    ]) {
        Some("Close the app using the file, then rescan.")
    } else if contains(&[
        "connection refused",
        "connection reset",
        "timed out",
        "timeout",
    ]) {
        Some("Check that the other device is online, then rescan.")
    } else if error.contains("directory has been deleted on a remote device but is not empty") {
        Some("Review the files still inside this directory before deciding what to keep.")
    } else {
        None
    }
}

fn pick(value: &Value, keys: &[&str]) -> Value {
    let mut result = serde_json::Map::new();
    for key in keys {
        if let Some(v) = value.get(*key) {
            result.insert((*key).to_string(), v.clone());
        }
    }
    Value::Object(result)
}

const BEGIN: &str = "// myDrive selection begin v1";
const END: &str = "// myDrive selection end v1";
const ON_DEMAND: &str = "// download when needed";

fn openable_sync_file(root: &Path, target: &Path) -> Result<Option<String>, String> {
    let resolved = match target.canonicalize() {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    if !resolved.starts_with(root) || !resolved.is_file() {
        return Err("The file is outside the sync root or is not a regular file.".into());
    }
    Ok(Some(friendly_path(&resolved)))
}

fn set_download_rule(rules: &mut Vec<SelectionRule>, path: &str) {
    rules.retain(|rule| rule.path != path);
    rules.push(SelectionRule { path: path.to_string(), sync: true, is_dir: false });
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SelectionRule {
    pub path: String,
    pub sync: bool,
    #[serde(default)]
    pub is_dir: bool,
}
fn bounds(lines: &[String]) -> Result<Option<(usize, usize)>, String> {
    let starts = lines
        .iter()
        .enumerate()
        .filter(|(_, v)| v.as_str() == BEGIN)
        .map(|(i, _)| i)
        .collect::<Vec<_>>();
    let ends = lines
        .iter()
        .enumerate()
        .filter(|(_, v)| v.as_str() == END)
        .map(|(i, _)| i)
        .collect::<Vec<_>>();
    if starts.is_empty() && ends.is_empty() {
        return Ok(None);
    }
    if starts.len() != 1 || ends.len() != 1 || starts[0] >= ends[0] {
        return Err("The myDrive selection block was edited manually. Repair its markers in Syncthing before applying selections.".into());
    }
    Ok(Some((starts[0], ends[0])))
}
fn on_demand_mode(lines: &[String]) -> Result<bool, String> {
    Ok(bounds(lines)?.is_some_and(|(start, end)|
        end - start >= 3 && lines[end - 2] == ON_DEMAND && lines[end - 1] == "**"))
}
fn parse_managed(lines: &[String]) -> Result<Vec<SelectionRule>, String> {
    let Some((start, end)) = bounds(lines)? else {
        return Ok(vec![]);
    };
    lines[start + 1..end]
        .iter()
        .filter_map(|line| line.strip_prefix("// rule "))
        .map(|text| {
            serde_json::from_str(text)
                .map_err(|_| "A myDrive selection rule was edited manually.".into())
        })
        .collect()
}
fn escaped_path(path: &str, escape: char) -> String {
    let mut output = String::new();
    for c in path.chars() {
        if c == escape || "*?[]{}".contains(c) {
            output.push(escape);
        }
        output.push(c);
    }
    output
}
fn block(rules: &[SelectionRule], escape: char, on_demand: bool) -> Result<Vec<String>, String> {
    if rules.is_empty() && !on_demand {
        return Ok(vec![]);
    }
    let mut rules = rules.to_vec();
    let mut seen = std::collections::HashSet::new();
    for r in &mut rules {
        r.path = crate::model::clean_path(&r.path)?;
        if r.path.is_empty()
            || r.path.contains(['\r', '\n'])
            || r.path.trim() != r.path
            || !seen.insert(r.path.to_lowercase())
        {
            return Err("Selections need unique, nonempty relative paths without line breaks or leading/trailing whitespace.".into());
        }
    }
    rules.sort_by(|a, b| {
        b.path
            .matches('/')
            .count()
            .cmp(&a.path.matches('/').count())
            .then(a.path.cmp(&b.path))
    });
    let mut output = vec![BEGIN.to_string()];
    for r in rules {
        output.push(format!(
            "// rule {}",
            serde_json::to_string(&r).map_err(|e| e.to_string())?
        ));
        let prefix = if r.sync { "!" } else { "" };
        let path = escaped_path(&r.path, escape);
        output.push(format!("{prefix}/{path}"));
        if r.is_dir {
            output.push(format!("{prefix}/{path}/**"));
        }
    }
    if on_demand {
        output.extend([ON_DEMAND.to_string(), "**".to_string()]);
    }
    output.push(END.to_string());
    Ok(output)
}
#[cfg(test)]
fn render_rules(
    existing: &[String],
    rules: &[SelectionRule],
    windows: bool,
) -> Result<Vec<String>, String> {
    render_rules_for_mode(existing, rules, windows, on_demand_mode(existing)?)
}

fn render_rules_for_mode(
    existing: &[String],
    rules: &[SelectionRule],
    windows: bool,
    on_demand: bool,
) -> Result<Vec<String>, String> {
    let escape = existing
        .iter()
        .find_map(|line| line.strip_prefix("#escape=").and_then(|s| s.chars().next()))
        .unwrap_or(if windows { '|' } else { '\\' });
    let mut untouched = existing.to_vec();
    if let Some((start, end)) = bounds(existing)? {
        let parsed = parse_managed(existing)?;
        if block(&parsed, escape, on_demand_mode(existing)?)? != existing[start..=end] {
            return Err("The generated myDrive rules were changed manually. Resolve that block in Syncthing before applying selections.".into());
        }
        untouched.drain(start..=end);
    }
    let generated = block(rules, escape, on_demand)?;
    if generated.is_empty() {
        return Ok(untouched);
    }
    let insertion = untouched
        .iter()
        .position(|s| s.starts_with("#escape="))
        .map_or(0, |p| p + 1);
    untouched.splice(insertion..insertion, generated);
    Ok(untouched)
}

#[cfg(test)]
mod tests {
    #[test]
    fn on_demand_preserves_other_rules_and_explicit_pins() {
        let existing = vec!["*.tmp".to_string()];
        let mut rules = vec![];
        let cold = render_rules_for_mode(&existing, &rules, false, true).unwrap();
        assert!(on_demand_mode(&cold).unwrap());
        set_download_rule(&mut rules, "docs/report.txt");
        let pinned = render_rules(&cold, &rules, false).unwrap();
        assert_eq!(parse_managed(&pinned).unwrap(), rules);
        assert!(pinned.iter().position(|line| line == "!/docs/report.txt") <
                pinned.iter().position(|line| line == "**"));
        let warm = render_rules_for_mode(&pinned, &rules, false, false).unwrap();
        assert!(!on_demand_mode(&warm).unwrap());
        assert!(warm.contains(&existing[0]));
        assert_eq!(parse_managed(&warm).unwrap(), rules);
    }

    fn share_fixture(path: &Path, id: &str, peers: &[&str]) -> Value {
        json!({"id":id,"label":id,"path":path,"devices":peers.iter().map(|id|json!({"deviceID":id})).collect::<Vec<_>>()})
    }
    #[test]
    fn nested_share_can_relay_to_a_different_device_without_changing_parent() {
        let temp = tempfile::tempdir().unwrap();
        let parent = temp.path().canonicalize().unwrap();
        let child = parent.join("project");
        fs::create_dir(&child).unwrap();
        let folders = json!([share_fixture(&parent, "github", &["mac", "laptop"])]);
        let before = folders.clone();
        let (existing, overlaps) = plan_share(&child, &folders, "mac", "desktop").unwrap();
        assert!(existing.is_none());
        assert_eq!(overlaps[0]["relationship"], "parent");
        assert_eq!(folders, before);
        assert!(plan_share(&child, &folders, "mac", "laptop").is_err());
        let folders = json!([share_fixture(&child, "project", &["mac", "desktop"])]);
        assert!(plan_share(&parent, &folders, "mac", "laptop").is_ok());
        assert!(plan_share(&parent, &folders, "mac", "desktop").is_err());
    }
    #[test]
    fn existing_nested_roots_cannot_add_an_overlapping_peer() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let child = root.join("project");
        fs::create_dir(&child).unwrap();
        let folders = json!([
            share_fixture(&root, "github", &["mac", "laptop"]),
            share_fixture(&child, "project", &["mac", "desktop"])
        ]);
        assert!(plan_share(&child, &folders, "mac", "desktop")
            .unwrap()
            .0
            .is_some());
        assert!(plan_share(&child, &folders, "mac", "laptop").is_err());
        assert!(plan_share(&root, &folders, "mac", "desktop").is_err());
        // Validate every existing member, even when the new target itself is unrelated.
        let duplicate = json!([
            share_fixture(&root, "github", &["mac", "laptop"]),
            share_fixture(&child, "project", &["mac", "laptop"])
        ]);
        assert!(plan_share(&child, &duplicate, "mac", "phone").is_err());
    }
    #[test]
    fn nesting_checks_all_ancestors_and_uses_path_components() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let middle = root.join("git");
        let child = middle.join("project");
        fs::create_dir_all(&child).unwrap();
        let folders = json!([
            share_fixture(&root, "outer", &["mac", "desktop"]),
            share_fixture(&middle, "middle", &["mac", "laptop"])
        ]);
        assert!(plan_share(&child, &folders, "mac", "desktop").is_err());
        let sibling = root.join("github-other");
        fs::create_dir(&sibling).unwrap();
        let folders = json!([share_fixture(&middle, "git", &["mac", "desktop"])]);
        assert!(plan_share(&sibling, &folders, "mac", "desktop").is_ok());
        let missing = child.join("temporarily-missing");
        let folders = json!([share_fixture(&missing, "missing", &["mac", "desktop"])]);
        assert!(plan_share(&middle, &folders, "mac", "desktop").is_err());
    }
    #[test]
    fn duplicate_roots_and_unverifiable_members_fail_before_mutation() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let child = root.join("child");
        fs::create_dir(&child).unwrap();
        assert!(plan_share(
            &root,
            &json!([
                share_fixture(&root, "one", &["mac"]),
                share_fixture(&root, "two", &["mac"])
            ]),
            "mac",
            "desktop"
        )
        .is_err());
        assert!(plan_share(
            &child,
            &json!([{"path":root,"devices":[{}]}]),
            "mac",
            "desktop"
        )
        .is_err());
    }
    #[cfg(unix)]
    #[test]
    fn alias_paths_do_not_bypass_nested_peer_checks() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let parent = root.join("github");
        fs::create_dir(&parent).unwrap();
        let child = parent.join("project");
        fs::create_dir(&child).unwrap();
        let alias = root.join("alias");
        std::os::unix::fs::symlink(&parent, &alias).unwrap();
        assert!(plan_share(
            &child,
            &json!([share_fixture(&alias, "github", &["mac", "desktop"])]),
            "mac",
            "desktop"
        )
        .is_err());
    }
    #[test]
    fn browser_merges_only_filesystem_equivalent_names() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::write(temp.path().join("Report.txt"), "first").unwrap();
        let entries =
            std::collections::BTreeMap::from([("Report.txt".into(), serde_json::json!({}))]);
        let alias = temp.path().join("REPORT.txt");
        let expected = if alias.exists()
            && alias.canonicalize().unwrap()
                == temp.path().join("Report.txt").canonicalize().unwrap()
        {
            "Report.txt"
        } else {
            "REPORT.txt"
        };
        assert_eq!(
            super::local_browser_key(
                &entries,
                &super::browser_case_names(&entries),
                temp.path(),
                "REPORT.txt"
            ),
            expected
        );
        assert_eq!(
            super::local_browser_key(
                &entries,
                &super::browser_case_names(&entries),
                temp.path(),
                "unrelated.txt"
            ),
            "unrelated.txt"
        );
    }
    #[test]
    fn browser_retains_case_distinct_remote_entries() {
        let temp = tempfile::tempdir().unwrap();
        let entries = std::collections::BTreeMap::from([
            ("Photo.jpg".into(), serde_json::json!({"remote":true})),
            ("photo.jpg".into(), serde_json::json!({"remote":true})),
        ]);
        assert_eq!(
            super::local_browser_key(
                &entries,
                &super::browser_case_names(&entries),
                temp.path(),
                "Photo.jpg"
            ),
            "Photo.jpg"
        );
        assert_eq!(
            super::local_browser_key(
                &entries,
                &super::browser_case_names(&entries),
                temp.path(),
                "photo.jpg"
            ),
            "photo.jpg"
        );
    }
    use super::*;
    #[test]
    fn recognizes_saved_alternative_names_without_hiding_ordinary_files() {
        assert_eq!(
            alternative_name("project.sync-conflict-20261113-134512-ABCDEFG.blend"),
            Some("project.blend".into())
        );
        assert_eq!(
            alternative_name("notes.sync-conflict-20261113-134512-ABCDEFG"),
            Some("notes".into())
        );
        assert_eq!(alternative_name("notes.sync-conflict-example.txt"), None);
        assert_eq!(alternative_name("notes.txt"), None);
    }
    #[test]
    fn rejects_remote_api_and_embedded_credentials() {
        for endpoint in [
            "http://example.com:8384",
            "http://user:secret@127.0.0.1:8384",
            "http://127.0.0.1:8384/rest",
            "file:///tmp/key",
        ] {
            assert!(Api::new(&Connection {
                endpoint: endpoint.into(),
                api_key: "fixture".into(),
                certificate_pem: String::new()
            })
            .is_err());
        }
    }
    #[test]
    fn preserves_existing_rules_and_escape_directive() {
        let old = vec![
            "// original".into(),
            "#escape=|".into(),
            "#include custom.ignore".into(),
            "*.tmp".into(),
        ];
        let rules = vec![SelectionRule {
            path: "Folder [1]/draft.txt".into(),
            sync: false,
            is_dir: false,
        }];
        let result = render_rules(&old, &rules, true).unwrap();
        assert!(result.iter().any(|s| s == "/Folder |[1|]/draft.txt"));
        assert!(result.ends_with(&old[2..]));
        assert_eq!(render_rules(&result, &[], true).unwrap(), old);
    }
    #[test]
    fn child_override_precedes_parent() {
        let rules = vec![
            SelectionRule {
                path: "Projects".into(),
                sync: true,
                is_dir: true,
            },
            SelectionRule {
                path: "Projects/cache".into(),
                sync: false,
                is_dir: true,
            },
        ];
        let result = render_rules(&[], &rules, false).unwrap();
        let child = result.iter().position(|s| s == "/Projects/cache").unwrap();
        let parent = result.iter().position(|s| s == "!/Projects").unwrap();
        assert!(child < parent);
        assert_eq!(parse_managed(&result).unwrap().len(), 2);
    }
    #[test]
    fn refuses_to_overwrite_manually_edited_block() {
        let rules = vec![SelectionRule {
            path: "file.txt".into(),
            sync: true,
            is_dir: false,
        }];
        let mut result = render_rules(&[], &rules, false).unwrap();
        result[2] = "/something-else".into();
        assert!(render_rules(&result, &rules, false).is_err());
    }
    #[test]
    fn refuses_duplicate_paths_and_traversal() {
        for paths in [vec!["../outside"], vec!["a\n*.txt"], vec!["same", "SAME"]] {
            let rules = paths
                .iter()
                .map(|p| SelectionRule {
                    path: (*p).into(),
                    sync: false,
                    is_dir: false,
                })
                .collect::<Vec<_>>();
            assert!(render_rules(&[], &rules, true).is_err());
        }
    }
}
