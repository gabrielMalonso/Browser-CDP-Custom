#!/usr/bin/env node
import { loadAppConfig, loadGatewayConfig } from "./config.js";
import { ProfileRegistry } from "./profileRegistry.js";
import { WorkerManager } from "./workerManager.js";
import { createGatewayApp } from "./server.js";

const gatewayConfig = loadGatewayConfig();
const { config, configPath } = loadAppConfig(gatewayConfig.configPath);
const registry = new ProfileRegistry(config);
const workers = new WorkerManager({
  idleTimeoutMs: gatewayConfig.idleTimeoutMs,
  sweepMs: gatewayConfig.workerSweepMs,
  toolTimeoutMs: gatewayConfig.toolTimeoutMs
});
workers.startSweeper();

const app = createGatewayApp({
  gatewayConfig,
  registry,
  workers
});

const server = app.listen(gatewayConfig.port, gatewayConfig.host, () => {
  console.log(`gabriel-browsers-mcp ouvindo em http://${gatewayConfig.host}:${gatewayConfig.port}`);
  console.log(`config de perfis: ${configPath}`);
  console.log(`perfis: ${registry.ids().join(", ")}`);
});

async function shutdown() {
  console.log("encerrando gabriel-browsers-mcp...");
  server.close();
  await workers.closeAll();
  process.exit(0);
}

process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
