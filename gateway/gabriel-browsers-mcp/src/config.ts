import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export type ProfileConfig = {
  id: string;
  name: string;
  kind: string;
  badge: string;
  user_data_dir: string;
  profile_directory: string;
  browser_command: string | null;
  port: number;
  default_url: string | null;
};

export type AppConfig = {
  profiles: ProfileConfig[];
  default_profile_id: string;
};

export type GatewayConfig = {
  host: string;
  port: number;
  token: string | null;
  idleTimeoutMs: number;
  workerSweepMs: number;
  toolTimeoutMs: number;
  configPath: string;
};

export function expandHome(input: string) {
  if (input === "~") {
    return os.homedir();
  }

  if (input.startsWith("~/")) {
    return path.join(os.homedir(), input.slice(2));
  }

  return input;
}

export function defaultProfiles(): AppConfig {
  const home = os.homedir();

  return {
    default_profile_id: "central-es",
    profiles: [
      {
        id: "pessoal",
        name: "Pessoal",
        kind: "personal",
        badge: "P",
        user_data_dir: path.join(home, ".chrome-cdp/pessoal"),
        profile_directory: "Default",
        browser_command: null,
        port: 9224,
        default_url: null
      },
      {
        id: "central-es",
        name: "Central ES",
        kind: "clinic",
        badge: "ES",
        user_data_dir: path.join(home, ".chrome-cdp/central-es"),
        profile_directory: "Default",
        browser_command: null,
        port: 9222,
        default_url: "https://web.whatsapp.com/"
      },
      {
        id: "central-rj",
        name: "Central RJ",
        kind: "clinic",
        badge: "RJ",
        user_data_dir: path.join(home, ".chrome-cdp/central-rj"),
        profile_directory: "Default",
        browser_command: null,
        port: 9223,
        default_url: "https://web.whatsapp.com/"
      },
      {
        id: "central-sp",
        name: "Financeiro/CentralSP",
        kind: "clinic",
        badge: "SP",
        user_data_dir: path.join(home, ".chrome-cdp/financeiro-centralsp"),
        profile_directory: "Default",
        browser_command: null,
        port: 9226,
        default_url: "https://web.whatsapp.com/"
      }
    ]
  };
}

export function defaultConfigPath() {
  return path.join(
    process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config"),
    "browser-cdp-custom-linux/profiles.json"
  );
}

export function loadAppConfig(configPath = process.env.BROWSER_CDP_CUSTOM_CONFIG ?? defaultConfigPath()) {
  if (!fs.existsSync(configPath)) {
    return { config: defaultProfiles(), configPath };
  }

  const config = JSON.parse(fs.readFileSync(configPath, "utf8")) as AppConfig;
  config.profiles = config.profiles.map((profile) => ({
    ...profile,
    user_data_dir: expandHome(profile.user_data_dir),
    browser_command: profile.browser_command ? expandHome(profile.browser_command) : null
  }));

  return { config, configPath };
}

function readTokenFromEnvFile() {
  const envPath = path.join(os.homedir(), ".codex/gabriel-browsers-mcp.env");
  if (!fs.existsSync(envPath)) {
    return null;
  }

  for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
    const match = line.match(/^GABRIEL_BROWSERS_MCP_TOKEN=(.+)$/);
    if (match?.[1]?.trim()) {
      return match[1].trim();
    }
  }

  return null;
}

export function loadGatewayConfig(configPath?: string): GatewayConfig {
  return {
    host: process.env.GABRIEL_BROWSERS_MCP_HOST ?? "127.0.0.1",
    port: Number(process.env.GABRIEL_BROWSERS_MCP_PORT ?? 8787),
    token: process.env.GABRIEL_BROWSERS_MCP_TOKEN ?? readTokenFromEnvFile(),
    idleTimeoutMs: Number(process.env.GABRIEL_BROWSERS_MCP_IDLE_MS ?? 300_000),
    workerSweepMs: Number(process.env.GABRIEL_BROWSERS_MCP_SWEEP_MS ?? 60_000),
    toolTimeoutMs: Number(process.env.GABRIEL_BROWSERS_MCP_TOOL_TIMEOUT_MS ?? 120_000),
    configPath: configPath ?? process.env.BROWSER_CDP_CUSTOM_CONFIG ?? defaultConfigPath()
  };
}
