use crate::{client::FileClient, model::*};
use hmac::{Hmac, Mac};
use reqwest::{
    blocking::{Client, Response},
    Method,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fs::File, io::Read, path::Path, time::Duration};
use url::Url;

type Hmac256 = Hmac<Sha256>;
fn hash(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn hmac(key: &[u8], message: &str) -> Vec<u8> {
    let mut mac = Hmac256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(message.as_bytes());
    mac.finalize().into_bytes().to_vec()
}
fn encode(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC)
        .to_string()
        .replace("%2D", "-")
        .replace("%2E", ".")
        .replace("%5F", "_")
        .replace("%7E", "~")
}

pub struct S3Client {
    client: Client,
    endpoint: Url,
    bucket: String,
    prefix: String,
    region: String,
    access: String,
    secret: String,
    token: String,
}
impl S3Client {
    pub fn new(b: &Bookmark, c: &Credentials) -> Result<Self, String> {
        let mut endpoint =
            Url::parse(&b.host).map_err(|_| "S3 endpoint must be an https:// URL.")?;
        if !["http", "https"].contains(&endpoint.scheme())
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
        {
            return Err("Invalid S3 endpoint URL.".into());
        }
        if b.port > 0 {
            endpoint
                .set_port(Some(b.port))
                .map_err(|_| "Invalid port")?;
        }
        Ok(Self {
            client: Client::builder()
                .connect_timeout(Duration::from_secs(15))
                .timeout(Duration::from_secs(3600))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .map_err(|e| e.to_string())?,
            endpoint,
            bucket: b
                .options
                .get("bucket")
                .ok_or("S3 bucket is required.")?
                .clone(),
            prefix: clean_path(&b.path)?,
            region: b
                .options
                .get("region")
                .filter(|s| !s.is_empty())
                .cloned()
                .unwrap_or("us-east-1".into()),
            access: b.username.clone(),
            secret: c.password.clone(),
            token: c.session_token.clone(),
        })
    }
    fn key(&self, path: &str) -> Result<String, String> {
        Ok(child(&self.prefix, &clean_path(path)?))
    }
    fn request(
        &self,
        method: &str,
        key: &str,
        query: &[(&str, String)],
        body: Vec<u8>,
        extra: &[(&str, String)],
    ) -> Result<Response, String> {
        let mut url = self.endpoint.clone();
        let path = format!(
            "{}/{}/{}",
            self.endpoint.path().trim_end_matches('/'),
            encode(&self.bucket),
            key.split('/').map(encode).collect::<Vec<_>>().join("/")
        );
        url.set_path(&path);
        let mut queries: Vec<_> = query.iter().map(|(k, v)| (encode(k), encode(v))).collect();
        queries.sort();
        let canonical_query = queries
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("&");
        if !queries.is_empty() {
            url.set_query(Some(&canonical_query));
        }
        let now = chrono::Utc::now();
        let stamp = now.format("%Y%m%dT%H%M%SZ").to_string();
        let date = now.format("%Y%m%d").to_string();
        let host = match url.port() {
            Some(p) => format!("{}:{p}", url.host_str().ok_or("Invalid S3 host")?),
            None => url.host_str().ok_or("Invalid S3 host")?.into(),
        };
        let mut headers = BTreeMap::from([
            ("host".to_string(), host),
            ("x-amz-content-sha256".into(), hash(&body)),
            ("x-amz-date".into(), stamp.clone()),
        ]);
        if !self.token.is_empty() {
            headers.insert("x-amz-security-token".into(), self.token.clone());
        }
        for (k, v) in extra {
            headers.insert(k.to_lowercase(), v.clone());
        }
        let signed = headers.keys().cloned().collect::<Vec<_>>().join(";");
        let canonical_headers = headers
            .iter()
            .map(|(k, v)| format!("{k}:{}\n", v.trim()))
            .collect::<String>();
        let canonical = format!(
            "{method}\n{}\n{canonical_query}\n{canonical_headers}\n{signed}\n{}",
            url.path(),
            hash(&body)
        );
        let scope = format!("{date}/{}/s3/aws4_request", self.region);
        let to_sign = format!(
            "AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{}",
            hash(canonical.as_bytes())
        );
        let date_key = hmac(format!("AWS4{}", self.secret).as_bytes(), &date);
        let region_key = hmac(&date_key, &self.region);
        let service_key = hmac(&region_key, "s3");
        let signing = hmac(&service_key, "aws4_request");
        let auth = format!(
            "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed}, Signature={}",
            self.access,
            hex::encode(hmac(&signing, &to_sign))
        );
        let mut request = self
            .client
            .request(
                Method::from_bytes(method.as_bytes()).map_err(|e| e.to_string())?,
                url,
            )
            .header("Authorization", auth)
            .body(body);
        for (k, v) in headers {
            request = request.header(k, v);
        }
        request.send().map_err(|e| e.to_string())
    }
    fn check(r: Response) -> Result<Response, String> {
        if r.status().is_success() {
            Ok(r)
        } else {
            let region = r
                .headers()
                .get("x-amz-bucket-region")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            Err(format!(
                "S3 returned HTTP {}. Check credentials, bucket permissions and region{}.",
                r.status().as_u16(),
                if region.is_empty() {
                    String::new()
                } else {
                    format!(" (server region: {region})")
                }
            ))
        }
    }
}
#[derive(Deserialize, Default)]
#[serde(rename_all = "PascalCase")]
struct Listing {
    #[serde(default)]
    contents: Vec<Object>,
    #[serde(default)]
    common_prefixes: Vec<Prefix>,
    #[serde(default)]
    is_truncated: bool,
    #[serde(default)]
    next_continuation_token: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Object {
    key: String,
    size: u64,
    #[serde(default)]
    last_modified: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Prefix {
    prefix: String,
}

impl FileClient for S3Client {
    fn list(&mut self, path: &str) -> Result<Vec<RemoteFile>, String> {
        let key = self.key(path)?;
        let prefix = if key.is_empty() {
            String::new()
        } else {
            format!("{}/", key.trim_end_matches('/'))
        };
        let mut token = String::new();
        let mut files = vec![];
        loop {
            let mut query = vec![
                ("list-type", "2".into()),
                ("delimiter", "/".into()),
                ("prefix", prefix.clone()),
            ];
            if !token.is_empty() {
                query.push(("continuation-token", token.clone()));
            }
            let response = self.request("GET", "", &query, vec![], &[])?;
            if let Some(region) = response
                .headers()
                .get("x-amz-bucket-region")
                .and_then(|v| v.to_str().ok())
            {
                if region != self.region {
                    self.region = region.into();
                    continue;
                }
            }
            let text = Self::check(response)?.text().map_err(|e| e.to_string())?;
            let listing: Listing = quick_xml::de::from_str(&text).map_err(|e| e.to_string())?;
            for item in listing.common_prefixes {
                let name = item
                    .prefix
                    .trim_end_matches('/')
                    .strip_prefix(&prefix)
                    .unwrap_or("")
                    .to_string();
                if name.is_empty() || name.contains('/') || clean_path(&name).is_err() {
                    continue;
                }
                files.push(RemoteFile {
                    path: child(path, &name),
                    name,
                    size: 0,
                    modified: String::new(),
                    is_dir: true,
                });
            }
            for item in listing.contents {
                let name = item.key.strip_prefix(&prefix).unwrap_or("").to_string();
                if name.is_empty() || name.contains('/') || clean_path(&name).is_err() {
                    continue;
                }
                files.push(RemoteFile {
                    path: child(path, &name),
                    name,
                    size: item.size,
                    modified: item.last_modified,
                    is_dir: false,
                });
            }
            if !listing.is_truncated {
                break;
            }
            if listing.next_continuation_token.is_empty()
                || listing.next_continuation_token == token
            {
                return Err("S3 returned an invalid pagination token.".into());
            }
            token = listing.next_continuation_token;
        }
        Ok(files)
    }
    fn download(&mut self, path: &str, local: &Path) -> Result<(), String> {
        let mut r = Self::check(self.request("GET", &self.key(path)?, &[], vec![], &[])?)?;
        let mut file = File::create(local).map_err(|e| e.to_string())?;
        std::io::copy(&mut r, &mut file).map_err(|e| e.to_string())?;
        Ok(())
    }
    fn upload(&mut self, local: &Path, path: &str) -> Result<(), String> {
        // Bounded memory in this first release. Multipart is tracked in ROADMAP.md.
        let file = File::open(local).map_err(|e| e.to_string())?;
        if file.metadata().map_err(|e| e.to_string())?.len() > 100 * 1024 * 1024 {
            return Err(
                "S3 uploads above 100 MiB need multipart upload, planned for the next milestone."
                    .into(),
            );
        }
        let mut bytes = vec![];
        file.take(100 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > 100 * 1024 * 1024 {
            return Err("File grew beyond the S3 upload limit.".into());
        }
        Self::check(self.request(
            "PUT",
            &self.key(path)?,
            &[],
            bytes,
            &[("if-none-match", "*".into())],
        )?)?;
        Ok(())
    }
    fn mkdir(&mut self, path: &str) -> Result<(), String> {
        Self::check(self.request(
            "PUT",
            &format!("{}/", self.key(path)?),
            &[],
            vec![],
            &[("if-none-match", "*".into())],
        )?)?;
        Ok(())
    }
    fn delete(&mut self, path: &str, is_dir: bool) -> Result<(), String> {
        if clean_path(path)?.is_empty() {
            return Err("Cannot delete a connection root.".into());
        }
        if is_dir && !self.list(path)?.is_empty() {
            return Err("Only empty S3 folders can be deleted.".into());
        }
        let key = format!("{}{}", self.key(path)?, if is_dir { "/" } else { "" });
        Self::check(self.request("DELETE", &key, &[], vec![], &[])?)?;
        Ok(())
    }
    fn rename(&mut self, _: &str, _: &str) -> Result<(), String> {
        Err(
            "S3 rename needs a copy/delete transaction and is not available in this release."
                .into(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn aws_encoding() {
        assert_eq!(encode("hello world+~.txt"), "hello%20world%2B~.txt");
    }
    #[test]
    fn hash_vector() {
        assert_eq!(
            hash(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }
    #[test]
    fn s3_listing_xml() {
        let xml = r#"<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><IsTruncated>false</IsTruncated><Contents><Key>a.txt</Key><Size>7</Size><LastModified>2026-01-01</LastModified></Contents><CommonPrefixes><Prefix>folder/</Prefix></CommonPrefixes></ListBucketResult>"#;
        let l: Listing = quick_xml::de::from_str(xml).unwrap();
        assert_eq!(l.contents[0].size, 7);
        assert_eq!(l.common_prefixes[0].prefix, "folder/");
    }
}
