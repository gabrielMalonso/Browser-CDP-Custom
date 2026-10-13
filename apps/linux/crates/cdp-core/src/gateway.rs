use crate::{Error, Result};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{env, fs, path::PathBuf, time::Duration};

#[derive(Clone, Debug)]
pub struct McpGatewayClient {
    base_url: String,
    http: reqwest::Client,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayCapabilities {
    pub control_api: u32,
    pub leases: bool,
    pub browser_lifecycle: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct GatewayHealth {
    pub version: String,
    pub capabilities: GatewayCapabilities,
}

impl GatewayHealth {
    pub fn is_compatible(&self) -> bool {
        self.capabilities.control_api == 1
            && self.capabilities.leases
            && self.capabilities.browser_lifecycle
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct McpWorker {
    pub profile_id: String,
    pub pid: Option<u32>,
    pub calls_in_flight: u32,
    pub lease_count: u32,
    pub idle_ms: u64,
    pub closing: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayBrowserStatus {
    pub state: String,
    pub cdp_alive: bool,
    pub process_ids: Vec<u32>,
    pub listener_process_ids: Vec<u32>,
    pub detail: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayProfile {
    pub id: String,
    pub aliases: Vec<String>,
    pub name: String,
    pub port: u16,
    pub endpoint: String,
    pub default_url: Option<String>,
    pub browser: GatewayBrowserStatus,
    pub worker: Option<McpWorker>,
}

#[derive(Clone, Debug, Deserialize)]
struct ProfilesResponse {
    profiles: Vec<GatewayProfile>,
}

#[derive(Clone, Debug, Deserialize)]
struct ReleaseResponse {
    released: bool,
}

#[derive(Clone, Debug, Deserialize)]
struct StopResponse {
    stopped: bool,
}

#[derive(Clone, Debug, Deserialize)]
struct ErrorResponse {
    code: Option<String>,
    error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct McpGatewayStatus {
    pub healthy: bool,
    pub workers: Vec<McpWorker>,
    pub message: String,
}

impl McpGatewayClient {
    pub fn new() -> Self {
        Self::with_base_url(
            env::var("GABRIEL_BROWSERS_MCP_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:8787".to_string()),
        )
    }

    pub fn with_base_url(base_url: String) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            http: reqwest::Client::builder()
                .connect_timeout(Duration::from_millis(800))
                .timeout(Duration::from_secs(15))
                .build()
                .expect("failed to build browser supervisor HTTP client"),
        }
    }

    pub async fn status(&self) -> McpGatewayStatus {
        if let Err(error) = self.health().await {
            return McpGatewayStatus {
                healthy: false,
                workers: Vec::new(),
                message: format!("Supervisor de navegadores indisponível: {error}"),
            };
        }

        match self.profiles().await {
            Ok(profiles) => McpGatewayStatus {
                healthy: true,
                workers: profiles
                    .into_iter()
                    .filter_map(|profile| profile.worker)
                    .filter(|worker| worker.pid.is_some())
                    .collect(),
                message: "Supervisor de navegadores ativo.".to_string(),
            },
            Err(error) => McpGatewayStatus {
                healthy: false,
                workers: Vec::new(),
                message: format!("Supervisor incompatível ou degradado: {error}"),
            },
        }
    }

    pub async fn health(&self) -> Result<GatewayHealth> {
        let health = self
            .http
            .get(format!("{}/health", self.base_url))
            .send()
            .await?
            .error_for_status()?
            .json::<GatewayHealth>()
            .await
            .map_err(|_| {
                Error::Gateway(
                    "API de capacidades ausente; atualize para 0.2.1 ou superior.".to_string(),
                )
            })?;
        if !health.is_compatible() {
            return Err(Error::Gateway(format!(
                "versão {} sem control API v1, leases e lifecycle completos",
                health.version
            )));
        }
        Ok(health)
    }

    pub async fn profiles(&self) -> Result<Vec<GatewayProfile>> {
        self.health().await?;
        Ok(self
            .authenticated_request::<ProfilesResponse>("GET", "/v1/profiles", None)
            .await?
            .profiles)
    }

    pub async fn start(&self, profile_id: &str) -> Result<()> {
        self.health().await?;
        self.authenticated_request::<serde_json::Value>(
            "POST",
            &format!("/v1/profiles/{}/start", urlencoding::encode(profile_id)),
            Some(serde_json::json!({})),
        )
        .await?;
        Ok(())
    }

    pub async fn stop(&self, profile_id: &str) -> Result<bool> {
        self.health().await?;
        Ok(self
            .authenticated_request::<StopResponse>(
                "POST",
                &format!("/v1/profiles/{}/stop", urlencoding::encode(profile_id)),
                Some(serde_json::json!({ "force": false })),
            )
            .await?
            .stopped)
    }

    pub async fn open_url(&self, profile_id: &str, url: &str) -> Result<()> {
        self.health().await?;
        self.authenticated_request::<serde_json::Value>(
            "POST",
            &format!("/v1/profiles/{}/open-url", urlencoding::encode(profile_id)),
            Some(serde_json::json!({ "url": url, "owner": "custom-cdp-browser-linux" })),
        )
        .await?;
        Ok(())
    }

    pub async fn release(&self, profile_id: &str) -> Result<bool> {
        self.health().await?;
        Ok(self
            .authenticated_request::<ReleaseResponse>(
                "POST",
                &format!(
                    "/v1/profiles/{}/worker/release",
                    urlencoding::encode(profile_id)
                ),
                Some(serde_json::json!({})),
            )
            .await?
            .released)
    }

    async fn authenticated_request<T: DeserializeOwned>(
        &self,
        method: &str,
        path: &str,
        body: Option<serde_json::Value>,
    ) -> Result<T> {
        let token = gateway_token().ok_or_else(|| {
            Error::Gateway("Token do supervisor de navegadores indisponível.".to_string())
        })?;
        let method = reqwest::Method::from_bytes(method.as_bytes())
            .map_err(|error| Error::Gateway(error.to_string()))?;
        let mut request = self
            .http
            .request(method, format!("{}{}", self.base_url, path))
            .bearer_auth(token);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await?;
        let status = response.status();
        if !status.is_success() {
            let payload = response.json::<ErrorResponse>().await.ok();
            let code = payload
                .as_ref()
                .and_then(|item| item.code.as_deref())
                .unwrap_or("gateway_error");
            let detail = payload
                .as_ref()
                .and_then(|item| item.error.as_deref())
                .unwrap_or("resposta sem detalhe");
            return Err(Error::Gateway(format!("{code}: {detail}")));
        }
        Ok(response.json::<T>().await?)
    }
}

impl Default for McpGatewayClient {
    fn default() -> Self {
        Self::new()
    }
}

pub fn gateway_token() -> Option<String> {
    if let Ok(token) = env::var("GABRIEL_BROWSERS_MCP_TOKEN") {
        if !token.trim().is_empty() {
            return Some(token);
        }
    }

    let path = dirs::home_dir()?.join(".codex/gabriel-browsers-mcp.env");
    read_gateway_token_file(path)
}

fn read_gateway_token_file(path: PathBuf) -> Option<String> {
    let contents = fs::read_to_string(path).ok()?;
    contents.lines().find_map(|line| {
        let normalized = line.trim().strip_prefix("export ").unwrap_or(line.trim());
        let (key, value) = normalized.split_once('=')?;
        if key == "GABRIEL_BROWSERS_MCP_TOKEN" && !value.trim().is_empty() {
            Some(value.trim().trim_matches(['\'', '"']).to_string())
        } else {
            None
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_gateway_token_from_env_file_contents() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("gateway.env");
        fs::write(
            &path,
            "OTHER=value\nexport GABRIEL_BROWSERS_MCP_TOKEN='from-file'\n",
        )
        .unwrap();

        assert_eq!(read_gateway_token_file(path).as_deref(), Some("from-file"));
    }

    #[test]
    fn requires_complete_capabilities() {
        let health = GatewayHealth {
            version: "0.2.1".to_string(),
            capabilities: GatewayCapabilities {
                control_api: 1,
                leases: true,
                browser_lifecycle: true,
            },
        };
        assert!(health.is_compatible());
    }
}
