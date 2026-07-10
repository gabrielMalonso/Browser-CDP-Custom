use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::{
    env, fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProfileConfig {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub badge: String,
    pub user_data_dir: PathBuf,
    pub profile_directory: String,
    pub browser_command: Option<String>,
    pub port: u16,
    pub default_url: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AppConfig {
    pub profiles: Vec<ProfileConfig>,
    pub default_profile_id: String,
}

impl AppConfig {
    pub fn load() -> Result<Self> {
        if let Some(path) = env::var_os("BROWSER_CDP_CUSTOM_CONFIG") {
            return Self::from_path(path.into());
        }

        let config_path = default_config_path();
        if config_path.exists() {
            return Self::from_path(config_path);
        }

        Ok(Self::default())
    }

    pub fn from_path(path: PathBuf) -> Result<Self> {
        let bytes = fs::read(path)?;
        let mut config: Self = serde_json::from_slice(&bytes)?;
        config.expand_home();
        Ok(config)
    }

    pub fn profile(&self, id: &str) -> Result<&ProfileConfig> {
        self.profiles
            .iter()
            .find(|profile| profile.id == id)
            .ok_or_else(|| Error::ProfileNotFound(id.to_string()))
    }

    pub fn default_profile(&self) -> Result<&ProfileConfig> {
        self.profile(&self.default_profile_id)
    }

    fn expand_home(&mut self) {
        for profile in &mut self.profiles {
            profile.user_data_dir = expand_tilde(&profile.user_data_dir);
        }
    }
}

impl Default for AppConfig {
    fn default() -> Self {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        Self {
            default_profile_id: "central-es".to_string(),
            profiles: vec![
                ProfileConfig {
                    id: "pessoal".to_string(),
                    name: "Pessoal".to_string(),
                    kind: "personal".to_string(),
                    badge: "P".to_string(),
                    user_data_dir: home.join(".chrome-cdp/pessoal"),
                    profile_directory: "Default".to_string(),
                    browser_command: None,
                    port: 9224,
                    default_url: None,
                },
                ProfileConfig {
                    id: "central-es".to_string(),
                    name: "Central ES".to_string(),
                    kind: "clinic".to_string(),
                    badge: "ES".to_string(),
                    user_data_dir: home.join(".chrome-cdp/central-es"),
                    profile_directory: "Default".to_string(),
                    browser_command: None,
                    port: 9222,
                    default_url: Some("https://web.whatsapp.com/".to_string()),
                },
                ProfileConfig {
                    id: "central-rj".to_string(),
                    name: "Central RJ".to_string(),
                    kind: "clinic".to_string(),
                    badge: "RJ".to_string(),
                    user_data_dir: home.join(".chrome-cdp/central-rj"),
                    profile_directory: "Default".to_string(),
                    browser_command: None,
                    port: 9223,
                    default_url: Some("https://web.whatsapp.com/".to_string()),
                },
                ProfileConfig {
                    id: "central-sp".to_string(),
                    name: "Financeiro/CentralSP".to_string(),
                    kind: "clinic".to_string(),
                    badge: "SP".to_string(),
                    user_data_dir: home.join(".chrome-cdp/financeiro-centralsp"),
                    profile_directory: "Default".to_string(),
                    browser_command: None,
                    port: 9226,
                    default_url: Some("https://web.whatsapp.com/".to_string()),
                },
            ],
        }
    }
}

pub fn default_config_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from(".config"))
        .join("browser-cdp-custom-linux/profiles.json")
}

pub fn default_pending_links_path() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from(".local/share"))
        .join("browser-cdp-custom-linux/pending-links.json")
}

fn expand_tilde(path: &Path) -> PathBuf {
    let Some(raw) = path.to_str() else {
        return path.to_path_buf();
    };

    if raw == "~" {
        return dirs::home_dir().unwrap_or_else(|| path.to_path_buf());
    }

    if let Some(rest) = raw.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }

    path.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn default_profiles_include_linux_centrals() {
        let config = AppConfig::default();
        let ids = config
            .profiles
            .iter()
            .map(|profile| profile.id.as_str())
            .collect::<Vec<_>>();

        assert!(ids.contains(&"central-es"));
        assert!(ids.contains(&"central-sp"));
        assert!(ids.contains(&"pessoal"));
        assert_eq!(config.profile("pessoal").unwrap().port, 9224);
        assert_eq!(config.profile("central-es").unwrap().port, 9222);
        assert_eq!(config.profile("central-sp").unwrap().port, 9226);
    }

    #[test]
    fn loads_json_config_and_expands_tilde() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("profiles.json");
        fs::write(
            &path,
            r#"{
              "default_profile_id": "central-sp",
              "profiles": [{
                "id": "central-sp",
                "name": "Central SP",
                "kind": "clinic",
                "badge": "SP",
                "user_data_dir": "~/.chrome-cdp/sp",
                "profile_directory": "Default",
                "browser_command": "google-chrome",
                "port": 9333,
                "default_url": "https://web.whatsapp.com/"
              }]
            }"#,
        )
        .unwrap();

        let config = AppConfig::from_path(path).unwrap();
        assert_eq!(config.default_profile().unwrap().port, 9333);
        assert!(config.profiles[0].user_data_dir.is_absolute());
    }
}
