import { mkdtemp, mkdir, lstat, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  matchingBrowserProcessIds,
  linuxBrowserEnvironment,
  parseProcessSnapshots,
  removeVerifiedStaleLocks,
} from "../src/browserLauncher.js";
import type { BrowserProfile } from "../src/profileRegistry.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  const { rm } = await import("node:fs/promises");
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("browser launcher safety", () => {
  it("matches a process only when profile root and CDP port both agree", () => {
    const profile = fixtureProfile("/tmp/profile-safe", 9224);
    const snapshots = parseProcessSnapshots(`
      100 /Applications/Google Chrome --user-data-dir=/tmp/profile-safe --remote-debugging-port=9224
      101 /Applications/Google Chrome --user-data-dir=/tmp/profile-other --remote-debugging-port=9224
      102 /Applications/Google Chrome --user-data-dir=/tmp/profile-safe --remote-debugging-port=9223
    `);
    expect(matchingBrowserProcessIds(snapshots, profile)).toEqual([100]);
  });

  it("removes only verified stale symbolic locks", async () => {
    const root = await temporaryRoot();
    const profile = fixtureProfile(root);
    await mkdir(path.join(root, "Default"), { recursive: true });
    await symlink(`host-${process.pid + 10_000_000}`, path.join(root, "SingletonLock"));
    await symlink(path.join(root, "missing.sock"), path.join(root, "SingletonSocket"));
    await symlink("cookie", path.join(root, "SingletonCookie"));

    await removeVerifiedStaleLocks(profile);

    await expect(lstat(path.join(root, "SingletonLock"))).rejects.toMatchObject({ code: "ENOENT" });
    await expect(lstat(path.join(root, "SingletonSocket"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("fails closed for an active or ambiguous lock", async () => {
    const root = await temporaryRoot();
    const profile = fixtureProfile(root);
    await mkdir(path.join(root, "Default"), { recursive: true });
    await symlink(`host-${process.pid}`, path.join(root, "SingletonLock"));
    await expect(removeVerifiedStaleLocks(profile)).rejects.toThrow("PID ativo");

    const otherRoot = await temporaryRoot();
    const otherProfile = fixtureProfile(otherRoot);
    await mkdir(path.join(otherRoot, "Default"), { recursive: true });
    await writeFile(path.join(otherRoot, "SingletonCookie"), "unexpected");
    await expect(removeVerifiedStaleLocks(otherProfile)).rejects.toThrow("formato inesperado");
  });

  it("recovers the graphical Linux environment without overriding configured values", () => {
    const recovered = linuxBrowserEnvironment(
      {},
      1000,
      (candidate) => ["/run/user/1000/bus", "/run/user/1000/gdm/Xauthority", "/tmp/.X11-unix/X0"].includes(candidate),
    );
    expect(recovered).toMatchObject({
      DISPLAY: ":0",
      XDG_RUNTIME_DIR: "/run/user/1000",
      DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/1000/bus",
      XAUTHORITY: "/run/user/1000/gdm/Xauthority",
    });

    const configured = linuxBrowserEnvironment({ DISPLAY: ":7", XDG_RUNTIME_DIR: "/custom" }, 1000, () => true);
    expect(configured.DISPLAY).toBe(":7");
    expect(configured.XDG_RUNTIME_DIR).toBe("/custom");
  });
});

async function temporaryRoot(): Promise<string> {
  const directory = await mkdtemp(path.join(os.tmpdir(), "gabriel-browser-test-"));
  temporaryDirectories.push(directory);
  return directory;
}

function fixtureProfile(profileRoot: string, port = 59_924): BrowserProfile {
  return {
    id: "pessoal",
    aliases: [],
    name: "Pessoal",
    port,
    resourceGroup: "pessoal",
    platform: "darwin",
    profileRoot,
    profileDirectory: "Default",
    browserAppName: "Google Chrome",
  };
}
