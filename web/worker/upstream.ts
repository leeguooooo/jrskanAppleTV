// Upstream access for the Worker: the jrs03 schedule, channel pages and the
// stream resolver. Every fetch sets the Safari UA (and Referer where the apps
// send one) the Apple and Android clients use.
import { createDecipheriv } from "node:crypto";
import { newQuickJSWASMModuleFromVariant, newVariant, type QuickJSWASMModule } from "quickjs-emscripten-core";
import RELEASE_SYNC from "@jitl/quickjs-wasmfile-release-sync";
import { applyEvents, eventConfigURL, eventFeedURL, parseEvents, type EventSnapshot } from "../src/core/events";
import { listingScriptURL, parseListing, parseSourcePage, playHosts } from "../src/core/listing";
import type { LiveMatch, MatchSource } from "../src/core/models";
import { DEFAULT_HOMEPAGE, StreamResolver, type ResolverIO } from "../src/core/resolver";

export const USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
  + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15";

export class UpstreamError extends Error {}

async function fetchText(url: string, init: { referer?: string; timeout?: number; okStatus?: (s: number) => boolean } = {}) {
  const response = await fetch(url, {
    headers: { "user-agent": USER_AGENT, ...(init.referer ? { referer: init.referer } : {}) },
    redirect: "follow",
    signal: AbortSignal.timeout(init.timeout ?? 20_000),
    cf: { cacheTtl: 0 },
  } as RequestInit);
  const ok = init.okStatus ?? ((s: number) => s >= 200 && s < 300);
  if (!ok(response.status)) throw new UpstreamError(`upstream ${response.status}`);
  const buffer = await response.arrayBuffer();
  if (buffer.byteLength > 4 * 1024 * 1024) throw new UpstreamError("upstream body too large");
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(buffer);
  } catch {
    text = new TextDecoder("latin1").decode(buffer);
  }
  return { text, url: response.url || url };
}

export function decryptECB(ciphertext: Uint8Array, key: Uint8Array): string {
  // ECB has no IV; workerd rejects `null` here, both runtimes accept an empty one.
  const decipher = createDecipheriv("aes-128-ecb", key, Buffer.alloc(0));
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
}

export interface Schedule {
  matches: LiveMatch[];
  eventURL?: string;
  /** PLAY_HOSTS origins: the only hosts a signed channel link may point to. */
  playOrigins: string[];
}

export async function fetchSchedule(homepageURL = DEFAULT_HOMEPAGE): Promise<Schedule> {
  const homepage = (await fetchText(homepageURL)).text;
  const scriptURL = listingScriptURL(homepage, homepageURL);
  if (!scriptURL) throw new UpstreamError("没有在首页找到比赛列表数据。");
  const hosts = playHosts(homepage);
  const script = (await fetchText(scriptURL)).text;
  const matches = parseListing(script, homepageURL, hosts);
  const playOrigins = Object.values(hosts).flatMap((h) => {
    try { return [new URL(h).origin]; } catch { return []; }
  });
  // index.js is only the initial list. The web page subsequently applies
  // the event snapshot configured by njs.js, including removing stale rows.
  let eventURL: string | undefined;
  try {
    const configURL = eventConfigURL(homepage, homepageURL);
    if (configURL) eventURL = eventFeedURL((await fetchText(configURL)).text, configURL);
  } catch {
    // A missing/broken event feed must not erase the schedule or invent
    // live/final status. The static list remains usable without badges.
  }
  return { matches, eventURL, playOrigins };
}

export async function fetchEvents(eventURL: string): Promise<EventSnapshot> {
  return parseEvents((await fetchText(eventURL)).text, decryptECB);
}

export { applyEvents };

export async function fetchChannels(sourcePageURL: string): Promise<MatchSource[]> {
  const page = await fetchText(sourcePageURL, { referer: DEFAULT_HOMEPAGE, okStatus: (s) => s >= 200 && s < 400 });
  return parseSourcePage(page.text, page.url);
}

let wasmModule: WebAssembly.Module | undefined;

/** The Worker passes the bundled CompiledWasm; Node tests let the variant load its own file. */
export function setQuickJSWasm(module: WebAssembly.Module) {
  wasmModule = module;
}

const io: ResolverIO = {
  fetchPage: (url, referer) => fetchText(url, { referer, okStatus: (s) => s >= 200 && s < 400 }),
  fetchPlaylist: (url) => fetchText(url, { timeout: 10_000 }),
  quickJS: (): Promise<QuickJSWASMModule> => newQuickJSWASMModuleFromVariant(
    wasmModule ? newVariant(RELEASE_SYNC, { wasmModule }) : RELEASE_SYNC,
  ),
};

export function resolveStream(sourcePageURL: string): Promise<string> {
  return new StreamResolver(io).resolve(sourcePageURL);
}
