use crate::model::*;
use std::{
    fs,
    path::{Path, PathBuf},
};

pub trait FileClient {
    fn list(&mut self, path: &str) -> Result<Vec<RemoteFile>, String>;
    fn download(&mut self, path: &str, local: &Path) -> Result<(), String>;
    fn upload(&mut self, local: &Path, path: &str) -> Result<(), String>;
    fn mkdir(&mut self, path: &str) -> Result<(), String>;
    fn delete(&mut self, path: &str, is_dir: bool) -> Result<(), String>;
    fn rename(&mut self, path: &str, destination: &str) -> Result<(), String>;
}

pub struct LocalClient {
    root: PathBuf,
}
impl LocalClient {
    pub fn new(b: &Bookmark) -> Result<Self, String> {
        let root = if b.protocol == Protocol::Smb {
            smb_root(b)?
        } else {
            PathBuf::from(&b.host).join(b.path.trim_start_matches(['/', '\\']))
        };
        Ok(Self {
            root: root
                .canonicalize()
                .map_err(|e| format!("Cannot open connection folder: {e}"))?,
        })
    }
    pub(crate) fn resolve(&self, path: &str, creating: bool) -> Result<PathBuf, String> {
        let target = self.root.join(clean_path(path)?);
        // Resolve links before access, including the existing parent for new files.
        let checked = if creating && !target.exists() {
            target
                .parent()
                .ok_or("Missing parent")?
                .canonicalize()
                .map_err(|e| e.to_string())?
        } else {
            target.canonicalize().map_err(|e| e.to_string())?
        };
        if !checked.starts_with(&self.root) {
            return Err("A symbolic link points outside the connection root.".into());
        }
        Ok(target)
    }
}
#[cfg(windows)]
fn smb_root(b: &Bookmark) -> Result<PathBuf, String> {
    Ok(PathBuf::from(format!(
        "\\\\{}\\{}",
        b.host.trim_matches('\\'),
        b.path.trim_matches(['/', '\\']).replace('/', "\\")
    )))
}

#[cfg(not(windows))]
fn smb_root(b: &Bookmark) -> Result<PathBuf, String> {
    let root = PathBuf::from(&b.mount_path);
    if root.is_absolute() {
        Ok(root)
    } else {
        Err("Mount this SMB share before browsing or transferring files.".into())
    }
}

impl FileClient for LocalClient {
    fn list(&mut self, path: &str) -> Result<Vec<RemoteFile>, String> {
        let mut files = vec![];
        for item in fs::read_dir(self.resolve(path, false)?).map_err(|e| e.to_string())? {
            let item = item.map_err(|e| e.to_string())?;
            let m = item.metadata().map_err(|e| e.to_string())?;
            let name = item.file_name().to_string_lossy().into_owned();
            files.push(RemoteFile {
                path: child(path, &name),
                name,
                size: m.len(),
                is_dir: m.is_dir(),
                modified: m
                    .modified()
                    .map(|t| chrono::DateTime::<chrono::Utc>::from(t).to_rfc3339())
                    .unwrap_or_default(),
            });
        }
        Ok(files)
    }
    fn download(&mut self, path: &str, local: &Path) -> Result<(), String> {
        fs::copy(self.resolve(path, false)?, local)
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
    fn upload(&mut self, local: &Path, path: &str) -> Result<(), String> {
        let dest = self.resolve(path, true)?;
        let parent = dest.parent().ok_or("Missing parent")?;
        let mut tmp = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
        let mut source = fs::File::open(local).map_err(|e| e.to_string())?;
        std::io::copy(&mut source, &mut tmp).map_err(|e| e.to_string())?;
        tmp.as_file().sync_all().map_err(|e| e.to_string())?;
        tmp.persist_noclobber(dest).map_err(|e| e.to_string())?;
        Ok(())
    }
    fn mkdir(&mut self, path: &str) -> Result<(), String> {
        fs::create_dir(self.resolve(path, true)?).map_err(|e| e.to_string())
    }
    fn delete(&mut self, path: &str, is_dir: bool) -> Result<(), String> {
        if clean_path(path)?.is_empty() {
            return Err("Cannot delete a connection root.".into());
        }
        let p = self.resolve(path, false)?;
        if is_dir {
            fs::remove_dir(p)
        } else {
            fs::remove_file(p)
        }
        .map_err(|e| e.to_string())
    }
    fn rename(&mut self, path: &str, destination: &str) -> Result<(), String> {
        let dest = self.resolve(destination, true)?;
        if dest.exists() {
            return Err("The destination already exists.".into());
        }
        fs::rename(self.resolve(path, false)?, dest).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_roundtrip() {
        let d = tempfile::tempdir().unwrap();
        let source = tempfile::NamedTempFile::new().unwrap();
        fs::write(source.path(), b"myDrive").unwrap();
        let b = Bookmark {
            id: "1".into(),
            nickname: "Test".into(),
            protocol: Protocol::Local,
            host: d.path().to_string_lossy().into(),
            port: 0,
            path: "".into(),
            username: "".into(),
            credentials_ref: "".into(),
            mount_path: "".into(),
            options: Default::default(),
        };
        let mut c = LocalClient::new(&b).unwrap();
        c.mkdir("folder").unwrap();
        c.upload(source.path(), "folder/test.txt").unwrap();
        assert_eq!(c.list("folder").unwrap()[0].size, 7);
        c.rename("folder/test.txt", "folder/new.txt").unwrap();
        assert!(c.rename("folder/new.txt", "folder/new.txt").is_err());
        let out = d.path().join("out");
        c.download("folder/new.txt", &out).unwrap();
        assert_eq!(fs::read(out).unwrap(), b"myDrive");
        c.delete("folder/new.txt", false).unwrap();
        c.delete("folder", true).unwrap();
        assert!(c.delete("", true).is_err());
    }
}
