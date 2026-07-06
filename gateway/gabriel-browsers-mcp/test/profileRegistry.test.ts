import { describe, expect, test } from "vitest";
import { defaultProfiles } from "../src/config.js";
import { ProfileRegistry } from "../src/profileRegistry.js";

describe("ProfileRegistry", () => {
  test("maps Linux profile ids to compatible MCP aliases", () => {
    const registry = new ProfileRegistry(defaultProfiles());

    expect(registry.profileForPathSegment("pessoal").id).toBe("pessoal");
    expect(registry.profileForPathSegment("central-es").id).toBe("central-es");
    expect(registry.profileForPathSegment("central-rj").id).toBe("central-rj");
    expect(registry.profileForPathSegment("financeiro-centralsp").id).toBe("central-sp");
  });

  test("keeps the expected CDP ports", () => {
    const registry = new ProfileRegistry(defaultProfiles());

    expect(registry.get("pessoal").port).toBe(9224);
    expect(registry.get("central-es").port).toBe(9222);
    expect(registry.get("central-rj").port).toBe(9223);
    expect(registry.get("central-sp").port).toBe(9226);
  });
});
