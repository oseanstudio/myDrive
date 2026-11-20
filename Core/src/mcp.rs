use crate::automation::{self, Kind, Tool, TOOLS, VERSION};
use serde_json::{json, Map, Value};
use std::io::{self, BufRead, Read, Write};

const VERSIONS: &[&str] = &["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const MAX_FRAME: u64 = 1024 * 1024;

fn schema(tool: &Tool) -> Value {
    let mut properties = Map::new();
    let mut required = Vec::new();
    for &(field, kind) in tool.fields {
        let value = match kind {
            Kind::Paths => {
                json!({"type":"array","items":{"type":"string","minLength":1},"minItems":1,"maxItems":256})
            }
            _ => json!({"type":"string","minLength":1}),
        };
        if !matches!(kind, Kind::OptionalText) {
            required.push(field);
        }
        properties.insert(field.into(), value);
    }
    json!({"name":tool.name(),"description":tool.description,
        "inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false},
        "annotations":{"readOnlyHint":tool.read_only,"destructiveHint":!tool.read_only}})
}

#[derive(Default)]
struct Session {
    negotiated: bool,
    initialized: bool,
    blip: automation::BlipHost,
}

fn error(id: &Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}

impl Session {
    fn respond(&mut self, request: Value) -> Option<Value> {
        let method = request["method"].as_str();
        let id = &request["id"];
        let params = &request["params"];
        if request["jsonrpc"] != "2.0" || method.is_none() {
            return Some(error(&Value::Null, -32600, "Invalid request"));
        }
        let method = method.unwrap();
        if request.get("id").is_none() {
            if method == "notifications/initialized" && self.negotiated {
                self.initialized = true;
            }
            return None;
        }
        if !(id.is_string() || id.is_i64() || id.is_u64()) {
            return Some(error(&Value::Null, -32600, "Invalid request ID"));
        }
        let result = match method {
            "ping" => json!({}),
            "initialize" if !self.negotiated => {
                let Some(version) = params["protocolVersion"].as_str() else {
                    return Some(error(id, -32602, "protocolVersion is required"));
                };
                let version = if VERSIONS.contains(&version) {
                    version
                } else {
                    VERSIONS[0]
                };
                self.negotiated = true;
                json!({"protocolVersion":version,"capabilities":{"tools":{}},"serverInfo":{"name":"mydrive","version":VERSION},
                    "instructions":"Use exact confirmation from the user before sending or accepting transfers or changing sync configuration. SMB connects to devices on the user's Tailscale account."})
            }
            "server/discover" => return Some(error(id, -32601, "Use initialize")),
            _ if !self.initialized => {
                return Some(error(id, -32002, "Initialize the session first"))
            }
            "tools/list" => json!({"tools":TOOLS.iter().map(schema).collect::<Vec<_>>()}),
            "tools/call" => {
                let Some(name) = params["name"].as_str() else {
                    return Some(error(id, -32602, "A tool name is required"));
                };
                let Some(tool) = TOOLS.iter().find(|tool| tool.name() == name) else {
                    return Some(error(id, -32602, "Unknown tool"));
                };
                let empty = json!({});
                let arguments = params.get("arguments").unwrap_or(&empty);
                let result = automation::run_with_host(tool, arguments, Some(&mut self.blip));
                match result {
                    Ok(value) => {
                        json!({"content":[{"type":"text","text":value.to_string()}],"structuredContent":{"data":value}})
                    }
                    Err(message) => {
                        json!({"content":[{"type":"text","text":message}],"isError":true})
                    }
                }
            }
            _ => return Some(error(id, -32601, "Method not found")),
        };
        Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
    }
}

pub fn serve() -> Result<(), String> {
    let mut session = Session::default();
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let mut line = Vec::new();
    loop {
        line.clear();
        let bytes = (&mut input)
            .take(MAX_FRAME + 1)
            .read_until(b'\n', &mut line)
            .map_err(|e| e.to_string())?;
        if bytes == 0 {
            return Ok(());
        }
        if bytes as u64 > MAX_FRAME {
            return Err("An MCP request exceeded the input limit.".into());
        }
        if line.iter().all(|b| b.is_ascii_whitespace()) {
            continue;
        }
        let response = match serde_json::from_slice(&line) {
            Ok(value) => session.respond(value),
            Err(_) => Some(error(&Value::Null, -32700, "Parse error")),
        };
        if let Some(response) = response {
            serde_json::to_writer(&mut output, &response).map_err(|e| e.to_string())?;
            output
                .write_all(b"\n")
                .and_then(|()| output.flush())
                .map_err(|e| e.to_string())?;
        }
    }
}
