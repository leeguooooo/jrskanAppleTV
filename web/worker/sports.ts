// GET /api/sports?url=<upstream> — read-only proxy for the sports insights
// (statistics + comments). Only the exact public endpoints the Apple/Android
// clients call are allowed, with the same UA/Referer they send. No cookies or
// credentials are forwarded either way. Mounted behind the session check.
import { catalogRows, compactCatalog } from "../src/sports/multi";
import { EgressError, egressFetch, type EgressResponse } from "./egress";

const USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
  + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15";
const TENCENT_REFERER = "https://sports.qq.com/";
const TIMEOUT_MS = 10_000;
const MB = 1024 * 1024;

interface Rule {
  host: string;
  path: RegExp;
  /** Allowed query keys → value pattern. Every listed key is required unless marked optional. */
  query: Record<string, { pattern: RegExp; optional?: boolean }>;
  referer?: string;
  /** Edge cache TTL in seconds. */
  ttl: number;
  maxBytes: number;
  /** Add a fresh `_t` cache-buster upstream, as the apps do for Tencent. */
  stamp?: boolean;
  /** Reduce the 1–1.5 MB Migu schedule page to the rows the client matches on. */
  compactCatalog?: boolean;
}

const TENCENT_MID = /^10000[08]:[0-9]{10,12}$/;
const STAMP = { pattern: /^[0-9]{1,16}$/, optional: true };

export const SPORTS_RULES: Rule[] = [
  { host: "matchweb.sports.qq.com", path: /^\/kbs\/matchDetail$/, query: { mid: { pattern: TENCENT_MID }, _t: STAMP },
    referer: TENCENT_REFERER, ttl: 300, maxBytes: 2 * MB, stamp: true },
  { host: "matchweb.sports.qq.com", path: /^\/kbs\/matchStat$/, query: { mid: { pattern: TENCENT_MID }, _t: STAMP },
    referer: TENCENT_REFERER, ttl: 10, maxBytes: 2 * MB, stamp: true },
  { host: "app.sports.qq.com", path: /^\/dmComment\/liveList$/,
    query: { mid: { pattern: TENCENT_MID }, topN: { pattern: /^20$/ }, commentId: { pattern: /^0$/ }, _t: STAMP },
    referer: TENCENT_REFERER, ttl: 8, maxBytes: 2 * MB, stamp: true },
  { host: "www.miguvideo.com", path: /^\/p\/home\/(?:3cd6ba04967742879aaa40bee02a99a6|494d21a4d6ee453b8b86bd3bb7658ed6)$/,
    query: {}, ttl: 300, maxBytes: 4 * MB, compactCatalog: true },
  { host: "v0-sc.miguvideo.com", path: /^\/oes-sport-static\/10\/live\/statistics\/[0-9]{12}$/,
    query: {}, ttl: 10, maxBytes: 4 * MB },
  { host: "webapi.miguvideo.com", path: /^\/gateway\/interaction\/v2\/comment\/1\/20\/[0-9]{12}\/40\/NEW$/,
    query: { clientType: { pattern: /^1$/ } }, ttl: 8, maxBytes: 4 * MB },
  { host: "site.api.espn.com", path: /^\/apis\/site\/v2\/sports\/basketball\/nba\/scoreboard$/,
    query: { dates: { pattern: /^[0-9]{8}$/ } }, ttl: 300, maxBytes: 4 * MB },
  { host: "site.api.espn.com", path: /^\/apis\/site\/v2\/sports\/basketball\/nba\/summary$/,
    query: { event: { pattern: /^[0-9]{1,12}$/ } }, ttl: 10, maxBytes: 4 * MB },
];

export interface AllowedTarget {
  rule: Rule;
  /** Canonical upstream URL without `_t` — also the cache key. */
  canonical: string;
}

/** Strict allowlist check. Returns undefined for anything not exactly allowed. */
export function allowSportsURL(raw: string | null): AllowedTarget | undefined {
  if (!raw || raw.length > 2048) return undefined;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return undefined;
  }
  if (url.protocol !== "https:" || url.username || url.password || url.port || url.hash) return undefined;
  const rule = SPORTS_RULES.find((r) => r.host === url.hostname && r.path.test(url.pathname));
  if (!rule) return undefined;
  const keys = [...url.searchParams.keys()];
  if (new Set(keys).size !== keys.length) return undefined; // no repeated keys
  for (const key of keys) {
    const spec = rule.query[key];
    if (!spec || !spec.pattern.test(url.searchParams.get(key) ?? "")) return undefined;
  }
  for (const [key, spec] of Object.entries(rule.query)) {
    if (!spec.optional && !url.searchParams.has(key)) return undefined;
  }
  const params = new URLSearchParams();
  for (const key of keys.filter((k) => k !== "_t").sort()) params.set(key, url.searchParams.get(key) as string);
  const query = params.toString();
  return { rule, canonical: `https://${rule.host}${url.pathname}${query ? `?${query}` : ""}` };
}

function upstreamURL(target: AllowedTarget, now: number): string {
  if (!target.rule.stamp) return target.canonical;
  const url = new URL(target.canonical);
  url.searchParams.set("_t", String(now));
  url.searchParams.sort();
  return url.toString();
}

function reply(body: BodyInit | null, status: number, contentType = "text/plain; charset=utf-8"): Response {
  return new Response(body, {
    status,
    headers: { "content-type": contentType, "cache-control": "private, no-store", "x-content-type-options": "nosniff" },
  });
}

function edgeCache(): Cache | undefined {
  try {
    return (globalThis as unknown as { caches?: { default?: Cache } }).caches?.default;
  } catch {
    return undefined;
  }
}

/** The part of ExecutionContext used here (structural, so tests type-check without workers-types). */
export interface SportsProxyContext {
  waitUntil(promise: Promise<unknown>): void;
}

export async function handleSportsProxy(request: Request, ctx: SportsProxyContext): Promise<Response> {
  if (request.method !== "GET") return reply("method not allowed", 405);
  const target = allowSportsURL(new URL(request.url).searchParams.get("url"));
  if (!target) return reply("url not allowed", 400);

  const cache = edgeCache();
  const cacheKey = new Request(`${new URL(request.url).origin}/__sports_cache/${encodeURIComponent(target.canonical)}`);
  if (cache) {
    try {
      const hit = await cache.match(cacheKey);
      if (hit) return reply(hit.body, 200, hit.headers.get("content-type") ?? undefined);
    } catch { /* cache is an optimisation only */ }
  }

  let upstream: EgressResponse;
  try {
    // Through the egress relay so Tencent/Migu/ESPN never see this Worker (see egress.ts).
    upstream = await egressFetch(upstreamURL(target, Date.now()), {
      headers: {
        "user-agent": USER_AGENT,
        accept: "application/json, text/html;q=0.9, */*;q=0.8",
        ...(target.rule.referer ? { referer: target.rule.referer } : {}),
      },
      // An allowlisted host must not bounce the proxy somewhere else.
      redirect: "manual",
      timeoutMs: TIMEOUT_MS,
      maxBytes: target.rule.maxBytes,
    });
  } catch (error) {
    if (error instanceof EgressError && error.code === "too_large") return reply("upstream body too large", 502);
    const timeout = error instanceof EgressError && error.code === "timeout";
    return reply(timeout ? "upstream timeout" : "upstream unavailable", timeout ? 504 : 502);
  }
  if (upstream.status !== 200) return reply(`upstream ${upstream.status}`, 502);

  const bytes = new Uint8Array(upstream.body);
  let body: Uint8Array<ArrayBuffer> | string = bytes;
  let contentType = upstream.contentType || "text/plain; charset=utf-8";
  if (target.rule.compactCatalog) {
    body = compactCatalog(catalogRows(new TextDecoder("utf-8").decode(bytes)));
    contentType = "text/html; charset=utf-8";
  }

  if (cache) {
    const stored = new Response(body, {
      headers: { "content-type": contentType, "cache-control": `public, max-age=${target.rule.ttl}` },
    });
    ctx.waitUntil(cache.put(cacheKey, stored).catch(() => undefined));
  }
  return reply(body, 200, contentType);
}
