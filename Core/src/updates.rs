use reqwest::{blocking::Client, redirect::Policy, StatusCode};
use serde::{Deserialize, Serialize};
use std::time::Duration;

const RELEASE_API: &str = "https://api.github.com/repos/oseanstudio/myDrive/releases/latest";
const DOWNLOAD_BASE: &str = "https://github.com/oseanstudio/myDrive/releases/download";

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    draft: bool,
    prerelease: bool,
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    state: String,
    size: u64,
}

#[derive(Serialize)]
pub struct Update {
    version: String,
    url: String,
}

pub fn check(installed: &str) -> Result<Option<Update>, String> {
    let installed = version_parts(installed).ok_or("Invalid installed app version.")?;
    let asset = if cfg!(all(target_os = "windows", target_arch = "x86_64")) {
        "myDrive-Windows-x64-Setup.exe"
    } else if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        "myDrive-macOS-AppleSilicon.dmg"
    } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        "myDrive-Linux-x86_64.AppImage"
    } else {
        return Err("GitHub releases do not contain an installer for this computer.".into());
    };

    let response = Client::builder()
        .https_only(true)
        .redirect(Policy::none())
        .user_agent("myDrive")
        .timeout(Duration::from_secs(8))
        .build()
        .and_then(|client| client.get(RELEASE_API).send())
        .map_err(|_| "Could not reach GitHub to check for updates.")?;
    if response.status() == StatusCode::NOT_FOUND {
        return Ok(None);
    }
    if response.status() != StatusCode::OK {
        return Err("GitHub could not check for updates. Try again later.".into());
    }
    let release: Release = response
        .json()
        .map_err(|_| "GitHub returned an unreadable update response.")?;
    Ok(available_update(installed, &release, asset))
}

fn version_parts(version: &str) -> Option<[u32; 3]> {
    let parts: Vec<_> = version.split('.').collect();
    let [major, minor, patch] = parts.as_slice() else {
        return None;
    };
    let parse = |part: &str| {
        if part.bytes().all(|byte| byte.is_ascii_digit()) && (part == "0" || !part.starts_with('0'))
        {
            part.parse::<u32>().ok()
        } else {
            None
        }
    };
    Some([parse(major)?, parse(minor)?, parse(patch)?])
}

fn available_update(installed: [u32; 3], release: &Release, asset: &str) -> Option<Update> {
    let version = release.tag_name.strip_prefix('v')?;
    if release.draft || release.prerelease || version_parts(version)? <= installed {
        return None;
    }
    if !release
        .assets
        .iter()
        .any(|entry| entry.name == asset && entry.state == "uploaded" && entry.size > 0)
    {
        return None;
    }
    Some(Update {
        version: version.into(),
        url: format!("{DOWNLOAD_BASE}/{}/{asset}", release.tag_name),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const WINDOWS: &str = "myDrive-Windows-x64-Setup.exe";
    const LINUX: &str = "myDrive-Linux-x86_64.AppImage";

    fn release() -> Release {
        Release {
            tag_name: "v0.4.10".into(),
            draft: false,
            prerelease: false,
            assets: vec![Asset {
                name: WINDOWS.into(),
                state: "uploaded".into(),
                size: 42,
            }],
        }
    }

    #[test]
    fn offers_only_a_newer_released_version_for_the_platform() {
        let release = release();
        let update = available_update([0, 4, 9], &release, WINDOWS).unwrap();
        assert_eq!(update.version, "0.4.10");
        assert_eq!(update.url, format!("{DOWNLOAD_BASE}/v0.4.10/{WINDOWS}"));
        assert!(available_update([0, 4, 10], &release, WINDOWS).is_none());
        assert!(available_update([0, 5, 0], &release, WINDOWS).is_none());
        assert!(available_update([0, 4, 9], &release, LINUX).is_none());
    }

    #[test]
    fn excludes_drafts_previews_and_unpublished_assets() {
        let mut release = release();
        release.draft = true;
        assert!(available_update([0, 4, 9], &release, WINDOWS).is_none());
        release.draft = false;
        release.prerelease = true;
        assert!(available_update([0, 4, 9], &release, WINDOWS).is_none());
        release.prerelease = false;
        release.assets[0].state = "new".into();
        assert!(available_update([0, 4, 9], &release, WINDOWS).is_none());
        for value in [
            "0.4.10-preview",
            "0.4.010",
            "0.4.10/extra",
            "0.4.+10",
            "0.4.",
        ] {
            assert!(version_parts(value).is_none());
        }
    }
}
