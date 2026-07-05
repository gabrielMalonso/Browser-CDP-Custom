use browser_cdp_core::{AppConfig, BrowserLauncher, PendingLink, ProfileStatus, SharedRouter};
use std::sync::Arc;
use std::{path::PathBuf, process::Command};
use tauri::State;
use tokio::sync::Mutex;

struct AppState {
    router: SharedRouter,
}

impl AppState {
    fn new() -> Result<Self, String> {
        let config = AppConfig::load().map_err(|error| error.to_string())?;
        let launcher = BrowserLauncher::new(config.clone());
        Ok(Self {
            router: SharedRouter::new(config, launcher),
        })
    }
}

#[tauri::command]
async fn profiles(state: State<'_, Arc<Mutex<AppState>>>) -> Result<Vec<ProfileStatus>, String> {
    let state = state.lock().await;
    state
        .router
        .profile_statuses()
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn pending_links(state: State<'_, Arc<Mutex<AppState>>>) -> Result<Vec<PendingLink>, String> {
    let state = state.lock().await;
    Ok(state.router.pending_links().await)
}

#[tauri::command]
async fn launch_profile(
    state: State<'_, Arc<Mutex<AppState>>>,
    profile_id: String,
) -> Result<String, String> {
    let state = state.lock().await;
    state
        .router
        .launch_profile(&profile_id)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn route_url(
    state: State<'_, Arc<Mutex<AppState>>>,
    profile_id: String,
    url: String,
) -> Result<String, String> {
    let state = state.lock().await;
    state
        .router
        .route_url(&profile_id, &url)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn close_profile(
    state: State<'_, Arc<Mutex<AppState>>>,
    profile_id: String,
) -> Result<String, String> {
    let state = state.lock().await;
    state
        .router
        .close_profile(&profile_id)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn close_all_controlled_browsers(
    state: State<'_, Arc<Mutex<AppState>>>,
) -> Result<String, String> {
    let state = state.lock().await;
    let closed = state
        .router
        .close_all_controlled_browsers()
        .await
        .map_err(|error| error.to_string())?;

    Ok(if closed == 0 {
        "Nenhum navegador controlado estava aberto.".to_string()
    } else {
        format!("{closed} navegador(es) controlado(s) encerrado(s).")
    })
}

#[tauri::command]
async fn retry_pending_links(state: State<'_, Arc<Mutex<AppState>>>) -> Result<String, String> {
    let state = state.lock().await;
    state
        .router
        .retry_pending_links()
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn open_normal_chrome() -> Result<String, String> {
    let browser = [
        "google-chrome",
        "google-chrome-stable",
        "chromium",
        "chromium-browser",
    ]
    .iter()
    .find_map(which)
    .ok_or_else(|| "Chrome/Chromium não encontrado.".to_string())?;

    Command::new(browser)
        .spawn()
        .map_err(|error| error.to_string())?;

    Ok("Google Chrome aberto.".to_string())
}

fn which(binary: &&str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(binary))
        .find(|candidate| candidate.is_file())
}

async fn route_cli_urls(state: Arc<Mutex<AppState>>, args: Vec<String>) {
    let urls = http_urls(args);

    if urls.is_empty() {
        return;
    }

    let state = state.lock().await;
    for url in urls {
        if let Err(error) = state.router.route_default_url(&url).await {
            eprintln!("falha ao rotear URL recebida por CLI: {error}");
        }
    }
}

fn http_urls(args: Vec<String>) -> Vec<String> {
    args.into_iter()
        .filter(|arg| arg.starts_with("http://") || arg.starts_with("https://"))
        .collect::<Vec<_>>()
}

pub fn run() {
    let state = Arc::new(Mutex::new(
        AppState::new().expect("failed to load Linux CDP app configuration"),
    ));
    let args = std::env::args().collect::<Vec<_>>();

    if !http_urls(args.clone()).is_empty() {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to start URL routing runtime");
        runtime.block_on(route_cli_urls(state, args));
        return;
    }

    tauri::Builder::default()
        .manage(state.clone())
        .setup(move |_app| {
            let state = state.clone();
            let args = std::env::args().collect::<Vec<_>>();
            tauri::async_runtime::spawn(async move {
                route_cli_urls(state, args).await;
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            profiles,
            pending_links,
            launch_profile,
            route_url,
            close_profile,
            close_all_controlled_browsers,
            retry_pending_links,
            open_normal_chrome
        ])
        .run(tauri::generate_context!())
        .expect("error while running Tauri application");
}
