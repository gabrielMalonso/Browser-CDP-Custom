use crate::{AppConfig, McpGatewayClient, ProfileConfig, Result};
use serde::Serialize;
use url::Url;

#[derive(Clone, Debug)]
pub struct BrowserLauncher {
    config: AppConfig,
    gateway: McpGatewayClient,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ProfileStatus {
    pub profile: ProfileConfig,
    pub profile_exists: bool,
    pub cdp_ok: bool,
    pub port_open: bool,
    pub message: String,
}

impl BrowserLauncher {
    pub fn new(config: AppConfig) -> Self {
        Self {
            config,
            gateway: McpGatewayClient::new(),
        }
    }

    pub fn with_gateway(config: AppConfig, gateway: McpGatewayClient) -> Self {
        Self { config, gateway }
    }

    pub async fn statuses(&self) -> Result<Vec<ProfileStatus>> {
        let gateway_profiles = self.gateway.profiles().await?;
        self.config
            .profiles
            .iter()
            .map(|profile| {
                let gateway_profile = gateway_profiles
                    .iter()
                    .find(|candidate| {
                        candidate.id == profile.id || candidate.aliases.contains(&profile.id)
                    })
                    .ok_or_else(|| crate::Error::ProfileNotFound(profile.id.clone()))?;
                let browser = &gateway_profile.browser;
                Ok(ProfileStatus {
                    profile: profile.clone(),
                    profile_exists: profile
                        .user_data_dir
                        .join(&profile.profile_directory)
                        .is_dir(),
                    cdp_ok: browser.cdp_alive,
                    port_open: browser.cdp_alive
                        || !browser.listener_process_ids.is_empty()
                        || browser.state == "degraded",
                    message: browser
                        .detail
                        .clone()
                        .unwrap_or_else(|| browser.state.clone()),
                })
            })
            .collect()
    }

    pub async fn launch_profile(&self, profile_id: &str) -> Result<String> {
        let profile = self.config.profile(profile_id)?;
        if let Some(default_url) = &profile.default_url {
            validate_http_url(default_url)?;
            self.gateway.open_url(profile_id, default_url).await?;
        } else {
            self.gateway.start(profile_id).await?;
        }
        Ok(format!(
            "{} está aberto na porta {}.",
            profile.name, profile.port
        ))
    }

    pub async fn open_url(&self, profile_id: &str, raw_url: &str) -> Result<String> {
        let profile = self.config.profile(profile_id)?;
        validate_http_url(raw_url)?;
        self.gateway.open_url(profile_id, raw_url).await?;
        Ok(format!("URL enviada para {}.", profile.name))
    }

    pub async fn close_profile(&self, profile_id: &str) -> Result<String> {
        let profile = self.config.profile(profile_id)?;
        let stopped = self.gateway.stop(profile_id).await?;
        Ok(if stopped {
            format!("{} encerrado.", profile.name)
        } else {
            format!("{} já estava fechado.", profile.name)
        })
    }

    pub async fn close_all_controlled_browsers(&self) -> Result<usize> {
        let mut closed = 0;
        for profile in &self.config.profiles {
            if self.gateway.stop(&profile.id).await? {
                closed += 1;
            }
        }
        Ok(closed)
    }
}

fn validate_http_url(raw_url: &str) -> Result<()> {
    let url = Url::parse(raw_url).map_err(|_| crate::Error::InvalidUrl(raw_url.to_string()))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(crate::Error::InvalidUrl(raw_url.to_string()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_http_links() {
        assert!(validate_http_url("https://example.com/?a=1").is_ok());
        assert!(validate_http_url("javascript:alert(1)").is_err());
    }
}
