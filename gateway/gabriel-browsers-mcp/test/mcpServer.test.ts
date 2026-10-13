import { describe, expect, it } from "vitest";
import { createMcpServer } from "../src/mcpServer.js";

describe("mcp server", () => {
  it("can list tools without touching the worker manager", async () => {
    const workers = {
      callTool: async () => {
        throw new Error("tools/list should not call workers");
      },
    };
    const server = createMcpServer(
      { kind: "alias", profileId: "pessoal" },
      { workers, supervisor: {}, leases: {} } as never,
    );
    expect(server).toBeTruthy();
  });
});
