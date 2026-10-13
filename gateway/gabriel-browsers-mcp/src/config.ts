export type GatewayConfig = {
  host: string;
  port: number;
  token: string;
  idleTimeoutMs: number;
  toolTimeoutMs: number;
  tokenEnvName: string;
  launchBrowsers: boolean;
};

export function loadConfig(env = process.env): GatewayConfig {
  const tokenEnvName = env.GABRIEL_BROWSERS_MCP_TOKEN_ENV_NAME || "GABRIEL_BROWSERS_MCP_TOKEN";
  const token = env[tokenEnvName];
  if (!token) {
    throw new Error(`${tokenEnvName} precisa estar definido para iniciar o gateway MCP.`);
  }

  return {
    host: "127.0.0.1",
    port: Number(env.GABRIEL_BROWSERS_MCP_PORT ?? 8787),
    token,
    idleTimeoutMs: Number(env.GABRIEL_BROWSERS_MCP_IDLE_MS ?? 5 * 60 * 1000),
    toolTimeoutMs: Number(env.GABRIEL_BROWSERS_MCP_TOOL_TIMEOUT_MS ?? 15_000),
    tokenEnvName,
    launchBrowsers: env.GABRIEL_BROWSERS_MCP_LAUNCH_BROWSERS !== "false",
  };
}
