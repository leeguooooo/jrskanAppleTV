// Port of App/Sources/Shared/JRSListingParser.swift (JRSListingParser + SourcePageParser).
import type { LiveMatch, MatchSource } from "./models";

export class ListingParserError extends Error {
  constructor() {
    super("公开页面当前没有可识别的比赛，或者页面格式已经变化。");
  }
}

/** All capture groups of every match, like String.regexCaptures in Swift. */
export function captures(text: string, pattern: RegExp): string[][] {
  const flags = pattern.flags.includes("g") ? pattern.flags : pattern.flags + "g";
  return Array.from(text.matchAll(new RegExp(pattern.source, flags)), (m) => Array.from(m, (v) => v ?? ""));
}

export function cleanHTML(value: string): string {
  return value
    .replace(/<[^>]+>/g, "")
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&nbsp;", " ")
    .trim();
}

function firstText(text: string, pattern: RegExp): string {
  const value = captures(text, pattern)[0]?.[1];
  return value === undefined ? "" : cleanHTML(value);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function resolveURL(raw: string, base: string): string | undefined {
  try {
    return raw.startsWith("//") ? new URL(`https:${raw}`).href : new URL(raw, base).href;
  } catch {
    return undefined;
  }
}

/// Decodes the homepage's `window.PLAY_HOSTS = { line1: atob("…"), … }`
/// table into `{ line1: "http://play.example", … }`.
export function playHosts(homepage: string): Record<string, string> {
  const hosts: Record<string, string> = {};
  for (const [, line, encoded] of captures(homepage, /(\w+)\s*:\s*atob\(\s*["']([A-Za-z0-9+/=]+)["']\s*\)/s)) {
    try {
      const host = atob(encoded).trim();
      if (host) hosts[line] = host;
    } catch {
      // Not base64; ignore like the Swift parser does.
    }
  }
  return hosts;
}

export function listingScriptURL(homepage: string, homepageURL: string): string | undefined {
  const raw = captures(homepage, /<script[^>]+src="([^"]*index\.js[^"]*)"/is)[0]?.[1];
  return raw === undefined ? undefined : resolveURL(raw, homepageURL);
}

function decodeDocumentWrites(script: string): string {
  // `href="' + getPlayUrl("line1", "821720") + '"` splits one write into
  // two string literals with a call in between. Fold the call back into
  // the literal as a `getPlayUrl:line1:821720` token first.
  const folded = script.replace(
    /'\s*\+\s*getPlayUrl\(\s*["'](\w+)["']\s*,\s*["']([A-Za-z0-9_-]+)["']\s*\)\s*\+\s*'/g,
    "getPlayUrl:$1:$2",
  );
  return captures(folded, /document\.write\(\s*'((?:\\'|[^'])*)'\s*\)\s*;?/is)
    .map((c) => c[1])
    .map((v) => v.replaceAll("\\'", "'").replaceAll("\\/", "/"))
    .join("\n");
}

function attribute(name: string, attributes: string): string | undefined {
  const value = captures(attributes, new RegExp(`${escapeRegExp(name)}="([^"]*)"`))[0]?.[1];
  return value === undefined ? undefined : cleanHTML(value);
}

/// `getPlayUrl:line1:821720` → `<host>/play/steam821720.html`.
function generatedPlayURL(attributes: string, hosts: Record<string, string>): string | undefined {
  const match = captures(attributes, /getPlayUrl:(\w+):([A-Za-z0-9_-]+)/)[0];
  const host = match && hosts[match[1]];
  return host ? `${host}/play/steam${match[2]}.html` : undefined;
}

function parseSources(block: string, baseURL: string, matchID: string, hosts: Record<string, string>): MatchSource[] {
  const seen = new Set<string>();
  const sources: MatchSource[] = [];
  captures(block, /<a\s+([^>]*class="[^"]*\bok\b[^"]*"[^>]*)>(.*?)<\/a>/is).forEach(([, attributes, innerHTML], offset) => {
    const dataPlay = attribute("data-play", attributes);
    let href: string | undefined;
    if (attributes.includes("getPlayUrl:")) {
      // A generated link whose line has no host on the homepage is
      // the site's own dead entry; its `data-play` is just ".html".
      href = generatedPlayURL(attributes, hosts);
      if (!href) return;
    } else {
      href = attribute("href", attributes);
    }
    // The public link is the route that can be opened independently.
    const raw = [href, dataPlay].find(
      (v): v is string => !!v && !v.startsWith("javascript:") && !v.includes("getPlayUrl"),
    );
    const pageURL = raw && resolveURL(raw, baseURL);
    if (!pageURL || seen.has(pageURL)) return;
    seen.add(pageURL);
    const label = firstText(innerHTML, /<strong[^>]*>(.+?)<\/strong>/is);
    sources.push({ id: `${matchID}-${offset}-${pageURL}`, name: label || `线路 ${offset + 1}`, pageURL });
  });
  return sources;
}

/// The homepage no longer writes channel URLs into the listing. Each anchor
/// carries `getPlayUrl("line1", "821720")` and the hosts live in PLAY_HOSTS.
export function parseListing(script: string, baseURL: string, hosts: Record<string, string> = {}): LiveMatch[] {
  const html = decodeDocumentWrites(script);
  const matches: LiveMatch[] = [];
  for (const [, block, dataID] of captures(html, /(<ul\s+class="item\s+play[^"]*"[^>]*data-lid="([^"]+)"[^>]*>.*?<\/ul>)/is)) {
    const league = firstText(block, /<li\s+class="lab_events"[^>]*>.*?<span\s+class="name">(.+?)<\/span>/is);
    const time = firstText(block, /<li\s+class="lab_time"[^>]*>(.+?)<\/li>/is);
    const teams = captures(block, /<li\s+class="lab_team_(?:home|away)"[^>]*>.*?<strong\s+class="name">(.+?)<\/strong>.*?<img[^>]+src="([^"]*)"/is);
    if (teams.length < 2) continue;
    const homeTeam = cleanHTML(teams[0][1]);
    const awayTeam = cleanHTML(teams[1][1]);
    if (!league || !homeTeam || !awayTeam) continue;
    const logo = (raw: string) => {
      const value = cleanHTML(raw);
      return value ? resolveURL(value, baseURL) : undefined;
    };
    matches.push({
      id: dataID,
      league,
      time,
      homeTeam,
      awayTeam,
      homeLogoURL: logo(teams[0][2]),
      awayLogoURL: logo(teams[1][2]),
      isHot: /class="[^"]*\bhot\b/.test(block),
      sources: parseSources(block, baseURL, dataID, hosts),
    });
  }
  if (matches.length === 0) throw new ListingParserError();
  return matches;
}

/// Second-level channel buttons on a match source page. The homepage only
/// carries mirror entrances such as `直播①`; the commentary choices
/// (for example `中文高清 Q ⑤`) live here.
export function parseSourcePage(html: string, pageURL: string): MatchSource[] {
  const uncommented = html.replace(/<!--.*?-->/gs, "");
  const block = captures(uncommented, /<div\s+[^>]*class=["'][^"']*\bsub_channel\b[^"']*["'][^>]*>(.*?)<\/div>/is)[0]?.[1];
  const scope = block ?? uncommented;
  const attr = (name: string, attributes: string) => {
    const value = captures(attributes, new RegExp(`${escapeRegExp(name)}=["']([^"']*)["']`))[0]?.[1];
    return value === undefined ? undefined : cleanHTML(value);
  };
  const seen = new Set<string>();
  const channels: MatchSource[] = [];
  captures(scope, /<a\s+([^>]*class=["'][^"']*\bok\b[^"']*["'][^>]*)>(.*?)<\/a>/is).forEach(([, attributes, innerHTML], offset) => {
    // Placeholder anchors carry `data-play="=&id2="` — query fragments with no path.
    const raw = [attr("data-play", attributes), attr("href", attributes)].find(
      (v): v is string => !!v && !v.startsWith("=") && !v.startsWith("&") && !v.startsWith("javascript:"),
    );
    const resolved = raw && resolveURL(raw, pageURL);
    if (!resolved || seen.has(resolved)) return;
    seen.add(resolved);
    const label = cleanHTML(captures(innerHTML, /<strong[^>]*>(.+?)<\/strong>/is)[0]?.[1] ?? "");
    channels.push({ id: `channel-${offset}-${resolved}`, name: label || `频道 ${offset + 1}`, pageURL: resolved });
  });
  return channels;
}
