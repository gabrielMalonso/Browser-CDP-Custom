use crate::config::default_pending_links_path;
use crate::{AppConfig, BrowserLauncher, Error, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PendingLink {
    pub url: String,
    pub profile_id: String,
    pub error: String,
}

#[derive(Clone, Debug)]
pub struct SharedRouter {
    config: AppConfig,
    launcher: BrowserLauncher,
    pending: Arc<Mutex<Vec<PendingLink>>>,
    pending_path: PathBuf,
}

impl SharedRouter {
    pub fn new(config: AppConfig, launcher: BrowserLauncher) -> Self {
        let pending_path = default_pending_links_path();
        let pending = read_pending_links(&pending_path).unwrap_or_default();

        Self {
            config,
            launcher,
            pending: Arc::new(Mutex::new(pending)),
            pending_path,
        }
    }

    pub fn with_pending_path(
        config: AppConfig,
        launcher: BrowserLauncher,
        pending_path: PathBuf,
    ) -> Self {
        let pending = read_pending_links(&pending_path).unwrap_or_default();

        Self {
            config,
            launcher,
            pending: Arc::new(Mutex::new(pending)),
            pending_path,
        }
    }

    pub async fn profile_statuses(&self) -> Result<Vec<crate::ProfileStatus>> {
        self.launcher.statuses().await
    }

    pub async fn pending_links(&self) -> Vec<PendingLink> {
        self.pending.lock().await.clone()
    }

    pub async fn launch_profile(&self, profile_id: &str) -> Result<String> {
        self.launcher.launch_profile(profile_id).await
    }

    pub async fn close_profile(&self, profile_id: &str) -> Result<String> {
        self.launcher.close_profile(profile_id).await
    }

    pub async fn close_all_controlled_browsers(&self) -> Result<usize> {
        self.launcher.close_all_controlled_browsers().await
    }

    pub async fn route_default_url(&self, url: &str) -> Result<String> {
        let profile_id = self.config.default_profile()?.id.clone();
        self.route_url(&profile_id, url).await
    }

    pub async fn route_url(&self, profile_id: &str, url: &str) -> Result<String> {
        match self.launcher.open_url(profile_id, url).await {
            Ok(message) => Ok(message),
            Err(error) => {
                self.pending.lock().await.push(PendingLink {
                    url: url.to_string(),
                    profile_id: profile_id.to_string(),
                    error: error.to_string(),
                });
                let _ = self.save_pending_links().await;
                Err(error)
            }
        }
    }

    pub async fn retry_pending_links(&self) -> Result<String> {
        let pending = {
            let mut guard = self.pending.lock().await;
            std::mem::take(&mut *guard)
        };

        let mut failed = Vec::new();
        let mut success_count = 0usize;

        for link in pending {
            match self.launcher.open_url(&link.profile_id, &link.url).await {
                Ok(_) => success_count += 1,
                Err(error) => failed.push(PendingLink {
                    error: error.to_string(),
                    ..link
                }),
            }
        }

        *self.pending.lock().await = failed;
        self.save_pending_links().await?;
        Ok(format!("{success_count} link(s) reenviado(s)."))
    }

    async fn save_pending_links(&self) -> Result<()> {
        let pending = self.pending.lock().await.clone();
        if let Some(parent) = self.pending_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        let json = serde_json::to_vec_pretty(&pending)?;
        tokio::fs::write(&self.pending_path, json).await?;
        Ok(())
    }
}

fn read_pending_links(path: &PathBuf) -> Result<Vec<PendingLink>> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes)?),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(error) => Err(Error::Io(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_link_is_serializable() {
        let link = PendingLink {
            url: "https://example.com".to_string(),
            profile_id: "central-es".to_string(),
            error: "offline".to_string(),
        };

        let json = serde_json::to_string(&link).unwrap();
        assert!(json.contains("central-es"));
    }

    #[test]
    fn reads_pending_links_from_disk() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("pending-links.json");
        std::fs::write(
            &path,
            r#"[{"url":"https://example.com","profile_id":"central-es","error":"offline"}]"#,
        )
        .unwrap();

        let links = read_pending_links(&path).unwrap();
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].profile_id, "central-es");
    }
}
