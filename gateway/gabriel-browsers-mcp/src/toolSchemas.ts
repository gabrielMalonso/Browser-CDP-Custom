import cachedTools from "./tool-cache.json" with { type: "json" };
import { profiles, type ProfileId } from "./profileRegistry.js";
import type { Tool } from "@modelcontextprotocol/sdk/types.js";

export const profileDescription = profiles.map((profile) => profile.id).join(", ");

export function aliasTools(): Tool[] {
  return cloneTools(cachedTools as unknown as Tool[]);
}

export function unifiedTools(): Tool[] {
  return cloneTools(cachedTools as unknown as Tool[]).map((tool) => ({
    ...tool,
    description: `${tool.description ?? ""}\n\nUse o campo profile para escolher: ${profileDescription}.`.trim(),
    inputSchema: withControlInput(tool.inputSchema),
  }));
}

export function splitUnifiedArguments(args: Record<string, unknown> | undefined): {
  profileId: ProfileId;
  workerArguments: Record<string, unknown>;
  sessionId?: string;
} {
  const profile = args?.profile;
  if (!profiles.some((candidate) => candidate.id === profile)) {
    throw new Error(`Informe profile com um destes valores: ${profileDescription}.`);
  }

  const { profile: _profile, session_id: sessionId, ...workerArguments } = args ?? {};
  return {
    profileId: profile as ProfileId,
    workerArguments,
    sessionId: typeof sessionId === "string" ? sessionId : undefined,
  };
}

function cloneTools(tools: Tool[]): Tool[] {
  return tools.map((tool) => JSON.parse(JSON.stringify(tool)) as Tool);
}

function withControlInput(inputSchema: Tool["inputSchema"]): Tool["inputSchema"] {
  const properties = {
    profile: {
      type: "string",
      enum: profiles.map((profile) => profile.id),
      description: "Perfil Helium/CDP a controlar.",
    },
    session_id: {
      type: "string",
      description: "Lease de automação opcional obtida com browser_session para manter exclusividade entre várias chamadas.",
    },
    ...(inputSchema.properties ?? {}),
  };
  const required = Array.from(new Set(["profile", ...(inputSchema.required ?? [])]));

  return {
    ...inputSchema,
    type: "object",
    properties,
    required,
  };
}
