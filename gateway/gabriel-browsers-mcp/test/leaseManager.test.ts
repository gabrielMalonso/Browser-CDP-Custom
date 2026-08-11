import { describe, expect, it } from "vitest";
import { LeaseManager } from "../src/leaseManager.js";

describe("lease manager", () => {
  it("allows shared reads and excludes writes", () => {
    const leases = new LeaseManager(() => 1_000);
    const first = leases.acquire("central-es", "read", "reader-a");
    const second = leases.acquire("central-es", "read", "reader-b");
    expect(first.fencingToken).toBe(1);
    expect(second.fencingToken).toBe(2);
    expect(() => leases.acquire("central-es", "write", "writer")).toThrow("reader-a");
  });

  it("expires stale leases and rejects old fencing holders", () => {
    let now = 1_000;
    const leases = new LeaseManager(() => now, 5_000);
    const stale = leases.acquire("pessoal", "write", "first", 5_000);
    now = 7_000;
    const current = leases.acquire("pessoal", "write", "second", 5_000);
    expect(current.fencingToken).toBeGreaterThan(stale.fencingToken);
    expect(() => leases.assertAccess(stale.id, "pessoal", "write")).toThrow("ausente ou expirada");
  });

  it("keeps independent profiles independent", () => {
    const leases = new LeaseManager(() => 1_000);
    leases.acquire("central-es", "write", "es");
    expect(() => leases.acquire("central-rj", "write", "rj")).not.toThrow();
  });
});
