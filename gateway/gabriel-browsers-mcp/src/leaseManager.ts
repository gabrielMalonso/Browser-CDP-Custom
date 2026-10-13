import { randomUUID } from "node:crypto";
import { getProfile, profiles, type ProfileId } from "./profileRegistry.js";

export type LeaseMode = "read" | "write";

export type AutomationLease = {
  id: string;
  profileId: ProfileId;
  resource: string;
  mode: LeaseMode;
  owner: string;
  fencingToken: number;
  acquiredAt: number;
  expiresAt: number;
};

export class LeaseManager {
  private readonly leases = new Map<string, AutomationLease>();
  private readonly nextFencingTokenByResource = new Map<string, number>();

  constructor(
    private readonly now: () => number = Date.now,
    private readonly defaultTtlMs = 30_000,
  ) {}

  list(profileId?: ProfileId): AutomationLease[] {
    this.cleanupExpired();
    return [...this.leases.values()]
      .filter((lease) => !profileId || lease.profileId === profileId)
      .sort((left, right) => left.acquiredAt - right.acquiredAt);
  }

  acquire(profileId: ProfileId, mode: LeaseMode, owner: string, ttlMs = this.defaultTtlMs): AutomationLease {
    this.cleanupExpired();
    const profile = getProfile(profileId);
    const resource = profile.resourceGroup;
    const conflicts = [...this.leases.values()].filter(
      (lease) => lease.resource === resource && (mode === "write" || lease.mode === "write"),
    );
    if (conflicts.length > 0) {
      const current = conflicts[0];
      throw Object.assign(
        new Error(`O perfil ${profileId} está em uso por ${current.owner} até ${new Date(current.expiresAt).toISOString()}.`),
        { statusCode: 409, code: "lease_conflict", lease: current },
      );
    }

    const normalizedTtl = Math.max(5_000, Math.min(ttlMs, 5 * 60_000));
    const fencingToken = (this.nextFencingTokenByResource.get(resource) ?? 0) + 1;
    this.nextFencingTokenByResource.set(resource, fencingToken);
    const acquiredAt = this.now();
    const lease: AutomationLease = {
      id: randomUUID(),
      profileId,
      resource,
      mode,
      owner: owner.trim() || "anonymous",
      fencingToken,
      acquiredAt,
      expiresAt: acquiredAt + normalizedTtl,
    };
    this.leases.set(lease.id, lease);
    return lease;
  }

  renew(id: string, ttlMs = this.defaultTtlMs): AutomationLease {
    this.cleanupExpired();
    const lease = this.leases.get(id);
    if (!lease) throw leaseMissing(id);
    const normalizedTtl = Math.max(5_000, Math.min(ttlMs, 5 * 60_000));
    const renewed = { ...lease, expiresAt: this.now() + normalizedTtl };
    this.leases.set(id, renewed);
    return renewed;
  }

  release(id: string): boolean {
    return this.leases.delete(id);
  }

  assertAccess(id: string, profileId: ProfileId, requiredMode: LeaseMode): AutomationLease {
    this.cleanupExpired();
    const lease = this.leases.get(id);
    if (!lease) throw leaseMissing(id);
    if (lease.profileId !== profileId) {
      throw Object.assign(new Error(`A lease ${id} pertence a outro perfil.`), {
        statusCode: 409,
        code: "lease_profile_mismatch",
      });
    }
    if (requiredMode === "write" && lease.mode !== "write") {
      throw Object.assign(new Error(`A lease ${id} é somente leitura.`), {
        statusCode: 409,
        code: "lease_mode_mismatch",
      });
    }
    return lease;
  }

  hasActive(profileId: ProfileId): boolean {
    return this.list(profileId).length > 0;
  }

  cleanupExpired(): number {
    const now = this.now();
    let removed = 0;
    for (const [id, lease] of this.leases) {
      if (lease.expiresAt > now) continue;
      this.leases.delete(id);
      removed += 1;
    }
    return removed;
  }

  profileStatuses(): Array<{ profileId: ProfileId; leases: AutomationLease[] }> {
    return profiles.map((profile) => ({ profileId: profile.id, leases: this.list(profile.id) }));
  }
}

function leaseMissing(id: string): Error {
  return Object.assign(new Error(`Lease ausente ou expirada: ${id}`), {
    statusCode: 409,
    code: "lease_missing",
  });
}
