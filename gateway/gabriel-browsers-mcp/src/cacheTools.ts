import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outputPath = path.join(__dirname, "generated/playwright-tools.json");
const version = "0.0.77";

const transport = new StdioClientTransport({
  command: process.env.PLAYWRIGHT_MCP_COMMAND ?? "playwright-mcp",
  args: [
    "--cdp-endpoint",
    process.env.PLAYWRIGHT_MCP_SCHEMA_CDP_ENDPOINT ?? "http://127.0.0.1:65535",
    "--cdp-timeout",
    "1000",
    "--output-mode",
    "stdout"
  ],
  env: process.env as Record<string, string>,
  stderr: "pipe"
});

let stderr = "";
transport.stderr?.on("data", (chunk) => {
  stderr += String(chunk);
});

const client = new Client({
  name: "gabriel-browsers-schema-cache",
  version: "0.1.0"
});

try {
  await client.connect(transport, { timeout: 15_000 });
  const result = await client.listTools(undefined, { timeout: 15_000 });
  const payload = {
    generatedAt: new Date().toISOString(),
    playwrightMcpVersion: version,
    tools: result.tools
  };

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(payload, null, 2)}\n`);
  console.log(`cache de tools salvo em ${outputPath} (${result.tools.length} tools)`);
} catch (error) {
  console.error(error);
  console.error(stderr);
  process.exitCode = 1;
} finally {
  await client.close().catch(() => undefined);
}
