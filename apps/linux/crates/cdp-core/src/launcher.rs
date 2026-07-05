use crate::cdp::{parse_http_url, CdpClient};
use crate::{AppConfig, Error, ProfileConfig, Result};
use serde::Serialize;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command as StdCommand, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::net::TcpStream;
use tokio::time::{sleep, Duration, Instant};

#[derive(Clone, Debug)]
pub struct BrowserLauncher {
    config: AppConfig,
    cdp: CdpClient,
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
            cdp: CdpClient::new(),
        }
    }

    pub async fn statuses(&self) -> Result<Vec<ProfileStatus>> {
        let mut statuses = Vec::with_capacity(self.config.profiles.len());
        for profile in &self.config.profiles {
            statuses.push(self.status(profile).await);
        }
        Ok(statuses)
    }

    pub async fn launch_profile(&self, profile_id: &str) -> Result<String> {
        let profile = self.config.profile(profile_id)?;
        self.ensure_browser(profile).await?;

        if let Some(default_url) = &profile.default_url {
            let url = parse_http_url(default_url)?;
            self.cdp.open_new_tab(profile.port, &url).await?;
        }

        Ok(format!(
            "{} está aberto na porta {}.",
            profile.name, profile.port
        ))
    }

    pub async fn open_url(&self, profile_id: &str, raw_url: &str) -> Result<String> {
        let profile = self.config.profile(profile_id)?;
        let url = parse_http_url(raw_url)?;

        self.ensure_browser(profile).await?;
        self.cdp.open_new_tab(profile.port, &url).await?;

        Ok(format!("URL enviada para {}.", profile.name))
    }

    pub async fn close_profile(&self, profile_id: &str) -> Result<String> {
        let profile = self.config.profile(profile_id)?;
        let closed = close_profile_processes(profile).await?;

        if closed == 0 {
            return Ok(format!("{} já estava fechado.", profile.name));
        }

        Ok(format!("{} encerrado.", profile.name))
    }

    pub async fn close_all_controlled_browsers(&self) -> Result<usize> {
        let mut closed = 0;
        for profile in &self.config.profiles {
            closed += close_profile_processes(profile).await?;
        }
        Ok(closed)
    }

    async fn status(&self, profile: &ProfileConfig) -> ProfileStatus {
        let profile_exists = profile_data_dir(profile).is_dir();
        let port_open = is_port_open(profile.port).await;
        if !port_open {
            return ProfileStatus {
                profile: profile.clone(),
                profile_exists,
                cdp_ok: false,
                port_open,
                message: if profile_exists {
                    "Porta fechada.".to_string()
                } else {
                    "Diretório do perfil não encontrado.".to_string()
                },
            };
        }

        match self.cdp.version(profile.port).await {
            Ok(version) if has_matching_browser_process(profile) => ProfileStatus {
                profile: profile.clone(),
                profile_exists,
                cdp_ok: true,
                port_open,
                message: version
                    .browser
                    .unwrap_or_else(|| "CDP respondeu sem nome de browser.".to_string()),
            },
            Ok(_) => ProfileStatus {
                profile: profile.clone(),
                profile_exists,
                cdp_ok: false,
                port_open,
                message: "CDP respondeu, mas o processo não bate com este perfil.".to_string(),
            },
            Err(error) => ProfileStatus {
                profile: profile.clone(),
                profile_exists,
                cdp_ok: false,
                port_open,
                message: format!("Porta ocupada, mas CDP falhou: {error}"),
            },
        }
    }

    async fn ensure_browser(&self, profile: &ProfileConfig) -> Result<()> {
        if is_port_open(profile.port).await {
            self.cdp
                .version(profile.port)
                .await
                .map_err(|_| Error::PortOccupied { port: profile.port })?;
            if !has_matching_browser_process(profile) {
                return Err(Error::PortOccupied { port: profile.port });
            }
            return Ok(());
        }

        spawn_browser(profile).await?;
        wait_for_cdp(&self.cdp, profile.port).await
    }
}

async fn wait_for_cdp(cdp: &CdpClient, port: u16) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if cdp.version(port).await.is_ok() {
            return Ok(());
        }
        sleep(Duration::from_millis(500)).await;
    }

    Err(Error::CdpUnavailable { port })
}

async fn spawn_browser(profile: &ProfileConfig) -> Result<()> {
    let profile_data_dir = profile_data_dir(profile);
    if !profile_data_dir.is_dir() {
        return Err(Error::ProfileDirectoryMissing(
            profile_data_dir.display().to_string(),
        ));
    }
    ensure_profile_is_not_locked(profile)?;

    let browser = match &profile.browser_command {
        Some(command) => PathBuf::from(command),
        None => find_browser().ok_or(Error::BrowserNotFound)?,
    };

    let mut command = StdCommand::new(browser);
    command
        .arg(format!(
            "--user-data-dir={}",
            profile.user_data_dir.display()
        ))
        .arg(format!("--profile-directory={}", profile.profile_directory))
        .arg(format!("--remote-debugging-port={}", profile.port))
        .arg("--remote-allow-origins=*")
        .arg("--no-first-run")
        .arg("--password-store=basic")
        .arg("--disable-features=DevToolsDebuggingRestrictions")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    add_graphical_environment(&mut command);
    detach_from_parent(&mut command);

    command
        .spawn()
        .map_err(|error| Error::SpawnFailed(error.to_string()))?;

    Ok(())
}

fn detach_from_parent(command: &mut StdCommand) {
    #[cfg(unix)]
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }

            Ok(())
        });
    }
}

fn find_browser() -> Option<PathBuf> {
    [
        "google-chrome",
        "google-chrome-stable",
        "chromium",
        "chromium-browser",
    ]
    .iter()
    .find_map(which)
}

fn which(binary: &&str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(binary))
        .find(|candidate| candidate.is_file())
}

async fn is_port_open(port: u16) -> bool {
    TcpStream::connect(("127.0.0.1", port)).await.is_ok()
}

fn profile_data_dir(profile: &ProfileConfig) -> PathBuf {
    profile.user_data_dir.join(&profile.profile_directory)
}

fn ensure_profile_is_not_locked(profile: &ProfileConfig) -> Result<()> {
    let lock_path = profile.user_data_dir.join("SingletonLock");
    let Ok(target) = std::fs::read_link(&lock_path) else {
        return Ok(());
    };

    let target_display = target.display().to_string();
    let live_or_unknown = lock_target_pid(&target).map(process_exists).unwrap_or(true);
    if live_or_unknown {
        return Err(Error::ProfileLocked {
            path: lock_path.display().to_string(),
            target: target_display,
        });
    }

    archive_stale_singleton_links(profile)?;
    Ok(())
}

fn lock_target_pid(target: &Path) -> Option<u32> {
    target
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.rsplit('-').next())
        .and_then(|pid| pid.parse::<u32>().ok())
}

fn process_exists(pid: u32) -> bool {
    PathBuf::from(format!("/proc/{pid}")).exists()
}

fn archive_stale_singleton_links(profile: &ProfileConfig) -> Result<()> {
    let backup_dir = singleton_backup_dir(profile);
    std::fs::create_dir_all(&backup_dir)?;

    for name in ["SingletonLock", "SingletonCookie", "SingletonSocket"] {
        let path = profile.user_data_dir.join(name);
        if std::fs::symlink_metadata(&path).is_err() {
            continue;
        }

        let target = backup_dir.join(name);
        std::fs::rename(path, target)?;
    }

    Ok(())
}

fn singleton_backup_dir(profile: &ProfileConfig) -> PathBuf {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    let backup_root = profile
        .user_data_dir
        .parent()
        .map(|parent| parent.join("backups"))
        .unwrap_or_else(|| PathBuf::from("backups"));

    backup_root.join(format!(
        "{}-stale-singleton-{timestamp}-{}",
        profile.id,
        std::process::id()
    ))
}

fn add_graphical_environment(command: &mut StdCommand) {
    let runtime_dir = std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .unwrap_or_else(|| format!("/run/user/{}", unsafe { libc::geteuid() }));

    if std::env::var_os("XDG_RUNTIME_DIR").is_none() && PathBuf::from(&runtime_dir).is_dir() {
        command.env("XDG_RUNTIME_DIR", &runtime_dir);
    }

    if std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_none() {
        let bus = PathBuf::from(&runtime_dir).join("bus");
        if bus.exists() {
            command.env(
                "DBUS_SESSION_BUS_ADDRESS",
                format!("unix:path={}", bus.display()),
            );
        }
    }

    if std::env::var_os("DISPLAY").is_none() && PathBuf::from("/tmp/.X11-unix/X0").exists() {
        command.env("DISPLAY", ":0");
    }

    if std::env::var_os("XAUTHORITY").is_none() {
        let xauthority = PathBuf::from(&runtime_dir).join("gdm/Xauthority");
        if xauthority.is_file() {
            command.env("XAUTHORITY", xauthority);
        }
    }
}

fn has_matching_browser_process(profile: &ProfileConfig) -> bool {
    let output = StdCommand::new("ps").args(["-eo", "args="]).output();

    let Ok(output) = output else {
        return false;
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout
        .lines()
        .any(|line| command_matches_profile(line, profile))
}

async fn close_profile_processes(profile: &ProfileConfig) -> Result<usize> {
    let pids = matching_profile_process_ids(&ps_pid_args_output()?, profile);
    if pids.is_empty() {
        return Ok(0);
    }

    for pid in &pids {
        terminate_pid(*pid)?;
    }

    let deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < deadline {
        if matching_profile_process_ids(&ps_pid_args_output()?, profile).is_empty() {
            return Ok(pids.len());
        }
        sleep(Duration::from_millis(200)).await;
    }

    Err(Error::StopFailed(format!(
        "processos ainda ativos para {}: {:?}",
        profile.name, pids
    )))
}

fn ps_pid_args_output() -> Result<String> {
    let output = StdCommand::new("ps").args(["-eo", "pid=,args="]).output()?;
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn matching_profile_process_ids(ps_output: &str, profile: &ProfileConfig) -> Vec<u32> {
    ps_output
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim_start();
            let (pid, command) = trimmed.split_once(char::is_whitespace)?;
            if command_matches_profile(command.trim_start(), profile) {
                pid.parse::<u32>().ok()
            } else {
                None
            }
        })
        .collect()
}

fn terminate_pid(pid: u32) -> Result<()> {
    let result = unsafe { libc::kill(pid as i32, libc::SIGTERM) };
    if result == 0 {
        return Ok(());
    }

    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(())
    } else {
        Err(error.into())
    }
}

fn command_matches_profile(command: &str, profile: &ProfileConfig) -> bool {
    let user_data_dir = profile.user_data_dir.display().to_string();
    let port = profile.port.to_string();
    let remote_debugging_equals = format!("--remote-debugging-port={port}");
    let remote_debugging_space = format!("--remote-debugging-port {port}");
    let user_data_equals = format!("--user-data-dir={user_data_dir}");
    let user_data_space = format!("--user-data-dir {user_data_dir}");

    (command.contains(&remote_debugging_equals) || command.contains(&remote_debugging_space))
        && (command.contains(&user_data_equals) || command.contains(&user_data_space))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_browser_command_skips_path_lookup() {
        let profile = ProfileConfig {
            id: "x".to_string(),
            name: "X".to_string(),
            kind: "clinic".to_string(),
            badge: "X".to_string(),
            user_data_dir: PathBuf::from("/tmp/x"),
            profile_directory: "Default".to_string(),
            browser_command: Some("/usr/bin/google-chrome".to_string()),
            port: 9222,
            default_url: None,
        };

        assert_eq!(
            profile.browser_command.as_deref(),
            Some("/usr/bin/google-chrome")
        );
    }

    #[test]
    fn command_match_requires_port_and_profile_root() {
        let profile = ProfileConfig {
            id: "central-es".to_string(),
            name: "Central ES".to_string(),
            kind: "clinic".to_string(),
            badge: "ES".to_string(),
            user_data_dir: PathBuf::from("/home/gabriel-alonso/.chrome-cdp/central-es"),
            profile_directory: "Default".to_string(),
            browser_command: None,
            port: 9222,
            default_url: None,
        };

        assert!(command_matches_profile(
            "google-chrome --user-data-dir=/home/gabriel-alonso/.chrome-cdp/central-es --remote-debugging-port=9222",
            &profile
        ));
        assert!(!command_matches_profile(
            "google-chrome --user-data-dir=/home/gabriel-alonso/.chrome-cdp/outro --remote-debugging-port=9222",
            &profile
        ));
        assert!(!command_matches_profile(
            "google-chrome --user-data-dir=/home/gabriel-alonso/.chrome-cdp/central-es --remote-debugging-port=9226",
            &profile
        ));
    }

    #[test]
    fn extracts_matching_profile_process_ids() {
        let profile = ProfileConfig {
            id: "central-es".to_string(),
            name: "Central ES".to_string(),
            kind: "clinic".to_string(),
            badge: "ES".to_string(),
            user_data_dir: PathBuf::from("/home/gabriel-alonso/.chrome-cdp/central-es"),
            profile_directory: "Default".to_string(),
            browser_command: None,
            port: 9222,
            default_url: None,
        };

        let ps_output = "\
          101 /usr/bin/google-chrome --user-data-dir=/home/gabriel-alonso/.chrome-cdp/central-es --remote-debugging-port=9222
          102 /usr/bin/google-chrome --user-data-dir=/home/gabriel-alonso/.chrome-cdp/central-rj --remote-debugging-port=9222
          103 /usr/bin/google-chrome --user-data-dir=/home/gabriel-alonso/.chrome-cdp/central-es --remote-debugging-port=9333
        ";

        assert_eq!(matching_profile_process_ids(ps_output, &profile), vec![101]);
    }

    #[test]
    fn parses_pid_from_singleton_lock_target() {
        assert_eq!(
            lock_target_pid(Path::new("gabriel-alonso-MSI-564777")),
            Some(564777)
        );
        assert_eq!(lock_target_pid(Path::new("not-a-pid")), None);
    }

    #[test]
    #[cfg(unix)]
    fn stale_singleton_links_are_archived_before_launch() {
        let root = tempfile::tempdir().unwrap();
        let user_data_dir = root.path().join(".chrome-cdp/central-es");
        std::fs::create_dir_all(user_data_dir.join("Default")).unwrap();

        std::os::unix::fs::symlink("host-4294967295", user_data_dir.join("SingletonLock")).unwrap();
        std::os::unix::fs::symlink("cookie", user_data_dir.join("SingletonCookie")).unwrap();
        std::os::unix::fs::symlink(
            "/tmp/browser-cdp-custom-test/SingletonSocket",
            user_data_dir.join("SingletonSocket"),
        )
        .unwrap();

        let profile = ProfileConfig {
            id: "central-es".to_string(),
            name: "Central ES".to_string(),
            kind: "clinic".to_string(),
            badge: "ES".to_string(),
            user_data_dir,
            profile_directory: "Default".to_string(),
            browser_command: None,
            port: 9222,
            default_url: None,
        };

        ensure_profile_is_not_locked(&profile).unwrap();

        assert!(std::fs::symlink_metadata(profile.user_data_dir.join("SingletonLock")).is_err());
        assert!(std::fs::symlink_metadata(profile.user_data_dir.join("SingletonCookie")).is_err());
        assert!(std::fs::symlink_metadata(profile.user_data_dir.join("SingletonSocket")).is_err());

        let backup_root = root.path().join(".chrome-cdp/backups");
        let backup_dir = std::fs::read_dir(backup_root)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(
            std::fs::read_link(backup_dir.join("SingletonLock")).unwrap(),
            PathBuf::from("host-4294967295")
        );
        assert_eq!(
            std::fs::read_link(backup_dir.join("SingletonCookie")).unwrap(),
            PathBuf::from("cookie")
        );
        assert_eq!(
            std::fs::read_link(backup_dir.join("SingletonSocket")).unwrap(),
            PathBuf::from("/tmp/browser-cdp-custom-test/SingletonSocket")
        );
    }

    #[test]
    #[cfg(unix)]
    fn live_or_unknown_singleton_lock_still_blocks_launch() {
        let root = tempfile::tempdir().unwrap();
        let user_data_dir = root.path().join(".chrome-cdp/central-es");
        std::fs::create_dir_all(user_data_dir.join("Default")).unwrap();

        std::os::unix::fs::symlink(
            format!("host-{}", std::process::id()),
            user_data_dir.join("SingletonLock"),
        )
        .unwrap();

        let profile = ProfileConfig {
            id: "central-es".to_string(),
            name: "Central ES".to_string(),
            kind: "clinic".to_string(),
            badge: "ES".to_string(),
            user_data_dir,
            profile_directory: "Default".to_string(),
            browser_command: None,
            port: 9222,
            default_url: None,
        };

        assert!(matches!(
            ensure_profile_is_not_locked(&profile),
            Err(Error::ProfileLocked { .. })
        ));
        assert!(std::fs::symlink_metadata(profile.user_data_dir.join("SingletonLock")).is_ok());
    }
}
