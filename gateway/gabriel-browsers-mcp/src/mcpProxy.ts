import { randomUUID } from "node:crypto";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import {
  CallToolRequestSchema,
  ErrorCode,
  ListToolsRequestSchema,
  McpError,
  isInitializeRequest
} from "@modelcontextprotocol/sdk/types.js";
import type { Request, Response } from "express";
import type { ProfileConfig } from "./config.js";
import type { ProfileRegistry } from "./profileRegistry.js";
import { toolsForAlias, toolsForUnified } from "./toolCache.js";
import type { WorkerManager } from "./workerManager.js";

type Mode =
  | {
      kind: "unified";
    }
  | {
      kind: "alias";
      profile: ProfileConfig;
    };

const transports = new Map<string, StreamableHTTPServerTransport>();

export async function handleMcpRequest(input: {
  req: Request;
  res: Response;
  mode: Mode;
  registry: ProfileRegistry;
  workers: WorkerManager;
}) {
  const sessionId = input.req.headers["mcp-session-id"];
  let transport: StreamableHTTPServerTransport;

  if (typeof sessionId === "string" && transports.has(sessionId)) {
    transport = transports.get(sessionId)!;
    await transport.handleRequest(input.req, input.res, input.req.body);
    return;
  }

  if (sessionId || !isInitializeRequest(input.req.body)) {
    input.res.status(400).json({
      jsonrpc: "2.0",
      error: {
        code: -32000,
        message: "Bad Request: inicialização MCP ausente ou sessão inválida"
      },
      id: null
    });
    return;
  }

  transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
    onsessioninitialized: (newSessionId) => {
      transports.set(newSessionId, transport);
    }
  });
  transport.onclose = () => {
    if (transport.sessionId) {
      transports.delete(transport.sessionId);
    }
  };

  const server = createProxyServer(input.mode, input.registry, input.workers);
  await server.connect(transport);
  await transport.handleRequest(input.req, input.res, input.req.body);
}

export function createProxyServer(mode: Mode, registry: ProfileRegistry, workers: WorkerManager) {
  const server = new Server(
    {
      name: mode.kind === "unified" ? "gabriel-browsers" : `gabriel-browsers-${mode.profile.id}`,
      version: "0.1.0"
    },
    {
      capabilities: {
        tools: {}
      },
      instructions:
        mode.kind === "unified"
          ? "Use o argumento profile para escolher o perfil CDP Linux."
          : `Alias compatível preso ao perfil ${mode.profile.id}.`
    }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: mode.kind === "unified" ? toolsForUnified(registry) : toolsForAlias()
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const toolName = request.params.name;
    const rawArgs = isRecord(request.params.arguments) ? { ...request.params.arguments } : {};
    const knownTools = new Set(toolsForAlias().map((tool) => tool.name));
    if (!knownTools.has(toolName)) {
      throw new McpError(ErrorCode.MethodNotFound, `tool desconhecida: ${toolName}`);
    }

    let profile: ProfileConfig;
    if (mode.kind === "alias") {
      profile = mode.profile;
    } else {
      const profileId = rawArgs.profile;
      if (typeof profileId !== "string") {
        throw new McpError(ErrorCode.InvalidParams, "argumento profile é obrigatório");
      }
      delete rawArgs.profile;
      profile = registry.get(profileId);
    }

    return workers.callTool(profile, toolName, rawArgs);
  });

  return server;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
