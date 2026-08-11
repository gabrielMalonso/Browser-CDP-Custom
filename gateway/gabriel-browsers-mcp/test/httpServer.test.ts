import { afterEach, describe, expect, it } from "vitest";
import { createGatewayHttpServer } from "../src/httpServer.js";
import type { GatewayConfig } from "../src/config.js";
import type { AddressInfo } from "node:net";
import type { Server } from "node:http";
import { LeaseManager } from "../src/leaseManager.js";

let server: Server | undefined;

afterEach(async () => {
  if (!server) return;
  await new Promise<void>((resolve) => server?.close(() => resolve()));
  server = undefined;
});

describe("control API", () => {
  it("reports all profiles without creating Playwright workers", async () => {
    let workerCalls = 0;
    const services = {
      workers: {
        listStatuses: () => [
          { profileId: "pessoal", pid: null, callsInFlight: 0, leaseCount: 0, idleMs: 0, closing: false, circuitOpenUntil: null },
        ],
        callTool: async () => {
          workerCalls += 1;
          throw new Error("unexpected worker call");
        },
      },
      supervisor: {
        listStatuses: async () => [
          { profileId: "pessoal", state: "ready", cdpAlive: true, processIds: [1], listenerProcessIds: [1], automationPaused: false },
          { profileId: "central-es", state: "stopped", cdpAlive: false, processIds: [], listenerProcessIds: [], automationPaused: false },
          { profileId: "central-rj", state: "stopped", cdpAlive: false, processIds: [], listenerProcessIds: [], automationPaused: false },
          { profileId: "financeiro-centralsp", state: "stopped", cdpAlive: false, processIds: [], listenerProcessIds: [], automationPaused: false },
        ],
      },
      leases: { list: () => [] },
    };
    const baseUrl = await start(services);
    const response = await fetch(`${baseUrl}/v1/profiles`, {
      headers: { Authorization: "Bearer test-token" },
    });
    const payload = (await response.json()) as { profiles: Array<Record<string, unknown>> };

    expect(response.status).toBe(200);
    expect(payload.profiles.map((profile) => profile.id)).toEqual([
      "pessoal",
      "central-es",
      "central-rj",
      "financeiro-centralsp",
    ]);
    expect(workerCalls).toBe(0);
  });

  it("keeps health lightweight and protects control endpoints", async () => {
    const services = {
      workers: { listStatuses: () => [] },
      supervisor: { listStatuses: async () => { throw new Error("health touched supervisor"); } },
      leases: { list: () => [] },
    };
    const baseUrl = await start(services);
    const healthResponse = await fetch(`${baseUrl}/health`);
    const health = (await healthResponse.json()) as { version: string; capabilities: Record<string, unknown> };
    expect(healthResponse.status).toBe(200);
    expect(health.version).toBe("0.2.1");
    expect(health.capabilities).toMatchObject({ controlApi: 1, leases: true, browserLifecycle: true });
    expect((await fetch(`${baseUrl}/v1/profiles`)).status).toBe(401);
  });

  it("reuses an existing write lease when a CLI starts a profile", async () => {
    let starts = 0;
    const leases = new LeaseManager();
    const lease = leases.acquire("central-es", "write", "central-cli", 30_000);
    const services = {
      workers: { listStatuses: () => [] },
      supervisor: {
        ensureRunning: async () => { starts += 1; },
        status: async () => ({ profileId: "central-es", state: "ready", cdpAlive: true }),
      },
      leases,
    };
    const baseUrl = await start(services);
    const response = await fetch(`${baseUrl}/v1/profiles/central-es/start`, {
      method: "POST",
      headers: {
        Authorization: "Bearer test-token",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ leaseId: lease.id }),
    });

    expect(response.status).toBe(200);
    expect(starts).toBe(1);
    expect(leases.list("central-es")).toHaveLength(1);
  });

  it("starts a profile for a read-only CLI without replacing its lease", async () => {
    let starts = 0;
    const leases = new LeaseManager();
    const lease = leases.acquire("central-rj", "read", "calendar-cli", 30_000);
    const services = {
      workers: { listStatuses: () => [] },
      supervisor: {
        ensureRunning: async () => { starts += 1; },
        status: async () => ({ profileId: "central-rj", state: "ready", cdpAlive: true }),
      },
      leases,
    };
    const baseUrl = await start(services);
    const response = await fetch(`${baseUrl}/v1/profiles/central-rj/start`, {
      method: "POST",
      headers: {
        Authorization: "Bearer test-token",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ leaseId: lease.id }),
    });

    expect(response.status).toBe(200);
    expect(starts).toBe(1);
    expect(leases.list("central-rj")).toEqual([expect.objectContaining({ id: lease.id, mode: "read" })]);
  });

  it("coordinates HTTP target creation with profile write leases", async () => {
    let targetCreations = 0;
    const leases = new LeaseManager();
    leases.acquire("pessoal", "write", "central-cli", 30_000);
    const services = {
      workers: { listStatuses: () => [] },
      supervisor: {
        createTarget: async () => {
          targetCreations += 1;
          return { id: "target-1" };
        },
      },
      leases,
    };
    const baseUrl = await start(services);
    const response = await fetch(`${baseUrl}/v1/profiles/pessoal/open-url`, {
      method: "POST",
      headers: {
        Authorization: "Bearer test-token",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ url: "https://example.com", owner: "app" }),
    });
    const payload = (await response.json()) as { code: string };

    expect(response.status).toBe(409);
    expect(payload.code).toBe("lease_conflict");
    expect(targetCreations).toBe(0);
  });
});

async function start(services: unknown): Promise<string> {
  const config: GatewayConfig = {
    host: "127.0.0.1",
    port: 0,
    token: "test-token",
    idleTimeoutMs: 60_000,
    toolTimeoutMs: 15_000,
    tokenEnvName: "GABRIEL_BROWSERS_MCP_TOKEN",
    launchBrowsers: false,
  };
  server = createGatewayHttpServer(config, services as never);
  await new Promise<void>((resolve) => server?.listen(0, "127.0.0.1", () => resolve()));
  const address = server.address() as AddressInfo;
  return `http://127.0.0.1:${address.port}`;
}
