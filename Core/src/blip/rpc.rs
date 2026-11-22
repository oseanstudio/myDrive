use socket2::{Domain, SockAddr, Socket, Type};
use std::io::{BufReader, Read, Write};
#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;
#[cfg(unix)]
use std::os::{
    fd::AsRawFd,
    unix::fs::{FileTypeExt, MetadataExt},
};
use std::path::Path;
#[cfg(windows)]
use std::ptr;
use std::time::{Duration, Instant};
#[cfg(windows)]
use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, INVALID_HANDLE_VALUE};
#[cfg(windows)]
use windows_sys::Win32::Security::Authorization::{GetNamedSecurityInfoW, SE_FILE_OBJECT};
#[cfg(windows)]
use windows_sys::Win32::Security::{
    EqualSid, GetTokenInformation, TokenUser, OWNER_SECURITY_INFORMATION, TOKEN_QUERY, TOKEN_USER,
};
#[cfg(windows)]
use windows_sys::Win32::Storage::FileSystem::{FindClose, FindFirstFileW, WIN32_FIND_DATAW};
#[cfg(windows)]
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

pub(super) type Result<T> = std::result::Result<T, &'static str>;
const MAXIMUM: usize = 32 * 1024 * 1024;
const INVALID: &str = "invalid_native_response";
const CONNECTION: &str = "native_connection_unavailable";
const READ_TIMEOUT: Duration = Duration::from_secs(if cfg!(target_os = "macos") { 5 } else { 2 });
const RESPONSE_TIMEOUT: Duration =
    Duration::from_secs(if cfg!(target_os = "macos") { 15 } else { 5 });

pub(super) fn connect(path: &Path) -> Result<Socket> {
    if !local_endpoint(path) {
        return Err(CONNECTION);
    }
    let address = SockAddr::unix(path).map_err(|_| CONNECTION)?;
    let socket = Socket::new(Domain::UNIX, Type::STREAM, None).map_err(|_| CONNECTION)?;
    socket
        .connect_timeout(&address, Duration::from_millis(500))
        .map_err(|_| CONNECTION)?;
    #[cfg(unix)]
    if !same_user(&socket) {
        return Err(CONNECTION);
    }
    socket
        .set_read_timeout(Some(READ_TIMEOUT))
        .map_err(|_| CONNECTION)?;
    socket
        .set_write_timeout(Some(READ_TIMEOUT))
        .map_err(|_| CONNECTION)?;
    Ok(socket)
}

#[cfg(windows)]
fn local_endpoint(path: &Path) -> bool {
    let Some(parent) = path.parent() else {
        return false;
    };
    if super::check_plain_directory(parent).is_err() {
        return false;
    }
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain([0]).collect();
    let parent: Vec<u16> = parent.as_os_str().encode_wide().chain([0]).collect();
    unsafe {
        let mut entry = WIN32_FIND_DATAW::default();
        let search = FindFirstFileW(wide.as_ptr(), &mut entry);
        if search == INVALID_HANDLE_VALUE {
            return false;
        }
        FindClose(search);
        // AF_UNIX entries are reparse points. Only the kernel socket tag is accepted.
        if entry.dwReserved0 != 0x80000023 {
            return false;
        }
        let mut owner = ptr::null_mut();
        let mut descriptor = ptr::null_mut();
        let status = GetNamedSecurityInfoW(
            parent.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            &mut owner,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            &mut descriptor,
        );
        let owned = status == 0 && !owner.is_null() && current_user_owns(owner);
        if !descriptor.is_null() {
            LocalFree(descriptor);
        }
        owned
    }
}

#[cfg(target_os = "macos")]
fn local_endpoint(path: &Path) -> bool {
    std::fs::symlink_metadata(path)
        .is_ok_and(|file| file.file_type().is_socket() && file.uid() == unsafe { libc::geteuid() })
}

#[cfg(target_os = "macos")]
fn same_user(socket: &Socket) -> bool {
    let mut uid = 0;
    let mut gid = 0;
    unsafe {
        libc::getpeereid(socket.as_raw_fd(), &mut uid, &mut gid) == 0 && uid == libc::geteuid()
    }
}

#[cfg(windows)]
unsafe fn current_user_owns(owner: windows_sys::Win32::Security::PSID) -> bool {
    let mut token = ptr::null_mut();
    if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
        return false;
    }
    let mut length = 0;
    GetTokenInformation(token, TokenUser, ptr::null_mut(), 0, &mut length);
    let mut storage = vec![0_usize; (length as usize).div_ceil(size_of::<usize>())];
    let success = length >= size_of::<TOKEN_USER>() as u32
        && GetTokenInformation(
            token,
            TokenUser,
            storage.as_mut_ptr().cast(),
            length,
            &mut length,
        ) != 0;
    CloseHandle(token);
    success && EqualSid(owner, (*storage.as_ptr().cast::<TOKEN_USER>()).User.Sid) != 0
}

#[cfg(target_os = "linux")]
fn local_endpoint(path: &Path) -> bool {
    path.parent()
        .is_some_and(|parent| super::check_plain_directory(parent).is_ok())
        && std::fs::symlink_metadata(path).is_ok_and(|file| {
            file.file_type().is_socket() && file.uid() == unsafe { libc::geteuid() }
        })
}

#[cfg(target_os = "linux")]
fn same_user(socket: &Socket) -> bool {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of_val(&credentials) as libc::socklen_t;
    unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        ) == 0
            && length as usize == std::mem::size_of_val(&credentials)
            && credentials.uid == libc::geteuid()
    }
}

// DRPC framing for the native Blip hosts.
pub(super) fn call(path: &Path, method: &str, body: &[u8]) -> Result<Vec<u8>> {
    let mut socket = connect(path)?;
    let metadata = field(
        1,
        &[
            string(1, "user-agent"),
            string(2, concat!("myDrive/", env!("CARGO_PKG_VERSION"))),
        ]
        .concat(),
    );
    let mut request = Vec::new();
    frame(&mut request, 7, 1, &metadata);
    frame(&mut request, 1, 2, method.as_bytes());
    frame(&mut request, 2, 3, body);
    frame(&mut request, 6, 4, &[]);
    socket.write_all(&request).map_err(|_| CONNECTION)?;
    let mut reader = BufReader::new(socket);
    let mut payload = Vec::new();
    let mut receiving = None;
    let mut total = 0;
    let deadline = Instant::now() + RESPONSE_TIMEOUT;
    for _ in 0..4096 {
        let flags = byte(&mut reader, deadline)?;
        let mut next = || byte(&mut reader, deadline);
        let stream = varint(&mut next)?;
        let message = varint(&mut next)?;
        let count = varint(&mut next)?;
        if count > (MAXIMUM - total) as u64 {
            return Err("native_response_too_large");
        }
        total += count as usize;
        let mut data = vec![0; count as usize];
        for slice in data.chunks_mut(8192) {
            if Instant::now() >= deadline {
                return Err(CONNECTION);
            }
            reader.read_exact(slice).map_err(|_| CONNECTION)?;
        }
        if flags & 128 != 0 {
            continue;
        }
        if stream != 1 {
            return Err(INVALID);
        }
        match (flags & 126) >> 1 {
            2 => {
                if receiving.is_some_and(|id| id != message) {
                    return Err(INVALID);
                }
                receiving = Some(message);
                payload.extend(data);
                if flags & 1 != 0 {
                    return Ok(payload);
                }
            }
            3 | 5 => return Err("native_request_rejected"),
            _ => {}
        }
    }
    Err(INVALID)
}

fn byte(reader: &mut impl Read, deadline: Instant) -> Result<u8> {
    if Instant::now() >= deadline {
        return Err(CONNECTION);
    }
    let mut one = [0];
    reader.read_exact(&mut one).map_err(|_| CONNECTION)?;
    Ok(one[0])
}

fn frame(output: &mut Vec<u8>, kind: u8, message: u64, body: &[u8]) {
    output.push(kind * 2 + 1);
    output.push(1);
    encode_varint(output, message);
    encode_varint(output, body.len() as u64);
    output.extend_from_slice(body);
}

pub(super) fn varint(mut next: impl FnMut() -> Result<u8>) -> Result<u64> {
    let mut value = 0;
    for shift in (0..64).step_by(7) {
        let byte = next()?;
        if shift == 63 && byte > 1 {
            return Err(INVALID);
        }
        value |= u64::from(byte & 127) << shift;
        if byte & 128 == 0 {
            return Ok(value);
        }
    }
    Err(INVALID)
}

pub(super) fn encode_varint(output: &mut Vec<u8>, mut value: u64) {
    while value >= 128 {
        output.push(value as u8 | 128);
        value >>= 7;
    }
    output.push(value as u8);
}

pub(super) fn field(tag: u64, value: &[u8]) -> Vec<u8> {
    let mut output = Vec::new();
    encode_varint(&mut output, tag * 8 + 2);
    encode_varint(&mut output, value.len() as u64);
    output.extend_from_slice(value);
    output
}

pub(super) fn string(tag: u64, value: &str) -> Vec<u8> {
    field(tag, value.as_bytes())
}

pub(super) fn number(tag: u64, value: u64) -> Vec<u8> {
    let mut output = Vec::new();
    encode_varint(&mut output, tag * 8);
    encode_varint(&mut output, value);
    output
}

#[derive(Default)]
pub(super) struct Proto<'a>(Vec<(u64, Wire<'a>)>);
enum Wire<'a> {
    Number(u64),
    Bytes(&'a [u8]),
    Unknown,
}

impl<'a> Proto<'a> {
    pub(super) fn parse(mut input: &'a [u8]) -> Result<Self> {
        fn take<'a>(input: &mut &'a [u8], count: usize) -> Result<&'a [u8]> {
            let (head, tail) = input.split_at_checked(count).ok_or(INVALID)?;
            *input = tail;
            Ok(head)
        }
        fn read(input: &mut &[u8]) -> Result<u64> {
            varint(|| Ok(take(input, 1)?[0]))
        }
        let mut fields = Vec::new();
        while !input.is_empty() {
            if fields.len() == 200_000 {
                return Err("native_response_too_large");
            }
            let key = read(&mut input)?;
            let tag = key >> 3;
            if !(1..=536_870_911).contains(&tag) {
                return Err(INVALID);
            }
            let value = match key & 7 {
                0 => Wire::Number(read(&mut input)?),
                2 => {
                    let length = usize::try_from(read(&mut input)?).map_err(|_| INVALID)?;
                    Wire::Bytes(take(&mut input, length)?)
                }
                1 => {
                    take(&mut input, 8)?;
                    Wire::Unknown
                }
                5 => {
                    take(&mut input, 4)?;
                    Wire::Unknown
                }
                _ => return Err(INVALID),
            };
            fields.push((tag, value));
        }
        Ok(Self(fields))
    }

    fn only(&self, tag: u64) -> Option<&Wire<'a>> {
        let mut found = self.0.iter().filter(|(key, _)| *key == tag);
        let (_, value) = found.next()?;
        found.next().is_none().then_some(value)
    }

    pub(super) fn bytes(&self, tag: u64) -> Option<&'a [u8]> {
        match self.only(tag)? {
            Wire::Bytes(value) => Some(value),
            _ => None,
        }
    }

    pub(super) fn text(&self, tag: u64) -> &'a str {
        self.bytes(tag)
            .and_then(|value| std::str::from_utf8(value).ok())
            .unwrap_or_default()
    }

    pub(super) fn number(&self, tag: u64) -> u64 {
        match self.only(tag) {
            Some(Wire::Number(value)) => *value,
            _ => 0,
        }
    }

    pub(super) fn has(&self, tag: u64) -> bool {
        self.0.iter().any(|(key, _)| *key == tag)
    }

    pub(super) fn message(&self, tag: u64) -> Result<Self> {
        Self::parse(self.bytes(tag).unwrap_or_default())
    }

    pub(super) fn messages(&self, tag: u64) -> impl Iterator<Item = Result<Self>> + '_ {
        self.0
            .iter()
            .filter(move |(key, _)| *key == tag)
            .map(|(_, value)| match value {
                Wire::Bytes(data) => Self::parse(data),
                _ => Err(INVALID),
            })
    }
}
