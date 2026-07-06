import { describe, expect, test } from "vitest";
import { defaultProfiles } from "../src/config.js";
import { ProfileRegistry } from "../src/profileRegistry.js";
import { loadToolCache, toolsForAlias, toolsForUnified } from "../src/toolCache.js";

describe("tool cache", () => {
  test("loads cached Playwright tools without starting workers", () => {
    const cache = loadToolCache();

    expect(cache.tools.length).toBeGreaterThan(10);
    expect(cache.tools.map((tool) => tool.name)).toContain("browser_snapshot");
  });

  test("does not advertise unsafe code execution by default", () => {
    expect(loadToolCache().tools.map((tool) => tool.name)).toContain("browser_run_code_unsafe");
    expect(toolsForAlias().map((tool) => tool.name)).not.toContain("browser_run_code_unsafe");
  });

  test("adds profile to unified schemas", () => {
    const registry = new ProfileRegistry(defaultProfiles());
    const snapshot = toolsForUnified(registry).find((tool) => tool.name === "browser_snapshot");

    expect(snapshot?.inputSchema?.properties).toMatchObject({
      profile: {
        type: "string",
        enum: ["pessoal", "central-es", "central-rj", "central-sp"]
      }
    });
    expect(snapshot?.inputSchema?.required).toContain("profile");
  });
});
