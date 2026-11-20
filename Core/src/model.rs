use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    Local,
    Smb,
    Sftp,
    Webdav,
    S3,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Bookmark {
    pub id: String,
    pub nickname: String,
    pub protocol: Protocol,
    pub host: String,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub credentials_ref: String,
    #[serde(default)]
    pub mount_path: String,
    #[serde(default)]
    pub options: BTreeMap<String, String>,
}

impl Bookmark {
    pub fn validate(&self) -> Result<(), String> {
        if self.id.is_empty() || self.nickname.trim().is_empty() {
            return Err("A name and bookmark ID are required.".into());
        }
        if self.host.trim().is_empty() {
            return Err("Enter a server address or local folder.".into());
        }
        if self.protocol == Protocol::S3 && self.options.get("bucket").is_none_or(|s| s.is_empty())
        {
            return Err("Enter an S3 bucket.".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Credentials {
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub private_key: String,
    #[serde(default)]
    pub passphrase: String,
    #[serde(default)]
    pub session_token: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteFile {
    pub name: String,
    pub path: String,
    pub size: u64,
    pub modified: String,
    pub is_dir: bool,
}

// Paths in the shared API are always relative to a bookmark's root.
pub fn clean_path(path: &str) -> Result<String, String> {
    if path.contains('\\') || path.contains('\0') || path.contains(':') {
        return Err("Invalid remote path.".into());
    }
    let parts: Vec<_> = path
        .split('/')
        .filter(|s| !s.is_empty() && *s != ".")
        .collect();
    if parts.contains(&"..") {
        return Err("Paths cannot escape the connection root.".into());
    }
    Ok(parts.join("/"))
}

pub fn child(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        name.to_string()
    } else {
        format!("{parent}/{name}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_traversal() {
        for p in ["../secret", "a/../../secret", "a\\..\\b", "C:/file", "x\0"] {
            assert!(clean_path(p).is_err());
        }
    }
    #[test]
    fn normalizes_paths() {
        assert_eq!(clean_path("/a//./b/").unwrap(), "a/b");
    }
}
