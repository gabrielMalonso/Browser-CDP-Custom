<script lang="ts">
  import { onMount } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import chromeIcon from "./assets/chrome-icon.png";
  import Settings from "./Settings.svelte";

  type Profile = {
    id: string;
    name: string;
    kind: string;
    badge: string;
    user_data_dir: string;
    profile_directory: string;
    browser_command: string | null;
    port: number;
    default_url: string | null;
  };

  type ProfileStatus = {
    profile: Profile;
    profile_exists: boolean;
    cdp_ok: boolean;
    port_open: boolean;
    message: string;
  };

  type PendingLink = { url: string; profile_id: string; error: string };
  type ActivationContext = {
    incomingUrls: string[];
    pendingLinks: PendingLink[];
    feedback: string | null;
  };
  type SelectionResult = { message: string; dismissOverlay: boolean };
  type McpWorker = {
    profile: string;
    port: number;
    pid: number | null;
    residentMemoryKilobytes: number;
  };
  type McpGatewayStatus = {
    healthy: boolean;
    workers: McpWorker[];
    message: string;
  };

  const isSettingsView = new URLSearchParams(window.location.search).get("view") === "settings";
  let statuses: ProfileStatus[] = [];
  let activation: ActivationContext = { incomingUrls: [], pendingLinks: [], feedback: null };
  let mcpStatus: McpGatewayStatus = {
    healthy: false,
    workers: [],
    message: "Gateway MCP indisponível."
  };
  let busy = false;
  let message = "Carregando perfis...";
  let expandedProfileId: string | null = null;

  const refresh = async () => {
    const [profileStatuses, context, gatewayStatus] = await Promise.all([
      invoke<ProfileStatus[]>("profiles"),
      invoke<ActivationContext>("activation_context"),
      invoke<McpGatewayStatus>("mcp_gateway_status").catch((error) => ({
        healthy: false,
        workers: [],
        message: String(error)
      }))
    ]);
    statuses = profileStatuses;
    activation = context;
    mcpStatus = gatewayStatus;
    message = context.feedback ?? (statuses.length > 0 ? "Pronto." : "Nenhum perfil configurado.");
  };

  const run = async (action: () => Promise<string>) => {
    busy = true;
    try {
      message = await action();
      await refresh();
    } catch (error) {
      message = String(error);
    } finally {
      busy = false;
    }
  };

  const finishSelection = async (action: () => Promise<SelectionResult>) => {
    busy = true;
    try {
      const result = await action();
      message = result.message;
      if (result.dismissOverlay) {
        window.setTimeout(() => invoke("dismiss_overlay"), 180);
      } else {
        await refresh();
      }
    } catch (error) {
      message = String(error);
      await refresh().catch(() => undefined);
    } finally {
      busy = false;
    }
  };

  const selectProfile = (profileId: string) =>
    finishSelection(() => invoke<SelectionResult>("activate_profile", { profileId }));

  const selectNormalBrowser = () =>
    finishSelection(() => invoke<SelectionResult>("activate_normal_browser"));

  const openUrl = (profileId: string, url: string) =>
    run(() => invoke<string>("route_url", { profileId, url }));

  const closeProfile = (profileId: string) =>
    run(() => invoke<string>("close_profile", { profileId }));

  const closeAllControlledBrowsers = () =>
    run(() => invoke<string>("close_all_controlled_browsers"));

  const releaseMcpWorker = (profileId: string) =>
    run(() => invoke<string>("release_mcp_worker", { profileId }));

  const retryPendingLinks = () =>
    run(() => invoke<string>("retry_pending_links"));

  const dismiss = () => invoke("dismiss_overlay");
  const openSettings = () => invoke("open_settings_window");
  const toggleDetails = (profileId: string) => {
    expandedProfileId = expandedProfileId === profileId ? null : profileId;
  };

  const formatPort = (port: number) => new Intl.NumberFormat("pt-BR").format(port);
  const rowState = (status: ProfileStatus) => {
    if (status.cdp_ok) return "CDP ativo";
    if (!status.profile_exists) return "perfil ausente";
    if (status.port_open) return "porta ocupada";
    return "disponível";
  };
  const badgeClass = (id: string) => `badge badge-${id}`;
  const mcpWorkersForProfile = (profileId: string) =>
    mcpStatus.workers.filter((worker) => worker.profile === profileId);
  const formatMemory = (kilobytes: number) => {
    const megabytes = (kilobytes * 1024) / 1_000_000;
    return `${new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 1 }).format(megabytes)} MB`;
  };
  const mcpMemorySummary = () => {
    const total = mcpStatus.workers.reduce((sum, worker) => sum + worker.residentMemoryKilobytes, 0);
    return `${formatMemory(total)} · ${mcpStatus.workers.length} worker${mcpStatus.workers.length === 1 ? "" : "s"}`;
  };
  const pendingSummary = () => {
    const first = activation.incomingUrls[0];
    if (!first) return "";
    try {
      const host = new URL(first).host;
      return `${activation.incomingUrls.length > 1 ? `${activation.incomingUrls.length} links · ` : ""}${host}`;
    } catch {
      return first;
    }
  };

  onMount(() => {
    if (isSettingsView) return;
    refresh();

    let stopListening: (() => void) | undefined;
    listen("incoming-links", refresh).then((unlisten) => (stopListening = unlisten));
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") dismiss();
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      stopListening?.();
      window.removeEventListener("keydown", closeOnEscape);
    };
  });
</script>

{#if isSettingsView}
  <Settings />
{:else}
  <main class="overlay" data-tauri-drag-region>
    <header class="panel-header" data-tauri-drag-region>
      <div class="brand">
        <span class="brand-icon" aria-hidden="true">⌁</span>
        <div>
          <h1>{activation.incomingUrls.length > 0 ? "Onde abrir este link?" : "Custom CDP Browser"}</h1>
          {#if activation.incomingUrls.length > 0}<p class="link-summary">{pendingSummary()}</p>{/if}
        </div>
      </div>
      <button class="escape-hint" on:click={dismiss}>ESC para fechar</button>
    </header>

    {#if activation.pendingLinks.length > 0}
      <button class="pending-banner" disabled={busy} on:click={retryPendingLinks}>
        <span>↻</span>
        <span><strong>{activation.pendingLinks.length} link(s) aguardando nova tentativa</strong><small>Clique para reenviar sem perder a URL.</small></span>
      </button>
    {/if}

    <section class="profile-list" aria-label="Perfis CDP">
      {#each statuses as status}
        <article class:active={status.cdp_ok} class:missing={!status.profile_exists} class:expanded={expandedProfileId === status.profile.id}>
          <button class="profile-main" disabled={busy} title={status.message} on:click={() => selectProfile(status.profile.id)}>
            <span class={badgeClass(status.profile.id)}>{status.profile.badge}</span>
            <div class="profile-copy">
              <h2>{status.profile.name} · porta {formatPort(status.profile.port)}</h2>
              <p>{rowState(status)}</p>
            </div>
          </button>
          <div class="row-actions">
            {#if status.profile.default_url && activation.incomingUrls.length === 0}
              <button class="round-button" disabled={busy || !status.profile_exists} title="Abrir página padrão" on:click|stopPropagation={() => openUrl(status.profile.id, status.profile.default_url ?? "")}>↗</button>
            {/if}
            {#if status.cdp_ok && activation.incomingUrls.length === 0}
              <button class="round-button" disabled={busy} title={`Fechar ${status.profile.name}`} on:click|stopPropagation={() => closeProfile(status.profile.id)}>×</button>
            {/if}
            {#if mcpWorkersForProfile(status.profile.id).length > 0 && activation.incomingUrls.length === 0}
              <button class="round-button" disabled={busy} title={`Liberar worker MCP de ${status.profile.name}`} on:click|stopPropagation={() => releaseMcpWorker(status.profile.id)}>⇥</button>
            {/if}
            <button class="round-button" disabled={busy} title="Detalhes do perfil" aria-expanded={expandedProfileId === status.profile.id} on:click|stopPropagation={() => toggleDetails(status.profile.id)}>{expandedProfileId === status.profile.id ? "⌃" : "⌄"}</button>
          </div>
          {#if expandedProfileId === status.profile.id}
            <div class="profile-details">
              <p><strong>App</strong><span>{status.profile.browser_command ?? "Chrome/Chromium automático"}</span></p>
              <p><strong>Perfil</strong><span>{status.profile.user_data_dir}/{status.profile.profile_directory}</span></p>
              <p><strong>Status</strong><span>{status.message}</span></p>
            </div>
          {/if}
        </article>
      {/each}

      <article class="chrome-row">
        <button class="profile-main" disabled={busy} on:click={selectNormalBrowser}>
          <img class="chrome-icon" src={chromeIcon} alt="" />
          <div class="profile-copy"><h2>Google Chrome</h2><p>perfil normal, sem CDP</p></div>
        </button>
      </article>
    </section>

    <footer>
      <strong title={mcpStatus.message}>MCP RAM · {mcpMemorySummary()}</strong>
      <div class="footer-actions">
        <button class="round-button" on:click={refresh} disabled={busy} title="Atualizar">↻</button>
        <button class="round-button" on:click={openSettings} disabled={busy} title="Configurações">⚙</button>
        <button class="round-button" on:click={closeAllControlledBrowsers} disabled={busy} title="Fechar navegadores controlados">×</button>
      </div>
    </footer>

    {#if message !== "Pronto."}
      <p class:bad={message.toLowerCase().includes("falha") || message.toLowerCase().includes("erro") || message.toLowerCase().includes("travado")} class="message">{message}</p>
    {/if}
  </main>
{/if}
