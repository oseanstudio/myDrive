use crate::{client::FileClient, model::*};
use ssh2::{CheckResult, KnownHostFileKind, Session};
use std::{
    fs::File,
    net::{TcpStream, ToSocketAddrs},
    path::{Path, PathBuf},
    time::Duration,
};

pub struct SftpClient {
    _session: Session,
    sftp: ssh2::Sftp,
    root: String,
}
impl SftpClient {
    pub fn new(b: &Bookmark, c: &Credentials) -> Result<Self, String> {
        let port = if b.port == 0 { 22 } else { b.port };
        let addresses = (b.host.as_str(), port)
            .to_socket_addrs()
            .map_err(|e| e.to_string())?;
        let mut connection = None;
        for address in addresses {
            if let Ok(stream) = TcpStream::connect_timeout(&address, Duration::from_secs(15)) {
                connection = Some(stream);
                break;
            }
        }
        let stream = connection.ok_or("Cannot reach the SFTP server.")?;
        let mut session = Session::new().map_err(|e| e.to_string())?;
        session.set_tcp_stream(stream);
        session.set_timeout(60000);
        session.handshake().map_err(|e| e.to_string())?;
        let mut known = session.known_hosts().map_err(|e| e.to_string())?;
        let home = std::env::var("USERPROFILE")
            .or_else(|_| std::env::var("HOME"))
            .map_err(|_| "Home folder is unavailable.")?;
        let known_path = b
            .options
            .get("known_hosts")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(home).join(".ssh/known_hosts"));
        known.read_file(&known_path,KnownHostFileKind::OpenSSH).map_err(|_|"No readable known_hosts file. Verify this server with OpenSSH first (ssh username@host).")?;
        let (key, _) = session
            .host_key()
            .ok_or("Server did not provide a host key.")?;
        match known.check_port(&b.host,port,key){CheckResult::Match=>{},CheckResult::Mismatch=>return Err("SECURITY: SSH host key changed. Verify the server before reconnecting.".into()),_=>return Err("SSH host key is not trusted. Verify this server with OpenSSH first (ssh username@host).".into())}
        if !c.private_key.is_empty() {
            session
                .userauth_pubkey_file(
                    &b.username,
                    None,
                    Path::new(&c.private_key),
                    if c.passphrase.is_empty() {
                        None
                    } else {
                        Some(&c.passphrase)
                    },
                )
                .map_err(|e| e.to_string())?;
        } else if !c.password.is_empty() {
            session
                .userauth_password(&b.username, &c.password)
                .map_err(|_| "SFTP authentication failed.")?;
        } else {
            session.userauth_agent(&b.username).map_err(|_|"SSH agent authentication failed. Add a key to your agent or enter a password/private key.")?;
        }
        let sftp = session.sftp().map_err(|e| e.to_string())?;
        let root = if b.path.is_empty() {
            ".".into()
        } else {
            b.path.clone()
        };
        Ok(Self {
            _session: session,
            sftp,
            root,
        })
    }
    fn remote(&self, path: &str) -> Result<PathBuf, String> {
        let path = clean_path(path)?;
        Ok(PathBuf::from(format!(
            "{}/{}",
            self.root.trim_end_matches('/'),
            path
        )))
    }
}
impl FileClient for SftpClient {
    fn list(&mut self, path: &str) -> Result<Vec<RemoteFile>, String> {
        let mut files = vec![];
        for (p, s) in self
            .sftp
            .readdir(&self.remote(path)?)
            .map_err(|e| e.to_string())?
        {
            let name = p
                .file_name()
                .ok_or("Invalid SFTP filename")?
                .to_string_lossy()
                .into_owned();
            if name == "." || name == ".." {
                continue;
            }
            files.push(RemoteFile {
                path: child(path, &name),
                name,
                size: s.size.unwrap_or(0),
                modified: s
                    .mtime
                    .and_then(|v| chrono::DateTime::from_timestamp(v as i64, 0))
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_default(),
                is_dir: s.is_dir(),
            });
        }
        Ok(files)
    }
    fn download(&mut self, path: &str, local: &Path) -> Result<(), String> {
        let mut remote = self
            .sftp
            .open(&self.remote(path)?)
            .map_err(|e| e.to_string())?;
        let mut out = File::create(local).map_err(|e| e.to_string())?;
        std::io::copy(&mut remote, &mut out).map_err(|e| e.to_string())?;
        Ok(())
    }
    fn upload(&mut self, local: &Path, path: &str) -> Result<(), String> {
        let remote = self.remote(path)?;
        let mut dest = self
            .sftp
            .open_mode(
                &remote,
                ssh2::OpenFlags::WRITE | ssh2::OpenFlags::CREATE | ssh2::OpenFlags::EXCLUSIVE,
                0o600,
                ssh2::OpenType::File,
            )
            .map_err(|e| e.to_string())?;
        let mut source = File::open(local).map_err(|e| e.to_string())?;
        std::io::copy(&mut source, &mut dest).map_err(|e| e.to_string())?;
        dest.fsync().map_err(|e| e.to_string())?;
        Ok(())
    }
    fn mkdir(&mut self, path: &str) -> Result<(), String> {
        self.sftp
            .mkdir(&self.remote(path)?, 0o755)
            .map_err(|e| e.to_string())
    }
    fn delete(&mut self, path: &str, is_dir: bool) -> Result<(), String> {
        if clean_path(path)?.is_empty() {
            return Err("Cannot delete a connection root.".into());
        }
        let path = self.remote(path)?;
        if is_dir {
            self.sftp.rmdir(&path)
        } else {
            self.sftp.unlink(&path)
        }
        .map_err(|e| e.to_string())
    }
    fn rename(&mut self, path: &str, destination: &str) -> Result<(), String> {
        let dest = self.remote(destination)?;
        if self.sftp.stat(&dest).is_ok() {
            return Err("The destination already exists.".into());
        }
        self.sftp
            .rename(&self.remote(path)?, &dest, Some(ssh2::RenameFlags::ATOMIC))
            .map_err(|e| e.to_string())
    }
}
