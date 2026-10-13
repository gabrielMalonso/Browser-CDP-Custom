import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { stopBrowser } from "../src/browserLauncher.js";
import type { BrowserProfile } from "../src/profileRegistry.js";

const state = vi.hoisted(() => ({
  cdpAlive: true,
  processRunning: true,
  exitOnClose: true,
  disconnectBeforeReply: false,
  commands: [] as string[],
}));

vi.mock("node:child_process", () => ({
  spawn: vi.fn(),
  execFile: (
    executable: string,
    _args: string[],
    _options: unknown,
    callback: (error: Error | null, stdout: string) => void,
  ) => {
    const stdout = executable.endsWith("/ps")
      ? state.processRunning
        ? "12345 browser --user-data-dir=/tmp/shutdown-fixture --remote-debugging-port=59924"
        : ""
      : state.cdpAlive ? "12345" : "";
    callback(null, stdout);
  },
}));

class BrowserSocket extends EventTarget {
  constructor(_url: string) {
    super();
    queueMicrotask(() => this.dispatchEvent(new Event("open")));
  }

  send(data: string) {
    const command = JSON.parse(data) as { id: number; method: string };
    state.commands.push(command.method);
    state.cdpAlive = false;
    if (state.exitOnClose) state.processRunning = false;
    queueMicrotask(() => {
      if (state.disconnectBeforeReply) this.close();
      else this.dispatchEvent(new MessageEvent("message", { data: JSON.stringify({ id: command.id, result: {} }) }));
    });
  }

  close() {
    this.dispatchEvent(new Event("close"));
  }
}

const profile: BrowserProfile = {
  id: "central-es",
  aliases: [],
  name: "Central ES",
  port: 59924,
  resourceGroup: "central-es",
  platform: "darwin",
  profileRoot: "/tmp/shutdown-fixture",
  profileDirectory: "Default",
  browserAppName: "Helium",
};

beforeEach(() => {
  vi.useFakeTimers();
  Object.assign(state, { cdpAlive: true, processRunning: true, exitOnClose: true, disconnectBeforeReply: false, commands: [] });
  vi.stubGlobal("WebSocket", BrowserSocket);
  vi.stubGlobal("fetch", vi.fn(async () => {
    if (!state.cdpAlive) throw new Error("CDP closed");
    return new Response(JSON.stringify({ webSocketDebuggerUrl: "ws://127.0.0.1:59924/devtools/browser/test" }));
  }));
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("browser shutdown", () => {
  it("requests Browser.close instead of signalling the browser and its helpers", async () => {
    const kill = vi.spyOn(process, "kill").mockImplementation(() => true);
    expect(await stopBrowser(profile)).toBe(true);
    expect(state.commands).toEqual(["Browser.close"]);
    expect(kill).not.toHaveBeenCalled();
  });

  it("accepts browser exit before the close command is acknowledged", async () => {
    state.disconnectBeforeReply = true;
    expect(await stopBrowser(profile)).toBe(true);
    expect(state.commands).toEqual(["Browser.close"]);
  });

  it("does not report closed while the profile process still runs after CDP disconnects", async () => {
    state.exitOnClose = false;
    const result = stopBrowser(profile);
    const assertion = expect(result).rejects.toMatchObject({ code: "browser_stop_failed" });
    await vi.advanceTimersByTimeAsync(6000);
    await assertion;
  });

  it("waits for delayed process exit before completing the close request", async () => {
    state.exitOnClose = false;
    let completed = false;
    const result = stopBrowser(profile).then((stopped) => { completed = true; return stopped; });
    await vi.advanceTimersByTimeAsync(500);
    expect(state.cdpAlive).toBe(false);
    expect(completed).toBe(false);
    state.processRunning = false;
    await vi.advanceTimersByTimeAsync(500);
    expect(await result).toBe(true);
  });
});
