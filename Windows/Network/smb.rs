//! Native SMB connection adapter. Runs in the cancellable Rust sidecar process.
use crate::model::{Bookmark, Credentials, Protocol};
use windows_sys::Win32::NetworkManagement::WNet::{
    WNetAddConnection2W, WNetGetConnectionW, NETRESOURCEW,
};
fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}
pub fn connect(b: &Bookmark, c: &Credentials) -> Result<(), String> {
    if b.protocol != Protocol::Smb
        || b.host.contains(['\\', '/', '\0', ':'])
        || b.host.trim().is_empty()
        || b.path
            .split(['\\', '/'])
            .any(|s| s == ".." || s.contains('\0'))
        || b.path.trim_matches(['\\', '/']).is_empty()
    {
        return Err("Enter a server name and share name for the SMB connection.".into());
    }
    let remote = format!(
        r"\\{}\{}",
        b.host,
        b.path.trim_matches(['\\', '/']).replace('/', r"\")
    );
    let remote_w = wide(&remote);
    let local_w = wide(&b.mount_path);
    let password = wide(&c.password);
    let user = wide(&b.username);
    if !b.mount_path.is_empty()
        && (b.mount_path.len() != 2
            || !b.mount_path.as_bytes()[0].is_ascii_alphabetic()
            || !b.mount_path.ends_with(':'))
    {
        return Err("Use a drive letter such as M: or leave it blank.".into());
    }
    let resource = NETRESOURCEW {
        dwScope: 0,
        dwType: 1,
        dwDisplayType: 0,
        dwUsage: 0,
        lpLocalName: if b.mount_path.is_empty() {
            std::ptr::null_mut()
        } else {
            local_w.as_ptr() as *mut u16
        },
        lpRemoteName: remote_w.as_ptr() as *mut u16,
        lpComment: std::ptr::null_mut(),
        lpProvider: std::ptr::null_mut(),
    };
    let result = unsafe {
        WNetAddConnection2W(
            &resource,
            if c.password.is_empty() {
                std::ptr::null()
            } else {
                password.as_ptr()
            },
            if b.username.is_empty() {
                std::ptr::null()
            } else {
                user.as_ptr()
            },
            0,
        )
    };
    match result{
        0=>Ok(()),
        85 if !b.mount_path.is_empty()=>{let mut buffer=vec![0u16;32768];let mut length=buffer.len() as u32;let check=unsafe{WNetGetConnectionW(local_w.as_ptr(),buffer.as_mut_ptr(),&mut length)};
            let current=String::from_utf16_lossy(&buffer[..buffer.iter().position(|v|*v==0).unwrap_or(buffer.len())]);
            if check==0&&current.trim_end_matches('\\').eq_ignore_ascii_case(remote.trim_end_matches('\\')){Ok(())}else{Err("That drive letter is already in use by a different location. Choose another drive letter.".into())}},
        5|86|1326=>Err("The SMB server rejected these credentials. Check your username, password and folder permissions.".into()),
        53|67=>Err("The shared folder cannot be reached. Check the server/share name and that both computers are online.".into()),
        1219=>Err("Windows already has a connection to this server using another account. Use that account or disconnect the other server session first.".into()),
        error=>Err(format!("Windows could not connect to this SMB share (error {error}).")),
    }
}
