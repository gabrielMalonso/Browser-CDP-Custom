#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const baseUrl = process.env.GABRIEL_BROWSERS_MCP_URL ?? "http://127.0.0.1:8787";
const token = await gatewayToken();
const [command, ...args] = process.argv.slice(2);

try {
  const result = await execute(command, args);
  process.stdout.write(typeof result === "string" ? `${result}\n` : `${JSON.stringify(result, null, 2)}\n`);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}

async function execute(name: string | undefined, values: string[]): Promise<unknown> {
  if (!name || name === "help" || name === "--help") return usage();
  if (name === "health") return request("GET", "/health", undefined, false);
  if (name === "profiles") return request("GET", "/v1/profiles");

  const profile = values[0];
  if (!profile) throw new Error(`Informe o perfil.\n${usage()}`);
  if (name === "status") return request("GET", `/v1/profiles/${encodeURIComponent(profile)}/status`);
  if (name === "start") return request("POST", `/v1/profiles/${encodeURIComponent(profile)}/start`, {});
  if (name === "stop") {
    return request("POST", `/v1/profiles/${encodeURIComponent(profile)}/stop`, {
      force: values.includes("--force"),
    });
  }
  if (name === "targets") return request("GET", `/v1/profiles/${encodeURIComponent(profile)}/targets`);
  if (name === "open-url") {
    const url = values[1];
    if (!url) throw new Error("Informe a URL.");
    return request("POST", `/v1/profiles/${encodeURIComponent(profile)}/open-url`, {
      url,
      owner: option(values, "--owner") ?? "browserctl",
    });
  }
  if (name === "worker-release") {
    return request("POST", `/v1/profiles/${encodeURIComponent(profile)}/worker/release`, {});
  }
  if (name === "pause") {
    return request("POST", `/v1/profiles/${encodeURIComponent(profile)}/automation/pause`, {});
  }
  if (name === "resume") {
    return request("POST", `/v1/profiles/${encodeURIComponent(profile)}/automation/resume`, {});
  }
  if (name === "diagnostics") {
    return request("GET", `/v1/profiles/${encodeURIComponent(profile)}/diagnostics`);
  }
  if (name === "lease-acquire") {
    return request("POST", "/v1/leases", {
      profile,
      mode: option(values, "--mode") ?? "write",
      owner: option(values, "--owner") ?? "browserctl",
      ttlMs: numericOption(values, "--ttl-ms"),
    });
  }
  if (name === "lease-renew") {
    const leaseId = values[1];
    if (!leaseId) throw new Error("Informe o ID da lease.");
    return request("PATCH", `/v1/leases/${encodeURIComponent(leaseId)}`, {
      ttlMs: numericOption(values, "--ttl-ms"),
    });
  }
  if (name === "lease-release") {
    const leaseId = values[1];
    if (!leaseId) throw new Error("Informe o ID da lease.");
    return request("DELETE", `/v1/leases/${encodeURIComponent(leaseId)}`);
  }

  throw new Error(`Comando desconhecido: ${name}\n${usage()}`);
}

async function request(method: string, pathname: string, body?: unknown, authenticated = true): Promise<unknown> {
  if (authenticated && !token) throw new Error("GABRIEL_BROWSERS_MCP_TOKEN não encontrado.");
  const response = await fetch(`${baseUrl}${pathname}`, {
    method,
    headers: {
      ...(authenticated ? { Authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const payload = (await response.json()) as Record<string, unknown>;
  if (!response.ok) throw new Error(`${payload.code ?? response.status}: ${payload.error ?? response.statusText}`);
  return payload;
}

async function gatewayToken(): Promise<string | undefined> {
  if (process.env.GABRIEL_BROWSERS_MCP_TOKEN) return process.env.GABRIEL_BROWSERS_MCP_TOKEN;
  try {
    const contents = await readFile(path.join(os.homedir(), ".codex", "gabriel-browsers-mcp.env"), "utf8");
    for (const line of contents.split(/\r?\n/)) {
      const match = line.match(/^GABRIEL_BROWSERS_MCP_TOKEN=(.+)$/);
      if (match) return match[1].trim().replace(/^['"]|['"]$/g, "");
    }
  } catch {
    return undefined;
  }
  return undefined;
}

function option(values: string[], name: string): string | undefined {
  const index = values.indexOf(name);
  return index >= 0 ? values[index + 1] : undefined;
}

function numericOption(values: string[], name: string): number | undefined {
  const value = option(values, name);
  if (value === undefined) return undefined;
  const number = Number(value);
  if (!Number.isFinite(number)) throw new Error(`${name} inválido.`);
  return number;
}

function usage(): string {
  return [
    "gabriel-browserctl health|profiles",
    "gabriel-browserctl status|start|stop|targets|diagnostics PROFILE",
    "gabriel-browserctl open-url PROFILE URL [--owner NAME]",
    "gabriel-browserctl worker-release|pause|resume PROFILE",
    "gabriel-browserctl lease-acquire PROFILE [--mode read|write] [--owner NAME] [--ttl-ms N]",
    "gabriel-browserctl lease-renew|lease-release PROFILE LEASE_ID [--ttl-ms N]",
  ].join("\n");
}
