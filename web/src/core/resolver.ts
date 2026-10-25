// Port of App/Sources/Shared/StreamResolver.swift. Runs in the Worker: every
// upstream page is fetched server-side and the site's player scripts run in a
// fresh QuickJS context (the JSContext of the Apple apps, Rhino on Android),
// so the browser only ever receives a validated m3u8 URL.
import type { QuickJSWASMModule } from "quickjs-emscripten-core";
import { captures } from "./listing";

export type ResolverErrorCode = "noPlayableStream" | "invalidResponse" | "tooManyRedirects" | "unavailableStream";

const MESSAGES: Record<ResolverErrorCode, string> = {
  noPlayableStream: "这条线路暂未提供可播放的视频。",
  invalidResponse: "线路页面暂时无法访问。",
  tooManyRedirects: "线路嵌套层级异常，已停止继续解析。",
  unavailableStream: "视频源暂不可用或尚未开播，请尝试其他线路。",
};

export class StreamResolverError extends Error {
  constructor(readonly code: ResolverErrorCode) {
    super(MESSAGES[code]);
  }
}

export interface ResolverIO {
  /** GET a page or script with the given Referer; resolves to its text and final URL. */
  fetchPage(url: string, referer: string): Promise<{ text: string; url: string }>;
  /** GET an m3u8 without Referer; resolves to its text and final URL, or rejects. */
  fetchPlaylist(url: string): Promise<{ text: string; url: string }>;
  /** A fresh QuickJS module instance per call; each sandbox run consumes one. */
  quickJS(): Promise<QuickJSWASMModule>;
}

export const DEFAULT_HOMEPAGE = "https://www.jrs03.com/";

function decodeHTMLEntities(value: string): string {
  return value
    .replaceAll("\\/", "/")
    .replace(/\\u0026/gi, "&")
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'");
}

function makeURL(raw: string, pageURL: string): string | undefined {
  const cleaned = raw.replaceAll("\\/", "/").replaceAll("&amp;", "&").trim();
  try {
    const url = cleaned.startsWith("//") ? new URL(`https:${cleaned}`) : new URL(cleaned, pageURL);
    return url.protocol === "http:" || url.protocol === "https:" ? url.href : undefined;
  } catch {
    return undefined;
  }
}

export function isM3U8URL(url: string): boolean {
  try {
    return new URL(url).pathname.toLowerCase().endsWith(".m3u8");
  } catch {
    return false;
  }
}

function hasMediaEntries(text: string): boolean {
  return text.includes("#EXTINF:") || text.includes("#EXT-X-STREAM-INF:") || text.includes("#EXT-X-PART:");
}

/** Raw (still percent-encoded) query of a URL, without the "?". */
function rawQuery(url: string): string | undefined {
  const index = url.indexOf("?");
  if (index < 0) return undefined;
  const hash = url.indexOf("#", index);
  return url.slice(index + 1, hash < 0 ? undefined : hash);
}

function safeDecode(value: string): string | undefined {
  try {
    return decodeURIComponent(value);
  } catch {
    return undefined;
  }
}

/// The msss wrapper reverses the second-level domain in its `id` value.
/// Match that specific player contract rather than treating every wrapper
/// query containing .m3u8 as media.
function restoredPlayerURL(html: string, pageURL: string): string | undefined {
  if (!/\brestoreStreamUrl\s*\(\s*id\s*\)/.test(html)) return undefined;
  if (!/\.split\(\s*["']["']\s*\)\s*\.reverse\(\s*\)\s*\.join\(\s*["']["']\s*\)/.test(html)) return undefined;
  const query = rawQuery(pageURL);
  const idMatch = query && /(?:^|&)id=/.exec(query);
  if (!query || !idMatch) return undefined;
  // J_get consumes the entire suffix, including unescaped '&' and '='
  // belonging to the media URL's signed query. Decode it exactly once.
  const rawValue = query.slice(idMatch.index + idMatch[0].length);
  const value = safeDecode(rawValue) ?? rawValue;
  const lower = value.toLowerCase();
  if (!(value.startsWith("//") || lower.startsWith("https://") || lower.startsWith("http://"))) return undefined;
  const resolved = makeURL(value, pageURL);
  if (!resolved || !isM3U8URL(resolved)) return undefined;
  const url = new URL(resolved);
  const labels = url.hostname.split(".");
  if (labels.length < 2 || labels.some((l) => !l)) return undefined;
  labels[labels.length - 2] = [...labels[labels.length - 2]].reverse().join("");
  url.hostname = labels.join(".");
  // The wrapper returns a protocol-relative URL even for an http input.
  url.protocol = "https:";
  return url.href;
}

export function extractM3U8URLs(html: string, pageURL: string): string[] {
  const decoded = decodeHTMLEntities(html);
  const restored = restoredPlayerURL(decoded, pageURL);
  if (restored) return [restored];
  const patterns = [
    /(?:src|file|url|m3u8Url)\s*[:=]\s*["']([^"'<>\s]+\.m3u8[^"'<>\s]*)["']/i,
    /(https?:\/\/[^"'<>\\\s]+\.m3u8[^"'<>\\\s]*)/i,
    /(\/\/[^"'<>\\\s]+\.m3u8[^"'<>\\\s]*)/i,
  ];
  const candidates: string[] = [];
  for (const pattern of patterns) {
    for (const c of captures(decoded, pattern)) {
      const url = makeURL(c[1], pageURL);
      if (url && isM3U8URL(url) && !candidates.includes(url)) candidates.push(url);
    }
  }
  if (candidates.length) return candidates;

  // Some player wrappers build the stream as a fixed host plus the
  // current page's `id` query value.
  const query = rawQuery(pageURL);
  const idMatch = query && /(?:^|&)id=/.exec(query);
  if (!query || !idMatch) return [];
  const streamPath = safeDecode(query.slice(idMatch.index + idMatch[0].length));
  if (!streamPath || !streamPath.toLowerCase().includes(".m3u8")) return [];
  const host = captures(decoded, /(?:const|let|var)\s+\w*[Uu]rl\s*=\s*["']((?:https?:)?\/\/[^"']+)["']\s*\+\s*id/is)[0]?.[1];
  const url = host && makeURL(host + streamPath, pageURL);
  return url ? [url] : [];
}

export function iframeURLs(html: string, pageURL: string): string[] {
  const decoded = decodeHTMLEntities(html);
  const urls = captures(decoded, /<iframe[^>]+src\s*=\s*["']([^"']+)["']/is)
    .map((c) => c[1])
    .filter((v) => !v.endsWith("/play/"))
    .map((v) => makeURL(v, pageURL))
    .filter((v): v is string => !!v);
  const buildsPlayerPath = /src\s*=\s*['"]\/play\/['"]\s*\+\s*id1\s*\+\s*['"]\.html/is.test(decoded);
  if (buildsPlayerPath) {
    const id = new URL(pageURL).searchParams.get("id");
    if (id && /^[A-Za-z0-9_-]+$/.test(id)) urls.push(new URL(`/play/${id}.html`, pageURL).href);
  }
  return [...new Set(urls)];
}

export const PLAYER_PRELUDE = String.raw`
var window = this, self = this;
var __frames = [], __requests = [];
var __b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var atob = function(value) {
  var s = String(value).replace(/[\t\n\f\r ]/g, '');
  if (s.length % 4 === 0) s = s.replace(/==?$/, '');
  if (s.length % 4 === 1 || /[^A-Za-z0-9+\/]/.test(s)) return null;
  var out = '', buffer = 0, bits = 0;
  for (var i = 0; i < s.length; i++) {
    buffer = (buffer << 6) | __b64.indexOf(s.charAt(i)); bits += 6;
    if (bits >= 8) { bits -= 8; out += String.fromCharCode((buffer >> bits) & 255); }
  }
  return out;
};
var btoa = function(value) {
  var s = String(value), out = '';
  for (var i = 0; i < s.length; i += 3) {
    var a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
    if (a > 255 || b > 255 || c > 255) return null;
    var n = (a << 16) | ((b || 0) << 8) | (c || 0);
    out += __b64.charAt(n >> 18) + __b64.charAt((n >> 12) & 63)
      + (i + 1 < s.length ? __b64.charAt((n >> 6) & 63) : '=')
      + (i + 2 < s.length ? __b64.charAt(n & 63) : '=');
  }
  return out;
};
var __container = {
  innerHTML: '', textContent: '',
  appendChild: function(node) { if (node.src) __frames.push(node.src); },
  replaceChildren: function(node) { this.appendChild(node); }
};
var document = {
  location: {href: __pageURL}, referrer: '', cookie: '',
  getElementById: function() { return __container; },
  createElement: function() { return {style:{}, setAttribute:function(k,v) {this[k]=v;}}; },
  write: function() {}
};
var navigator = {userAgent:'iPhone',maxTouchPoints:0};
var console = {log:function(){},error:function(){},warn:function(){},info:function(){},debug:function(){},exception:function(){},trace:function(){}};
var setTimeout=function(){return 0},setInterval=setTimeout,clearTimeout=function(){},clearInterval=clearTimeout;
var TextEncoder=function(){};
TextEncoder.prototype.encode=function(text){var s=unescape(encodeURIComponent(text));return Uint8Array.from(s,function(c){return c.charCodeAt(0);});};
var TextDecoder=function(){};
TextDecoder.prototype.decode=function(bytes){var s='';for(var i=0;i<bytes.length;i++) s+=String.fromCharCode(bytes[i]);return decodeURIComponent(escape(s));};
var crypto={getRandomValues:function(bytes){for(var i=0;i<bytes.length;i++) bytes[i]=Math.floor(Math.random()*256);return bytes;}};
var URLSearchParams=function(values){this.values=values;};
URLSearchParams.prototype.toString=function(){var v=this.values;return Object.keys(v).map(function(k){return encodeURIComponent(k)+'='+encodeURIComponent(v[k]);}).join('&');};
var URL=function(value){var m=/^(https?):\/\/([^\/?#]+)([^#]*)(#.*)?$/i.exec(value);if(!m)throw Error('Invalid URL');this.hostname=m[2];this.username='';this.password='';this.hash=m[4]||'';if(m[2].indexOf('@')>=0)this.username='invalid';};
// Only record requests here. The Worker validates and fetches the supported API.
// No AbortController: the page skips speculative media probes and selects its fallback URL.
var fetch=function(url){var i=__requests.length;__requests.push(String(url));if(i>=__responses.length)return new Promise(function(){});var data=JSON.parse(__responses[i]);return Promise.resolve({ok:true,status:200,json:function(){return Promise.resolve(data);}});};
`;

/** Evaluate snippets in one fresh, network-free QuickJS context and read back a JSON value.
 *  `QuickJS` must be a module instance of its own: it may be unusable afterwards. */
function runSandboxed(QuickJS: QuickJSWASMModule, globals: Record<string, unknown>, scripts: string[], readBack: string): unknown {
  const runtime = QuickJS.newRuntime();
  runtime.setMemoryLimit(32 * 1024 * 1024);
  const deadline = Date.now() + 3000;
  runtime.setInterruptHandler(() => Date.now() > deadline);
  const vm = runtime.newContext();
  try {
    const setup = Object.entries(globals)
      .map(([name, value]) => `var ${name} = ${JSON.stringify(value)};`)
      .join("\n");
    for (const code of [setup, ...scripts]) {
      const result = vm.evalCode(code);
      if (result.error) {
        result.error.dispose();
        return undefined;
      }
      result.value.dispose();
      // Like JSContext, a failing microtask does not fail the script that queued it.
      const jobs = runtime.executePendingJobs();
      if (jobs.error) jobs.error.dispose();
    }
    const result = vm.evalCode(`JSON.stringify(${readBack})`);
    if (result.error) {
      result.error.dispose();
      return undefined;
    }
    const text = vm.getString(result.value);
    result.value.dispose();
    return JSON.parse(text);
  } catch {
    return undefined;
  } finally {
    // A script left suspended (an async function awaiting the never-settling
    // fetch) makes QuickJS assert while freeing the runtime. That aborts only
    // this single-use module instance, so the abort is swallowed here.
    try {
      vm.dispose();
      runtime.dispose();
    } catch {
      // ignored, see above
    }
  }
}

export function playerScriptResult(
  QuickJS: QuickJSWASMModule, html: string, playerScript: string, pageURL: string, responses: string[] = [],
): { url?: string; requests: string[] } {
  if (new TextEncoder().encode(playerScript).length > 512_000) return { requests: [] };
  const encoded = captures(html, /var\s+encodedStr\s*=\s*["']([^"']+)["']/is)[0]?.[1];
  const config = captures(html, /playerUrlBase64\s*:\s*["']([^"']+)["']/is)[0]?.[1];
  const payload = captures(html, /["']en_str["']\s*:\s*["']([^"']+)["']/is)[0]?.[1];
  if (encoded === undefined && payload === undefined) return { requests: [] };
  const out = runSandboxed(
    QuickJS,
    {
      __pageURL: pageURL,
      __responses: responses,
      encodedStr: encoded ?? "",
      playerConfig: { playerUrlBase64: config ?? "" },
      playerData: { en_str: payload ?? "" },
    },
    [PLAYER_PRELUDE, playerScript],
    "{frames: __frames.map(String), written: String(__container.innerHTML || ''), requests: __requests}",
  ) as { frames: string[]; written: string; requests: string[] } | undefined;
  if (!out) return { requests: [] };
  const url = out.frames.map((f) => makeURL(f, pageURL)).find((v) => v) ?? iframeURLs(out.written, pageURL)[0];
  return { url, requests: out.requests };
}

export function evaluateEncryptedHLSURL(
  QuickJS: QuickJSWASMModule, libraryScript: string, pageScript: string, pageURL: string,
): string | undefined {
  const value = runSandboxed(QuickJS, { __pageURL: pageURL, __responses: [] }, [
    PLAYER_PRELUDE, libraryScript, pageScript,
  ], "String(decryptUrlWithExpiry(encryptedBase64Str))");
  return typeof value === "string" && isM3U8URL(value) ? value : undefined;
}

export class StreamResolver {
  constructor(private readonly io: ResolverIO, private readonly maximumDepth = 6) {}

  resolve(sourcePageURL: string): Promise<string> {
    return this.resolvePage(sourcePageURL, DEFAULT_HOMEPAGE, 0, new Set());
  }

  private async resolvePage(pageURL: string, referer: string, depth: number, visited: Set<string>): Promise<string> {
    if (depth > this.maximumDepth) throw new StreamResolverError("tooManyRedirects");
    if (isM3U8URL(pageURL)) return this.validateStream(pageURL);
    if (visited.has(pageURL)) throw new StreamResolverError("noPlayableStream");
    visited.add(pageURL);

    const page = await this.fetch(pageURL, referer);
    const html = page.text, effectiveURL = page.url;
    if (html.trim().startsWith("#EXTM3U")) {
      if (!hasMediaEntries(html)) throw new StreamResolverError("unavailableStream");
      return effectiveURL;
    }
    let lastError: unknown = new StreamResolverError("noPlayableStream");
    for (const streamURL of extractM3U8URLs(html, effectiveURL)) {
      try {
        return await this.validateStream(streamURL);
      } catch (error) {
        lastError = error;
      }
    }
    try {
      const streamURL = await this.encryptedHLSURL(html, effectiveURL);
      if (streamURL) return await this.validateStream(streamURL);
    } catch (error) {
      lastError = error;
    }

    const nested = iframeURLs(html, effectiveURL);
    try {
      const generated = await this.generatedIframeURL(html, effectiveURL);
      if (generated && !nested.includes(generated)) nested.push(generated);
    } catch (error) {
      lastError = error;
    }
    for (const iframeURL of nested) {
      try {
        return await this.resolvePage(iframeURL, effectiveURL, depth + 1, visited);
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError;
  }

  private async generatedIframeURL(html: string, pageURL: string): Promise<string | undefined> {
    const isDataPlayer = /["']en_str["']\s*:/.test(html);
    if (!html.includes("encodedStr") && !isDataPlayer) return undefined;
    const rawScript = captures(html, /<script[^>]+src\s*=\s*["']([^"']+)["']/is)
      .map((c) => c[1])
      .find((raw) => {
        const resolved = makeURL(raw, pageURL);
        if (!resolved) return false;
        const url = new URL(resolved);
        const last = url.pathname.split("/").pop() ?? "";
        return last === "pjs.js" || (isDataPlayer && url.hostname === "im-imgs-bucket.oss-accelerate.aliyuncs.com"
          && url.pathname.endsWith(".js") && last.length > 20);
      });
    const scriptURL = rawScript && makeURL(rawScript, pageURL);
    if (!scriptURL) return undefined;
    const script = (await this.fetch(scriptURL, pageURL)).text;
    const responses: string[] = [];
    for (let pass = 0; pass < 2; pass++) {
      const result = playerScriptResult(await this.io.quickJS(), html, script, pageURL, responses);
      if (result.url) return result.url;
      const request = result.requests[0];
      if (responses.length || !request) return undefined;
      let url: URL;
      try {
        url = new URL(request);
      } catch {
        return undefined;
      }
      if (url.protocol !== "https:" || url.hostname !== "infozb6.video.qq.com" || url.port
        || url.username || url.password || url.pathname !== "/cgi-bin/getliveinfo") return undefined;
      responses.push((await this.fetch(url.href, pageURL)).text);
    }
    return undefined;
  }

  private async encryptedHLSURL(html: string, pageURL: string): Promise<string | undefined> {
    if (!html.includes("decryptUrlWithExpiry")) return undefined;
    const pageScript = captures(html, /<script(?:\s[^>]*)?>(.*?)<\/script>/is)
      .map((c) => c[1])
      .find((s) => s.includes("decryptUrlWithExpiry"));
    const rawLibrary = captures(html, /<script[^>]+src\s*=\s*["']([^"']*index\.min\.js[^"']*)["']/is)[0]?.[1];
    const libraryURL = rawLibrary && makeURL(rawLibrary, pageURL);
    if (!libraryURL || !pageScript) return undefined;
    const library = (await this.fetch(libraryURL, pageURL)).text;
    return evaluateEncryptedHLSURL(await this.io.quickJS(), library, pageScript, pageURL);
  }

  private async fetch(url: string, referer: string) {
    try {
      return await this.io.fetchPage(url, referer);
    } catch (error) {
      if (error instanceof StreamResolverError) throw error;
      throw new StreamResolverError("invalidResponse");
    }
  }

  /// Reject an expired URL or HTML error page before opening a black player.
  private async validateStream(url: string): Promise<string> {
    try {
      const playlist = await this.io.fetchPlaylist(url);
      if (playlist.text.trim().startsWith("#EXTM3U") && hasMediaEntries(playlist.text)) return playlist.url;
    } catch {
      // Same outcome as an empty playlist.
    }
    throw new StreamResolverError("unavailableStream");
  }
}
