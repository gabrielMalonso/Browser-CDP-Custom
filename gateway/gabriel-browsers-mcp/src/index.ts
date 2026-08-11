#!/usr/bin/env node
import { loadConfig } from "./config.js";
import { BrowserSupervisor } from "./browserSupervisor.js";
import { createGatewayHttpServer } from "./httpServer.js";
import { LeaseManager } from "./leaseManager.js";
import { WorkerManager } from "./workerManager.js";

const config = loadConfig();
const supervisor = new BrowserSupervisor(config.launchBrowsers);
const leases = new LeaseManager();
const workers = new WorkerManager({
  idleTimeoutMs: config.idleTimeoutMs,
  toolTimeoutMs: config.toolTimeoutMs,
  launchBrowsers: config.launchBrowsers,
  ensureBrowser: (profileId) => supervisor.ensureRunning(profileId),
});
workers.startIdleCleanup();

const server = createGatewayHttpServer(config, { workers, supervisor, leases });

server.listen(config.port, config.host, () => {
  console.error(`gabriel-browsers-mcp ouvindo em http://${config.host}:${config.port}`);
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    server.close(() => {
      void workers.closeAll().finally(() => process.exit(0));
    });
  });
}
