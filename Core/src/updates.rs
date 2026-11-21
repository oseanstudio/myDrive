use reqwest::{blocking::Client, header, redirect::Policy, StatusCode};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{BufReader, Read, Write},
    path::Path,
    time::{Duration, Instant},
};

const RELEASE_API: &str = "https://api.github.com/repos/oseanstudio/myDrive/releases";
const DOWNLOAD_BASE: &str = "https://github.com/oseanstudio/myDrive/releases/download";
const CHECK_TIMEOUT: Duration = Duration::from_secs(8);

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
    digest: Option<String>,
}

#[derive(Serialize)]
pub struct Update {
    pub version: String,
    url: String,
    #[serde(skip)]
    size: u64,
    #[serde(skip)]
    checksum: [u8; 32],
}

pub fn asset_name() -> Result<&'static str, String> {
    if cfg!(all(target_os = "windows", target_arch = "x86_64")) {
        Ok("myDrive-Windows-x64-Setup.exe")
    } else if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Ok("myDrive-macOS-AppleSilicon.dmg")
    } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        Ok("myDrive-Linux-x86_64.AppImage")
    } else {
        Err("GitHub releases do not contain an installer for this computer.".into())
    }
}

pub fn check(installed: &str) -> Result<Option<Update>, String> {
    let installed = version_parts(installed).ok_or("Invalid installed app version.")?;
    let asset = asset_name()?;
    let client = Client::builder()
        .https_only(true)
        .redirect(Policy::none())
        .user_agent("myDrive")
        .build()
        .map_err(|_| "Could not reach GitHub to check for updates.")?;
    let deadline = Instant::now() + CHECK_TIMEOUT;
    let mut minimum = installed;
    let mut latest = None;
    for page in 1u32.. {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("GitHub did not finish listing releases in time.".into());
        }
        let response = client
            .get(RELEASE_API)
            .query(&[("per_page", 100), ("page", page)])
            .header(header::CACHE_CONTROL, "no-cache")
            .timeout(remaining)
            .send()
            .map_err(|_| "Could not reach GitHub to check for updates.")?;
        if response.status() == StatusCode::NOT_FOUND && page == 1 {
            return Ok(None);
        }
        if response.status() != StatusCode::OK {
            return Err("GitHub could not check for updates. Try again later.".into());
        }
        let more = response.headers().get_all(header::LINK).iter().any(|link| {
            link.to_str().is_ok_and(|value| {
                value.split(',').any(|part| {
                    part.split(';')
                        .skip(1)
                        .any(|parameter| parameter.trim() == "rel=\"next\"")
                })
            })
        });
        let releases: Vec<Release> =
            serde_json::from_reader(BufReader::new(response.take(16 * 1024 * 1024)))
                .map_err(|_| "GitHub returned an unreadable update response.")?;
        if let Some((version, update)) = latest_update(minimum, &releases, asset) {
            minimum = version;
            latest = Some(update);
        }
        if !more {
            return Ok(latest);
        }
    }
    Err("GitHub returned too many releases to check.".into())
}

pub fn download(update: &Update, destination: &Path) -> Result<(), String> {
    let redirects = Policy::custom(|attempt| {
        let url = attempt.url();
        if attempt.previous().len() < 4
            && url.scheme() == "https"
            && matches!(
                url.host_str(),
                Some("release-assets.githubusercontent.com" | "objects.githubusercontent.com")
            )
        {
            attempt.follow()
        } else {
            attempt.error("Unexpected update download redirect")
        }
    });
    let response = Client::builder()
        .https_only(true)
        .redirect(redirects)
        .user_agent("myDrive")
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(600))
        .build()
        .and_then(|client| client.get(&update.url).send())
        .and_then(|response| response.error_for_status())
        .map_err(|_| "Could not download the update from GitHub.")?;
    let mut file = File::create(destination).map_err(|_| "Could not save the update package.")?;
    copy_verified(response, &mut file, update.size, &update.checksum)?;
    file.sync_all()
        .map_err(|_| "Could not save the update package.".into())
}

fn copy_verified(
    reader: impl Read,
    mut destination: impl Write,
    size: u64,
    checksum: &[u8; 32],
) -> Result<(), String> {
    let mut reader = reader.take(size + 1);
    let mut hasher = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    let mut length = 0;
    loop {
        let count = reader
            .read(&mut buffer)
            .map_err(|_| "The update download was interrupted.")?;
        if count == 0 {
            break;
        }
        length += count as u64;
        if length > size {
            break;
        }
        hasher.update(&buffer[..count]);
        destination
            .write_all(&buffer[..count])
            .map_err(|_| "Could not save the update package.")?;
    }
    if length != size || <[u8; 32]>::from(hasher.finalize()) != *checksum {
        return Err("The downloaded package did not match GitHub’s checksum.".into());
    }
    Ok(())
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

fn latest_update(
    installed: [u32; 3],
    releases: &[Release],
    asset: &str,
) -> Option<([u32; 3], Update)> {
    releases
        .iter()
        .filter_map(|release| available_update(installed, release, asset))
        .max_by_key(|(version, _)| *version)
}

fn available_update(
    installed: [u32; 3],
    release: &Release,
    asset: &str,
) -> Option<([u32; 3], Update)> {
    let version = release.tag_name.strip_prefix('v')?;
    let parts = version_parts(version)?;
    if release.draft || release.prerelease || parts <= installed {
        return None;
    }
    let package = release.assets.iter().find(|entry| {
        entry.name == asset
            && entry.state == "uploaded"
            && (1..=1024 * 1024 * 1024).contains(&entry.size)
    })?;
    let digest = package.digest.as_deref()?.strip_prefix("sha256:")?;
    let mut checksum = [0; 32];
    hex::decode_to_slice(digest, &mut checksum).ok()?;
    Some((
        parts,
        Update {
            version: version.into(),
            url: format!("{DOWNLOAD_BASE}/{}/{asset}", release.tag_name),
            size: package.size,
            checksum,
        },
    ))
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
                digest: Some(format!("sha256:{}", "1a".repeat(32))),
            }],
        }
    }

    #[test]
    fn offers_only_a_newer_released_version_for_the_platform() {
        let release = release();
        let (_, update) = available_update([0, 4, 9], &release, WINDOWS).unwrap();
        assert_eq!(update.version, "0.4.10");
        assert_eq!(update.url, format!("{DOWNLOAD_BASE}/v0.4.10/{WINDOWS}"));
        assert!(available_update([0, 4, 10], &release, WINDOWS).is_none());
        assert!(available_update([0, 5, 0], &release, WINDOWS).is_none());
        assert!(available_update([0, 4, 9], &release, LINUX).is_none());
    }

    #[test]
    fn skips_intermediate_releases_and_selects_the_highest_compatible_version() {
        let versions = [
            ("v0.4.8", WINDOWS, false),
            ("v0.4.30", LINUX, false),
            ("v0.4.12", WINDOWS, false),
            ("v0.4.9", WINDOWS, false),
            ("v0.4.40", WINDOWS, true),
        ];
        let releases = versions.map(|(tag, asset, prerelease)| {
            let mut release = release();
            release.tag_name = tag.into();
            release.assets[0].name = asset.into();
            release.prerelease = prerelease;
            release
        });
        let (version, update) = latest_update([0, 4, 7], &releases, WINDOWS).unwrap();
        assert_eq!(version, [0, 4, 12]);
        assert_eq!(update.version, "0.4.12");
        assert_eq!(
            latest_update([0, 4, 7], &releases, LINUX)
                .unwrap()
                .1
                .version,
            "0.4.30"
        );
        assert!(latest_update(version, &releases, WINDOWS).is_none());
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

    #[test]
    fn stages_only_content_matching_the_release_size_and_digest() {
        let content = b"known payload";
        let checksum = Sha256::digest(content).into();
        let mut file = Vec::new();
        copy_verified(&content[..], &mut file, content.len() as u64, &checksum).unwrap();
        assert_eq!(file, content);
        assert!(copy_verified(&content[..], Vec::new(), 2, &checksum).is_err());
        assert!(copy_verified(&content[..], Vec::new(), content.len() as u64, &[0; 32]).is_err());
        assert!(copy_verified(&content[..4], Vec::new(), content.len() as u64, &checksum).is_err());
    }
}
