import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";
import { execFileSync } from "node:child_process";
import type { ProfileConfig } from "./config.js";
import { ensureBrowser } from "./browser.js";
import { errorMessage, GatewayError } from "./errors.js";

type WorkerRecord = {
  profile: ProfileConfig;
  client: Client;
  transport: StdioClientTransport;
  activeCalls: number;
  createdAt: number;
  lastUsedAt: number;
  lastError: string | null;
};

export type WorkerSnapshot = {
  profile: string;
  port: number;
  pid: number | null;
  residentMemoryKilobytes: number;
  activeCalls: number;
  createdAt: string;
  lastUsedAt: string;
  idleMs: number;
  lastError: string | null;
};

export class WorkerManager {
  private readonly workers = new Map<string, WorkerRecord>();
  private readonly pendingStarts = new Map<string, Promise<WorkerRecord>>();
  private sweepTimer: NodeJS.Timeout | null = null;

  constructor(
    private readonly options: {
      idleTimeoutMs: number;
      sweepMs: number;
      toolTimeoutMs: number;
    }
  ) {}

  startSweeper() {
    if (this.sweepTimer) {
      return;
    }

    this.sweepTimer = setInterval(() => {
      this.releaseIdleWorkers().catch((error) => {
        console.error("Falha ao liberar workers ociosos:", error);
      });
    }, this.options.sweepMs);
    this.sweepTimer.unref();
  }

  async callTool(profile: ProfileConfig, name: string, args: Record<string, unknown>) {
    const worker = await this.workerFor(profile);
    worker.activeCalls += 1;
    worker.lastUsedAt = Date.now();

    try {
      return await withTimeout(
        worker.client.callTool(
          {
            name,
            arguments: args
          },
          CompatibilityCallToolResultSchema,
          {
            timeout: this.options.toolTimeoutMs + 1_000
          }
        ),
        this.options.toolTimeoutMs,
        () => new Error(`${name} excedeu ${this.options.toolTimeoutMs} ms; o worker ${profile.id} será recriado.`)
      );
    } catch (error) {
      worker.lastError = errorMessage(error);
      if (worker.lastError.includes("ref") || worker.lastError.includes("closed") || worker.lastError.includes("Target")) {
        worker.lastError = `${worker.lastError}\n\nO worker pode ter sido recriado; rode um novo snapshot antes de reutilizar refs antigas.`;
      }
      await this.closeWorker(profile.id, worker);
      throw error;
    } finally {
      worker.activeCalls -= 1;
      worker.lastUsedAt = Date.now();
    }
  }

  snapshots(): WorkerSnapshot[] {
    const now = Date.now();
    return [...this.workers.values()].map((worker) => ({
      profile: worker.profile.id,
      port: worker.profile.port,
      pid: worker.transport.pid,
      residentMemoryKilobytes: residentMemoryKilobytes(worker.transport.pid),
      activeCalls: worker.activeCalls,
      createdAt: new Date(worker.createdAt).toISOString(),
      lastUsedAt: new Date(worker.lastUsedAt).toISOString(),
      idleMs: Math.max(0, now - worker.lastUsedAt),
      lastError: worker.lastError
    }));
  }

  async release(profileId: string) {
    const worker = this.workers.get(profileId);
    if (!worker || worker.activeCalls > 0) {
      return false;
    }

    await this.closeWorker(profileId, worker);
    return true;
  }

  async releaseIdleWorkers() {
    let released = 0;
    const now = Date.now();

    for (const [profileId, worker] of this.workers) {
      if (worker.activeCalls > 0) {
        continue;
      }

      if (now - worker.lastUsedAt >= this.options.idleTimeoutMs) {
        await this.closeWorker(profileId, worker);
        released += 1;
      }
    }

    return released;
  }

  async closeAll() {
    await Promise.all([...this.workers].map(([profileId, worker]) => this.closeWorker(profileId, worker)));
  }

  private async workerFor(profile: ProfileConfig) {
    const existing = this.workers.get(profile.id);
    if (existing) {
      return existing;
    }

    const pending = this.pendingStarts.get(profile.id);
    if (pending) {
      return pending;
    }

    const start = this.startWorker(profile);
    this.pendingStarts.set(profile.id, start);

    try {
      return await start;
    } finally {
      this.pendingStarts.delete(profile.id);
    }
  }

  private async startWorker(profile: ProfileConfig) {
    await ensureBrowser(profile);

    const transport = new StdioClientTransport({
      command: process.env.PLAYWRIGHT_MCP_COMMAND ?? "playwright-mcp",
      args: [
        "--cdp-endpoint",
        `http://127.0.0.1:${profile.port}`,
        "--cdp-timeout",
        "30000",
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
      name: `gabriel-browsers-worker-${profile.id}`,
      version: "0.1.0"
    });

    try {
      await client.connect(transport, { timeout: 30_000 });
    } catch (error) {
      await transport.close().catch(() => undefined);
      throw new GatewayError(`falha ao iniciar worker MCP de ${profile.id}: ${errorMessage(error)}\n${stderr}`.trim(), 502);
    }

    const worker: WorkerRecord = {
      profile,
      client,
      transport,
      activeCalls: 0,
      createdAt: Date.now(),
      lastUsedAt: Date.now(),
      lastError: null
    };
    this.workers.set(profile.id, worker);
    return worker;
  }

  private async closeWorker(profileId: string, worker: WorkerRecord) {
    if (this.workers.get(profileId) !== worker) {
      return;
    }

    this.workers.delete(profileId);
    await settlesWithin(worker.client.close(), 1_000);
    const transportClosed = await settlesWithin(worker.transport.close(), 1_000);
    if (!transportClosed && worker.transport.pid) {
      try {
        process.kill(worker.transport.pid, "SIGKILL");
      } catch {
        return;
      }
    }
  }
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, error: () => Error): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(error()), timeoutMs);
    timer.unref();
  });

  return Promise.race([promise, timeout]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

async function settlesWithin(promise: Promise<unknown>, timeoutMs: number): Promise<boolean> {
  let timer: NodeJS.Timeout | undefined;
  const settled = promise.then(
    () => true,
    () => true
  );
  const timedOut = new Promise<boolean>((resolve) => {
    timer = setTimeout(() => resolve(false), timeoutMs);
    timer.unref();
  });

  return Promise.race([settled, timedOut]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

function residentMemoryKilobytes(pid: number | null) {
  if (!pid) {
    return 0;
  }

  try {
    const output = execFileSync("ps", ["-o", "rss=", "-p", String(pid)], {
      encoding: "utf8"
    });
    return Number(output.trim()) || 0;
  } catch {
    return 0;
  }
}
