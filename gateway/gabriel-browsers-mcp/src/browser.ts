import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import type { ProfileConfig } from "./config.js";
import { cdpVersion, isPortOpen, waitForCdp } from "./cdp.js";
import { GatewayError } from "./errors.js";

const execFileAsync = promisify(execFile);

function profileDataDir(profile: ProfileConfig) {
  return path.join(profile.user_data_dir, profile.profile_directory);
}

function commandMatchesProfile(command: string, profile: ProfileConfig) {
  const port = String(profile.port);
  const userDataDir = profile.user_data_dir;

  return (
    (command.includes(`--remote-debugging-port=${port}`) ||
      command.includes(`--remote-debugging-port ${port}`)) &&
    (command.includes(`--user-data-dir=${userDataDir}`) ||
      command.includes(`--user-data-dir ${userDataDir}`))
  );
}

async function hasMatchingBrowserProcess(profile: ProfileConfig) {
  try {
    const { stdout } = await execFileAsync("ps", ["-eo", "args="], { maxBuffer: 2_000_000 });
    return stdout.split(/\r?\n/).some((line) => commandMatchesProfile(line, profile));
  } catch {
    return false;
  }
}

async function which(binary: string) {
  const pathValue = process.env.PATH ?? "";
  for (const directory of pathValue.split(path.delimiter)) {
    const candidate = path.join(directory, binary);
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return null;
}

async function findBrowser(profile: ProfileConfig) {
  if (profile.browser_command) {
    return profile.browser_command;
  }

  for (const binary of ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]) {
    const candidate = await which(binary);
    if (candidate) {
      return candidate;
    }
  }

  throw new GatewayError(
    "navegador não encontrado; instale google-chrome, google-chrome-stable, chromium ou chromium-browser",
    500
  );
}

function lockTargetPid(target: string) {
  const pid = Number(path.basename(target).split("-").at(-1));
  return Number.isInteger(pid) && pid > 0 ? pid : null;
}

function processExists(pid: number) {
  return fs.existsSync(`/proc/${pid}`);
}

function singletonBackupDir(profile: ProfileConfig) {
  const backupRoot = path.join(path.dirname(profile.user_data_dir), "backups");
  return path.join(backupRoot, `${profile.id}-stale-singleton-${Math.floor(Date.now() / 1000)}-${process.pid}`);
}

function archiveStaleSingletonLinks(profile: ProfileConfig) {
  const backupDir = singletonBackupDir(profile);
  fs.mkdirSync(backupDir, { recursive: true });

  for (const name of ["SingletonLock", "SingletonCookie", "SingletonSocket"]) {
    const source = path.join(profile.user_data_dir, name);
    if (!fs.existsSync(source)) {
      continue;
    }

    fs.renameSync(source, path.join(backupDir, name));
  }
}

function ensureProfileIsNotLocked(profile: ProfileConfig) {
  const lockPath = path.join(profile.user_data_dir, "SingletonLock");
  let target: string;
  try {
    target = fs.readlinkSync(lockPath);
  } catch {
    return;
  }

  const pid = lockTargetPid(target);
  if (!pid || processExists(pid)) {
    throw new GatewayError(`perfil parece travado por lock: ${lockPath} aponta para ${target}`, 409);
  }

  archiveStaleSingletonLinks(profile);
}

function graphicalEnvironment() {
  const env: NodeJS.ProcessEnv = { ...process.env };
  const runtimeDir = env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.() ?? os.userInfo().uid}`;

  if (!env.XDG_RUNTIME_DIR && fs.existsSync(runtimeDir)) {
    env.XDG_RUNTIME_DIR = runtimeDir;
  }

  const busPath = path.join(runtimeDir, "bus");
  if (!env.DBUS_SESSION_BUS_ADDRESS && fs.existsSync(busPath)) {
    env.DBUS_SESSION_BUS_ADDRESS = `unix:path=${busPath}`;
  }

  if (!env.DISPLAY && fs.existsSync("/tmp/.X11-unix/X0")) {
    env.DISPLAY = ":0";
  }

  const xauthority = path.join(runtimeDir, "gdm/Xauthority");
  if (!env.XAUTHORITY && fs.existsSync(xauthority)) {
    env.XAUTHORITY = xauthority;
  }

  return env;
}

async function spawnBrowser(profile: ProfileConfig) {
  if (!fs.existsSync(profileDataDir(profile))) {
    throw new GatewayError(`diretório do perfil não existe: ${profileDataDir(profile)}`, 404);
  }

  ensureProfileIsNotLocked(profile);

  const browser = await findBrowser(profile);
  const child = (await import("node:child_process")).spawn(
    browser,
    [
      `--user-data-dir=${profile.user_data_dir}`,
      `--profile-directory=${profile.profile_directory}`,
      `--remote-debugging-port=${profile.port}`,
      "--remote-allow-origins=*",
      "--no-first-run",
      "--password-store=basic",
      "--disable-features=DevToolsDebuggingRestrictions",
      "--disable-background-timer-throttling",
      "--disable-backgrounding-occluded-windows",
      "--disable-renderer-backgrounding"
    ],
    {
      detached: true,
      env: graphicalEnvironment(),
      stdio: "ignore"
    }
  );
  child.unref();
}

export async function ensureBrowser(profile: ProfileConfig) {
  if (await isPortOpen(profile.port)) {
    await cdpVersion(profile.port).catch(() => {
      throw new GatewayError(`porta ${profile.port} está ocupada, mas não respondeu como CDP`, 409);
    });

    if (!(await hasMatchingBrowserProcess(profile))) {
      throw new GatewayError(`CDP respondeu na porta ${profile.port}, mas o processo não bate com ${profile.id}`, 409);
    }

    return;
  }

  await spawnBrowser(profile);
  await waitForCdp(profile.port);
}
