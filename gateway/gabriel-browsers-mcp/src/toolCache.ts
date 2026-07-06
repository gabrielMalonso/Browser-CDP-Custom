import toolsPayload from "./generated/playwright-tools.json" with { type: "json" };
import type { ProfileRegistry } from "./profileRegistry.js";

export type McpTool = {
  name: string;
  title?: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
  annotations?: Record<string, unknown>;
  _meta?: Record<string, unknown>;
};

export type ToolCache = {
  generatedAt: string;
  playwrightMcpVersion: string;
  tools: McpTool[];
};

export function loadToolCache(): ToolCache {
  return toolsPayload as ToolCache;
}

export function toolsForAlias() {
  return advertisedTools();
}

export function toolsForUnified(registry: ProfileRegistry) {
  return advertisedTools().map((tool) => ({
    ...tool,
    inputSchema: addProfileToInputSchema(tool.inputSchema, registry.ids())
  }));
}

function advertisedTools() {
  const tools = loadToolCache().tools;
  if (process.env.GABRIEL_BROWSERS_MCP_ALLOW_UNSAFE === "1") {
    return tools;
  }

  return tools.filter((tool) => tool.name !== "browser_run_code_unsafe");
}

function addProfileToInputSchema(inputSchema: Record<string, unknown> | undefined, profileIds: string[]) {
  const schema = inputSchema ?? { type: "object" };
  const properties = isRecord(schema.properties) ? schema.properties : {};
  const required = Array.isArray(schema.required) ? schema.required.filter((item) => typeof item === "string") : [];

  return {
    ...schema,
    type: "object",
    properties: {
      profile: {
        type: "string",
        enum: profileIds,
        description: "Perfil CDP Linux que deve receber esta ação."
      },
      ...properties
    },
    required: ["profile", ...required.filter((item) => item !== "profile")]
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
