// No console window behind the app on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{ChildStdin, Command, Stdio};
use std::sync::Mutex;

use tauri::{AppHandle, Emitter, State};

/// The input of the engine process that is running right now, so Stop can reach it.
struct Running(Mutex<Option<ChildStdin>>);

/// Programs that ship next to the app: `y1sync`, `ffmpeg`, `ffprobe`.
fn sibling(name: &str) -> PathBuf {
    let exe = std::env::current_exe().expect("the app's own path");
    let dir = exe.parent().expect("the app's folder").to_path_buf();
    if cfg!(windows) {
        dir.join(format!("{name}.exe"))
    } else {
        dir.join(name)
    }
}

fn quiet(cmd: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    #[cfg(not(windows))]
    {
        let _ = cmd;
    }
}

/// Send one request to `y1sync api`. Progress lines become `y1-progress` events;
/// the last line is the answer.
#[tauri::command]
async fn api_call(
    app: AppHandle,
    state: State<'_, Running>,
    request: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let mut cmd = Command::new(sibling("y1sync"));
    cmd.arg("api")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    quiet(&mut cmd);

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Could not start the engine (y1sync): {e}"))?;
    let mut stdin = child.stdin.take().ok_or("The engine has no input")?;
    let stdout = child.stdout.take().ok_or("The engine has no output")?;

    writeln!(stdin, "{}", request).map_err(|e| e.to_string())?;
    stdin.flush().map_err(|e| e.to_string())?;
    *state.0.lock().unwrap() = Some(stdin);

    let result = tauri::async_runtime::spawn_blocking(move || {
        let mut last: Option<serde_json::Value> = None;
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
            if value.get("event").and_then(|e| e.as_str()) == Some("progress") {
                let _ = app.emit("y1-progress", value);
            } else {
                last = Some(value);
            }
        }
        let _ = child.wait();
        last
    })
    .await
    .map_err(|e| e.to_string())?;

    *state.0.lock().unwrap() = None;
    result.ok_or_else(|| "The engine stopped without an answer.".to_string())
}

/// Ask a running copy to finish its current file and stop.
#[tauri::command]
fn api_stop(state: State<'_, Running>) {
    if let Some(stdin) = state.0.lock().unwrap().as_mut() {
        let _ = writeln!(stdin, "stop");
        let _ = stdin.flush();
    }
}

/// Open a web page in the default browser (https only).
#[tauri::command]
fn open_url(url: String) -> Result<(), String> {
    if !url.starts_with("https://") || url.contains(['"', ' ', '&', '|', '^', '<', '>']) {
        return Err("not a plain https link".into());
    }
    let mut cmd = if cfg!(windows) {
        let mut c = Command::new("cmd");
        c.args(["/C", "start", "", &url]);
        c
    } else if cfg!(target_os = "macos") {
        let mut c = Command::new("open");
        c.arg(&url);
        c
    } else {
        let mut c = Command::new("xdg-open");
        c.arg(&url);
        c
    };
    quiet(&mut cmd);
    cmd.spawn().map(|_| ()).map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Running(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![api_call, api_stop, open_url])
        .run(tauri::generate_context!())
        .expect("error while running Y1 Sync");
}
