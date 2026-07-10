<script lang="ts">
  import { onMount } from "svelte";
  import { invoke } from "@tauri-apps/api/core";

  type Profile = { id: string; name: string };
  type Preferences = {
    link_routing_mode: "ask_every_time" | "default_destination" | "last_selected";
    default_destination_id: string;
    last_selected_destination_id: string | null;
    dismiss_overlay_after_selection: boolean;
  };
  type Snapshot = {
    preferences: Preferences;
    profiles: Profile[];
    currentDefaultBrowser: string;
    isSystemDefault: boolean;
    launchAtLogin: boolean;
    version: string;
  };

  let snapshot: Snapshot | null = null;
  let busy = false;
  let message = "";

  const refresh = async () => {
    snapshot = await invoke<Snapshot>("app_settings");
  };

  const run = async (action: () => Promise<string>, reload = false) => {
    busy = true;
    try {
      message = await action();
      if (reload) await refresh();
    } catch (error) {
      message = String(error);
    } finally {
      busy = false;
    }
  };

  const save = () => {
    if (!snapshot) return;
    run(() => invoke<string>("save_app_settings", { preferences: snapshot!.preferences }));
  };

  const toggleLaunchAtLogin = (event: Event) => {
    if (!snapshot) return;
    const enabled = (event.currentTarget as HTMLInputElement).checked;
    snapshot.launchAtLogin = enabled;
    run(() => invoke<string>("set_launch_at_login", { enabled }), true);
  };

  onMount(refresh);
</script>

<main class="settings-page">
  <header class="settings-header">
    <div><span class="eyebrow">UBUNTU</span><h1>Configurações</h1><p>Comportamento do overlay e dos links.</p></div>
    <button class="close-settings" title="Fechar" on:click={() => invoke("close_settings_window")}>×</button>
  </header>

  {#if snapshot}
    <section class="settings-section">
      <div class="section-heading"><h2>Overlay</h2><p>O launcher fica fora do caminho depois da escolha.</p></div>
      <label class="toggle-row">
        <span><strong>Ocultar após abrir</strong><small>O processo continua leve em segundo plano e reaparece ao abrir o app.</small></span>
        <input type="checkbox" bind:checked={snapshot.preferences.dismiss_overlay_after_selection} />
      </label>
      <label class="toggle-row">
        <span><strong>Iniciar com o Ubuntu</strong><small>Inicia oculto; não joga uma janela na sua cara ao fazer login.</small></span>
        <input type="checkbox" checked={snapshot.launchAtLogin} on:change={toggleLaunchAtLogin} />
      </label>
    </section>

    <section class="settings-section">
      <div class="section-heading"><h2>Links</h2><p>Primeiro o Ubuntu entrega o link ao app; depois esta regra escolhe o destino.</p></div>
      <label class="field-row">
        <span>Abrir links</span>
        <select bind:value={snapshot.preferences.link_routing_mode}>
          <option value="ask_every_time">Perguntar sempre</option>
          <option value="default_destination">Usar destino fixo</option>
          <option value="last_selected">Usar o último selecionado</option>
        </select>
      </label>
      <label class="field-row">
        <span>Destino fixo</span>
        <select bind:value={snapshot.preferences.default_destination_id}>
          {#each snapshot.profiles as profile}<option value={profile.id}>{profile.name}</option>{/each}
          <option value="normal-browser">Google Chrome normal</option>
        </select>
      </label>
      <div class="browser-status">
        <span class:status-ok={snapshot.isSystemDefault} class="status-dot"></span>
        <div><strong>{snapshot.isSystemDefault ? "Este app é o navegador padrão" : "Este app ainda não recebe os links"}</strong><small>Handler atual: {snapshot.currentDefaultBrowser}</small></div>
        <button disabled={busy || snapshot.isSystemDefault} on:click={() => run(() => invoke<string>("set_as_default_browser"), true)}>Definir como padrão</button>
      </div>
    </section>

    <section class="settings-section compact">
      <div class="section-heading"><h2>MCP</h2><p>Libera workers ociosos sem fechar os navegadores CDP.</p></div>
      <button class="secondary-button" disabled={busy} on:click={() => run(() => invoke<string>("release_all_mcp_workers"))}>Liberar workers agora</button>
    </section>

    <footer class="settings-footer">
      <div><span>Versão {snapshot.version}</span>{#if message}<strong>{message}</strong>{/if}</div>
      <div class="settings-actions">
        <button class="danger-button" disabled={busy} on:click={() => invoke("quit_application")}>Encerrar app</button>
        <button class="primary-button" disabled={busy} on:click={save}>Salvar</button>
      </div>
    </footer>
  {:else}
    <div class="settings-loading">Carregando configurações…</div>
  {/if}
</main>
