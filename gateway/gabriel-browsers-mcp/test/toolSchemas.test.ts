import { describe, expect, it } from "vitest";
import { aliasTools, splitUnifiedArguments, unifiedTools } from "../src/toolSchemas.js";

describe("tool schemas", () => {
  it("serves alias tools from cache without a profile argument", () => {
    const tabs = aliasTools().find((tool) => tool.name === "browser_tabs");
    expect(tabs).toBeTruthy();
    expect(tabs?.inputSchema.properties?.profile).toBeUndefined();
  });

  it("adds profile to unified tools", () => {
    const tabs = unifiedTools().find((tool) => tool.name === "browser_tabs");
    expect(tabs?.inputSchema.properties?.profile).toMatchObject({
      type: "string",
      enum: ["pessoal", "central-es", "central-rj", "financeiro-centralsp"],
    });
    expect(tabs?.inputSchema.required).toContain("profile");
  });

  it("splits profile away before forwarding to Playwright MCP", () => {
    expect(splitUnifiedArguments({ profile: "pessoal", url: "https://example.com" })).toEqual({
      profileId: "pessoal",
      workerArguments: { url: "https://example.com" },
    });
    expect(() => splitUnifiedArguments({ url: "https://example.com" })).toThrow("Informe profile");
  });
});
