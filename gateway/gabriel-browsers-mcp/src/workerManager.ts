import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CompatibilityCallToolResultSchema, type CompatibilityCallToolResult } from "@modelcontextprotocol/sdk/types.js";
import path from "node:path";
import { ensureBrowserRunning } from "./browserLauncher.js";
import { cdpEndpoint, getProfile, profiles, type ProfileId } from "./profileRegistry.js";

type WorkerRecord = {
  profileId: ProfileId;
  client: Client;
  transport: StdioClientTransport;
  pid: number | null;
  callsInFlight: number;
  leaseCount: number;
  lastUsedAt: number;
  closing: boolean;
  mutex: Promise<unknown>;
};

export type WorkerStatus = {
  profileId: ProfileId;
  pid: number | null;
  callsInFlight: number;
  leaseCount: number;
  idleMs: number;
  closing: boolean;
  circuitOpenUntil: number | null;
};

export type WorkerManagerOptions = {
  idleTimeoutMs: number;
  toolTimeoutMs?: number;
  launchBrowsers: boolean;
  now?: () => number;
  command?: string;
  argsForProfile?: (profileId: ProfileId) => string[];
  ensureBrowser?: (profileId: ProfileId) => Promise<void>;
};

const gatewayRoot = process.env.GABRIEL_BROWSERS_MCP_ROOT ?? process.cwd();
const defaultCommand = path.join(gatewayRoot, "node_modules", ".bin", "playwright-mcp");

export class WorkerManager {
  private readonly workers = new Map<ProfileId, WorkerRecord>();
  private readonly workerCreations = new Map<ProfileId, Promise<WorkerRecord>>();
  private readonly now: () => number;
  private readonly replacementFailures = new Map<ProfileId, number[]>();
  private readonly circuitOpenUntil = new Map<ProfileId, number>();
  private cleanupTimer: NodeJS.Timeout | undefined;

  constructor(private readonly options: WorkerManagerOptions) {
    this.now = options.now ?? Date.now;
  }

  startIdleCleanup(): void {
    this.cleanupTimer ??= setInterval(() => {
      void this.cleanupIdleWorkers();
    }, Math.min(this.options.idleTimeoutMs, 60_000)).unref();
  }

  stopIdleCleanup(): void {
    if (this.cleanupTimer) clearInterval(this.cleanupTimer);
    this.cleanupTimer = undefined;
  }

  listStatuses(): WorkerStatus[] {
    const now = this.now();
    return profiles.map((profile) => {
      const worker = this.workers.get(profile.id);
      return {
        profileId: profile.id,
        pid: worker?.pid ?? null,
        callsInFlight: worker?.callsInFlight ?? 0,
        leaseCount: worker?.leaseCount ?? 0,
        idleMs: worker ? Math.max(0, now - worker.lastUsedAt) : 0,
        closing: worker?.closing ?? false,
        circuitOpenUntil: this.circuitOpenUntil.get(profile.id) ?? null,
      };
    });
  }

  async callTool(
    profileId: ProfileId,
    name: string,
    args: Record<string, unknown> | undefined,
  ): Promise<CompatibilityCallToolResult> {
    const worker = await this.ensureWorker(profileId);
    return this.withWorkerMutex(worker, async () => {
      if (worker.closing || this.workers.get(profileId) !== worker) {
        return this.callTool(profileId, name, args);
      }

      worker.callsInFlight += 1;
      worker.leaseCount += 1;
      try {
        const timeoutMs = this.options.toolTimeoutMs ?? 15_000;
        return await withTimeout(
          worker.client.callTool(
            { name, arguments: normalizeToolArguments(name, args) },
            CompatibilityCallToolResultSchema,
            { timeout: timeoutMs + 1_000 },
          ),
          timeoutMs,
          () => Object.assign(
            new Error(`${name} excedeu ${timeoutMs} ms; o worker ${profileId} será recriado.`),
            { code: "worker_tool_timeout", statusCode: 504 },
          ),
        );
      } catch (error) {
        if (shouldReplaceWorker(error)) {
          await this.closeWorker(profileId, worker);
          this.recordReplacementFailure(profileId);
        }
        throw normalizeWorkerError(error);
      } finally {
        worker.callsInFlight -= 1;
        worker.leaseCount -= 1;
        worker.lastUsedAt = this.now();
      }
    });
  }

  async release(profileId: ProfileId): Promise<boolean> {
    const worker = this.workers.get(profileId);
    if (!worker || worker.callsInFlight > 0 || worker.leaseCount > 0) {
      return false;
    }
    await this.closeWorker(profileId, worker);
    return true;
  }

  async cleanupIdleWorkers(): Promise<number> {
    let closed = 0;
    const now = this.now();
    for (const worker of [...this.workers.values()]) {
      if (worker.callsInFlight > 0 || worker.leaseCount > 0) continue;
      if (now - worker.lastUsedAt < this.options.idleTimeoutMs) continue;
      await this.closeWorker(worker.profileId, worker);
      closed += 1;
    }
    return closed;
  }

  async closeAll(): Promise<void> {
    this.stopIdleCleanup();
    await Promise.allSettled([...this.workerCreations.values()]);
    await Promise.all([...this.workers.keys()].map((profileId) => this.closeWorker(profileId)));
  }

  private async ensureWorker(profileId: ProfileId): Promise<WorkerRecord> {
    const circuitOpenUntil = this.circuitOpenUntil.get(profileId) ?? 0;
    if (circuitOpenUntil > this.now()) {
      throw Object.assign(
        new Error(`O circuit breaker de ${profileId} está aberto até ${new Date(circuitOpenUntil).toISOString()}.`),
        { code: "worker_circuit_open", statusCode: 503 },
      );
    }
    if (circuitOpenUntil) this.circuitOpenUntil.delete(profileId);
    const existing = this.workers.get(profileId);
    if (existing && !existing.closing) return existing;

    const pendingCreation = this.workerCreations.get(profileId);
    if (pendingCreation) return pendingCreation;

    const creation = this.createWorker(profileId);
    this.workerCreations.set(profileId, creation);
    try {
      return await creation;
    } finally {
      if (this.workerCreations.get(profileId) === creation) {
        this.workerCreations.delete(profileId);
      }
    }
  }

  private async createWorker(profileId: ProfileId): Promise<WorkerRecord> {
    const existing = this.workers.get(profileId);
    if (existing && !existing.closing) return existing;

    const profile = getProfile(profileId);
    if (this.options.ensureBrowser) {
      await this.options.ensureBrowser(profileId);
    } else {
      await ensureBrowserRunning(profile, this.options.launchBrowsers);
    }

    const transport = new StdioClientTransport({
      command: this.options.command ?? defaultCommand,
      args: this.options.argsForProfile?.(profileId) ?? ["--cdp-endpoint", cdpEndpoint(profile)],
      cwd: gatewayRoot,
      stderr: "pipe",
    });
    const client = new Client({ name: `gabriel-browsers-worker-${profileId}`, version: "0.1.0" });
    await client.connect(transport, { timeout: 30_000 });

    const worker: WorkerRecord = {
      profileId,
      client,
      transport,
      pid: transport.pid,
      callsInFlight: 0,
      leaseCount: 0,
      lastUsedAt: this.now(),
      closing: false,
      mutex: Promise.resolve(),
    };

    transport.onclose = () => {
      if (this.workers.get(profileId) === worker) {
        this.workers.delete(profileId);
      }
    };

    this.workers.set(profileId, worker);
    return worker;
  }

  private async closeWorker(profileId: ProfileId, expectedWorker?: WorkerRecord): Promise<void> {
    const worker = this.workers.get(profileId);
    if (!worker || (expectedWorker && worker !== expectedWorker)) return;

    worker.closing = true;
    this.workers.delete(profileId);
    await settlesWithin(worker.client.close(), 1_000);
    const transportClosed = await settlesWithin(worker.transport.close(), 1_000);
    if (!transportClosed && worker.pid) {
      try {
        process.kill(worker.pid, "SIGKILL");
      } catch {
        return;
      }
    }
  }

  private async withWorkerMutex<T>(worker: WorkerRecord, fn: () => Promise<T>): Promise<T> {
    const previous = worker.mutex.catch(() => undefined);
    const next = previous.then(fn);
    worker.mutex = next.catch(() => undefined);
    return next;
  }

  private recordReplacementFailure(profileId: ProfileId): void {
    const cutoff = this.now() - 60_000;
    const failures = [...(this.replacementFailures.get(profileId) ?? []), this.now()].filter(
      (timestamp) => timestamp >= cutoff,
    );
    this.replacementFailures.set(profileId, failures);
    if (failures.length >= 3) this.circuitOpenUntil.set(profileId, this.now() + 30_000);
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
    () => true,
  );
  const timedOut = new Promise<boolean>((resolve) => {
    timer = setTimeout(() => resolve(false), timeoutMs);
    timer.unref();
  });

  return Promise.race([settled, timedOut]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

function normalizeToolArguments(
  name: string,
  args: Record<string, unknown> | undefined,
): Record<string, unknown> | undefined {
  if (name === "browser_tabs" && !args?.action) {
    return { ...(args ?? {}), action: "list" };
  }

  return args;
}

function normalizeWorkerError(error: unknown): Error {
  const message = error instanceof Error ? error.message : String(error);
  if (/ref|element|snapshot|locator/i.test(message)) {
    return Object.assign(new Error(`${message}\n\nFaça um novo browser_snapshot antes de agir de novo.`), {
      code: errorCode(error),
    });
  }
  return error instanceof Error ? error : new Error(message);
}

function shouldReplaceWorker(error: unknown): boolean {
  if (errorCode(error) === "worker_tool_timeout") return true;
  const message = error instanceof Error ? error.message : String(error);
  return /transport closed|connection closed|browser has been closed|target page, context or browser has been closed/i.test(message);
}

function errorCode(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error && typeof error.code === "string"
    ? error.code
    : undefined;
}
