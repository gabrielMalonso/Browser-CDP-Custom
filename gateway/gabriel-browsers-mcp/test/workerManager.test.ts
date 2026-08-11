import { describe, expect, it } from "vitest";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WorkerManager } from "../src/workerManager.js";

const fixture = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "fake-worker.mjs");

describe("worker manager", () => {
  it("spawns on first call, reuses while alive, and releases safely", async () => {
    const manager = new WorkerManager({
      idleTimeoutMs: 60_000,
      launchBrowsers: false,
      command: process.execPath,
      argsForProfile: () => [fixture],
      ensureBrowser: async () => undefined,
    });

    const first = await manager.callTool("pessoal", "browser_tabs", {});
    const firstPid = manager.listStatuses().find((status) => status.profileId === "pessoal")?.pid;
    const second = await manager.callTool("pessoal", "browser_tabs", { hello: "world" });
    const secondPid = manager.listStatuses().find((status) => status.profileId === "pessoal")?.pid;

    expect(first.content).toEqual(expect.arrayContaining([expect.objectContaining({ type: "text" })]));
    expect(JSON.parse((first.content as [{ text: string }])[0].text).arguments).toEqual({ action: "list" });
    expect(second.content).toEqual(expect.arrayContaining([expect.objectContaining({ type: "text" })]));
    expect(firstPid).toEqual(secondPid);
    expect(await manager.release("pessoal")).toBe(true);
    expect(manager.listStatuses().find((status) => status.profileId === "pessoal")?.pid).toBeNull();

    await manager.closeAll();
  });

  it("cleans up idle workers after timeout", async () => {
    let now = 1_000;
    const manager = new WorkerManager({
      idleTimeoutMs: 500,
      launchBrowsers: false,
      now: () => now,
      command: process.execPath,
      argsForProfile: () => [fixture],
      ensureBrowser: async () => undefined,
    });

    await manager.callTool("central-es", "browser_tabs", {});
    now = 2_000;

    expect(await manager.cleanupIdleWorkers()).toBe(1);
    expect(manager.listStatuses().find((status) => status.profileId === "central-es")?.pid).toBeNull();

    await manager.closeAll();
  });

  it("serializes first worker creation per profile", async () => {
    let spawnCount = 0;
    let ensureCount = 0;
    const manager = new WorkerManager({
      idleTimeoutMs: 60_000,
      launchBrowsers: false,
      command: process.execPath,
      argsForProfile: () => {
        spawnCount += 1;
        return [fixture];
      },
      ensureBrowser: async () => {
        ensureCount += 1;
        await new Promise((resolve) => setTimeout(resolve, 50));
      },
    });

    await Promise.all([
      manager.callTool("pessoal", "browser_tabs", {}),
      manager.callTool("pessoal", "browser_tabs", {}),
    ]);

    const worker = manager.listStatuses().find((status) => status.profileId === "pessoal");
    expect(worker?.pid).toEqual(expect.any(Number));
    expect(spawnCount).toBe(1);
    expect(ensureCount).toBe(1);

    await manager.closeAll();
  });

  it("times out a stuck call and recreates only its worker", async () => {
    const manager = new WorkerManager({
      idleTimeoutMs: 60_000,
      toolTimeoutMs: 100,
      launchBrowsers: false,
      command: process.execPath,
      argsForProfile: () => [fixture],
      ensureBrowser: async () => undefined,
    });

    const stuckCall = manager.callTool("pessoal", "browser_tabs", { hang: true });
    const firstPid = await waitForWorkerPid(manager, "pessoal");

    await expect(stuckCall).rejects.toThrow("browser_tabs excedeu 100 ms");
    expect(manager.listStatuses().find((status) => status.profileId === "pessoal")?.pid).toBeNull();

    await manager.callTool("pessoal", "browser_tabs", {});
    const replacementPid = manager.listStatuses().find((status) => status.profileId === "pessoal")?.pid;
    expect(replacementPid).toEqual(expect.any(Number));
    expect(replacementPid).not.toBe(firstPid);

    await manager.closeAll();
  });

  it("keeps a healthy worker after an ordinary tool error", async () => {
    const manager = new WorkerManager({
      idleTimeoutMs: 60_000,
      launchBrowsers: false,
      command: process.execPath,
      argsForProfile: () => [fixture],
      ensureBrowser: async () => undefined,
    });

    await expect(manager.callTool("pessoal", "browser_click", { fail: true })).rejects.toThrow("locator not found");
    const firstPid = manager.listStatuses().find((status) => status.profileId === "pessoal")?.pid;
    await manager.callTool("pessoal", "browser_tabs", {});
    const secondPid = manager.listStatuses().find((status) => status.profileId === "pessoal")?.pid;
    expect(firstPid).toEqual(secondPid);

    await manager.closeAll();
  });
});

async function waitForWorkerPid(manager: WorkerManager, profileId: "pessoal"): Promise<number> {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const pid = manager.listStatuses().find((status) => status.profileId === profileId)?.pid;
    if (pid) return pid;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }

  throw new Error(`worker ${profileId} não iniciou`);
}
