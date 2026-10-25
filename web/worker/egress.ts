// Every request this Worker makes to a third party goes through here. A Worker
// subrequest always carries `Cf-Worker: <our zone>`, which would tell jrs03,
// the play hosts, Tencent, Migu and ESPN who is asking. So upstream fetches are
// handed, encrypted, to the egress relay on a plain VM (relay/relay.mjs) and go
// out from there with only the headers named below.
//
// Fails closed: with no relay configured it refuses to fetch rather than fall
// back to a direct request. `EGRESS=direct` is for local development only.
import { open, seal } from "../relay/protocol.mjs";

export interface EgressConfig {
  RELAY_URL?: string;
  RELAY_SECRET?: string;
  EGRESS?: string;
}

export interface EgressInit {
  headers?: Record<string, string>;
  redirect?: "follow" | "manual";
  timeoutMs?: number;
  maxBytes?: number;
}

export interface EgressResponse {
  status: number;
  url: string;
  contentType: string;
  body: Uint8Array;
}

export class EgressError extends Error {
  constructor(readonly code: "timeout" | "too_large" | "unavailable" | "not_configured") {
    super(`egress ${code}`);
  }
}

let config: EgressConfig = {};

export function configureEgress(env: EgressConfig) {
  config = env;
}

async function direct(url: string, init: EgressInit): Promise<EgressResponse> {
  const response = await fetch(url, {
    headers: init.headers,
    redirect: init.redirect ?? "follow",
    signal: AbortSignal.timeout(init.timeoutMs ?? 20_000),
  });
  const body = new Uint8Array(await response.arrayBuffer());
  if (body.length > (init.maxBytes ?? 4 * 1024 * 1024)) throw new EgressError("too_large");
  return { status: response.status, url: response.url || url, contentType: response.headers.get("content-type") ?? "", body };
}

export async function egressFetch(url: string, init: EgressInit = {}): Promise<EgressResponse> {
  if (config.EGRESS === "direct") return direct(url, init);
  if (!config.RELAY_URL || !config.RELAY_SECRET) throw new EgressError("not_configured");
  const timeoutMs = init.timeoutMs ?? 20_000;
  const request = await seal(config.RELAY_SECRET, {
    ts: Date.now(),
    nonce: crypto.randomUUID(),
    url,
    headers: init.headers ?? {},
    redirect: init.redirect ?? "follow",
    timeoutMs,
    maxBytes: init.maxBytes ?? 4 * 1024 * 1024,
  });
  let response: Response;
  try {
    response = await fetch(config.RELAY_URL, {
      method: "POST",
      body: request,
      headers: { "content-type": "application/octet-stream" },
      signal: AbortSignal.timeout(timeoutMs + 5_000),
    });
  } catch {
    throw new EgressError("unavailable");
  }
  if (!response.ok) throw new EgressError("unavailable");
  const { header, body } = await open(config.RELAY_SECRET, new Uint8Array(await response.arrayBuffer())) as {
    header: { ok: boolean; error?: EgressError["code"]; status: number; url: string; contentType: string };
    body: Uint8Array;
  };
  if (!header.ok) throw new EgressError(header.error ?? "unavailable");
  return { status: header.status, url: header.url, contentType: header.contentType ?? "", body };
}
