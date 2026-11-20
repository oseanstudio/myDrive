use crate::{client::FileClient, model::*};
use reqwest::{
    blocking::{Client, Response},
    Method,
};
use serde::Deserialize;
use std::{fs::File, path::Path, time::Duration};
use url::Url;

pub struct WebDav {
    client: Client,
    base: Url,
    user: String,
    password: String,
}
impl WebDav {
    pub fn new(b: &Bookmark, c: &Credentials) -> Result<Self, String> {
        let mut base = Url::parse(&b.host).map_err(|_| {
            "WebDAV address must start with https:// (or http:// for a trusted local server)."
        })?;
        if !["https", "http"].contains(&base.scheme())
            || !base.username().is_empty()
            || base.password().is_some()
            || base.query().is_some()
            || base.fragment().is_some()
        {
            return Err(
                "Use an HTTP(S) server URL without embedded credentials, query or fragment.".into(),
            );
        }
        if b.port > 0 {
            base.set_port(Some(b.port)).map_err(|_| "Invalid port")?;
        }
        let path = format!(
            "{}/{}/",
            base.path().trim_end_matches('/'),
            b.path.trim_matches('/')
        );
        base.set_path(&path.replace("//", "/"));
        Ok(Self {
            client: Client::builder()
                .connect_timeout(Duration::from_secs(15))
                .timeout(Duration::from_secs(3600))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .map_err(|e| e.to_string())?,
            base,
            user: b.username.clone(),
            password: c.password.clone(),
        })
    }
    fn url(&self, path: &str) -> Result<Url, String> {
        let path = clean_path(path)?;
        let mut url = self.base.clone();
        {
            let mut segments = url.path_segments_mut().map_err(|_| "Invalid server URL")?;
            segments.pop_if_empty();
            for p in path.split('/').filter(|s| !s.is_empty()) {
                segments.push(p);
            }
        }
        Ok(url)
    }
    fn request(&self, verb: &str, path: &str) -> Result<reqwest::blocking::RequestBuilder, String> {
        Ok(self
            .client
            .request(
                Method::from_bytes(verb.as_bytes()).map_err(|e| e.to_string())?,
                self.url(path)?,
            )
            .basic_auth(&self.user, Some(&self.password)))
    }
    fn check(response: Response) -> Result<Response, String> {
        let status = response.status();
        if status.is_success() {
            Ok(response)
        } else {
            Err(format!(
                "WebDAV returned HTTP {}. Check the address, credentials and server permissions.",
                status.as_u16()
            ))
        }
    }
}

#[derive(Debug, Deserialize)]
struct MultiStatus {
    #[serde(rename = "response", default)]
    responses: Vec<DavResponse>,
}
#[derive(Debug, Deserialize)]
struct DavResponse {
    href: String,
    #[serde(rename = "propstat", default)]
    props: Vec<PropStat>,
}
#[derive(Debug, Deserialize)]
struct PropStat {
    #[serde(default)]
    status: String,
    prop: Prop,
}
#[derive(Debug, Deserialize, Default)]
struct Prop {
    #[serde(default)]
    getcontentlength: Option<u64>,
    #[serde(default)]
    getlastmodified: String,
    #[serde(default)]
    resourcetype: ResourceType,
}
#[derive(Debug, Deserialize, Default)]
struct ResourceType {
    #[serde(default)]
    collection: Option<Collection>,
}
#[derive(Debug, Deserialize)]
struct Collection {}

fn parse_listing(xml: &str, base: &Url, parent: &str) -> Result<Vec<RemoteFile>, String> {
    let parsed: MultiStatus =
        quick_xml::de::from_str(xml).map_err(|e| format!("Invalid WebDAV listing: {e}"))?;
    let mut output = vec![];
    let base_path = percent_encoding::percent_decode_str(base.path())
        .decode_utf8_lossy()
        .trim_end_matches('/')
        .to_string();
    for r in parsed.responses {
        let href = base.join(&r.href).map_err(|e| e.to_string())?;
        if href.origin() != base.origin() {
            continue;
        }
        let decoded = percent_encoding::percent_decode_str(href.path())
            .decode_utf8_lossy()
            .trim_end_matches('/')
            .to_string();
        if decoded == base_path {
            continue;
        }
        let prefix = format!("{base_path}/");
        let Some(name) = decoded.strip_prefix(&prefix) else {
            continue;
        };
        if name.is_empty() || name.contains('/') || clean_path(name).is_err() {
            continue;
        }
        if let Some(p) = r.props.into_iter().find(|p| p.status.contains(" 200 ")) {
            output.push(RemoteFile {
                name: name.into(),
                path: child(parent, name),
                size: p.prop.getcontentlength.unwrap_or(0),
                modified: p.prop.getlastmodified,
                is_dir: p.prop.resourcetype.collection.is_some(),
            });
        }
    }
    Ok(output)
}

impl FileClient for WebDav {
    fn list(&mut self, path: &str) -> Result<Vec<RemoteFile>, String> {
        let response=Self::check(self.request("PROPFIND",path)?.header("Depth","1").header("Content-Type","application/xml").body(r#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"#).send().map_err(|e|e.to_string())?)?;
        parse_listing(
            &response.text().map_err(|e| e.to_string())?,
            &self.url(path)?,
            path,
        )
    }
    fn download(&mut self, path: &str, local: &Path) -> Result<(), String> {
        let mut r = Self::check(
            self.request("GET", path)?
                .send()
                .map_err(|e| e.to_string())?,
        )?;
        let mut f = File::create(local).map_err(|e| e.to_string())?;
        std::io::copy(&mut r, &mut f).map_err(|e| e.to_string())?;
        Ok(())
    }
    fn upload(&mut self, local: &Path, path: &str) -> Result<(), String> {
        let file = File::open(local).map_err(|e| e.to_string())?;
        Self::check(
            self.request("PUT", path)?
                .header("If-None-Match", "*")
                .body(file)
                .send()
                .map_err(|e| e.to_string())?,
        )?;
        Ok(())
    }
    fn mkdir(&mut self, path: &str) -> Result<(), String> {
        Self::check(
            self.request("MKCOL", path)?
                .send()
                .map_err(|e| e.to_string())?,
        )?;
        Ok(())
    }
    fn delete(&mut self, path: &str, _: bool) -> Result<(), String> {
        if clean_path(path)?.is_empty() {
            return Err("Cannot delete a connection root.".into());
        }
        Self::check(
            self.request("DELETE", path)?
                .send()
                .map_err(|e| e.to_string())?,
        )?;
        Ok(())
    }
    fn rename(&mut self, path: &str, destination: &str) -> Result<(), String> {
        Self::check(
            self.request("MOVE", path)?
                .header("Destination", self.url(destination)?.as_str())
                .header("Overwrite", "F")
                .send()
                .map_err(|e| e.to_string())?,
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dav_namespaces_and_encoded_names() {
        let xml = r#"<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:response><d:href>/dav/hello%20world.txt</d:href><d:propstat><d:prop><d:getcontentlength>42</d:getcontentlength><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"#;
        let files =
            parse_listing(xml, &Url::parse("https://example.test/dav/").unwrap(), "").unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].name, "hello world.txt");
        assert_eq!(files[0].size, 42);
    }
}
