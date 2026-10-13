import type { IncomingMessage } from "node:http";

const allowedHosts = new Set(["127.0.0.1", "localhost"]);

export function isLoopbackHost(hostHeader: string | undefined, port: number): boolean {
  if (!hostHeader) return false;
  const host = port === 0 ? hostHeader.replace(/:\d+$/, "") : hostHeader.replace(new RegExp(`:${port}$`), "");
  return allowedHosts.has(host) || host === `[::1]`;
}

export function hasBearerToken(request: IncomingMessage, token: string): boolean {
  const authorization = request.headers.authorization;
  return authorization === `Bearer ${token}`;
}

export function assertLocalRequest(request: IncomingMessage, port: number): void {
  if (!isLoopbackHost(request.headers.host, port)) {
    throw Object.assign(new Error("Host não autorizado para o gateway MCP."), { statusCode: 403 });
  }
}

export function assertAuthorizedRequest(request: IncomingMessage, port: number, token: string): void {
  assertLocalRequest(request, port);
  if (!hasBearerToken(request, token)) {
    throw Object.assign(new Error("Bearer token ausente ou inválido."), { statusCode: 401 });
  }
}
