import { describe, expect, it } from "vitest";
import { cdpEndpoint, getProfile, profiles, profilesForPlatform, resolveProfileId } from "../src/profileRegistry.js";

describe("profile registry", () => {
  it("keeps canonical ports and normalizes CDP endpoints to 127.0.0.1", () => {
    expect(Object.fromEntries(profiles.map((profile) => [profile.id, profile.port]))).toEqual({
      pessoal: 9224,
      "central-es": 9222,
      "central-rj": 9223,
      "financeiro-centralsp": 9226,
    });

    for (const profile of profiles) {
      expect(cdpEndpoint(profile)).toBe(`http://127.0.0.1:${profile.port}`);
      expect(cdpEndpoint(profile)).not.toContain("localhost");
    }
  });

  it("resolves aliases without exposing duplicate profiles", () => {
    expect(resolveProfileId("central-sp")).toBe("financeiro-centralsp");
    expect(resolveProfileId("sp")).toBe("financeiro-centralsp");
    expect(getProfile("central-sp").id).toBe("financeiro-centralsp");
    expect(() => getProfile("desconhecido")).toThrow("Perfil CDP desconhecido");
  });

  it("keeps platform-specific browser ownership in the canonical manifest", () => {
    const mac = profilesForPlatform("darwin");
    const linux = profilesForPlatform("linux");
    expect(mac.find((profile) => profile.id === "pessoal")?.browserAppName).toBe("Google Chrome");
    expect(mac.find((profile) => profile.id === "central-es")?.browserAppName).toBe("Helium");
    expect(linux.find((profile) => profile.id === "financeiro-centralsp")?.profileRoot).toContain(
      "financeiro-centralsp",
    );
  });
});
