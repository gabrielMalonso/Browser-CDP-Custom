import type { AppConfig, ProfileConfig } from "./config.js";
import { GatewayError } from "./errors.js";

export type ProfileAlias = {
  pathSegment: string;
  mcpName: string;
  profileId: string;
};

export const PROFILE_ALIASES: ProfileAlias[] = [
  {
    pathSegment: "pessoal",
    mcpName: "playwright-cdp-pessoal",
    profileId: "pessoal"
  },
  {
    pathSegment: "central-es",
    mcpName: "playwright-cdp-es",
    profileId: "central-es"
  },
  {
    pathSegment: "central-rj",
    mcpName: "playwright-cdp-rj",
    profileId: "central-rj"
  },
  {
    pathSegment: "financeiro-centralsp",
    mcpName: "playwright-cdp-financeiro-centralsp",
    profileId: "central-sp"
  }
];

export class ProfileRegistry {
  readonly profiles: ProfileConfig[];
  readonly aliases = PROFILE_ALIASES;

  constructor(config: AppConfig) {
    this.profiles = config.profiles;
  }

  ids() {
    return this.profiles.map((profile) => profile.id);
  }

  get(profileId: string) {
    const profile = this.profiles.find((candidate) => candidate.id === profileId);
    if (!profile) {
      throw new GatewayError(`perfil não encontrado: ${profileId}`, 404);
    }
    return profile;
  }

  profileForPathSegment(pathSegment: string) {
    const alias = this.aliases.find((candidate) => candidate.pathSegment === pathSegment);
    if (!alias) {
      throw new GatewayError(`alias MCP desconhecido: ${pathSegment}`, 404);
    }

    return this.get(alias.profileId);
  }

  metadata() {
    return this.profiles.map((profile) => ({
      id: profile.id,
      name: profile.name,
      port: profile.port,
      user_data_dir: profile.user_data_dir,
      profile_directory: profile.profile_directory
    }));
  }
}
