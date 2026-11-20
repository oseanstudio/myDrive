//! Local wire fixtures exercise the actual HTTP client without cloud accounts.
use crate::{client::FileClient, model::*, s3::S3Client, webdav::WebDav};
use std::{
    io::{Read, Write},
    net::TcpListener,
    thread,
};

struct Exchange {
    method: &'static str,
    target: &'static str,
    status: u16,
    body: String,
    expect_body: Option<Vec<u8>>,
    expected_header: Option<&'static str>,
}
fn server(exchanges: Vec<Exchange>) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}", listener.local_addr().unwrap());
    let worker = thread::spawn(move || {
        for expected in exchanges {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut bytes = vec![];
            let mut one = [0u8; 1];
            while !bytes.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut one).unwrap();
                bytes.push(one[0]);
                assert!(bytes.len() < 65536);
            }
            let headers = String::from_utf8(bytes).unwrap();
            let first = headers.lines().next().unwrap();
            assert_eq!(
                first,
                format!("{} {} HTTP/1.1", expected.method, expected.target)
            );
            let length = headers
                .lines()
                .find_map(|line| {
                    line.to_lowercase()
                        .strip_prefix("content-length:")
                        .map(|v| v.trim().parse::<usize>().unwrap())
                })
                .unwrap_or(0);
            let mut body = vec![0u8; length];
            stream.read_exact(&mut body).unwrap();
            if let Some(want) = expected.expect_body {
                assert_eq!(body, want);
            }
            if let Some(header) = expected.expected_header {
                assert!(
                    headers.to_lowercase().contains(&header.to_lowercase()),
                    "missing expected header"
                );
            }
            write!(
                stream,
                "HTTP/1.1 {} Test\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                expected.status,
                expected.body.len(),
                expected.body
            )
            .unwrap();
        }
    });
    (address, worker)
}
fn bookmark(host: String, protocol: Protocol) -> Bookmark {
    Bookmark {
        id: "wire-test".into(),
        nickname: "Wire test".into(),
        protocol,
        host,
        port: 0,
        path: String::new(),
        username: "tester".into(),
        credentials_ref: String::new(),
        mount_path: String::new(),
        options: std::collections::BTreeMap::from([
            ("bucket".into(), "test-bucket".into()),
            ("region".into(), "us-east-1".into()),
        ]),
    }
}
#[test]
fn webdav_real_http_roundtrip() {
    let listing = r#"<d:multistatus xmlns:d="DAV:"><d:response><d:href>/hello%20world.txt</d:href><d:propstat><d:prop><d:getcontentlength>5</d:getcontentlength><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"#;
    let (host, worker) = server(vec![
        Exchange {
            method: "PROPFIND",
            target: "/",
            status: 207,
            body: listing.into(),
            expect_body: None,
            expected_header: Some("depth: 1"),
        },
        Exchange {
            method: "GET",
            target: "/hello%20world.txt",
            status: 200,
            body: "hello".into(),
            expect_body: None,
            expected_header: Some("authorization: Basic dGVzdGVyOnNlY3JldA=="),
        },
        Exchange {
            method: "PUT",
            target: "/new.txt",
            status: 201,
            body: String::new(),
            expect_body: Some(b"hello".to_vec()),
            expected_header: Some("if-none-match: *"),
        },
        Exchange {
            method: "MKCOL",
            target: "/folder",
            status: 201,
            body: String::new(),
            expect_body: None,
            expected_header: None,
        },
        Exchange {
            method: "MOVE",
            target: "/new.txt",
            status: 201,
            body: String::new(),
            expect_body: None,
            expected_header: Some("overwrite: F"),
        },
        Exchange {
            method: "DELETE",
            target: "/moved.txt",
            status: 204,
            body: String::new(),
            expect_body: None,
            expected_header: None,
        },
    ]);
    let mut client = WebDav::new(
        &bookmark(host, Protocol::Webdav),
        &Credentials {
            password: "secret".into(),
            ..Default::default()
        },
    )
    .unwrap();
    let files = client.list("").unwrap();
    assert_eq!(files[0].name, "hello world.txt");
    let temporary = tempfile::tempdir().unwrap();
    let local = temporary.path().join("download");
    client.download("hello world.txt", &local).unwrap();
    assert_eq!(std::fs::read(&local).unwrap(), b"hello");
    client.upload(&local, "new.txt").unwrap();
    client.mkdir("folder").unwrap();
    client.rename("new.txt", "moved.txt").unwrap();
    client.delete("moved.txt", false).unwrap();
    worker.join().unwrap();
}
#[test]
fn s3_real_http_signing_and_encoding() {
    let listing = r#"<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>hello world+.txt</Key><Size>5</Size></Contents></ListBucketResult>"#;
    let (host, worker) = server(vec![
        Exchange {
            method: "GET",
            target: "/test-bucket/?delimiter=%2F&list-type=2&prefix=",
            status: 200,
            body: listing.into(),
            expect_body: None,
            expected_header: Some("authorization: AWS4-HMAC-SHA256 Credential=tester/"),
        },
        Exchange {
            method: "GET",
            target: "/test-bucket/hello%20world%2B.txt",
            status: 200,
            body: "hello".into(),
            expect_body: None,
            expected_header: Some("x-amz-content-sha256: e3b0c442"),
        },
        Exchange {
            method: "PUT",
            target: "/test-bucket/new%20file.txt",
            status: 200,
            body: String::new(),
            expect_body: Some(b"hello".to_vec()),
            expected_header: Some("if-none-match: *"),
        },
        Exchange {
            method: "DELETE",
            target: "/test-bucket/new%20file.txt",
            status: 204,
            body: String::new(),
            expect_body: None,
            expected_header: None,
        },
    ]);
    let mut client = S3Client::new(
        &bookmark(host, Protocol::S3),
        &Credentials {
            password: "secret".into(),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(client.list("").unwrap()[0].size, 5);
    let temporary = tempfile::tempdir().unwrap();
    let local = temporary.path().join("download");
    client.download("hello world+.txt", &local).unwrap();
    client.upload(&local, "new file.txt").unwrap();
    client.delete("new file.txt", false).unwrap();
    worker.join().unwrap();
}
#[test]
fn webdav_does_not_follow_credential_redirects() {
    let (host, worker) = server(vec![Exchange {
        method: "GET",
        target: "/secret",
        status: 302,
        body: String::new(),
        expect_body: None,
        expected_header: None,
    }]);
    let mut client =
        WebDav::new(&bookmark(host, Protocol::Webdav), &Credentials::default()).unwrap();
    let temp = tempfile::tempdir().unwrap();
    assert!(client
        .download("secret", &temp.path().join("file"))
        .unwrap_err()
        .contains("302"));
    worker.join().unwrap();
}
#[test]
fn syncthing_events_poll_is_bounded_and_returns_cursor() {
    let events = r#"[{"id":41,"globalID":7,"type":"StateChanged","time":"2026-11-14T10:00:00Z","data":{"folder":"test","from":"idle","to":"scanning"}},{"id":42,"globalID":8,"type":"DeviceConnected","time":"2026-11-14T10:00:05Z","data":{"id":"DEVICE-1"}}]"#;
    let (host, worker) = server(vec![Exchange {
        method: "GET",
        target: "/rest/events?events=ItemFinished%2CStateChanged%2CDeviceConnected%2CDeviceDisconnected%2CFolderErrors%2CFolderSummary&since=40&timeout=10",
        status: 200,
        body: events.into(),
        expect_body: None,
        expected_header: Some("x-api-key: test-key"),
    }]);
    let api = crate::syncthing::Api::new(&crate::syncthing::Connection {
        endpoint: host,
        api_key: "test-key".into(),
        certificate_pem: String::new(),
    })
    .unwrap();
    let result = api.events(40, 30).unwrap();
    assert_eq!(result["last_id"], 42);
    assert_eq!(result["events"].as_array().unwrap().len(), 2);
    worker.join().unwrap();
}

#[test]
fn syncthing_attention_previews_the_real_error_with_a_suggested_fix() {
    let (host, worker) = server(vec![Exchange {
        method: "GET",
        target: "/rest/folder/errors?folder=studio&page=1&perpage=1",
        status: 200,
        body: r#"{"errors":[{"path":"Blender/Scene.blend","error":"sharing violation"}]}"#.into(),
        expect_body: None,
        expected_header: Some("x-api-key: test-key"),
    }]);
    let api = crate::syncthing::Api::new(&crate::syncthing::Connection {
        endpoint: host,
        api_key: "test-key".into(),
        certificate_pem: String::new(),
    })
    .unwrap();
    let result = api
        .execute(
            "attention",
            &serde_json::json!({"folder_ids":["studio"]}),
            std::path::Path::new(""),
        )
        .unwrap();
    assert_eq!(result["studio"]["errors"][0]["path"], "Blender/Scene.blend");
    assert_eq!(result["studio"]["errors"][0]["error"], "sharing violation");
    assert_eq!(
        result["studio"]["errors"][0]["advice"],
        "Close the app using the file, then rescan."
    );
    worker.join().unwrap();
}

#[test]
fn syncthing_browser_preserves_case_distinct_remote_names() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("local.txt"), "local").unwrap();
    let exchanges = vec![
        (
            "/rest/config/folders/test?",
            serde_json::json!({"id":"test","path":temp.path()}),
        ),
        (
            "/rest/db/browse?folder=test&prefix=&levels=0",
            serde_json::json!([
                {"name":"Photo.jpg","type":"FILE_INFO_TYPE_FILE","size":1},
                {"name":"photo.jpg","type":"FILE_INFO_TYPE_FILE","size":2}
            ]),
        ),
        (
            "/rest/db/ignores?folder=test",
            serde_json::json!({"ignore":[]}),
        ),
    ];
    let (host, worker) = server(
        exchanges
            .into_iter()
            .map(|(target, body)| Exchange {
                method: "GET",
                target,
                status: 200,
                body: body.to_string(),
                expect_body: None,
                expected_header: Some("x-api-key: test-key"),
            })
            .collect(),
    );
    let api = crate::syncthing::Api::new(&crate::syncthing::Connection {
        endpoint: host,
        api_key: "test-key".into(),
        certificate_pem: String::new(),
    })
    .unwrap();
    let result = api.browse("test", "").unwrap();
    let entries = result["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 3);
    assert_eq!(
        entries
            .iter()
            .find(|entry| entry["name"] == "Photo.jpg")
            .unwrap()["size"],
        1
    );
    assert_eq!(
        entries
            .iter()
            .find(|entry| entry["name"] == "photo.jpg")
            .unwrap()["size"],
        2
    );
    assert!(!result["local_limit_reached"].as_bool().unwrap());
    worker.join().unwrap();
}
