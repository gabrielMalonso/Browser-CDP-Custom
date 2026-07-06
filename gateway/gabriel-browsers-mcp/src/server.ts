import express from "express";
import { createMcpExpressApp } from "@modelcontextprotocol/sdk/server/express.js";
import { validateLoopbackHost, requireBearerToken } from "./auth.js";
import type { GatewayConfig } from "./config.js";
import type { ProfileRegistry } from "./profileRegistry.js";
import { errorMessage, GatewayError } from "./errors.js";
import { handleMcpRequest } from "./mcpProxy.js";
import type { WorkerManager } from "./workerManager.js";
import { loadToolCache } from "./toolCache.js";

export function createGatewayApp(input: {
  gatewayConfig: GatewayConfig;
  registry: ProfileRegistry;
  workers: WorkerManager;
}) {
  const app = createMcpExpressApp();
  const requireAuth = requireBearerToken(input.gatewayConfig.token);

  app.use(validateLoopbackHost);

  app.get("/health", (_req, res) => {
    res.json({
      ok: true,
      version: "0.1.0",
      profiles: input.registry.metadata(),
      toolCache: {
        generatedAt: loadToolCache().generatedAt,
        playwrightMcpVersion: loadToolCache().playwrightMcpVersion,
        count: loadToolCache().tools.length
      },
      workers: input.workers.snapshots().length
    });
  });

  app.get("/workers", requireAuth, (_req, res) => {
    res.json({ workers: input.workers.snapshots() });
  });

  app.post("/release", requireAuth, express.json(), async (req, res, next) => {
    try {
      const profile = typeof req.body?.profile === "string" ? input.registry.get(req.body.profile) : null;
      if (!profile) {
        throw new GatewayError("campo profile é obrigatório", 400);
      }

      const released = await input.workers.release(profile.id);
      res.json({ profile: profile.id, released });
    } catch (error) {
      next(error);
    }
  });

  app.post("/mcp", requireAuth, async (req, res, next) => {
    try {
      await handleMcpRequest({
        req,
        res,
        mode: { kind: "unified" },
        registry: input.registry,
        workers: input.workers
      });
    } catch (error) {
      next(error);
    }
  });

  for (const alias of input.registry.aliases) {
    app.post(`/${alias.pathSegment}/mcp`, requireAuth, async (req, res, next) => {
      try {
        await handleMcpRequest({
          req,
          res,
          mode: {
            kind: "alias",
            profile: input.registry.get(alias.profileId)
          },
          registry: input.registry,
          workers: input.workers
        });
      } catch (error) {
        next(error);
      }
    });
  }

  app.get(["/mcp", "/:profile/mcp"], (_req, res) => {
    res.status(405).set("Allow", "POST").send("Method Not Allowed");
  });

  app.delete(["/mcp", "/:profile/mcp"], (_req, res) => {
    res.status(405).set("Allow", "POST").send("Method Not Allowed");
  });

  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    const statusCode = error instanceof GatewayError ? error.statusCode : 500;
    res.status(statusCode).json({
      error: errorMessage(error)
    });
  });

  return app;
}
