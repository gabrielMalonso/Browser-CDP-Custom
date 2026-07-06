import { describe, expect, test } from "vitest";
import { validateLoopbackHost } from "../src/auth.js";

function response() {
  return {
    statusCode: 200,
    body: undefined as unknown,
    status(code: number) {
      this.statusCode = code;
      return this;
    },
    json(payload: unknown) {
      this.body = payload;
      return this;
    }
  };
}

describe("validateLoopbackHost", () => {
  test("accepts 127.0.0.1", () => {
    const res = response();
    let called = false;

    validateLoopbackHost(
      { headers: { host: "127.0.0.1:8787" } } as never,
      res as never,
      (() => {
        called = true;
      }) as never
    );

    expect(called).toBe(true);
    expect(res.statusCode).toBe(200);
  });

  test("rejects non-loopback hosts", () => {
    const res = response();
    let called = false;

    validateLoopbackHost(
      { headers: { host: "example.com" } } as never,
      res as never,
      (() => {
        called = true;
      }) as never
    );

    expect(called).toBe(false);
    expect(res.statusCode).toBe(403);
    expect(res.body).toEqual({ error: "host_not_allowed" });
  });
});
