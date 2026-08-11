import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { lstat, readlink, stat, unlink } from "node:fs/promises";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import {
  type BrowserProfile,
  cdpEndpoint,
  expandHome,
  profileJsonVersionUrl,
} from "./profileRegistry.js";

export type BrowserState = "stopped" | "starting" | "ready" | "degraded" | "blocked" | "stopping";

export type BrowserStatus = {
  state: BrowserState;
  cdpAlive: boolean;
  processIds: number[];
  listenerProcessIds: number[];
  detail?: string;
};

export type CDPTarget = {
  id: string;
  type: string;
  title: string;
  url: string;
  webSocketDebuggerUrl?: string;
};

type ProcessSnapshot = {
  pid: number;
  command: string;
};

const lockNames = ["SingletonLock", "SingletonSocket", "SingletonCookie"];

export async function isCdpAlive(profile: BrowserProfile, timeoutMs = 800): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(profileJsonVersionUrl(profile), { signal: controller.signal });
    if (!response.ok) return false;
    const body = await response.text();
    return body.includes("webSocketDebuggerUrl");
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

export async function inspectBrowser(profile: BrowserProfile): Promise<BrowserStatus> {
  const [cdpAlive, processes, listenerProcessIds] = await Promise.all([
    isCdpAlive(profile),
    processSnapshots(),
    listeningProcessIds(profile.port),
  ]);
  const processIds = matchingBrowserProcessIds(processes, profile);

  if (cdpAlive) {
    return { state: "ready", cdpAlive, processIds, listenerProcessIds };
  }
  if (processIds.length > 0) {
    return {
      state: "degraded",
      cdpAlive,
      processIds,
      listenerProcessIds,
      detail: "O processo do perfil está vivo, mas o endpoint CDP não respondeu.",
    };
  }
  if (listenerProcessIds.length > 0) {
    return {
      state: "blocked",
      cdpAlive,
      processIds,
      listenerProcessIds,
      detail: `A porta ${profile.port} está ocupada por outro processo.`,
    };
  }
  return { state: "stopped", cdpAlive, processIds, listenerProcessIds };
}

export async function ensureBrowserRunning(profile: BrowserProfile, launchBrowsers: boolean): Promise<void> {
  const initial = await inspectBrowser(profile);
  if (initial.state === "ready") return;
  if (!launchBrowsers) {
    throw supervisorError(`CDP ${profile.id} não está respondendo em 127.0.0.1:${profile.port}.`, 503, "browser_stopped");
  }
  if (initial.state !== "stopped") throw statusError(profile, initial);

  await removeVerifiedStaleLocks(profile);
  const beforeLaunch = await inspectBrowser(profile);
  if (beforeLaunch.state !== "stopped") throw statusError(profile, beforeLaunch);

  await launchBrowser(profile);
  for (let attempt = 0; attempt < 10; attempt += 1) {
    if (await isCdpAlive(profile, 1200)) return;
    await delay(1000);
  }

  const finalStatus = await inspectBrowser(profile);
  throw supervisorError(
    `${profile.name} iniciou, mas o CDP não ficou pronto: ${finalStatus.detail ?? finalStatus.state}.`,
    503,
    "browser_start_failed",
  );
}

export async function stopBrowser(profile: BrowserProfile, force = false): Promise<boolean> {
  const status = await inspectBrowser(profile);
  if (status.state === "stopped") return false;
  if (status.state === "blocked") throw statusError(profile, status);
  if (status.processIds.length === 0) {
    throw supervisorError(
      `O CDP ${profile.id} responde, mas o processo correspondente ao profile não pôde ser identificado.`,
      409,
      "browser_identity_unknown",
    );
  }

  for (const pid of status.processIds) safeKill(pid, "SIGTERM");
  for (let attempt = 0; attempt < 10; attempt += 1) {
    if (!(await isCdpAlive(profile, 500))) return true;
    await delay(500);
  }

  if (force) {
    for (const pid of status.processIds) safeKill(pid, "SIGKILL");
    for (let attempt = 0; attempt < 6; attempt += 1) {
      if (!(await isCdpAlive(profile, 500))) return true;
      await delay(500);
    }
  }

  throw supervisorError(`O navegador ${profile.id} não encerrou.`, 409, "browser_stop_failed");
}

export async function listTargets(profile: BrowserProfile, timeoutMs = 1500): Promise<CDPTarget[]> {
  const response = await fetchWithTimeout(`${cdpEndpoint(profile)}/json/list`, { method: "GET" }, timeoutMs);
  if (!response.ok) throw supervisorError(`Falha ao listar targets de ${profile.id}.`, 502, "target_list_failed");
  const payload = (await response.json()) as Array<Record<string, unknown>>;
  return payload
    .filter((item) => item.type === "page")
    .map((item) => ({
      id: String(item.id ?? ""),
      type: String(item.type ?? ""),
      title: String(item.title ?? ""),
      url: String(item.url ?? ""),
      webSocketDebuggerUrl:
        typeof item.webSocketDebuggerUrl === "string" ? item.webSocketDebuggerUrl : undefined,
    }))
    .filter((target) => target.id.length > 0);
}

export async function openTarget(profile: BrowserProfile, url: string): Promise<CDPTarget> {
  await ensureBrowserRunning(profile, true);
  const endpoint = `${cdpEndpoint(profile)}/json/new?${encodeURIComponent(url)}`;
  const response = await fetchWithTimeout(endpoint, { method: "PUT" }, 4000);
  if (!response.ok) throw supervisorError(`Falha ao abrir target em ${profile.id}.`, 502, "target_open_failed");
  const item = (await response.json()) as Record<string, unknown>;
  return {
    id: String(item.id ?? ""),
    type: String(item.type ?? "page"),
    title: String(item.title ?? ""),
    url: String(item.url ?? url),
    webSocketDebuggerUrl:
      typeof item.webSocketDebuggerUrl === "string" ? item.webSocketDebuggerUrl : undefined,
  };
}

export async function closeTarget(profile: BrowserProfile, targetId: string): Promise<boolean> {
  const response = await fetchWithTimeout(
    `${cdpEndpoint(profile)}/json/close/${encodeURIComponent(targetId)}`,
    { method: "GET" },
    2000,
  );
  if (!response.ok) throw supervisorError(`Falha ao fechar target ${targetId}.`, 502, "target_close_failed");
  return true;
}

export async function activateTarget(profile: BrowserProfile, targetId: string): Promise<boolean> {
  const target = (await listTargets(profile)).find((candidate) => candidate.id === targetId);
  if (!target) throw supervisorError(`Target ${targetId} não encontrado em ${profile.id}.`, 404, "target_not_found");
  const response = await fetchWithTimeout(
    `${cdpEndpoint(profile)}/json/activate/${encodeURIComponent(targetId)}`,
    { method: "GET" },
    2000,
  );
  if (!response.ok) throw supervisorError(`Falha ao ativar target ${targetId}.`, 502, "target_activate_failed");
  return true;
}

export async function navigateTarget(profile: BrowserProfile, targetId: string, url: string): Promise<void> {
  const target = (await listTargets(profile)).find((candidate) => candidate.id === targetId);
  if (!target?.webSocketDebuggerUrl) {
    throw supervisorError(`Target ${targetId} não encontrado em ${profile.id}.`, 404, "target_not_found");
  }
  await sendTargetCommand(target.webSocketDebuggerUrl, "Page.navigate", { url }, 5000);
}

export function parseProcessSnapshots(output: string): ProcessSnapshot[] {
  return output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .flatMap((line) => {
      const match = line.match(/^(\d+)\s+(.+)$/);
      return match ? [{ pid: Number(match[1]), command: match[2] }] : [];
    });
}

export function matchingBrowserProcessIds(processes: ProcessSnapshot[], profile: BrowserProfile): number[] {
  const root = expandHome(profile.profileRoot);
  const rootFlag = `--user-data-dir=${root}`;
  const portFlag = `--remote-debugging-port=${profile.port}`;
  return processes
    .filter((process) => process.command.includes(rootFlag) && process.command.includes(portFlag))
    .map((process) => process.pid);
}

export async function removeVerifiedStaleLocks(profile: BrowserProfile): Promise<void> {
  const root = expandHome(profile.profileRoot);
  const profileDirectory = path.join(root, profile.profileDirectory);
  const lockPaths = [...new Set(lockNames.flatMap((name) => [path.join(root, name), path.join(profileDirectory, name)]))];
  const staleLocks: string[] = [];

  for (const lockPath of lockPaths) {
    let metadata;
    try {
      metadata = await lstat(lockPath);
    } catch (error) {
      if (isMissing(error)) continue;
      throw error;
    }
    if (!metadata.isSymbolicLink()) {
      throw supervisorError(`Lock em formato inesperado: ${lockPath}`, 409, "profile_lock_ambiguous");
    }

    const target = await readlink(lockPath);
    if (path.basename(lockPath) === "SingletonLock") {
      const match = target.match(/-(\d+)$/);
      if (!match) throw supervisorError(`SingletonLock inválido: ${lockPath}`, 409, "profile_lock_ambiguous");
      if (isProcessAlive(Number(match[1]))) {
        throw supervisorError(`SingletonLock aponta para o PID ativo ${match[1]}.`, 409, "profile_in_use");
      }
    }
    if (path.basename(lockPath) === "SingletonSocket") {
      try {
        const socket = await stat(target);
        if (socket.isSocket()) {
          throw supervisorError(`SingletonSocket ainda está ativo: ${target}`, 409, "profile_in_use");
        }
        throw supervisorError(`SingletonSocket aponta para um caminho existente: ${target}`, 409, "profile_lock_ambiguous");
      } catch (error) {
        if (!isMissing(error)) throw error;
      }
    }
    staleLocks.push(lockPath);
  }

  const status = await inspectBrowser(profile);
  if (status.state !== "stopped") throw statusError(profile, status);
  await Promise.all(staleLocks.map((lockPath) => unlink(lockPath)));
}

async function launchBrowser(profile: BrowserProfile): Promise<void> {
  const args = [
    `--user-data-dir=${expandHome(profile.profileRoot)}`,
    `--profile-directory=${profile.profileDirectory}`,
    `--remote-debugging-port=${profile.port}`,
    "--remote-allow-origins=*",
    "--no-first-run",
    "--disable-features=DevToolsDebuggingRestrictions",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
  ];

  if (profile.platform === "darwin") {
    if (!profile.browserAppName) throw new Error(`browserAppName ausente para ${profile.id}.`);
    const child = spawn("/usr/bin/open", ["-na", profile.browserAppName, "--args", ...args], {
      stdio: "ignore",
      detached: true,
    });
    child.unref();
    return;
  }

  const executable = await firstExecutable(profile.browserExecutableCandidates ?? []);
  if (!executable) {
    throw supervisorError(`Nenhum Chrome/Chromium disponível para ${profile.id}.`, 503, "browser_missing");
  }
  const env = linuxBrowserEnvironment();
  if (!env.DISPLAY && !env.WAYLAND_DISPLAY) {
    throw supervisorError("Sessão gráfica Linux indisponível para abrir o navegador.", 503, "graphical_session_missing");
  }
  args.push("--password-store=basic");
  const child = spawn(executable, args, { stdio: "ignore", detached: true, env });
  child.unref();
}

export function linuxBrowserEnvironment(
  environment: NodeJS.ProcessEnv = process.env,
  uid = typeof process.getuid === "function" ? process.getuid() : undefined,
  pathExists: (candidate: string) => boolean = existsSync,
): NodeJS.ProcessEnv {
  const resolved = { ...environment };
  if (!resolved.XDG_RUNTIME_DIR && uid !== undefined) resolved.XDG_RUNTIME_DIR = `/run/user/${uid}`;
  if (!resolved.DBUS_SESSION_BUS_ADDRESS && resolved.XDG_RUNTIME_DIR && pathExists(`${resolved.XDG_RUNTIME_DIR}/bus`)) {
    resolved.DBUS_SESSION_BUS_ADDRESS = `unix:path=${resolved.XDG_RUNTIME_DIR}/bus`;
  }
  if (!resolved.DISPLAY && !resolved.WAYLAND_DISPLAY && pathExists("/tmp/.X11-unix/X0")) resolved.DISPLAY = ":0";
  const gdmAuthority = resolved.XDG_RUNTIME_DIR ? `${resolved.XDG_RUNTIME_DIR}/gdm/Xauthority` : undefined;
  if (!resolved.XAUTHORITY && gdmAuthority && pathExists(gdmAuthority)) resolved.XAUTHORITY = gdmAuthority;
  return resolved;
}

async function processSnapshots(): Promise<ProcessSnapshot[]> {
  try {
    return parseProcessSnapshots(await runFile("/bin/ps", ["-axo", "pid=,command="]));
  } catch {
    return [];
  }
}

async function listeningProcessIds(port: number): Promise<number[]> {
  const executable = process.platform === "darwin" ? "/usr/sbin/lsof" : await firstExecutable(["lsof"]);
  if (!executable) return [];
  try {
    const output = await runFile(executable, ["-nP", `-tiTCP:${port}`, "-sTCP:LISTEN"]);
    return [...new Set(output.split(/\s+/).filter(Boolean).map(Number).filter(Number.isInteger))];
  } catch (error) {
    if (exitCode(error) === 1) return [];
    return [];
  }
}

async function firstExecutable(candidates: string[]): Promise<string | undefined> {
  for (const candidate of candidates) {
    if (candidate.startsWith("/")) return candidate;
    try {
      const resolved = (await runFile("/usr/bin/which", [candidate])).trim();
      if (resolved) return resolved;
    } catch {
      continue;
    }
  }
  return undefined;
}

function runFile(executable: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(executable, args, { encoding: "utf8", maxBuffer: 4 * 1024 * 1024 }, (error, stdout) => {
      if (error) reject(error);
      else resolve(stdout);
    });
  });
}

async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function sendTargetCommand(
  webSocketUrl: string,
  method: string,
  params: Record<string, unknown>,
  timeoutMs: number,
): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const socket = new WebSocket(webSocketUrl);
    const timer = setTimeout(() => {
      socket.close();
      reject(supervisorError(`${method} excedeu ${timeoutMs} ms.`, 504, "target_command_timeout"));
    }, timeoutMs);
    const finish = (error?: Error) => {
      clearTimeout(timer);
      socket.close();
      if (error) reject(error);
      else resolve();
    };
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ id: 1, method, params }));
    });
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data)) as { id?: number; error?: { message?: string } };
      if (message.id !== 1) return;
      if (message.error) {
        finish(supervisorError(message.error.message ?? `${method} falhou.`, 502, "target_command_failed"));
      } else {
        finish();
      }
    });
    socket.addEventListener("error", () => {
      finish(supervisorError(`WebSocket do target falhou durante ${method}.`, 502, "target_websocket_failed"));
    });
  });
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function safeKill(pid: number, signal: NodeJS.Signals): void {
  try {
    process.kill(pid, signal);
  } catch {
    return;
  }
}

function isMissing(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT";
}

function exitCode(error: unknown): number | undefined {
  return typeof error === "object" && error !== null && "code" in error && typeof error.code === "number"
    ? error.code
    : undefined;
}

function statusError(profile: BrowserProfile, status: BrowserStatus): Error {
  return supervisorError(
    `${profile.name} está ${status.state}: ${status.detail ?? "estado incompatível com a operação"}`,
    409,
    `browser_${status.state}`,
  );
}

function supervisorError(message: string, statusCode: number, code: string): Error {
  return Object.assign(new Error(message), { statusCode, code });
}
