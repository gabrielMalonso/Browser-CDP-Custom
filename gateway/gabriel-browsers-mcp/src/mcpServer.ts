import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type CompatibilityCallToolResult,
  type Tool,
} from "@modelcontextprotocol/sdk/types.js";
import type { GatewayServices } from "./httpServer.js";
import type { LeaseMode } from "./leaseManager.js";
import { getProfile, type ProfileId } from "./profileRegistry.js";
import { aliasTools, splitUnifiedArguments, unifiedTools } from "./toolSchemas.js";
import { gatewayVersion } from "./version.js";

export type McpMode =
  | { kind: "alias"; profileId: ProfileId }
  | { kind: "unified" };

const controlToolNames = new Set([
  "browser_profile_status",
  "browser_targets",
  "browser_session",
  "browser_target_open",
  "browser_target_close",
  "browser_target_activate",
  "browser_target_navigate",
]);

export function createMcpServer(mode: McpMode, services: GatewayServices): Server {
  const server = new Server(
    { name: serverName(mode), version: gatewayVersion },
    {
      capabilities: { tools: {} },
      instructions:
        mode.kind === "unified"
          ? "Use profile para escolher o navegador. Workers Playwright são criados somente quando uma ferramenta visual é chamada."
          : `Alias compatível para o perfil ${getProfile(mode.profileId).name}.`,
    },
  );

  server.setRequestHandler(ListToolsRequestSchema, () => ({
    tools: [
      ...(mode.kind === "unified" ? unifiedTools() : aliasTools()),
      ...controlTools(mode),
    ],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request): Promise<CompatibilityCallToolResult> => {
    if (controlToolNames.has(request.params.name)) {
      return handleControlTool(mode, request.params.name, request.params.arguments, services);
    }

    if (mode.kind === "unified") {
      const { profileId, workerArguments, sessionId } = splitUnifiedArguments(request.params.arguments);
      return callWorkerWithLease(
        profileId,
        request.params.name,
        workerArguments,
        sessionId,
        services,
      );
    }

    return callWorkerWithLease(
      mode.profileId,
      request.params.name,
      request.params.arguments,
      undefined,
      services,
    );
  });

  return server;
}

async function callWorkerWithLease(
  profileId: ProfileId,
  name: string,
  args: Record<string, unknown> | undefined,
  sessionId: string | undefined,
  services: GatewayServices,
): Promise<CompatibilityCallToolResult> {
  const requiredMode = toolAccessMode(name, args);
  if (requiredMode === "write" && services.supervisor.isAutomationPaused(profileId)) {
    throw Object.assign(new Error(`A automação de ${profileId} está pausada.`), {
      statusCode: 409,
      code: "automation_paused",
    });
  }

  if (sessionId) {
    services.leases.assertAccess(sessionId, profileId, requiredMode);
    services.leases.renew(sessionId);
    return callWorkerWithReadRetry(profileId, name, args, requiredMode, services);
  }

  const lease = services.leases.acquire(profileId, requiredMode, `mcp:${name}`, 30_000);
  try {
    return await callWorkerWithReadRetry(profileId, name, args, requiredMode, services);
  } finally {
    services.leases.release(lease.id);
  }
}

async function callWorkerWithReadRetry(
  profileId: ProfileId,
  name: string,
  args: Record<string, unknown> | undefined,
  mode: LeaseMode,
  services: GatewayServices,
): Promise<CompatibilityCallToolResult> {
  if (name === "browser_tabs" && args?.action === "close") {
    throw Object.assign(
      new Error("Fechamento por índice foi desabilitado. Use browser_target_close com target_id."),
      { statusCode: 409, code: "unsafe_tab_close" },
    );
  }
  let existingTargetIds: Set<string> | undefined;
  if (name === "browser_tabs" && args?.action === "new") {
    await services.supervisor.ensureRunning(profileId);
    existingTargetIds = new Set((await services.supervisor.targets(profileId)).map((target) => target.id));
  }
  try {
    const result = await services.workers.callTool(profileId, name, args);
    if (existingTargetIds) {
      const created = (await services.supervisor.targets(profileId)).filter((target) => !existingTargetIds.has(target.id));
      const requestedUrl = typeof args?.url === "string" ? args.url : undefined;
      const owned = requestedUrl ? created.filter((target) => target.url === requestedUrl) : created;
      if (owned.length === 1) {
        services.supervisor.registerOwnedTarget(profileId, owned[0].id, "mcp:browser_tabs:new");
      }
    }
    return result;
  } catch (error) {
    if (mode !== "read" || errorCode(error) !== "worker_tool_timeout") throw error;
    return services.workers.callTool(profileId, name, args);
  }
}

async function handleControlTool(
  mode: McpMode,
  name: string,
  args: Record<string, unknown> | undefined,
  services: GatewayServices,
): Promise<CompatibilityCallToolResult> {
  const profileId = profileForMode(mode, args?.profile);

  if (name === "browser_profile_status") {
    return textResult({
      profile: getProfile(profileId),
      browser: await services.supervisor.status(profileId),
      worker: services.workers.listStatuses().find((status) => status.profileId === profileId),
      leases: services.leases.list(profileId),
    });
  }
  if (name === "browser_targets") {
    return textResult({ targets: await services.supervisor.targets(profileId) });
  }
  if (name === "browser_session") {
    const action = args?.action;
    if (action === "acquire") {
      const leaseMode = args?.mode === "read" ? "read" : "write";
      if (leaseMode === "write" && services.supervisor.isAutomationPaused(profileId)) {
        throw Object.assign(new Error(`A automação de ${profileId} está pausada.`), {
          statusCode: 409,
          code: "automation_paused",
        });
      }
      return textResult({
        lease: services.leases.acquire(
          profileId,
          leaseMode,
          typeof args?.owner === "string" ? args.owner : "mcp-session",
          typeof args?.ttl_ms === "number" ? args.ttl_ms : undefined,
        ),
      });
    }
    const sessionId = requiredString(args?.session_id, "session_id");
    if (action === "renew") {
      services.leases.assertAccess(sessionId, profileId, "read");
      return textResult({
        lease: services.leases.renew(sessionId, typeof args?.ttl_ms === "number" ? args.ttl_ms : undefined),
      });
    }
    if (action === "release") {
      services.leases.assertAccess(sessionId, profileId, "read");
      return textResult({ released: services.leases.release(sessionId) });
    }
    throw new Error("action deve ser acquire, renew ou release.");
  }
  if (name === "browser_target_open") {
    const sessionId = typeof args?.session_id === "string" ? args.session_id : undefined;
    const targetUrl = requiredUrl(args?.url);
    return withControlLease(profileId, "write", sessionId, services, async () =>
      textResult({
        target: await services.supervisor.createTarget(
          profileId,
          targetUrl,
          typeof args?.owner === "string" ? args.owner : "mcp-target",
        ),
      }),
    );
  }
  if (name === "browser_target_close") {
    const sessionId = typeof args?.session_id === "string" ? args.session_id : undefined;
    const targetId = requiredString(args?.target_id, "target_id");
    return withControlLease(profileId, "write", sessionId, services, async () =>
      textResult({ closed: await services.supervisor.closeOwnedTarget(profileId, targetId) }),
    );
  }
  if (name === "browser_target_activate") {
    const sessionId = typeof args?.session_id === "string" ? args.session_id : undefined;
    const targetId = requiredString(args?.target_id, "target_id");
    return withControlLease(profileId, "write", sessionId, services, async () =>
      textResult({ activated: await services.supervisor.activateTarget(profileId, targetId) }),
    );
  }
  if (name === "browser_target_navigate") {
    const sessionId = typeof args?.session_id === "string" ? args.session_id : undefined;
    const targetId = requiredString(args?.target_id, "target_id");
    const targetUrl = requiredUrl(args?.url);
    return withControlLease(profileId, "write", sessionId, services, async () => {
      await services.supervisor.navigateTarget(profileId, targetId, targetUrl);
      return textResult({ navigated: true, target_id: targetId, url: targetUrl });
    });
  }

  throw new Error(`Ferramenta de controle desconhecida: ${name}`);
}

async function withControlLease<T>(
  profileId: ProfileId,
  requiredMode: LeaseMode,
  sessionId: string | undefined,
  services: GatewayServices,
  operation: () => Promise<T>,
): Promise<T> {
  if (sessionId) {
    services.leases.assertAccess(sessionId, profileId, requiredMode);
    services.leases.renew(sessionId);
    return operation();
  }
  const lease = services.leases.acquire(profileId, requiredMode, "mcp-control", 30_000);
  try {
    return await operation();
  } finally {
    services.leases.release(lease.id);
  }
}

function controlTools(mode: McpMode): Tool[] {
  const profileProperties = mode.kind === "unified" ? { profile: profileProperty() } : {};
  const profileRequired = mode.kind === "unified" ? ["profile"] : [];
  return [
    controlTool("browser_profile_status", "Consulta navegador, worker e leases sem criar worker Playwright.", profileProperties, profileRequired),
    controlTool("browser_targets", "Lista targets CDP por ID sem criar worker Playwright.", profileProperties, profileRequired),
    controlTool(
      "browser_session",
      "Adquire, renova ou libera uma lease para coordenar várias chamadas no mesmo perfil.",
      {
        ...profileProperties,
        action: { type: "string", enum: ["acquire", "renew", "release"] },
        mode: { type: "string", enum: ["read", "write"] },
        owner: { type: "string" },
        session_id: { type: "string" },
        ttl_ms: { type: "number", minimum: 5000, maximum: 300000 },
      },
      [...profileRequired, "action"],
    ),
    controlTool(
      "browser_target_open",
      "Abre uma aba registrada como pertencente à automação.",
      {
        ...profileProperties,
        url: { type: "string" },
        owner: { type: "string" },
        session_id: { type: "string" },
      },
      [...profileRequired, "url"],
    ),
    controlTool(
      "browser_target_close",
      "Fecha apenas uma aba criada e registrada pela automação.",
      {
        ...profileProperties,
        target_id: { type: "string" },
        session_id: { type: "string" },
      },
      [...profileRequired, "target_id"],
    ),
    controlTool(
      "browser_target_activate",
      "Ativa uma aba pelo target_id, sem traduzir índices entre camadas.",
      {
        ...profileProperties,
        target_id: { type: "string" },
        session_id: { type: "string" },
      },
      [...profileRequired, "target_id"],
    ),
    controlTool(
      "browser_target_navigate",
      "Navega uma aba específica pelo target_id via CDP bruto.",
      {
        ...profileProperties,
        target_id: { type: "string" },
        url: { type: "string" },
        session_id: { type: "string" },
      },
      [...profileRequired, "target_id", "url"],
    ),
  ];
}

function controlTool(
  name: string,
  description: string,
  properties: Record<string, unknown>,
  required: string[],
): Tool {
  return {
    name,
    description,
    inputSchema: { type: "object", properties, required },
  } as Tool;
}

function profileProperty(): Record<string, unknown> {
  return {
    type: "string",
    enum: ["pessoal", "central-es", "central-rj", "financeiro-centralsp"],
  };
}

function profileForMode(mode: McpMode, value: unknown): ProfileId {
  if (mode.kind === "alias") return mode.profileId;
  if (value === "pessoal" || value === "central-es" || value === "central-rj" || value === "financeiro-centralsp") {
    return value;
  }
  throw new Error("profile obrigatório para a ferramenta de controle.");
}

function toolAccessMode(name: string, args: Record<string, unknown> | undefined): LeaseMode {
  if (name === "browser_tabs") return !args?.action || args.action === "list" ? "read" : "write";
  if (
    name === "browser_snapshot" ||
    name === "browser_take_screenshot" ||
    name === "browser_console_messages" ||
    name === "browser_network_requests" ||
    name === "browser_page_errors"
  ) {
    return "read";
  }
  return "write";
}

function textResult(value: unknown): CompatibilityCallToolResult {
  return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }] };
}

function requiredString(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${name} obrigatório.`);
  return value;
}

function requiredUrl(value: unknown): string {
  const url = requiredString(value, "url");
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw Object.assign(new Error("URL inválida."), { statusCode: 400, code: "invalid_url" });
  }
  if (!["http:", "https:", "about:"].includes(parsed.protocol)) {
    throw Object.assign(new Error("Protocolo de URL não permitido."), { statusCode: 400, code: "invalid_url" });
  }
  return parsed.href;
}

function errorCode(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error && typeof error.code === "string"
    ? error.code
    : undefined;
}

function serverName(mode: McpMode): string {
  return mode.kind === "unified" ? "gabriel-browsers" : `gabriel-browsers-${mode.profileId}`;
}
