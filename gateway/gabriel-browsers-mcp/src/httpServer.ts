import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { assertAuthorizedRequest, assertLocalRequest } from "./auth.js";
import type { BrowserSupervisor } from "./browserSupervisor.js";
import type { GatewayConfig } from "./config.js";
import type { LeaseManager, LeaseMode } from "./leaseManager.js";
import { createMcpServer, type McpMode } from "./mcpServer.js";
import {
  cdpEndpoint,
  getProfile,
  profileSchemaVersion,
  profiles,
  resolveProfileId,
  type ProfileId,
} from "./profileRegistry.js";
import type { WorkerManager } from "./workerManager.js";
import { gatewayCapabilities, gatewayVersion } from "./version.js";

type Route = {
  pattern: RegExp;
  mode: McpMode;
};

const routes: Route[] = [
  { pattern: /^\/mcp\/?$/, mode: { kind: "unified" } },
  ...profiles.flatMap((profile) =>
    [profile.id, ...profile.aliases].map((id) => ({
      pattern: new RegExp(`^/${escapeRegExp(id)}/mcp/?$`),
      mode: { kind: "alias" as const, profileId: profile.id },
    })),
  ),
];

export type GatewayServices = {
  workers: WorkerManager;
  supervisor: BrowserSupervisor;
  leases: LeaseManager;
};

export function createGatewayHttpServer(config: GatewayConfig, services: GatewayServices) {
  return createServer(async (request, response) => {
    try {
      const url = new URL(request.url ?? "/", `http://127.0.0.1:${config.port}`);
      assertLocalRequest(request, config.port);

      if (request.method === "GET" && url.pathname === "/health") {
        return sendJson(response, 200, {
          ok: true,
          version: gatewayVersion,
          profileSchemaVersion,
          capabilities: gatewayCapabilities,
        });
      }

      if (request.method === "GET" && url.pathname === "/ready") {
        return sendJson(response, 200, { ok: true, profiles: profiles.length });
      }

      if (url.pathname === "/workers") {
        assertAuthorizedRequest(request, config.port, config.token);
        return sendJson(response, 200, { workers: services.workers.listStatuses() });
      }

      if (request.method === "POST" && url.pathname === "/release") {
        assertAuthorizedRequest(request, config.port, config.token);
        const profileId = requiredProfileId((await readJson(request)).profile);
        return sendJson(response, 200, { released: await services.workers.release(profileId) });
      }

      if (url.pathname.startsWith("/v1/")) {
        assertAuthorizedRequest(request, config.port, config.token);
        return await handleControlRequest(request, response, url, services);
      }

      const route = routes.find((candidate) => candidate.pattern.test(url.pathname));
      if (!route) return sendJson(response, 404, { error: "Endpoint não encontrado.", code: "not_found" });

      assertAuthorizedRequest(request, config.port, config.token);
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      const mcpServer = createMcpServer(route.mode, services);
      await mcpServer.connect(transport);
      await transport.handleRequest(request, response, await maybeReadJson(request));
      return;
    } catch (error) {
      return sendJson(response, errorStatusCode(error), errorPayload(error));
    }
  });
}

async function handleControlRequest(
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  services: GatewayServices,
): Promise<void> {
  if (request.method === "GET" && url.pathname === "/v1/profiles") {
    const statuses = await services.supervisor.listStatuses();
    const workerByProfile = new Map(services.workers.listStatuses().map((status) => [status.profileId, status]));
    return sendJson(response, 200, {
      schemaVersion: profileSchemaVersion,
      profiles: profiles.map((profile) => ({
        id: profile.id,
        aliases: profile.aliases,
        name: profile.name,
        port: profile.port,
        endpoint: cdpEndpoint(profile),
        resourceGroup: profile.resourceGroup,
        defaultUrl: profile.defaultUrl,
        browser: statuses.find((status) => status.profileId === profile.id),
        worker: workerByProfile.get(profile.id),
        leases: services.leases.list(profile.id),
      })),
    });
  }

  if (request.method === "POST" && url.pathname === "/v1/leases") {
    const body = await readJson(request);
    const profileId = requiredProfileId(body.profile);
    const mode = requiredLeaseMode(body.mode);
    const owner = typeof body.owner === "string" ? body.owner : "control-api";
    const ttlMs = typeof body.ttlMs === "number" ? body.ttlMs : undefined;
    return sendJson(response, 201, { lease: services.leases.acquire(profileId, mode, owner, ttlMs) });
  }

  const leaseMatch = url.pathname.match(/^\/v1\/leases\/([^/]+)$/);
  if (leaseMatch && request.method === "PATCH") {
    const body = await readJson(request);
    const ttlMs = typeof body.ttlMs === "number" ? body.ttlMs : undefined;
    return sendJson(response, 200, { lease: services.leases.renew(decodeURIComponent(leaseMatch[1]), ttlMs) });
  }
  if (leaseMatch && request.method === "DELETE") {
    return sendJson(response, 200, { released: services.leases.release(decodeURIComponent(leaseMatch[1])) });
  }

  const profileMatch = url.pathname.match(/^\/v1\/profiles\/([^/]+)(?:\/(.*))?$/);
  if (!profileMatch) return sendJson(response, 404, { error: "Endpoint não encontrado.", code: "not_found" });
  const profileId = requiredProfileId(decodeURIComponent(profileMatch[1]));
  const action = profileMatch[2] ?? "status";

  if (request.method === "GET" && action === "status") {
    return sendJson(response, 200, await profileStatusPayload(profileId, services));
  }
  if (request.method === "POST" && action === "start") {
    const body = await readJson(request);
    const leaseId = typeof body.leaseId === "string" ? body.leaseId : undefined;
    if (leaseId) {
      services.leases.assertAccess(leaseId, profileId, "read");
      services.leases.renew(leaseId);
      await services.supervisor.ensureRunning(profileId);
    } else {
      await withHttpLease(profileId, "start", services, () => services.supervisor.ensureRunning(profileId));
    }
    return sendJson(response, 200, await profileStatusPayload(profileId, services));
  }
  if (request.method === "POST" && action === "stop") {
    if (services.leases.hasActive(profileId)) throw conflict("O perfil possui leases ativas.", "active_leases");
    const body = await readJson(request);
    const worker = services.workers.listStatuses().find((status) => status.profileId === profileId);
    if (worker?.callsInFlight || worker?.leaseCount) throw conflict("O worker possui chamada ativa.", "worker_busy");
    await services.workers.release(profileId);
    const stopped = await services.supervisor.stop(profileId, body.force === true);
    return sendJson(response, 200, { stopped, status: await services.supervisor.status(profileId) });
  }
  if (request.method === "POST" && action === "open-url") {
    const body = await readJson(request);
    const targetUrl = requiredUrl(body.url);
    const owner = typeof body.owner === "string" ? body.owner : "control-api";
    const target = await withHttpLease(profileId, owner, services, () =>
      services.supervisor.createTarget(profileId, targetUrl, owner),
    );
    return sendJson(response, 201, { target });
  }
  if (request.method === "GET" && action === "targets") {
    return sendJson(response, 200, { targets: await services.supervisor.targets(profileId) });
  }
  if (request.method === "POST" && action === "targets") {
    const body = await readJson(request);
    const owner = typeof body.owner === "string" ? body.owner : "control-api";
    const target = await withHttpLease(profileId, owner, services, () =>
      services.supervisor.createTarget(profileId, requiredUrl(body.url), owner),
    );
    return sendJson(response, 201, { target });
  }
  const targetAction = action.match(/^targets\/([^/]+)\/(activate|navigate)$/);
  if (request.method === "POST" && targetAction) {
    const targetId = decodeURIComponent(targetAction[1]);
    const body = await readJson(request);
    if (targetAction[2] === "activate") {
      const activated = await withHttpLease(profileId, "control-api", services, () =>
        services.supervisor.activateTarget(profileId, targetId),
      );
      return sendJson(response, 200, { activated });
    }
    const targetUrl = requiredUrl(body.url);
    await withHttpLease(profileId, "control-api", services, () =>
      services.supervisor.navigateTarget(profileId, targetId, targetUrl),
    );
    return sendJson(response, 200, { navigated: true, targetId, url: targetUrl });
  }
  if (request.method === "DELETE" && action.startsWith("targets/")) {
    const targetId = decodeURIComponent(action.slice("targets/".length));
    const closed = await withHttpLease(profileId, "control-api", services, () =>
      services.supervisor.closeOwnedTarget(profileId, targetId),
    );
    return sendJson(response, 200, { closed });
  }
  if (request.method === "POST" && action === "worker/release") {
    return sendJson(response, 200, { released: await services.workers.release(profileId) });
  }
  if (request.method === "POST" && action === "automation/pause") {
    services.supervisor.setAutomationPaused(profileId, true);
    return sendJson(response, 200, { automationPaused: true });
  }
  if (request.method === "POST" && action === "automation/resume") {
    services.supervisor.setAutomationPaused(profileId, false);
    return sendJson(response, 200, { automationPaused: false });
  }
  if (request.method === "GET" && action === "diagnostics") {
    let targets: unknown[] = [];
    try {
      targets = await services.supervisor.targets(profileId);
    } catch {
      targets = [];
    }
    return sendJson(response, 200, {
      ...(await profileStatusPayload(profileId, services)),
      targets,
    });
  }

  return sendJson(response, 404, { error: "Endpoint não encontrado.", code: "not_found" });
}

async function withHttpLease<T>(
  profileId: ProfileId,
  owner: string,
  services: GatewayServices,
  operation: () => Promise<T>,
): Promise<T> {
  const lease = services.leases.acquire(profileId, "write", `http:${owner}`, 30_000);
  try {
    return await operation();
  } finally {
    services.leases.release(lease.id);
  }
}

async function profileStatusPayload(profileId: ProfileId, services: GatewayServices) {
  const profile = getProfile(profileId);
  return {
    profile: {
      id: profile.id,
      aliases: profile.aliases,
      name: profile.name,
      port: profile.port,
      endpoint: cdpEndpoint(profile),
      resourceGroup: profile.resourceGroup,
      defaultUrl: profile.defaultUrl,
    },
    browser: await services.supervisor.status(profileId),
    worker: services.workers.listStatuses().find((status) => status.profileId === profileId),
    leases: services.leases.list(profileId),
  };
}

function requiredProfileId(value: unknown): ProfileId {
  const profileId = resolveProfileId(value);
  if (!profileId) throw Object.assign(new Error("profile inválido."), { statusCode: 400, code: "invalid_profile" });
  return profileId;
}

function requiredLeaseMode(value: unknown): LeaseMode {
  if (value === "read" || value === "write") return value;
  throw Object.assign(new Error("mode deve ser read ou write."), { statusCode: 400, code: "invalid_lease_mode" });
}

function requiredUrl(value: unknown): string {
  if (typeof value !== "string") {
    throw Object.assign(new Error("url obrigatória."), { statusCode: 400, code: "invalid_url" });
  }
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw Object.assign(new Error("URL inválida."), { statusCode: 400, code: "invalid_url" });
  }
  if (!["http:", "https:", "about:"].includes(parsed.protocol)) {
    throw Object.assign(new Error("Protocolo de URL não permitido."), { statusCode: 400, code: "invalid_url" });
  }
  return parsed.href;
}

function errorStatusCode(error: unknown): number {
  if (typeof error === "object" && error && "statusCode" in error) {
    return Number((error as { statusCode: number }).statusCode);
  }
  return 500;
}

function errorPayload(error: unknown): Record<string, unknown> {
  if (!(error instanceof Error)) return { error: String(error), code: "internal_error" };
  const payload: Record<string, unknown> = { error: error.message };
  if ("code" in error && typeof error.code === "string") payload.code = error.code;
  if ("lease" in error) payload.lease = error.lease;
  return payload;
}

function sendJson(response: ServerResponse, statusCode: number, body: unknown): void {
  if (response.headersSent) return;
  response.writeHead(statusCode, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(body));
}

async function maybeReadJson(request: IncomingMessage): Promise<unknown | undefined> {
  if (request.method !== "POST") return undefined;
  return readJson(request);
}

async function readJson(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw.trim()) return {};
  const parsed = JSON.parse(raw) as unknown;
  return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : {};
}

function conflict(message: string, code: string): Error {
  return Object.assign(new Error(message), { statusCode: 409, code });
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
