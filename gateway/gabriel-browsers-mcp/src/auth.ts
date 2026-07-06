import type { Request, Response, NextFunction } from "express";

export function validateLoopbackHost(req: Request, res: Response, next: NextFunction) {
  const rawHost = req.headers.host ?? "";
  const host = rawHost.split(":")[0]?.replace(/^\[(.*)\]$/, "$1");

  if (host !== "127.0.0.1") {
    res.status(403).json({ error: "host_not_allowed" });
    return;
  }

  next();
}

export function requireBearerToken(token: string | null) {
  return (req: Request, res: Response, next: NextFunction) => {
    if (!token) {
      res.status(503).json({ error: "gateway_token_missing" });
      return;
    }

    if (req.headers.authorization !== `Bearer ${token}`) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }

    next();
  };
}
