import { DEFAULT_CONFIG, normalize } from "./config.js";

// GET /v1/<app>.json → the app's config from KV key "<app>", normalized.
//
// Cost: each response is cached at the edge for 60 s and in the isolate for
// 30 s, and the apps fetch at most every 10 minutes, so KV reads stay far
// inside the free allowance. An edit shows up within about two minutes
// (cache plus KV propagation).
const APPS = new Set(["jrkan"]);
const EDGE_TTL = 60;
const MEMO_TTL_MS = 30_000;
const memo = new Map();

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const match = /^\/v1\/([a-z0-9-]+)\.json$/.exec(url.pathname);
    if (!match || !APPS.has(match[1])) return new Response("not found", { status: 404 });
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("method not allowed", { status: 405, headers: { allow: "GET, HEAD" } });
    }

    const cacheKey = new Request(`${url.origin}${url.pathname}`);
    const cached = await caches.default.match(cacheKey);
    if (cached) return cached;

    const response = await build(match[1], env);
    ctx.waitUntil(caches.default.put(cacheKey, response.clone()));
    return response;
  },
};

async function build(app, env) {
  const hit = memo.get(app);
  let body;
  if (hit && Date.now() - hit.at < MEMO_TTL_MS) {
    body = hit.body;
  } else {
    let problems = [];
    let config = DEFAULT_CONFIG;
    const raw = await env.CONFIG.get(app);
    if (raw) {
      try {
        ({ config, problems } = normalize(JSON.parse(raw)));
      } catch {
        problems = ["stored value is not JSON; serving defaults"];
      }
    }
    if (problems.length) console.log(`config ${app}: ${problems.join("; ")}`);
    body = JSON.stringify(config);
    memo.set(app, { at: Date.now(), body });
  }
  return new Response(body, {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": `public, max-age=${EDGE_TTL}`,
      "access-control-allow-origin": "*",
    },
  });
}
