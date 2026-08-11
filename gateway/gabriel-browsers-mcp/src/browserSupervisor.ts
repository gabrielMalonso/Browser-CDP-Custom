import {
  type BrowserState,
  type BrowserStatus,
  type CDPTarget,
  activateTarget,
  closeTarget,
  ensureBrowserRunning,
  inspectBrowser,
  listTargets,
  navigateTarget,
  openTarget,
  stopBrowser,
} from "./browserLauncher.js";
import { getProfile, profiles, type ProfileId } from "./profileRegistry.js";

export type SupervisorTarget = CDPTarget & {
  automationOwned: boolean;
  owner?: string;
};

export type ProfileStatus = BrowserStatus & {
  profileId: ProfileId;
  automationPaused: boolean;
};

type OwnedTarget = {
  profileId: ProfileId;
  owner: string;
};

export class BrowserSupervisor {
  private readonly operations = new Map<ProfileId, Promise<unknown>>();
  private readonly transientStates = new Map<ProfileId, BrowserState>();
  private readonly ownedTargets = new Map<string, OwnedTarget>();
  private readonly pausedProfiles = new Set<ProfileId>();

  constructor(private readonly launchBrowsers: boolean) {}

  async status(profileId: ProfileId): Promise<ProfileStatus> {
    const profile = getProfile(profileId);
    const status = await inspectBrowser(profile);
    return {
      ...status,
      state: this.transientStates.get(profileId) ?? status.state,
      profileId,
      automationPaused: this.pausedProfiles.has(profileId),
    };
  }

  async listStatuses(): Promise<ProfileStatus[]> {
    return Promise.all(profiles.map((profile) => this.status(profile.id)));
  }

  async ensureRunning(profileId: ProfileId): Promise<void> {
    await this.serialized(profileId, async () => {
      this.transientStates.set(profileId, "starting");
      try {
        await ensureBrowserRunning(getProfile(profileId), this.launchBrowsers);
      } finally {
        this.transientStates.delete(profileId);
      }
    });
  }

  async stop(profileId: ProfileId, force = false): Promise<boolean> {
    return this.serialized(profileId, async () => {
      this.transientStates.set(profileId, "stopping");
      try {
        return await stopBrowser(getProfile(profileId), force);
      } finally {
        this.transientStates.delete(profileId);
      }
    });
  }

  async targets(profileId: ProfileId): Promise<SupervisorTarget[]> {
    const targets = await listTargets(getProfile(profileId));
    const visibleIds = new Set(targets.map((target) => target.id));
    for (const [targetId, owned] of this.ownedTargets) {
      if (owned.profileId === profileId && !visibleIds.has(targetId)) this.ownedTargets.delete(targetId);
    }
    return targets.map((target) => {
      const owned = this.ownedTargets.get(target.id);
      return {
        ...target,
        automationOwned: owned?.profileId === profileId,
        owner: owned?.profileId === profileId ? owned.owner : undefined,
      };
    });
  }

  async createTarget(profileId: ProfileId, url: string, owner = "supervisor"): Promise<SupervisorTarget> {
    if (this.pausedProfiles.has(profileId)) {
      throw Object.assign(new Error(`A automação de ${profileId} está pausada.`), {
        statusCode: 409,
        code: "automation_paused",
      });
    }
    await this.ensureRunning(profileId);
    const target = await openTarget(getProfile(profileId), url);
    this.ownedTargets.set(target.id, { profileId, owner });
    return { ...target, automationOwned: true, owner };
  }

  registerOwnedTarget(profileId: ProfileId, targetId: string, owner: string): void {
    this.ownedTargets.set(targetId, { profileId, owner });
  }

  async activateTarget(profileId: ProfileId, targetId: string): Promise<boolean> {
    return activateTarget(getProfile(profileId), targetId);
  }

  async navigateTarget(profileId: ProfileId, targetId: string, url: string): Promise<void> {
    if (this.pausedProfiles.has(profileId)) {
      throw Object.assign(new Error(`A automação de ${profileId} está pausada.`), {
        statusCode: 409,
        code: "automation_paused",
      });
    }
    await navigateTarget(getProfile(profileId), targetId, url);
  }

  async closeOwnedTarget(profileId: ProfileId, targetId: string): Promise<boolean> {
    const owned = this.ownedTargets.get(targetId);
    if (!owned || owned.profileId !== profileId) {
      throw Object.assign(new Error(`O target ${targetId} não pertence a uma sessão de automação.`), {
        statusCode: 409,
        code: "target_not_owned",
      });
    }
    const closed = await closeTarget(getProfile(profileId), targetId);
    this.ownedTargets.delete(targetId);
    return closed;
  }

  setAutomationPaused(profileId: ProfileId, paused: boolean): void {
    if (paused) this.pausedProfiles.add(profileId);
    else this.pausedProfiles.delete(profileId);
  }

  isAutomationPaused(profileId: ProfileId): boolean {
    return this.pausedProfiles.has(profileId);
  }

  private async serialized<T>(profileId: ProfileId, operation: () => Promise<T>): Promise<T> {
    const previous = this.operations.get(profileId)?.catch(() => undefined) ?? Promise.resolve();
    const next = previous.then(operation);
    const tracked = next.catch(() => undefined);
    this.operations.set(profileId, tracked);
    try {
      return await next;
    } finally {
      if (this.operations.get(profileId) === tracked) this.operations.delete(profileId);
    }
  }
}
