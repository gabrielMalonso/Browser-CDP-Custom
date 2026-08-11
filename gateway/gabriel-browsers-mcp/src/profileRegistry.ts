import path from "node:path";
import manifest from "./profiles.json" with { type: "json" };

export type ProfileId = "pessoal" | "central-es" | "central-rj" | "financeiro-centralsp";
export type PlatformId = "darwin" | "linux";

type PlatformProfile = {
  profileRoot: string;
  profileDirectory: string;
  browserAppName?: string;
  browserExecutableCandidates?: string[];
};

type ProfileDefinition = {
  id: ProfileId;
  aliases: string[];
  name: string;
  port: number;
  resourceGroup: string;
  defaultUrl?: string;
  platforms: Record<PlatformId, PlatformProfile>;
};

export type BrowserProfile = Omit<ProfileDefinition, "platforms"> & PlatformProfile & {
  platform: PlatformId;
};

export const profileSchemaVersion = manifest.schemaVersion;
export const profileDefinitions = manifest.profiles as ProfileDefinition[];
export const profiles = profilesForPlatform(platformId());

const profileById = new Map(profiles.map((profile) => [profile.id, profile]));
const canonicalIdByAlias = new Map(
  profiles.flatMap((profile) => profile.aliases.map((alias) => [alias, profile.id] as const)),
);

export function profilesForPlatform(platform: PlatformId): BrowserProfile[] {
  return profileDefinitions.map((definition) => ({
    id: definition.id,
    aliases: [...definition.aliases],
    name: definition.name,
    port: definition.port,
    resourceGroup: definition.resourceGroup,
    defaultUrl: definition.defaultUrl,
    platform,
    ...definition.platforms[platform],
  }));
}

export function platformId(value = process.platform): PlatformId {
  if (value === "darwin" || value === "linux") return value;
  throw new Error(`Plataforma sem launcher CDP configurado: ${value}`);
}

export function cdpEndpoint(profile: BrowserProfile): string {
  return `http://127.0.0.1:${profile.port}`;
}

export function profileJsonVersionUrl(profile: BrowserProfile): string {
  return `${cdpEndpoint(profile)}/json/version`;
}

export function resolveProfileId(value: unknown): ProfileId | undefined {
  if (typeof value !== "string") return undefined;
  if (profileById.has(value as ProfileId)) return value as ProfileId;
  return canonicalIdByAlias.get(value);
}

export function getProfile(id: string): BrowserProfile {
  const profileId = resolveProfileId(id);
  const profile = profileId ? profileById.get(profileId) : undefined;
  if (!profile) throw new Error(`Perfil CDP desconhecido: ${id}`);
  return profile;
}

export function isProfileId(value: unknown): value is ProfileId {
  return typeof value === "string" && profileById.has(value as ProfileId);
}

export function expandHome(value: string, home = process.env.HOME ?? ""): string {
  const expanded = value === "~" ? home : value.replace(/^~\//, `${home}/`);
  const configuredRoot = process.env.CHROME_CDP_ROOT;
  const defaultRoot = path.join(home, ".chrome-cdp");
  if (!configuredRoot || !expanded.startsWith(`${defaultRoot}${path.sep}`)) return expanded;
  return path.join(configuredRoot, path.relative(defaultRoot, expanded));
}
