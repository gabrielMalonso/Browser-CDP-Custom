import { describe, expect, it } from "vitest";
import { hasBearerToken, isLoopbackHost } from "../src/auth.js";
import type { IncomingMessage } from "node:http";

describe("auth", () => {
  it("accepts only loopback host headers", () => {
    expect(isLoopbackHost("127.0.0.1:8787", 8787)).toBe(true);
    expect(isLoopbackHost("localhost:8787", 8787)).toBe(true);
    expect(isLoopbackHost("[::1]:8787", 8787)).toBe(true);
    expect(isLoopbackHost("example.com:8787", 8787)).toBe(false);
  });

  it("requires the bearer token exactly", () => {
    const request = { headers: { authorization: "Bearer secret" } } as IncomingMessage;
    expect(hasBearerToken(request, "secret")).toBe(true);
    expect(hasBearerToken(request, "other")).toBe(false);
  });
});
