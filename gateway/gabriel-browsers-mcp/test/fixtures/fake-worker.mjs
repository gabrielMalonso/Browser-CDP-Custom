import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const server = new Server(
  { name: "fake-playwright-worker", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, () => ({
  tools: [
    {
      name: "browser_tabs",
      description: "Fake tabs",
      inputSchema: { type: "object", properties: {} },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.arguments?.hang === true) {
    await new Promise(() => undefined);
  }
  if (request.params.arguments?.fail === true) {
    throw new Error("locator not found");
  }

  return {
    content: [
      {
        type: "text",
        text: JSON.stringify({ name: request.params.name, arguments: request.params.arguments ?? {} }),
      },
    ],
  };
});

await server.connect(new StdioServerTransport());
