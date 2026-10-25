// The egress relay: only sealed, fresh requests are served, internal targets are
// refused, and the Worker never falls back to a direct fetch.
import { spawn, type ChildProcess } from "node:child_process";
import http from "node:http";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { open, seal } from "../relay/protocol.mjs";
import { configureEgress, EgressError, egressFetch } from "../worker/egress";

const SECRET = "test-relay-secret-0123456789abcdef0123456789";
const PORT = 18000 + Math.floor(Math.random() * 1000);
const RELAY = `http://127.0.0.1:${PORT}/f`;
let relay: ChildProcess;
let target: http.Server;
let targetHits = 0;

beforeAll(async () => {
  target = http.createServer((_, res) => { targetHits += 1; res.end("internal"); }).listen(0);
  relay = spawn(process.execPath, [new URL("../relay/relay.mjs", import.meta.url).pathname], {
    env: { ...process.env, RELAY_SECRET: SECRET, PORT: String(PORT) },
    stdio: ["ignore", "pipe", "inherit"],
  });
  await new Promise<void>((resolve) => relay.stdout!.once("data", () => resolve()));
});

afterAll(() => {
  relay.kill();
  target.close();
});

async function post(body: Uint8Array<ArrayBuffer>) {
  return fetch(RELAY, { method: "POST", body });
}

describe("relay", () => {
  it("answers unauthenticated or malformed requests with a bare 404", async () => {
    expect((await fetch(RELAY.replace("/f", "/"))).status).toBe(404);
    expect((await post(new Uint8Array(new TextEncoder().encode("hello")))).status).toBe(404);
    const wrongKey = await seal("another-secret-0123456789abcdef0123456789", { ts: Date.now(), nonce: "a", url: "https://example.com/" });
    expect((await post(wrongKey)).status).toBe(404);
  });

  it("rejects stale requests and replays", async () => {
    const stale = await seal(SECRET, { ts: Date.now() - 5 * 60_000, nonce: "stale", url: "http://127.0.0.1/" });
    expect((await post(stale)).status).toBe(404);
    const once = await seal(SECRET, { ts: Date.now(), nonce: "replay-me", url: `http://127.0.0.1:${(target.address() as { port: number }).port}/` });
    expect((await post(once)).status).toBe(200);
    expect((await post(once)).status).toBe(404);
  });

  it("refuses loopback, private and metadata destinations without connecting", async () => {
    const port = (target.address() as { port: number }).port;
    for (const url of [`http://127.0.0.1:${port}/`, `http://localhost:${port}/`, "http://169.254.0.23/latest/meta-data/",
      "http://10.0.0.1/", "http://192.168.1.1/", "http://[::1]/"]) {
      const response = await post(await seal(SECRET, { ts: Date.now(), nonce: crypto.randomUUID(), url, timeoutMs: 2000 }));
      expect(response.status, url).toBe(200);
      const { header } = await open(SECRET, new Uint8Array(await response.arrayBuffer())) as { header: { ok: boolean } };
      expect(header.ok, url).toBe(false);
    }
    expect(targetHits).toBe(0);
  });

  it("the Worker refuses to fetch when no relay is configured", async () => {
    configureEgress({});
    await expect(egressFetch("https://www.jrs03.com/")).rejects.toBeInstanceOf(EgressError);
  });

  it("the Worker's sealed request round-trips through the relay", async () => {
    configureEgress({ RELAY_URL: RELAY, RELAY_SECRET: SECRET });
    // A blocked target still proves the full encrypt → relay → decrypt path.
    await expect(egressFetch("http://127.0.0.1:9/", { timeoutMs: 2000 })).rejects.toMatchObject({ code: "unavailable" });
  });
});
