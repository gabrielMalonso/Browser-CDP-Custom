import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bin = path.join(root, "node_modules", ".bin", "playwright-mcp");
const output = path.join(root, "src", "tool-cache.json");

const transport = new StdioClientTransport({
  command: bin,
  args: ["--cdp-endpoint", "http://127.0.0.1:9224"],
  cwd: root,
  stderr: "pipe",
});
const client = new Client({ name: "gabriel-browsers-tool-cache-generator", version: "0.1.0" });

try {
  await client.connect(transport, { timeout: 30_000 });
  const result = await client.listTools(undefined, { timeout: 30_000 });
  await writeFile(output, `${JSON.stringify(result.tools, null, 2)}\n`);
  console.log(`Wrote ${result.tools.length} tools to ${output}`);
} finally {
  await client.close().catch(() => undefined);
}
