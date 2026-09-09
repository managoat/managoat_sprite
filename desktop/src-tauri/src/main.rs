#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::Manager;

#[cfg(target_os = "macos")]
extern "C" {
    fn manasprites_snapshot(webview: *mut std::ffi::c_void, destination: *const std::ffi::c_char);
}

fn main() {
    let bridge = elixirkit::PubSub::listen("tcp://127.0.0.1:0").expect("local bridge unavailable");
    let child = Arc::new(Mutex::new(None::<std::process::Child>));
    let owned_child = child.clone();
    let app = tauri::Builder::default()
        .setup(move |app| {
            let handle = app.handle().clone();
            let smoke_renamed = AtomicBool::new(false);
            let smoke_fleet_started = AtomicBool::new(false);
            bridge.subscribe("shell", move |message| {
                let Ok(event) = serde_json::from_slice::<serde_json::Value>(message) else {
                    return;
                };
                if event["event"] == "live_connected" {
                    if let Ok(path) = std::env::var("MANASPRITES_DESKTOP_SMOKE_FILE") {
                        // Opt-in packaging probe. The isolated test root contains
                        // synthetic state; normal launches never write this file.
                        use std::io::Write;
                        use std::os::unix::fs::OpenOptionsExt;
                        if let Ok(mut file) = std::fs::OpenOptions::new()
                            .write(true)
                            .create(true)
                            .truncate(true)
                            .mode(0o600)
                            .open(path)
                        {
                            let _ = file.write_all(message);
                        }
                        #[cfg(target_os = "macos")]
                        if std::env::var("MANASPRITES_DESKTOP_SMOKE_FLEET").is_ok() {
                            if let Ok(directory) = std::env::var("MANASPRITES_DESKTOP_SMOKE_SCREENSHOTS") {
                                let filename = match event["workspace"].as_str() {
                                    Some("Demo fleet") => Some("desktop-fleet.png"),
                                    Some("Demo files") => Some("desktop-files.png"),
                                    Some("Demo changes") => Some("desktop-changes.png"),
                                    _ => None,
                                };
                                if let (Some(filename), Some(window)) = (filename, handle.get_webview_window("main")) {
                                    let path = std::path::Path::new(&directory).join(filename);
                                    if let Ok(destination) = std::ffi::CString::new(path.to_string_lossy().as_bytes()) {
                                        std::thread::spawn(move || {
                                            // Allow the LiveView patch to reach WebKit first.
                                            std::thread::sleep(Duration::from_millis(500));
                                            window.with_webview(move |webview| unsafe {
                                                manasprites_snapshot(webview.inner(), destination.as_ptr());
                                            }).ok();
                                        });
                                    }
                                }
                            }
                        }
                        if let Ok(raw) = std::env::var("MANASPRITES_DESKTOP_SMOKE_FLEET") {
                            if !smoke_fleet_started.swap(true, Ordering::SeqCst) {
                                // A fixed synthetic workflow, never an arbitrary script.
                                // Require plain loopback origins before filling forms.
                                if let Ok(urls) = serde_json::from_str::<Vec<String>>(&raw) {
                                    let valid = (2..=3).contains(&urls.len()) && urls.iter().all(|value| {
                                        tauri::Url::parse(value).is_ok_and(|url| {
                                            url.scheme() == "http" && url.host_str() == Some("127.0.0.1")
                                                && url.port().is_some() && url.path() == "/"
                                                && url.username().is_empty() && url.password().is_none()
                                                && url.query().is_none() && url.fragment().is_none()
                                        })
                                    });
                                    if valid {
                                        let script = format!("({})({});", include_str!("smoke_fleet.js"), serde_json::to_string(&urls).unwrap());
                                        if let Some(window) = handle.get_webview_window("main") {
                                            // Clipboard operations require the native window to be
                                            // focused, including on a fresh hosted macOS desktop.
                                            window.set_focus().ok();
                                            window.eval(&script).ok();
                                        }
                                    }
                                }
                            }
                        }
                        if let Ok(name) = std::env::var("MANASPRITES_DESKTOP_SMOKE_NAME") {
                            if !smoke_renamed.swap(true, Ordering::SeqCst) {
                                let value = serde_json::to_string(&name).unwrap();
                                let script = format!(
                                    r#"
                                    let opened = false;
                                    const probe = setInterval(() => {{
                                      if (!document.querySelector('[data-phx-main].phx-connected')) return;
                                      if (!opened) {{
                                        opened = true;
                                        document.querySelector('#settings-open').click();
                                        return;
                                      }}
                                      const form = document.querySelector('#workspace-form');
                                      if (!form) return;
                                      clearInterval(probe);
                                      const input = document.querySelector('#workspace-name-input');
                                      input.value = {value};
                                      input.dispatchEvent(new Event('input', {{bubbles:true}}));
                                      form.requestSubmit();
                                    }}, 50);
                                    setTimeout(() => clearInterval(probe), 5000);
                                "#
                                );
                                if let Some(window) = handle.get_webview_window("main") {
                                    window.eval(&script).ok();
                                }
                            }
                        }
                    }
                    return;
                }
                if event["event"] != "ready" {
                    return;
                }
                let Some(url) = event["url"]
                    .as_str()
                    .and_then(|u| u.parse::<tauri::Url>().ok())
                else {
                    return;
                };
                if url.scheme() != "http"
                    || url.host_str() != Some("127.0.0.1")
                    || url.port().is_none()
                {
                    return;
                }
                let origin = url.origin();
                let handle = handle.clone();
                handle
                    .clone()
                    .run_on_main_thread(move || {
                        if handle.get_webview_window("main").is_some() {
                            return;
                        }
                        let window = tauri::WebviewWindowBuilder::new(
                            &handle,
                            "main",
                            tauri::WebviewUrl::External(url),
                        )
                        .title("Manasprites")
                        .inner_size(1320.0, 860.0)
                        .min_inner_size(850.0, 600.0)
                        .on_navigation(move |url| url.origin() == origin)
                        .build();
                        if window.is_err() {
                            handle.exit(1);
                        }
                    })
                    .ok();
            });
            let rel_dir = app.path().resource_dir()?.join("rel");
            let mut command = elixirkit::release(rel_dir, "manasprites_desktop");
            command.env("ELIXIRKIT_PUBSUB", bridge.url());
            command.env("RELEASE_DISTRIBUTION", "none");
            command.env("RELEASE_COOKIE", "unused-local-desktop");
            command.env("ERL_CRASH_DUMP", "/dev/null");
            command.stdin(std::process::Stdio::null());
            // Phoenix logs must never end up in a user's launch console.
            command.stdout(std::process::Stdio::null());
            command.stderr(std::process::Stdio::null());
            *owned_child.lock().unwrap() = Some(command.spawn()?);
            // Keep the bridge alive until the native shell exits. A killed shell
            // closes its socket; ElixirKit then shuts down the owned BEAM.
            app.manage(bridge);
            let handle = app.handle().clone();
            let watched_child = owned_child.clone();
            std::thread::spawn(move || loop {
                std::thread::sleep(Duration::from_millis(250));
                let mut guard = watched_child.lock().unwrap();
                if let Some(process) = guard.as_mut() {
                    if let Ok(Some(status)) = process.try_wait() {
                        handle.exit(status.code().unwrap_or(1));
                        break;
                    }
                }
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("could not initialize Manasprites");

    app.run(move |_handle, event| {
        if let tauri::RunEvent::Exit = event {
            // Bridge teardown handles normal and abrupt exit. Give the VM an
            // explicit graceful request before the native process disappears.
            if let Some(process) = child.lock().unwrap().as_mut() {
                let _ = std::process::Command::new("/bin/kill")
                    .args(["-TERM", &process.id().to_string()])
                    .status();
            }
        }
    });
}
