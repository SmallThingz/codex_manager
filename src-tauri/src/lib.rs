use std::io::Read;
use std::io::Write;
use std::net::TcpListener;
use std::net::TcpStream;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::time::Duration;
use reqwest::header::AUTHORIZATION;
use reqwest::header::HeaderMap;
use reqwest::header::HeaderName;
use reqwest::header::HeaderValue;
use reqwest::header::USER_AGENT;
use serde::Serialize;
use serde_json::Value;

static OAUTH_LISTENER_CANCEL: AtomicBool = AtomicBool::new(false);

fn write_http_response(stream: &mut TcpStream, status: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn extract_request_target(request: &str) -> Option<String> {
    let first_line = request.lines().next()?;
    let mut parts = first_line.split_whitespace();
    let method = parts.next()?;
    let target = parts.next()?;

    if method != "GET" {
        return None;
    }

    Some(target.to_string())
}

fn wait_for_oauth_callback_blocking(timeout_seconds: u64) -> Result<String, String> {
    OAUTH_LISTENER_CANCEL.store(false, Ordering::SeqCst);

    let listener = TcpListener::bind(("127.0.0.1", 1455))
        .map_err(|error| format!("Failed to bind callback listener on 127.0.0.1:1455: {error}"))?;

    listener
        .set_nonblocking(true)
        .map_err(|error| format!("Failed to configure callback listener: {error}"))?;

    let poll_sleep = Duration::from_millis(100);
    let mut remaining = Duration::from_secs(timeout_seconds);

    while remaining > Duration::ZERO {
        if OAUTH_LISTENER_CANCEL.load(Ordering::SeqCst) {
            return Err("Callback listener stopped.".to_string());
        }

        match listener.accept() {
            Ok((mut stream, _address)) => {
                let mut buffer = [0_u8; 8192];
                let size = stream
                    .read(&mut buffer)
                    .map_err(|error| format!("Failed to read callback request: {error}"))?;

                let request = String::from_utf8_lossy(&buffer[..size]).to_string();
                let target = extract_request_target(&request);

                if let Some(path) = target {
                    if path.starts_with("/auth/callback") {
                        write_http_response(
                            &mut stream,
                            "200 OK",
                            "<html><body><h3>Login completed. You can return to Codex Account Manager.</h3></body></html>",
                        );
                        return Ok(format!("http://localhost:1455{path}"));
                    }

                    write_http_response(&mut stream, "404 Not Found", "<html><body>Not Found</body></html>");
                    continue;
                }

                write_http_response(
                    &mut stream,
                    "400 Bad Request",
                    "<html><body>Invalid callback request.</body></html>",
                );
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(poll_sleep);
                remaining = remaining.saturating_sub(poll_sleep);
            }
            Err(error) => {
                return Err(format!("Callback listener failed: {error}"));
            }
        }
    }

    Err("Timed out waiting for OAuth callback.".to_string())
}

#[tauri::command]
async fn wait_for_oauth_callback(timeout_seconds: Option<u64>) -> Result<String, String> {
    let timeout = timeout_seconds.unwrap_or(180);
    tauri::async_runtime::spawn_blocking(move || wait_for_oauth_callback_blocking(timeout))
        .await
        .map_err(|error| format!("Callback listener task failed: {error}"))?
}

#[tauri::command]
fn cancel_oauth_callback_listener() -> bool {
    OAUTH_LISTENER_CANCEL.store(true, Ordering::SeqCst);
    true
}

#[derive(Serialize)]
struct WhamUsageResponse {
    status: u16,
    body: Value,
}

#[tauri::command]
async fn fetch_wham_usage(access_token: String, account_id: Option<String>) -> Result<WhamUsageResponse, String> {
    if access_token.trim().is_empty() {
        return Err("access_token is required".to_string());
    }

    let mut headers = HeaderMap::new();
    let bearer = format!("Bearer {access_token}");
    let auth_value = HeaderValue::from_str(&bearer)
        .map_err(|error| format!("Invalid authorization header: {error}"))?;
    headers.insert(AUTHORIZATION, auth_value);
    headers.insert(USER_AGENT, HeaderValue::from_static("codex-cli"));

    if let Some(account_id) = account_id {
        let trimmed = account_id.trim();
        if !trimmed.is_empty() {
            let account_header = HeaderName::from_static("chatgpt-account-id");
            let account_value = HeaderValue::from_str(trimmed)
                .map_err(|error| format!("Invalid ChatGPT-Account-Id header: {error}"))?;
            headers.insert(account_header, account_value);
        }
    }

    let client = reqwest::Client::builder()
        .build()
        .map_err(|error| format!("Failed to create HTTP client: {error}"))?;

    let response = client
        .get("https://chatgpt.com/backend-api/wham/usage")
        .headers(headers)
        .send()
        .await
        .map_err(|error| format!("Usage request failed: {error}"))?;

    let status = response.status().as_u16();
    let text = response
        .text()
        .await
        .map_err(|error| format!("Failed reading usage response: {error}"))?;

    let body = serde_json::from_str::<Value>(&text)
        .unwrap_or_else(|_| Value::String(text));

    Ok(WhamUsageResponse { status, body })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_fs::init())
        .invoke_handler(tauri::generate_handler![
            wait_for_oauth_callback,
            cancel_oauth_callback_listener,
            fetch_wham_usage
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
