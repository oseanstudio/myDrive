use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::Path,
    thread,
    time::{Duration, Instant, SystemTime},
};

const BLOCK: usize = 8 * 1024 * 1024;
const RETRY_WINDOW: Duration = Duration::from_secs(45);
const NETWORK_RETRY_WINDOW: Duration = Duration::from_secs(300);
const RETRY_DELAY: Duration = Duration::from_secs(2);

#[derive(Debug, Deserialize, PartialEq, Serialize)]
struct Source {
    size: u64,
    modified: SystemTime,
}

impl Source {
    fn read(file: &File) -> io::Result<Self> {
        let metadata = file.metadata()?;
        if !metadata.is_file() {
            return Err(invalid("Select a regular file to transfer."));
        }
        Ok(Self {
            size: metadata.len(),
            modified: metadata.modified()?,
        })
    }
}

#[derive(Deserialize, Serialize)]
struct Checkpoint {
    part: String,
    source: Source,
    offset: u64,
    last_block: String,
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

impl Checkpoint {
    fn save(&self, path: &Path) -> io::Result<()> {
        let mut temporary = tempfile::NamedTempFile::new_in(path.parent().unwrap())?;
        serde_json::to_writer(&mut temporary, self)?;
        temporary.as_file().sync_all()?;
        temporary.persist(path).map_err(|error| error.error)?;
        Ok(())
    }

    fn start(source: Source, parent: &Path, record: &Path) -> io::Result<Self> {
        let temporary = tempfile::Builder::new()
            .prefix(".mydrive-")
            .suffix(".part")
            .tempfile_in(parent)?;
        let checkpoint = Self {
            part: temporary
                .path()
                .file_name()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            source,
            offset: 0,
            last_block: String::new(),
        };
        let (_, part) = temporary.keep().map_err(|error| error.error)?;
        if let Err(error) = checkpoint.save(record) {
            let _ = fs::remove_file(part);
            return Err(error);
        }
        Ok(checkpoint)
    }

    fn verify(&self, source: &mut File, part: &mut File, block: &mut [u8]) -> io::Result<()> {
        if self.offset > self.source.size || part.metadata()?.len() < self.offset {
            return Err(invalid("The partial copy is incomplete or changed. Use a different destination to start over."));
        }
        if self.offset > 0 {
            let start = (self.offset - 1) / BLOCK as u64 * BLOCK as u64;
            let last = &mut block[..(self.offset - start) as usize];
            for file in [source, part] {
                file.seek(SeekFrom::Start(start))?;
                file.read_exact(last)?;
                if digest(last) != self.last_block {
                    return Err(invalid("The source or partial copy changed. Use a different destination to start over."));
                }
            }
        }
        Ok(())
    }
}

pub fn copy(source: &Path, destination: &Path, data: &Path, bookmark: &str) -> Result<(), String> {
    if !source.is_absolute() || !destination.is_absolute() || !data.is_absolute() {
        return Err("SMB transfers require absolute file and application data paths.".into());
    }
    let identity =
        serde_json::to_vec(&(bookmark, source, destination)).map_err(|e| e.to_string())?;
    let id = digest(&identity);
    let state = data.join("smb-transfers");
    fs::create_dir_all(&state).map_err(|e| e.to_string())?;
    let record = state.join(format!("{id}.json"));
    // Keep the lock path stable between processes. Removing it could leave two
    // different processes holding locks on different files for the same copy.
    let lock = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(state.join(format!("{id}.lock")))
        .map_err(|e| e.to_string())?;
    lock.try_lock()
        .map_err(|_| "This SMB transfer is already running.".to_string())?;

    copy_with_retries(source, destination, &record, RETRY_WINDOW)
}

fn copy_with_retries(
    source: &Path,
    destination: &Path,
    record: &Path,
    window: Duration,
) -> Result<(), String> {
    retry(window, RETRY_DELAY, |advanced| {
        copy_once(source, destination, record, advanced)
    })
}

fn retry(
    window: Duration,
    delay: Duration,
    mut attempt: impl FnMut(&mut bool) -> io::Result<()>,
) -> Result<(), String> {
    let mut failed_since = None;
    loop {
        let mut advanced = false;
        match attempt(&mut advanced) {
            Ok(()) => return Ok(()),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::AlreadyExists
                        | io::ErrorKind::InvalidData
                        | io::ErrorKind::InvalidInput
                        | io::ErrorKind::PermissionDenied
                        | io::ErrorKind::StorageFull
                ) =>
            {
                return Err(error.to_string())
            }
            Err(error) => {
                if advanced {
                    failed_since = None;
                }
                let limit = if window != Duration::ZERO && is_network_error(&error) {
                    NETWORK_RETRY_WINDOW
                } else {
                    window
                };
                if failed_since.get_or_insert_with(Instant::now).elapsed() >= limit {
                    return Err(format!(
                        "SMB transfer stopped: {error}. Retry the same source and destination to continue from the saved checkpoint."
                    ));
                }
                thread::sleep(delay);
            }
        }
    }
}

fn is_network_error(error: &io::Error) -> bool {
    use io::ErrorKind::*;
    if matches!(
        error.kind(),
        NetworkDown
            | NetworkUnreachable
            | HostUnreachable
            | ConnectionAborted
            | ConnectionReset
            | ConnectionRefused
            | BrokenPipe
            | NotConnected
            | TimedOut
    ) {
        return true;
    }
    #[cfg(windows)]
    if matches!(
        error.raw_os_error(),
        Some(53 | 54 | 58 | 59 | 64 | 67 | 121 | 1231 | 1232 | 1236)
    ) {
        return true;
    }
    false
}

fn copy_once(
    source: &Path,
    destination: &Path,
    record: &Path,
    advanced: &mut bool,
) -> io::Result<()> {
    match fs::symlink_metadata(destination) {
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "The destination already exists.",
            ))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let parent = destination
        .parent()
        .ok_or_else(|| invalid("Invalid destination folder."))?;
    let mut origin = File::open(source)?;
    let stamp = Source::read(&origin)?;
    let mut checkpoint = match fs::read(record) {
        Ok(bytes) => serde_json::from_slice(&bytes)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            Checkpoint::start(Source::read(&origin)?, parent, record)?
        }
        Err(error) => return Err(error),
    };
    if stamp != checkpoint.source {
        return Err(invalid("The source changed since this transfer started. Use a different destination to start over."));
    }
    let name = &checkpoint.part;
    if !name.starts_with(".mydrive-")
        || !name.ends_with(".part")
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b".-_".contains(&byte))
    {
        return Err(invalid("Invalid SMB transfer checkpoint."));
    }
    let partial = parent.join(name);
    if !fs::symlink_metadata(&partial)?.is_file() {
        return Err(invalid("The partial copy is no longer a regular file."));
    }
    let mut output = OpenOptions::new().read(true).write(true).open(&partial)?;
    let mut block = vec![0; BLOCK];
    checkpoint.verify(&mut origin, &mut output, &mut block)?;
    output.set_len(checkpoint.offset)?;
    origin.seek(SeekFrom::Start(checkpoint.offset))?;
    output.seek(SeekFrom::Start(checkpoint.offset))?;
    while checkpoint.offset < stamp.size {
        let next = &mut block[..(stamp.size - checkpoint.offset).min(BLOCK as u64) as usize];
        origin.read_exact(next)?;
        output.write_all(next)?;
        output.sync_all()?;
        checkpoint.offset += next.len() as u64;
        checkpoint.last_block = digest(next);
        checkpoint.save(record)?;
        *advanced = true;
    }
    if stamp != Source::read(&origin)? || stamp != Source::read(&File::open(source)?)? {
        return Err(invalid(
            "The source changed during this transfer. Use a different destination to start over.",
        ));
    }
    drop(output);
    let part = tempfile::TempPath::try_from_path(partial)?;
    if let Err(error) = part.persist_noclobber(destination) {
        error.path.keep().map_err(|error| error.error)?;
        return Err(error.error);
    }
    let _ = fs::remove_file(record);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn continues_saved_copy_and_never_replaces_an_existing_file() {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path().join("checkpoint.json");
        let source = temp.path().join("source");
        let destination = temp.path().join("destination");
        let content = [vec![37; BLOCK], b"remaining bytes".to_vec()].concat();
        fs::write(&source, &content).unwrap();
        let mut check = Checkpoint::start(
            Source::read(&File::open(&source).unwrap()).unwrap(),
            temp.path(),
            &state,
        )
        .unwrap();
        check.offset = BLOCK as u64;
        check.last_block = digest(&content[..BLOCK]);
        check.save(&state).unwrap();
        let partial = temp.path().join(&check.part);

        fs::write(&partial, &content[..BLOCK - 1]).unwrap();
        assert!(copy_with_retries(&source, &destination, &state, Duration::ZERO).is_err());
        assert!(!destination.exists());

        fs::write(&partial, [&content[..BLOCK], b"uncommitted bytes"].concat()).unwrap();
        let mut attempts = 0;
        retry(Duration::from_secs(1), Duration::ZERO, |advanced| {
            attempts += 1;
            if attempts == 1 {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionReset,
                    "fixture dropped connection",
                ));
            }
            copy_once(&source, &destination, &state, advanced)
        })
        .unwrap();
        assert_eq!(attempts, 2);
        assert_eq!(fs::read(&destination).unwrap(), content);
        assert!(!partial.exists());
        assert!(!state.exists());
        assert!(copy_with_retries(&source, &destination, &state, Duration::ZERO).is_err());
    }
}
