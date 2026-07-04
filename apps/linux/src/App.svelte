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

  let statuses: ProfileStatus[] = [];
  let busy = false;
  let message = "Carregando perfis...";

  const refresh = async () => {
    statuses = await invoke<ProfileStatus[]>("profiles");
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

  const closeWindow = () => getCurrentWindow().close();

  const formatPort = (port: number) =>
    new Intl.NumberFormat("pt-BR").format(port);

  const rowState = (status: ProfileStatus) => {
    if (status.cdp_ok) return "CDP ativo";
    if (!status.profile_exists) return "perfil ausente";
    if (status.port_open) return "porta ocupada";
    return "offline";
  };

  const badgeClass = (id: string) => `badge badge-${id}`;

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
      <article class:active={status.cdp_ok} class:missing={!status.profile_exists}>
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
              on:click={() => openUrl(status.profile.id, status.profile.default_url ?? "")}
            >↗</button>
          {/if}
          <button
            class="round-button"
            disabled={busy}
            title={status.message}
            on:click={() => launch(status.profile.id)}
          >⌄</button>
        </div>
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
    <strong>MCP RAM · 0 MB</strong>
    <div class="footer-actions">
      <button class="round-button" on:click={refresh} disabled={busy} title="Atualizar">↻</button>
      <button class="round-button" disabled title="Configurações">⚙</button>
      <button class="round-button" on:click={closeWindow} title="Fechar janela">×</button>
    </div>
  </footer>

  {#if message !== "Pronto."}
    <p class:bad={message.includes("erro") || message.includes("falhou") || message.includes("travado")} class="message">{message}</p>
  {/if}
</main>
