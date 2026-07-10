use browser_cdp_core::{
    AppConfig, AppPreferences, BrowserLauncher, McpGatewayClient, McpGatewayStatus, PendingLink,
    ProfileConfig, ProfileStatus, SharedRouter, NORMAL_BROWSER_DESTINATION,
};
use serde::Serialize;
use std::sync::Arc;
use std::{fs, path::PathBuf, process::Command};
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder, Window};
use tokio::sync::Mutex;

const DESKTOP_FILE_ID: &str = "browser-cdp-custom-linux.desktop";
const AUTOSTART_FILE_ID: &str = "browser-cdp-custom-linux.desktop";

struct AppState {
    config: AppConfig,
    preferences: AppPreferences,
    router: SharedRouter,
    incoming_urls: Vec<String>,
    activation_feedback: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ActivationContext {
    incoming_urls: Vec<String>,
    pending_links: Vec<PendingLink>,
    feedback: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsSnapshot {
    preferences: AppPreferences,
    profiles: Vec<ProfileConfig>,
    current_default_browser: String,
    is_system_default: bool,
    launch_at_login: bool,
    version: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SelectionResult {
    message: String,
    dismiss_overlay: bool,
}

impl AppState {
    fn new() -> Result<Self, String> {
        let config = AppConfig::load().map_err(|error| error.to_string())?;
        let preferences = AppPreferences::load(&config).map_err(|error| error.to_string())?;
        let launcher = BrowserLauncher::new(config.clone());
        Ok(Self {
            config: config.clone(),
            preferences,
            router: SharedRouter::new(config, launcher),
            incoming_urls: Vec::new(),
            activation_feedback: None,
        })
    }

    fn remember_destination(&mut self, destination_id: &str) -> Result<(), String> {
        self.preferences.last_selected_destination_id = Some(destination_id.to_string());
        self.preferences.save().map_err(|error| error.to_string())
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
async fn activation_context(
    state: State<'_, Arc<Mutex<AppState>>>,
) -> Result<ActivationContext, String> {
    let state = state.lock().await;
    Ok(ActivationContext {
        incoming_urls: state.incoming_urls.clone(),
        pending_links: state.router.pending_links().await,
        feedback: state.activation_feedback.clone(),
    })
}

#[tauri::command]
async fn activate_profile(
    state: State<'_, Arc<Mutex<AppState>>>,
    profile_id: String,
) -> Result<SelectionResult, String> {
    let mut state = state.lock().await;
    state
        .config
        .profile(&profile_id)
        .map_err(|error| error.to_string())?;
    state.remember_destination(&profile_id)?;
    state.activation_feedback = None;

    let incoming_urls = std::mem::take(&mut state.incoming_urls);
    let message = if incoming_urls.is_empty() {
        state
            .router
            .launch_profile(&profile_id)
            .await
            .map_err(|error| error.to_string())?
    } else {
        let total = incoming_urls.len();
        for (index, url) in incoming_urls.iter().enumerate() {
            if let Err(error) = state.router.route_url(&profile_id, url).await {
                state
                    .incoming_urls
                    .extend(incoming_urls.iter().skip(index + 1).cloned());
                return Err(error.to_string());
            }
        }
        format!("{total} link(s) aberto(s) no perfil selecionado.")
    };

    Ok(SelectionResult {
        message,
        dismiss_overlay: state.preferences.dismiss_overlay_after_selection,
    })
}

#[tauri::command]
async fn activate_normal_browser(
    state: State<'_, Arc<Mutex<AppState>>>,
) -> Result<SelectionResult, String> {
    let mut state = state.lock().await;
    state.remember_destination(NORMAL_BROWSER_DESTINATION)?;
    state.activation_feedback = None;

    let incoming_urls = std::mem::take(&mut state.incoming_urls);
    if incoming_urls.is_empty() {
        open_normal_browser(None)?;
    } else {
        for (index, url) in incoming_urls.iter().enumerate() {
            if let Err(error) = open_normal_browser(Some(url)) {
                state.incoming_urls = incoming_urls[index..].to_vec();
                return Err(error);
            }
        }
    }

    Ok(SelectionResult {
        message: "Google Chrome aberto.".to_string(),
        dismiss_overlay: state.preferences.dismiss_overlay_after_selection,
    })
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
async fn mcp_gateway_status() -> Result<McpGatewayStatus, String> {
    Ok(McpGatewayClient::new().status().await)
}

#[tauri::command]
async fn release_mcp_worker(profile_id: String) -> Result<String, String> {
    let released = McpGatewayClient::new()
        .release(&profile_id)
        .await
        .map_err(|error| error.to_string())?;

    Ok(if released {
        format!("Worker MCP de {profile_id} liberado.")
    } else {
        format!("Nenhum worker MCP ocioso em {profile_id}.")
    })
}

#[tauri::command]
async fn release_all_mcp_workers(state: State<'_, Arc<Mutex<AppState>>>) -> Result<String, String> {
    let profile_ids = {
        let state = state.lock().await;
        state
            .config
            .profiles
            .iter()
            .map(|profile| profile.id.clone())
            .collect::<Vec<_>>()
    };
    let client = McpGatewayClient::new();
    let mut released = 0usize;
    for profile_id in profile_ids {
        if client
            .release(&profile_id)
            .await
            .map_err(|error| error.to_string())?
        {
            released += 1;
        }
    }

    Ok(if released == 0 {
        "Nenhum worker MCP ocioso para liberar.".to_string()
    } else {
        format!("{released} worker(s) MCP liberado(s).")
    })
}

#[tauri::command]
async fn app_settings(state: State<'_, Arc<Mutex<AppState>>>) -> Result<SettingsSnapshot, String> {
    let state = state.lock().await;
    let current_default_browser = current_default_browser();
    Ok(SettingsSnapshot {
        preferences: state.preferences.clone(),
        profiles: state.config.profiles.clone(),
        is_system_default: current_default_browser == DESKTOP_FILE_ID,
        current_default_browser,
        launch_at_login: autostart_path().is_file(),
        version: env!("CARGO_PKG_VERSION").to_string(),
    })
}

#[tauri::command]
async fn save_app_settings(
    state: State<'_, Arc<Mutex<AppState>>>,
    mut preferences: AppPreferences,
) -> Result<String, String> {
    let mut state = state.lock().await;
    preferences.normalize(&state.config);
    preferences.save().map_err(|error| error.to_string())?;
    state.preferences = preferences;
    Ok("Configurações salvas.".to_string())
}

#[tauri::command]
fn set_as_default_browser() -> Result<String, String> {
    install_desktop_file()?;
    for mime_type in [
        "x-scheme-handler/http",
        "x-scheme-handler/https",
        "text/html",
    ] {
        let status = Command::new("xdg-mime")
            .args(["default", DESKTOP_FILE_ID, mime_type])
            .status()
            .map_err(|error| format!("Falha ao executar xdg-mime: {error}"))?;
        if !status.success() {
            return Err(format!("xdg-mime recusou o handler para {mime_type}."));
        }
    }

    Ok("Custom CDP Browser agora é o navegador padrão.".to_string())
}

#[tauri::command]
fn set_launch_at_login(enabled: bool) -> Result<String, String> {
    let path = autostart_path();
    if enabled {
        let executable = current_executable()?;
        let body = format!(
            "[Desktop Entry]\nType=Application\nName=Custom CDP Browser\nComment=Mantém o overlay de perfis CDP disponível.\nExec={} --background\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
            desktop_exec(&executable)
        );
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        fs::write(path, body).map_err(|error| error.to_string())?;
        Ok("Inicialização automática ativada.".to_string())
    } else {
        match fs::remove_file(path) {
            Ok(()) => Ok("Inicialização automática desativada.".to_string()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok("Inicialização automática já estava desativada.".to_string())
            }
            Err(error) => Err(error.to_string()),
        }
    }
}

#[tauri::command]
fn open_settings_window(app: AppHandle) -> Result<(), String> {
    if let Some(main_window) = app.get_webview_window("main") {
        main_window.hide().map_err(|error| error.to_string())?;
    }

    if let Some(window) = app.get_webview_window("settings") {
        window.show().map_err(|error| error.to_string())?;
        window.set_focus().map_err(|error| error.to_string())?;
        return Ok(());
    }

    WebviewWindowBuilder::new(
        &app,
        "settings",
        WebviewUrl::App("index.html?view=settings".into()),
    )
    .title("Configurações · Custom CDP Browser")
    .inner_size(520.0, 720.0)
    .min_inner_size(480.0, 660.0)
    .resizable(true)
    .center()
    .build()
    .map_err(|error| error.to_string())?;
    Ok(())
}

#[tauri::command]
fn close_settings_window(window: Window) -> Result<(), String> {
    window.close().map_err(|error| error.to_string())
}

#[tauri::command]
fn dismiss_overlay(window: Window) -> Result<(), String> {
    window.hide().map_err(|error| error.to_string())
}

#[tauri::command]
fn quit_application(app: AppHandle) {
    app.exit(0);
}

fn open_normal_browser(url: Option<&str>) -> Result<(), String> {
    let browser = [
        "google-chrome",
        "google-chrome-stable",
        "chromium",
        "chromium-browser",
    ]
    .iter()
    .find_map(which)
    .ok_or_else(|| "Chrome/Chromium não encontrado.".to_string())?;

    let mut command = Command::new(browser);
    if let Some(url) = url {
        command.arg(url);
    }
    command.spawn().map_err(|error| error.to_string())?;
    Ok(())
}

fn which(binary: &&str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(binary))
        .find(|candidate| candidate.is_file())
}

fn http_urls(args: &[String]) -> Vec<String> {
    args.iter()
        .filter(|arg| arg.starts_with("http://") || arg.starts_with("https://"))
        .cloned()
        .collect()
}

fn schedule_activation(app: AppHandle, args: Vec<String>) {
    let background = args.iter().any(|arg| arg == "--background");
    let urls = http_urls(&args);
    let state = app.state::<Arc<Mutex<AppState>>>().inner().clone();
    tauri::async_runtime::spawn(async move {
        let mut show_overlay = !background && urls.is_empty();

        for url in urls {
            let destination = {
                let state = state.lock().await;
                state
                    .preferences
                    .routing_destination_id()
                    .map(ToOwned::to_owned)
            };

            match destination {
                None => {
                    let mut state = state.lock().await;
                    if !state.incoming_urls.contains(&url) {
                        state.incoming_urls.push(url);
                    }
                    state.activation_feedback = None;
                    show_overlay = true;
                }
                Some(destination_id) if destination_id == NORMAL_BROWSER_DESTINATION => {
                    if let Err(error) = open_normal_browser(Some(&url)) {
                        let mut state = state.lock().await;
                        state.incoming_urls.push(url);
                        state.activation_feedback = Some(error);
                        show_overlay = true;
                    }
                }
                Some(profile_id) => {
                    let mut state = state.lock().await;
                    if let Err(error) = state.router.route_url(&profile_id, &url).await {
                        state.activation_feedback = Some(error.to_string());
                        show_overlay = true;
                    }
                }
            }
        }

        if show_overlay {
            show_main_window(&app);
            let _ = app.emit("incoming-links", ());
        }
    });
}

fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.center();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn current_default_browser() -> String {
    Command::new("xdg-mime")
        .args(["query", "default", "x-scheme-handler/https"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "Não definido".to_string())
}

fn install_desktop_file() -> Result<(), String> {
    let executable = current_executable()?;
    let path = dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from(".local/share"))
        .join("applications")
        .join(DESKTOP_FILE_ID);
    let body = format!(
        "[Desktop Entry]\nType=Application\nName=Custom CDP Browser\nComment=Escolhe o perfil Chrome para abrir links.\nExec={} %u\nTerminal=false\nCategories=Network;WebBrowser;\nMimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;\nStartupNotify=true\n",
        desktop_exec(&executable)
    );

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    fs::write(&path, body).map_err(|error| error.to_string())?;
    let _ = Command::new("update-desktop-database")
        .arg(path.parent().unwrap_or_else(|| std::path::Path::new(".")))
        .status();
    Ok(())
}

fn current_executable() -> Result<PathBuf, String> {
    std::env::current_exe()
        .map_err(|error| format!("Não foi possível localizar o executável: {error}"))
}

fn desktop_exec(path: &std::path::Path) -> String {
    format!("\"{}\"", path.display().to_string().replace('"', "\\\""))
}

fn autostart_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from(".config"))
        .join("autostart")
        .join(AUTOSTART_FILE_ID)
}

pub fn run() {
    let state = Arc::new(Mutex::new(
        AppState::new().expect("failed to load Linux CDP app configuration"),
    ));

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            schedule_activation(app.clone(), args);
        }))
        .manage(state)
        .setup(|app| {
            schedule_activation(app.handle().clone(), std::env::args().collect());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            profiles,
            activation_context,
            activate_profile,
            activate_normal_browser,
            route_url,
            close_profile,
            close_all_controlled_browsers,
            retry_pending_links,
            mcp_gateway_status,
            release_mcp_worker,
            release_all_mcp_workers,
            app_settings,
            save_app_settings,
            set_as_default_browser,
            set_launch_at_login,
            open_settings_window,
            close_settings_window,
            dismiss_overlay,
            quit_application
        ])
        .run(tauri::generate_context!())
        .expect("error while running Tauri application");
}
