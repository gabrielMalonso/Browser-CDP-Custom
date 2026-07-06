import net from "node:net";
import { GatewayError } from "./errors.js";

export async function isPortOpen(port: number) {
  return new Promise<boolean>((resolve) => {
    const socket = net.connect({ host: "127.0.0.1", port });
    socket.setTimeout(600);
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("timeout", () => {
      socket.destroy();
      resolve(false);
    });
    socket.once("error", () => resolve(false));
  });
}

export async function cdpVersion(port: number) {
  const response = await fetch(`http://127.0.0.1:${port}/json/version`, {
    signal: AbortSignal.timeout(2_000)
  });

  if (!response.ok) {
    throw new GatewayError(`CDP retornou HTTP ${response.status} na porta ${port}`, 502);
  }

  return (await response.json()) as Record<string, unknown>;
}

export async function waitForCdp(port: number) {
  const deadline = Date.now() + 30_000;
  let lastError: unknown;

  while (Date.now() < deadline) {
    try {
      await cdpVersion(port);
      return;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }

  throw new GatewayError(
    `CDP não ficou disponível em http://127.0.0.1:${port}: ${lastError instanceof Error ? lastError.message : String(lastError)}`,
    504
  );
}
