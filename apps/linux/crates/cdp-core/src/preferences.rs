use crate::{AppConfig, Error, Result};
use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf};

pub const NORMAL_BROWSER_DESTINATION: &str = "normal-browser";

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LinkRoutingMode {
    #[default]
    AskEveryTime,
    DefaultDestination,
    LastSelected,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct AppPreferences {
    pub link_routing_mode: LinkRoutingMode,
    pub default_destination_id: String,
    pub last_selected_destination_id: Option<String>,
    pub dismiss_overlay_after_selection: bool,
}

impl Default for AppPreferences {
    fn default() -> Self {
        Self {
            link_routing_mode: LinkRoutingMode::AskEveryTime,
            default_destination_id: String::new(),
            last_selected_destination_id: None,
            dismiss_overlay_after_selection: true,
        }
    }
}

impl AppPreferences {
    pub fn load(config: &AppConfig) -> Result<Self> {
        Self::load_from_path(config, default_preferences_path())
    }

    pub fn load_from_path(config: &AppConfig, path: PathBuf) -> Result<Self> {
        let mut preferences = match fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Self::default(),
            Err(error) => return Err(Error::Io(error)),
        };
        preferences.normalize(config);
        Ok(preferences)
    }

    pub fn save(&self) -> Result<()> {
        self.save_to_path(default_preferences_path())
    }

    pub fn save_to_path(&self, path: PathBuf) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        let temporary_path = path.with_extension("json.tmp");
        fs::write(&temporary_path, serde_json::to_vec_pretty(self)?)?;
        fs::rename(temporary_path, path)?;
        Ok(())
    }

    pub fn normalize(&mut self, config: &AppConfig) {
        if !destination_exists(config, &self.default_destination_id) {
            self.default_destination_id = config.default_profile_id.clone();
        }

        if self
            .last_selected_destination_id
            .as_deref()
            .is_some_and(|id| !destination_exists(config, id))
        {
            self.last_selected_destination_id = None;
        }
    }

    pub fn routing_destination_id(&self) -> Option<&str> {
        match self.link_routing_mode {
            LinkRoutingMode::AskEveryTime => None,
            LinkRoutingMode::DefaultDestination => Some(&self.default_destination_id),
            LinkRoutingMode::LastSelected => self
                .last_selected_destination_id
                .as_deref()
                .or(Some(&self.default_destination_id)),
        }
    }
}

pub fn default_preferences_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from(".config"))
        .join("browser-cdp-custom-linux/preferences.json")
}

fn destination_exists(config: &AppConfig, id: &str) -> bool {
    id == NORMAL_BROWSER_DESTINATION || config.profiles.iter().any(|profile| profile.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn defaults_to_asking_and_the_configured_profile() {
        let config = AppConfig::default();
        let directory = tempdir().unwrap();
        let preferences = AppPreferences::load_from_path(
            &config,
            directory.path().join("missing-preferences.json"),
        )
        .unwrap();

        assert_eq!(preferences.link_routing_mode, LinkRoutingMode::AskEveryTime);
        assert_eq!(
            preferences.default_destination_id,
            config.default_profile_id
        );
        assert_eq!(preferences.routing_destination_id(), None);
    }

    #[test]
    fn last_selected_falls_back_to_default_destination() {
        let mut preferences = AppPreferences {
            link_routing_mode: LinkRoutingMode::LastSelected,
            default_destination_id: "central-rj".to_string(),
            ..AppPreferences::default()
        };

        assert_eq!(preferences.routing_destination_id(), Some("central-rj"));
        preferences.last_selected_destination_id = Some(NORMAL_BROWSER_DESTINATION.to_string());
        assert_eq!(
            preferences.routing_destination_id(),
            Some(NORMAL_BROWSER_DESTINATION)
        );
    }

    #[test]
    fn invalid_saved_destinations_are_repaired() {
        let config = AppConfig::default();
        let directory = tempdir().unwrap();
        let path = directory.path().join("preferences.json");
        fs::write(
            &path,
            r#"{
              "link_routing_mode": "default_destination",
              "default_destination_id": "apagado",
              "last_selected_destination_id": "tambem-apagado",
              "dismiss_overlay_after_selection": false
            }"#,
        )
        .unwrap();

        let preferences = AppPreferences::load_from_path(&config, path).unwrap();
        assert_eq!(
            preferences.default_destination_id,
            config.default_profile_id
        );
        assert_eq!(preferences.last_selected_destination_id, None);
        assert!(!preferences.dismiss_overlay_after_selection);
    }

    #[test]
    fn preferences_round_trip() {
        let config = AppConfig::default();
        let directory = tempdir().unwrap();
        let path = directory.path().join("preferences.json");
        let preferences = AppPreferences {
            link_routing_mode: LinkRoutingMode::DefaultDestination,
            default_destination_id: NORMAL_BROWSER_DESTINATION.to_string(),
            last_selected_destination_id: Some("pessoal".to_string()),
            dismiss_overlay_after_selection: true,
        };

        preferences.save_to_path(path.clone()).unwrap();
        assert_eq!(
            AppPreferences::load_from_path(&config, path).unwrap(),
            preferences
        );
    }
}
