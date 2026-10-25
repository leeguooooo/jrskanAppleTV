// Port of EventSnapshot in App/Sources/Shared/JRSClient.swift.
import { captures, resolveURL } from "./listing";
import { FEED_UTC_OFFSET_MS, type LiveMatch, type ProviderMatchState } from "./models";

export interface EventSnapshot {
  /** Keyed "<sport>,<id>". */
  events: Record<string, { kickoff: number; state: ProviderMatchState }>;
  updatedAt: number;
}

export class InvalidEventsError extends Error {
  constructor() {
    super("目标站点返回了无效响应。");
  }
}

export function eventConfigURL(homepage: string, baseURL: string): string | undefined {
  const raw = captures(homepage, /((?:https?:)?\/\/[^\s"'<>]+\/tmp\/njs\.js)/i)[0]?.[1];
  return raw === undefined ? undefined : resolveURL(raw, baseURL);
}

export function eventFeedURL(config: string, baseURL: string): string | undefined {
  const raw = captures(config, /["']base_zqlq_url["']\s*:\s*["']([^"']+)["']/)[0]?.[1];
  const resolved = raw && resolveURL(raw, baseURL);
  if (!resolved) return undefined;
  const url = new URL(resolved);
  url.searchParams.delete("callback");
  url.searchParams.append("callback", "jrkanEvents");
  return url.href;
}

/**
 * Parses the JSONP event feed. The site's public transport encoding wraps the
 * JSON in `[base64(AES-128-ECB("abcdabcdabcdabcd")), …]`; `decrypt` turns that
 * ciphertext into plaintext. Decode data only; never execute returned JS.
 */
export function parseEvents(
  response: string,
  decrypt: (ciphertext: Uint8Array, key: Uint8Array) => string,
  now: number = Date.now(),
): EventSnapshot {
  const text = response.trim();
  const json = captures(text, /^[A-Za-z_$][\w$]*\s*\((.*)\)\s*;?$/s)[0]?.[1] ?? text;
  let object: unknown;
  try {
    object = JSON.parse(json);
    if (Array.isArray(object) && object.length === 2 && typeof object[0] === "string") {
      const binary = atob(object[0]);
      const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
      object = JSON.parse(decrypt(bytes, new TextEncoder().encode("abcdabcdabcdabcd")));
    }
  } catch {
    throw new InvalidEventsError();
  }
  const payload = object as { success?: unknown; time?: unknown; list?: { fields?: unknown; values?: unknown } };
  const fields = payload?.list?.fields;
  const rows = payload?.list?.values;
  if (
    payload?.success !== true || typeof payload.time !== "number" ||
    !Array.isArray(fields) || !fields.every((f) => typeof f === "string") ||
    !Array.isArray(rows) || new Set(fields).size !== fields.length ||
    !["id", "sportid", "status", "st_first", "st_second"].every((f) => fields.includes(f))
  ) throw new InvalidEventsError();
  const updatedAt = payload.time * 1000;
  if (now - updatedAt >= 10 * 60_000 || updatedAt - now >= 5 * 60_000) throw new InvalidEventsError();

  const int = (v: unknown) => (typeof v === "number" && Number.isInteger(v) ? v : undefined);
  const events: EventSnapshot["events"] = {};
  for (const row of rows) {
    if (!Array.isArray(row) || row.length !== fields.length) throw new InvalidEventsError();
    const values: Record<string, unknown> = {};
    fields.forEach((f: string, i) => { values[f] = row[i]; });
    const id = int(values.id), sport = int(values.sportid), code = int(values.status);
    const first = values.st_first, second = values.st_second;
    if (id === undefined || sport === undefined || code === undefined || typeof first !== "number" || typeof second !== "number") {
      throw new InvalidEventsError();
    }
    events[`${sport},${id}`] = {
      kickoff: first,
      state: {
        sportID: sport, code, periodStartedAt: second, updatedAt,
        matchType: int(values.mtype) ?? 0,
        homeScore: int(values.s1), awayScore: int(values.s2),
        homeHalfScore: int(values.hs1), awayHalfScore: int(values.hs2),
        homeCorners: int(values.corner1), awayCorners: int(values.corner2),
      },
    };
  }
  return { events, updatedAt };
}

function feedTime(epoch: number): string {
  const d = new Date(epoch + FEED_UTC_OFFSET_MS);
  const two = (n: number) => String(n).padStart(2, "0");
  return `${two(d.getUTCMonth() + 1)}-${two(d.getUTCDate())} ${two(d.getUTCHours())}:${two(d.getUTCMinutes())}`;
}

export function applyEvents(snapshot: EventSnapshot, matches: LiveMatch[]): LiveMatch[] {
  return matches.flatMap((match) => {
    const ids = match.id.split(",");
    if (ids.length !== 3 || (ids[1] !== "1" && ids[1] !== "2")) return [match];
    // An absent football/basketball row is removed by the web page too;
    // absence means "no longer listed", not proof the match finished.
    const event = snapshot.events[`${ids[1]},${ids[2]}`];
    if (!event) return [];
    return [{ ...match, time: feedTime(event.kickoff), providerState: event.state }];
  });
}
