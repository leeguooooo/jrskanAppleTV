// leeguoo sports web: static UI (assets) + the data API the apps compute on
// device. Every /api route requires a signed-in leeguoo account; upstream URLs
// only come back in as links this Worker signed, so it is not a general proxy.
//
// Cost (Workers Paid, no KV/D1): one request per poll. A watching viewer makes
// ~2 req/min (events every 30 s) plus one per channel switch; the schedule,
// events, channel pages and resolved streams are shared via caches.default, so
// upstream load does not grow with viewers. QuickJS only runs on cache misses
// of /api/resolve (a few ms CPU each).
// The specifier must end in .wasm for wrangler to load it as CompiledWasm.
import wasmModule from "../node_modules/@jitl/quickjs-wasmfile-release-sync/dist/emscripten-module.wasm";
import { handleAuth, handleMe, readSession, signLink, verifyLink, type Env } from "./auth";
import { configureEgress } from "./egress";
import { handleSportsProxy } from "./sports";
import { fetchChannels, fetchEvents, fetchSchedule, resolveStream, setQuickJSWasm } from "./upstream";
import type { LiveMatch, MatchSource } from "../src/core/models";
import { StreamResolverError } from "../src/core/resolver";

setQuickJSWasm(wasmModule as WebAssembly.Module);

const SCHEDULE_TTL = 60;
const EVENTS_TTL = 10;
const CHANNELS_TTL = 60;
const RESOLVE_TTL = 30;

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "private, no-store", ...extra },
  });
}

function failure(message: string, status = 502, code?: string): Response {
  return json({ error: code ?? "upstream", message }, status);
}

// Some dependency typings pull in lib.dom, whose CacheStorage lacks Workers' `default`.
const edgeCache = (caches as unknown as { default: Cache }).default;

/// Shared edge cache keyed on an internal URL. Only successful values are stored.
async function cached<T>(ctx: ExecutionContext, key: string, ttl: number, build: () => Promise<T>, fresh = false): Promise<T> {
  const cacheKey = new Request(`https://cache.internal/${key}`);
  if (!fresh) {
    const hit = await edgeCache.match(cacheKey);
    if (hit) return hit.json() as Promise<T>;
  }
  const value = await build();
  ctx.waitUntil(edgeCache.put(cacheKey, new Response(JSON.stringify(value), { headers: { "cache-control": `public, max-age=${ttl}` } })));
  return value;
}

interface CachedSchedule {
  matches: LiveMatch[];
  /** Stays server-side; /api/events reads it from this entry. */
  eventURL?: string;
  fetchedAt: number;
}

function schedule(env: Env, ctx: ExecutionContext): Promise<CachedSchedule> {
  return cached(ctx, "schedule", SCHEDULE_TTL, async () => {
    const fetched = await fetchSchedule();
    const matches = await Promise.all(fetched.matches.map(async (m) => ({ ...m, sources: await signSources(env, m.sources) })));
    return { matches, eventURL: fetched.eventURL, fetchedAt: Date.now() };
  });
}

async function signSources(env: Env, sources: MatchSource[]): Promise<MatchSource[]> {
  return Promise.all(sources.map(async (s) => ({ ...s, sig: await signLink(env.SESSION_SECRET, s.pageURL) })));
}

async function api(request: Request, env: Env, ctx: ExecutionContext, url: URL): Promise<Response> {
  const session = await readSession(request, env);
  if (!session) return json({ error: "signed_out", message: "请先登录 leeguoo 账号。" }, 401);
  if (url.pathname === "/api/me") return handleMe(request, env, session);
  if (request.method !== "GET") return json({ error: "method" }, 405, { allow: "GET" });

  switch (url.pathname) {
    case "/api/schedule":
      try {
        const { matches, eventURL, fetchedAt } = await schedule(env, ctx);
        return json({ matches, hasEvents: !!eventURL, fetchedAt });
      } catch (error) {
        return failure(error instanceof Error ? error.message : "目标站点返回了无效响应。");
      }
    case "/api/events":
      try {
        const { eventURL } = await schedule(env, ctx);
        if (!eventURL) return failure("比分暂不可用", 503, "no_events");
        return json(await cached(ctx, "events", EVENTS_TTL, () => fetchEvents(eventURL)));
      } catch (error) {
        return failure(error instanceof Error ? error.message : "比分暂不可用");
      }
    case "/api/channels": {
      const target = url.searchParams.get("url") ?? "";
      if (!(await verifyLink(env.SESSION_SECRET, target, url.searchParams.get("sig")))) return json({ error: "bad_link" }, 400);
      try {
        return json(await cached(ctx, `channels?${encodeURIComponent(target)}`, CHANNELS_TTL, async () => {
          const channels = await fetchChannels(target);
          if (!channels.length) throw new Error("这个入口没有找到可选择的具体频道。");
          return { channels: await signSources(env, channels) };
        }));
      } catch (error) {
        return failure(error instanceof Error ? error.message : "频道页面暂时无法访问。");
      }
    }
    case "/api/resolve": {
      const target = url.searchParams.get("url") ?? "";
      if (!(await verifyLink(env.SESSION_SECRET, target, url.searchParams.get("sig")))) return json({ error: "bad_link" }, 400);
      try {
        // `fresh=1` after a stall: the cached URL may be the one that just failed.
        return json(await cached(ctx, `resolve?${encodeURIComponent(target)}`, RESOLVE_TTL,
          async () => ({ url: await resolveStream(target), resolvedAt: Date.now() }), url.searchParams.get("fresh") === "1"));
      } catch (error) {
        if (error instanceof StreamResolverError) return failure(error.message, 502, error.code);
        return failure("线路页面暂时无法访问。", 502, "invalidResponse");
      }
    }
    case "/api/sports":
      return handleSportsProxy(request, ctx);
  }
  return json({ error: "not_found" }, 404);
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    configureEgress(env);
    const url = new URL(request.url);
    if (url.pathname.startsWith("/auth/")) return handleAuth(request, env, url);
    if (url.pathname.startsWith("/api/")) return api(request, env, ctx, url);
    return env.ASSETS.fetch(request);
  },
} satisfies ExportedHandler<Env>;
