<script lang="ts">
  import { onMount } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import chromeIcon from "./assets/chrome-icon.png";

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

  type McpWorker = {
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

  type McpGatewayStatus = {
    healthy: boolean;
    workers: McpWorker[];
    message: string;
  };

  let statuses: ProfileStatus[] = [];
  let mcpStatus: McpGatewayStatus = {
    healthy: false,
    workers: [],
    message: "Gateway MCP indisponível."
  };
  let busy = false;
  let message = "Carregando perfis...";
  let expandedProfileId: string | null = null;

  const refresh = async () => {
    const [profileStatuses, gatewayStatus] = await Promise.all([
      invoke<ProfileStatus[]>("profiles"),
      invoke<McpGatewayStatus>("mcp_gateway_status").catch((error) => ({
        healthy: false,
        workers: [],
        message: String(error)
      }))
    ]);
    statuses = profileStatuses;
    mcpStatus = gatewayStatus;
    message = statuses.length > 0 ? "Pronto." : "Nenhum perfil configurado.";
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

  const launch = (profileId: string) =>
    run(() => invoke<string>("launch_profile", { profileId }));

  const openUrl = (profileId: string, url: string) =>
    run(() => invoke<string>("route_url", { profileId, url }));

  const openNormalChrome = () =>
    run(() => invoke<string>("open_normal_chrome"));

  const closeProfile = (profileId: string) =>
    run(() => invoke<string>("close_profile", { profileId }));

  const closeAllControlledBrowsers = () =>
    run(() => invoke<string>("close_all_controlled_browsers"));

  const releaseMcpWorker = (profileId: string) =>
    run(() => invoke<string>("release_mcp_worker", { profileId }));

  const closeWindow = () => getCurrentWindow().close();

  const toggleDetails = (profileId: string) => {
    expandedProfileId = expandedProfileId === profileId ? null : profileId;
  };

  const formatPort = (port: number) =>
    new Intl.NumberFormat("pt-BR").format(port);

  const rowState = (status: ProfileStatus) => {
    if (status.cdp_ok) return "CDP ativo";
    if (!status.profile_exists) return "perfil ausente";
    if (status.port_open) return "porta ocupada";
    return "offline";
  };

  const badgeClass = (id: string) => `badge badge-${id}`;

  const profileStatusLabel = (status: ProfileStatus) => {
    if (status.cdp_ok) return "Rodando";
    if (!status.profile_exists) return "Perfil ausente";
    if (status.port_open) return "Porta ocupada";
    return "Disponível";
  };

  const profileBrowserLabel = (profile: Profile) =>
    profile.browser_command ?? "Chrome/Chromium automático";

  const mcpWorkersForProfile = (profileId: string) =>
    mcpStatus.workers.filter((worker) => worker.profile === profileId);

  const mcpWorkerLabel = (profileId: string) => {
    const workers = mcpWorkersForProfile(profileId);
    if (workers.length === 0) return "Sem workers ativos";

    return workers
      .map((worker) => `PID ${worker.pid ?? "?"} · ${formatMemory(worker.residentMemoryKilobytes)}`)
      .join(", ");
  };

  const formatMemory = (kilobytes: number) => {
    const megabytes = (kilobytes * 1024) / 1_000_000;
    return `${new Intl.NumberFormat("pt-BR", { maximumFractionDigits: 1 }).format(megabytes)} MB`;
  };

  const mcpMemorySummary = () => {
    const totalKilobytes = mcpStatus.workers.reduce(
      (sum, worker) => sum + worker.residentMemoryKilobytes,
      0
    );
    return `${formatMemory(totalKilobytes)} · ${mcpStatus.workers.length} worker${mcpStatus.workers.length === 1 ? "" : "s"}`;
  };

  onMount(() => {
    refresh();

    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        closeWindow();
      }
    };

    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  });
</script>

<main data-tauri-drag-region>
  <header class="panel-header" data-tauri-drag-region>
    <div class="brand">
      <span class="brand-icon" aria-hidden="true">⌁</span>
      <h1>Custom CDP Browser</h1>
    </div>
    <span class="escape-hint">ESC para fechar</span>
  </header>

  <section class="profile-list" aria-label="Perfis CDP">
    {#each statuses as status}
      <article
        class:active={status.cdp_ok}
        class:missing={!status.profile_exists}
        class:expanded={expandedProfileId === status.profile.id}
      >
        <button
          class="profile-main"
          disabled={busy}
          title={status.message}
          on:click={() => launch(status.profile.id)}
        >
          <span class={badgeClass(status.profile.id)}>{status.profile.badge}</span>
          <div class="profile-copy">
            <h2>{status.profile.name} · porta {formatPort(status.profile.port)}</h2>
            <p>{rowState(status)}</p>
          </div>
        </button>
        <div class="row-actions">
          {#if status.profile.default_url}
            <button
              class="round-button"
              disabled={busy || !status.profile_exists}
              title="Abrir página padrão"
              on:click|stopPropagation={() => openUrl(status.profile.id, status.profile.default_url ?? "")}
            >↗</button>
          {/if}
          {#if status.cdp_ok}
            <button
              class="round-button"
              disabled={busy}
              title={`Fechar ${status.profile.name}`}
              on:click|stopPropagation={() => closeProfile(status.profile.id)}
            >×</button>
          {/if}
          {#if mcpWorkersForProfile(status.profile.id).length > 0}
            <button
              class="round-button"
              disabled={busy}
              title={`Liberar worker MCP de ${status.profile.name}`}
              on:click|stopPropagation={() => releaseMcpWorker(status.profile.id)}
            >⇥</button>
          {/if}
          <button
            class="round-button"
            disabled={busy}
            title={expandedProfileId === status.profile.id ? "Ocultar detalhes" : "Mostrar detalhes"}
            aria-expanded={expandedProfileId === status.profile.id}
            on:click|stopPropagation={() => toggleDetails(status.profile.id)}
          >{expandedProfileId === status.profile.id ? "⌃" : "⌄"}</button>
        </div>
        {#if expandedProfileId === status.profile.id}
          <div class="profile-details">
            <p><strong>Default</strong><span>{status.profile.default_url ?? "Sem URL padrão"}</span></p>
            <p><strong>App</strong><span>{profileBrowserLabel(status.profile)}</span></p>
            <p><strong>Perfil</strong><span>{status.profile.user_data_dir}/{status.profile.profile_directory}</span></p>
            <p><strong>Status</strong><span>{profileStatusLabel(status)} · {status.message}</span></p>
            <p><strong>MCP</strong><span>{mcpWorkerLabel(status.profile.id)}</span></p>
          </div>
        {/if}
      </article>
    {/each}

    <article class="chrome-row">
      <button class="profile-main" disabled={busy} on:click={openNormalChrome}>
        <img class="chrome-icon" src={chromeIcon} alt="" />
        <div class="profile-copy">
          <h2>Google Chrome</h2>
          <p>perfil normal</p>
        </div>
      </button>
      <div class="row-actions">
        <button class="round-button" disabled={busy} title="Abrir Chrome normal" on:click={openNormalChrome}>□</button>
      </div>
    </article>
  </section>

  <footer>
    <strong title={mcpStatus.message}>MCP RAM · {mcpMemorySummary()}</strong>
    <div class="footer-actions">
      <button class="round-button" on:click={refresh} disabled={busy} title="Atualizar">↻</button>
      <button class="round-button" disabled title="Configurações">⚙</button>
      <button class="round-button" on:click={closeAllControlledBrowsers} disabled={busy} title="Fechar navegadores controlados">×</button>
    </div>
  </footer>

  {#if message !== "Pronto."}
    <p class:bad={message.includes("erro") || message.includes("falhou") || message.includes("travado")} class="message">{message}</p>
  {/if}
</main>
