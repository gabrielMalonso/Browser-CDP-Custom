mod cdp;
mod config;
mod launcher;
mod router;

pub use cdp::{cdp_new_tab_url, CdpClient, CdpVersion};
pub use config::{AppConfig, ProfileConfig};
pub use launcher::{BrowserLauncher, ProfileStatus};
pub use router::{PendingLink, SharedRouter};

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("perfil não encontrado: {0}")]
    ProfileNotFound(String),
    #[error("URL inválida: {0}")]
    InvalidUrl(String),
    #[error("porta {port} está ocupada, mas não respondeu como CDP")]
    PortOccupied { port: u16 },
    #[error("diretório do perfil não existe: {0}")]
    ProfileDirectoryMissing(String),
    #[error("perfil parece travado por lock: {path} aponta para {target}")]
    ProfileLocked { path: String, target: String },
    #[error("CDP não ficou disponível em http://127.0.0.1:{port}")]
    CdpUnavailable { port: u16 },
    #[error("navegador não encontrado; instale google-chrome, google-chrome-stable, chromium ou chromium-browser")]
    BrowserNotFound,
    #[error("falha ao iniciar navegador: {0}")]
    SpawnFailed(String),
    #[error("falha ao encerrar navegador: {0}")]
    StopFailed(String),
    #[error("falha HTTP no CDP: {0}")]
    Http(#[from] reqwest::Error),
    #[error("falha de I/O: {0}")]
    Io(#[from] std::io::Error),
    #[error("falha ao ler configuração JSON: {0}")]
    Json(#[from] serde_json::Error),
}
