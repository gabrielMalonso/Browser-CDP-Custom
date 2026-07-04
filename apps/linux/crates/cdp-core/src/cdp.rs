use crate::{Error, Result};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use url::Url;

#[derive(Clone, Debug)]
pub struct CdpClient {
    http: Client,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CdpVersion {
    #[serde(rename = "Browser")]
    pub browser: Option<String>,
    #[serde(rename = "Protocol-Version")]
    pub protocol_version: Option<String>,
    #[serde(rename = "webSocketDebuggerUrl")]
    pub web_socket_debugger_url: Option<String>,
}

impl CdpClient {
    pub fn new() -> Self {
        Self {
            http: Client::builder()
                .connect_timeout(Duration::from_secs(2))
                .timeout(Duration::from_secs(5))
                .build()
                .expect("failed to build CDP HTTP client"),
        }
    }

    pub async fn version(&self, port: u16) -> Result<CdpVersion> {
        Ok(self
            .http
            .get(format!("http://127.0.0.1:{port}/json/version"))
            .send()
            .await?
            .error_for_status()?
            .json::<CdpVersion>()
            .await?)
    }

    pub async fn open_new_tab(&self, port: u16, url: &Url) -> Result<()> {
        let endpoint = cdp_new_tab_url(port, url);
        let response = self.http.put(endpoint.clone()).send().await?;

        if response.status() == StatusCode::METHOD_NOT_ALLOWED {
            self.http.get(endpoint).send().await?.error_for_status()?;
            return Ok(());
        }

        response.error_for_status()?;
        Ok(())
    }
}

impl Default for CdpClient {
    fn default() -> Self {
        Self::new()
    }
}

pub fn parse_http_url(raw: &str) -> Result<Url> {
    let url = Url::parse(raw).map_err(|_| Error::InvalidUrl(raw.to_string()))?;
    match url.scheme() {
        "http" | "https" => Ok(url),
        _ => Err(Error::InvalidUrl(raw.to_string())),
    }
}

pub fn cdp_new_tab_url(port: u16, url: &Url) -> String {
    let encoded = utf8_percent_encode(url.as_str(), NON_ALPHANUMERIC).to_string();
    format!("http://127.0.0.1:{port}/json/new?{encoded}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::{
        matchers::{method, path},
        Mock, MockServer, ResponseTemplate,
    };

    #[test]
    fn encodes_full_url_for_json_new_endpoint() {
        let url = Url::parse("https://example.com/a b?x=1&next=https://a.test/?q=sim").unwrap();
        let endpoint = cdp_new_tab_url(9222, &url);

        assert_eq!(
            endpoint,
            "http://127.0.0.1:9222/json/new?https%3A%2F%2Fexample%2Ecom%2Fa%2520b%3Fx%3D1%26next%3Dhttps%3A%2F%2Fa%2Etest%2F%3Fq%3Dsim"
        );
    }

    #[test]
    fn accepts_only_http_and_https() {
        assert!(parse_http_url("https://example.com").is_ok());
        assert!(parse_http_url("http://example.com").is_ok());
        assert!(parse_http_url("file:///tmp/nope").is_err());
    }

    #[tokio::test]
    async fn reads_cdp_version_from_mock() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/json/version"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "Browser": "Chrome/1",
                "Protocol-Version": "1.3",
                "webSocketDebuggerUrl": "ws://127.0.0.1/devtools/browser/1"
            })))
            .mount(&server)
            .await;

        let body = CdpClient::new()
            .version(server.address().port())
            .await
            .unwrap();

        assert_eq!(body.browser.as_deref(), Some("Chrome/1"));
    }
}
