// Egress relay for leeguoo sports. Runs on a plain VM (Tencent Cloud, Shanghai)
// so upstream sites see only this machine — no Cf-Worker header naming our zone,
// no Origin, no Referer of ours. Only the Worker, holding RELAY_SECRET, can use it.
//
//   RELAY_SECRET=… PORT=18080 node relay.mjs   (reached through cloudflared, see cloudflared.yml)
//
// It refuses private, loopback, link-local and cloud-metadata destinations
// (checked on the resolved address, every redirect hop), sends only the headers
// the Worker names, and caps time and size. Node 22+, no dependencies.
import { lookup as dnsLookup } from "node:dns";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import zlib from "node:zlib";
import { MAX_SKEW_MS, open, seal } from "./protocol.mjs";

const SECRET = process.env.RELAY_SECRET;
const PORT = Number(process.env.PORT || 18080);
// Behind cloudflared on the same machine: listen on loopback only.
const HOST = process.env.HOST || "127.0.0.1";
if (!SECRET || SECRET.length < 32) {
  console.error("RELAY_SECRET (32+ chars) is required");
  process.exit(1);
}

const ALLOWED_HEADERS = new Set(["user-agent", "referer", "accept", "accept-language"]);
const MAX_REQUEST = 64 * 1024;
const HARD_MAX_BYTES = 8 * 1024 * 1024;
const seen = new Map(); // nonce -> expiry

function blockedAddress(address) {
  if (net.isIPv4(address)) {
    const [a, b] = address.split(".").map(Number);
    return a === 0 || a === 10 || a === 127 || a >= 224
      || (a === 100 && b >= 64 && b <= 127) // CGNAT
      || (a === 169 && b === 254) // link-local, metadata
      || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168)
      || (a === 198 && (b === 18 || b === 19));
  }
  const v6 = address.toLowerCase();
  if (v6.startsWith("::ffff:")) return blockedAddress(v6.slice(7));
  return v6 === "::" || v6 === "::1" || v6.startsWith("fc") || v6.startsWith("fd") || v6.startsWith("fe8")
    || v6.startsWith("fe9") || v6.startsWith("fea") || v6.startsWith("feb") || v6.startsWith("ff");
}

// Resolve, then refuse internal targets. Used as the socket's lookup so the
// checked address is the one actually connected to (no DNS rebinding gap).
// Node's happy-eyeballs connect asks for `all: true` and expects an array back.
function guardedLookup(hostname, options, callback) {
  dnsLookup(hostname, { ...options, all: true }, (error, addresses) => {
    if (error) return callback(error);
    const allowed = addresses.filter((entry) => !blockedAddress(entry.address));
    if (!allowed.length || allowed.length !== addresses.length) {
      return callback(Object.assign(new Error("blocked destination"), { code: "EBLOCKED" }));
    }
    if (options.all) return callback(null, allowed);
    callback(null, allowed[0].address, allowed[0].family);
  });
}

function fetchOnce(target, headers, timeoutMs, maxBytes) {
  return new Promise((resolve, reject) => {
    const client = target.protocol === "https:" ? https : http;
    if (net.isIP(target.hostname) && blockedAddress(target.hostname)) return reject(new Error("blocked destination"));
    const request = client.request(target, {
      method: "GET",
      headers: { ...headers, "accept-encoding": "gzip, deflate, br" },
      lookup: guardedLookup,
      timeout: timeoutMs,
    }, (response) => {
      const status = response.statusCode ?? 0;
      if (status >= 300 && status < 400 && response.headers.location) {
        response.resume();
        return resolve({ status, location: response.headers.location });
      }
      const encoding = String(response.headers["content-encoding"] || "").toLowerCase();
      let stream = response;
      if (encoding === "gzip" || encoding === "x-gzip") stream = response.pipe(zlib.createGunzip());
      else if (encoding === "deflate") stream = response.pipe(zlib.createInflate());
      else if (encoding === "br") stream = response.pipe(zlib.createBrotliDecompress());
      const chunks = [];
      let total = 0;
      stream.on("data", (chunk) => {
        total += chunk.length;
        if (total > maxBytes) {
          request.destroy();
          reject(Object.assign(new Error("too large"), { code: "ETOOLARGE" }));
          return;
        }
        chunks.push(chunk);
      });
      stream.on("end", () => resolve({ status, contentType: response.headers["content-type"] || "", body: Buffer.concat(chunks) }));
      stream.on("error", reject);
    });
    request.on("timeout", () => request.destroy(Object.assign(new Error("timeout"), { code: "ETIMEDOUT" })));
    request.on("error", reject);
    request.end();
  });
}

async function relayFetch({ url, headers = {}, redirect = "follow", timeoutMs = 20_000, maxBytes = 4 * 1024 * 1024 }) {
  const picked = {};
  for (const [name, value] of Object.entries(headers)) {
    if (ALLOWED_HEADERS.has(name.toLowerCase()) && typeof value === "string") picked[name.toLowerCase()] = value;
  }
  const deadline = Date.now() + Math.min(timeoutMs, 30_000);
  const cap = Math.min(maxBytes, HARD_MAX_BYTES);
  let target = new URL(url);
  for (let hop = 0; hop <= 5; hop++) {
    if ((target.protocol !== "http:" && target.protocol !== "https:") || target.username || target.password) {
      throw new Error("unsupported url");
    }
    const result = await fetchOnce(target, picked, Math.max(1000, deadline - Date.now()), cap);
    if (result.location === undefined) return { ...result, url: target.href };
    if (redirect === "manual") return { status: result.status, contentType: "", body: Buffer.alloc(0), url: target.href };
    target = new URL(result.location, target);
  }
  throw new Error("too many redirects");
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    request.on("data", (chunk) => {
      total += chunk.length;
      if (total > MAX_REQUEST) {
        reject(new Error("request too large"));
        request.destroy();
      } else chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

const server = http.createServer(async (request, response) => {
  // Anything that is not a well-formed, fresh, authenticated request gets a bare 404.
  const reject = () => { response.writeHead(404).end(); };
  if (request.method !== "POST" || request.url !== "/f") return reject();
  let message;
  try {
    const { header } = await open(SECRET, new Uint8Array(await readBody(request)));
    const now = Date.now();
    if (typeof header.ts !== "number" || Math.abs(now - header.ts) > MAX_SKEW_MS
      || typeof header.nonce !== "string" || seen.has(header.nonce)) return reject();
    seen.set(header.nonce, now + 2 * MAX_SKEW_MS);
    message = header;
  } catch {
    return reject();
  }
  let reply;
  let body = new Uint8Array(0);
  try {
    const result = await relayFetch(message);
    reply = { ok: true, status: result.status, url: result.url, contentType: result.contentType };
    body = result.body;
  } catch (error) {
    reply = { ok: false, error: error.code === "ETIMEDOUT" ? "timeout" : error.code === "ETOOLARGE" ? "too_large" : "unavailable" };
  }
  const sealed = await seal(SECRET, reply, body);
  response.writeHead(200, { "content-type": "application/octet-stream", "content-length": sealed.length }).end(sealed);
});

setInterval(() => {
  const now = Date.now();
  for (const [nonce, expiry] of seen) if (expiry < now) seen.delete(nonce);
}, 30_000).unref();

server.requestTimeout = 40_000;
server.listen(PORT, HOST, () => console.log(`relay listening on ${HOST}:${PORT}`));
