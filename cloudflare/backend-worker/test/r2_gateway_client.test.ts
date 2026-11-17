import { describe, expect, it } from "vitest";
import { gatewayBase } from "../src/r2_gateway_client.js";
import { ApiError } from "../src/errors.js";
import type { Env } from "../src/index.js";

const env = (gatewayUrl: string, local = true): Env => ({
  MEDIA_BUCKET: {} as R2Bucket,
  FIREBASE_PROJECT_ID: "demo-localspot",
  FIREBASE_PROJECT_NUMBER: "1",
  LOCAL_EMULATORS: local ? "true" : "false",
  R2_GATEWAY_URL: gatewayUrl,
});

describe("R2 gateway URL validation", () => {
  it("allows an RFC1918 HTTP gateway for a physical emulator device", () => {
    expect(gatewayBase(env("http://192.168.1.58:8787"))).toBe("http://192.168.1.58:8787");
    expect(gatewayBase(env("http://10.0.0.8:8787"))).toBe("http://10.0.0.8:8787");
    expect(gatewayBase(env("http://172.20.1.4:8787"))).toBe("http://172.20.1.4:8787");
  });

  it("keeps HTTP loopback available for local tests", () => {
    expect(gatewayBase(env("http://127.0.0.1:8787"))).toBe("http://127.0.0.1:8787");
    expect(gatewayBase(env("http://localhost:8787"))).toBe("http://localhost:8787");
  });

  it("requires HTTPS outside emulator mode and rejects public HTTP hosts", () => {
    for (const [url, local] of [["http://192.168.1.58:8787", false], ["http://203.0.113.10:8787", true]] as const) {
      expect(() => gatewayBase(env(url, local))).toThrow(ApiError);
    }
    expect(gatewayBase(env("https://gateway.example.test", false))).toBe("https://gateway.example.test");
  });

  it("rejects URL userinfo, paths, queries, and fragments", () => {
    for (const url of [
      "https://user:secret@gateway.example.test",
      "https://gateway.example.test/path",
      "https://gateway.example.test?bucket=other",
      "https://gateway.example.test#fragment",
    ]) {
      expect(() => gatewayBase(env(url, false))).toThrow(ApiError);
    }
  });
});
