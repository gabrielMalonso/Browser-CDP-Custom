use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::{env, fs, path::PathBuf, time::Duration};

#[derive(Clone, Debug)]
pub struct McpGatewayClient {
    base_url: String,
    http: reqwest::Client,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct McpWorker {
    pub profile: String,
    pub port: u16,
    pub pid: Option<u32>,
    pub resident_memory_kilobytes: u64,
    pub active_calls: u32,
    pub created_at: String,
    pub last_used_at: String,
    pub idle_ms: u64,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct WorkersResponse {
    workers: Vec<McpWorker>,
}

#[derive(Clone, Debug, Deserialize)]
struct ReleaseResponse {
    released: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct McpGatewayStatus {
    pub healthy: bool,
    pub workers: Vec<McpWorker>,
    pub message: String,
}

impl McpGatewayClient {
    pub fn new() -> Self {
        Self {
            base_url: "http://127.0.0.1:8787".to_string(),
            http: reqwest::Client::builder()
                .connect_timeout(Duration::from_millis(800))
                .timeout(Duration::from_secs(2))
                .build()
                .expect("failed to build MCP gateway HTTP client"),
        }
    }

    pub async fn status(&self) -> McpGatewayStatus {
        if let Err(error) = self.health().await {
            return McpGatewayStatus {
                healthy: false,
                workers: Vec::new(),
                message: format!("Gateway MCP indisponível: {error}"),
            };
        }

        match self.workers().await {
            Ok(workers) => McpGatewayStatus {
                healthy: true,
                workers,
                message: "Gateway MCP ativo.".to_string(),
            },
            Err(error) => McpGatewayStatus {
                healthy: true,
                workers: Vec::new(),
                message: format!("Gateway MCP ativo, mas status dos workers falhou: {error}"),
            },
        }
    }

    pub async fn release(&self, profile_id: &str) -> Result<bool> {
        let token = gateway_token()
            .ok_or_else(|| Error::Gateway("Token do Gateway MCP indisponível.".to_string()))?;
        let response = self
            .http
            .post(format!("{}/release", self.base_url))
            .bearer_auth(token)
            .json(&serde_json::json!({ "profile": profile_id }))
            .send()
            .await?
            .error_for_status()?
            .json::<ReleaseResponse>()
            .await?;

        Ok(response.released)
    }

    async fn health(&self) -> Result<()> {
        self.http
            .get(format!("{}/health", self.base_url))
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    async fn workers(&self) -> Result<Vec<McpWorker>> {
        let token = gateway_token()
            .ok_or_else(|| Error::Gateway("Token do Gateway MCP indisponível.".to_string()))?;
        Ok(self
            .http
            .get(format!("{}/workers", self.base_url))
            .bearer_auth(token)
            .send()
            .await?
            .error_for_status()?
            .json::<WorkersResponse>()
            .await?
            .workers)
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
        let (key, value) = line.split_once('=')?;
        if key == "GABRIEL_BROWSERS_MCP_TOKEN" && !value.trim().is_empty() {
            Some(value.trim().to_string())
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
        fs::write(&path, "OTHER=value\nGABRIEL_BROWSERS_MCP_TOKEN=from-file\n").unwrap();

        assert_eq!(read_gateway_token_file(path).as_deref(), Some("from-file"));
    }
}
