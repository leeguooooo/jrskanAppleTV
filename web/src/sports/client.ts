// Port of MultiSportsClient's network flow. A failed/empty provider never
// becomes a sticky preference: every refresh starts with Tencent, then Migu,
// then ESPN (statistics only). Statistics and comments choose independently.
import { kickoff, type LiveMatch, type MatchSource } from "../core/models";
import { sportsFetch } from "./fetch";
import {
  catalogRows, complete, espnIDFromScoreboard, espnScoreboardURL, espnStatistics, espnSummaryURL,
  miguCatalogURL, miguComments, miguCommentsURL, miguIDFromCatalog, miguStatistics, miguStatisticsURL, select,
} from "./multi";
import { newYorkDate } from "./teams";
import {
  candidateMID, liveCommentsURL, matchDetailURL, matchStatURL, parseTencentComments, parseTencentStatistics,
  tencentData, tencentMatches,
} from "./tencent";
import { obj, parseJSONObject, SportsDataError, type JsonObject, type SportsComment, type SportsSnapshot } from "./types";

export type FetchText = (url: string) => Promise<string>;

export interface SportsClientOptions {
  fetchText?: FetchText;
  now?: () => number;
}

const CATALOG_TTL_MS = 5 * 60_000;
const CACHE_LIMIT = 20;

export function matchKey(match: LiveMatch): string {
  return `${match.league}|${match.homeTeam}|${match.awayTeam}|${match.time}`;
}

function remember<V>(map: Map<string, V>, key: string, value: V) {
  if (map.size > CACHE_LIMIT) map.clear();
  map.set(key, value);
}

export class MultiSportsClient {
  private readonly fetchText: FetchText;
  private readonly now: () => number;
  private readonly miguIDs = new Map<string, string>();
  private readonly espnIDs = new Map<string, string>();
  private readonly verifiedTencent = new Set<string>();
  private readonly catalogs = new Map<string, { at: number; rows: JsonObject[] }>();
  /** In-flight catalog fetches, so two consumers of one match share a request. */
  private readonly pending = new Map<string, Promise<JsonObject[]>>();

  constructor(options: SportsClientOptions = {}) {
    this.fetchText = options.fetchText ?? sportsFetch;
    this.now = options.now ?? Date.now;
  }

  private async json(url: string): Promise<JsonObject> {
    return parseJSONObject(await this.fetchText(url));
  }

  async tencentStatistics(mid: string, match: LiveMatch): Promise<SportsSnapshot> {
    const data = tencentData(await this.fetchText(matchStatURL(mid)));
    const info = { ...obj(data.teamInfo), mid };
    if (!tencentMatches(info, match, mid, this.now())) throw new SportsDataError();
    return parseTencentStatistics(data, mid, this.now());
  }

  async tencentVerify(match: LiveMatch, mid: string): Promise<void> {
    const data = tencentData(await this.fetchText(matchDetailURL(mid)));
    if (!tencentMatches(obj(data.matchInfo), match, mid, this.now())) throw new SportsDataError();
  }

  async statistics(match: LiveMatch, channels: MatchSource[], onPartial?: (value: SportsSnapshot) => void): Promise<SportsSnapshot> {
    const values: SportsSnapshot[] = [];
    const accept = () => {
      const result = select(values);
      if (result) onPartial?.(result);
      return result && complete(result) ? result : undefined;
    };
    const mid = candidateMID(match, channels);
    if (mid) {
      try {
        values.push(await this.tencentStatistics(mid, match));
        const done = accept();
        if (done) return done;
      } catch { /* fall through to the next provider */ }
    }
    try {
      const id = await this.miguID(match);
      values.push(miguStatistics(await this.json(miguStatisticsURL(id)), id, match, this.now()));
      const done = accept();
      if (done) return done;
    } catch { /* fall through */ }
    try {
      const id = await this.espnID(match);
      values.push(espnStatistics(await this.json(espnSummaryURL(id)), id, match, this.now()));
    } catch { /* ESPN is the last resort */ }
    const value = select(values);
    if (!value) throw new SportsDataError();
    return value;
  }

  /// Tencent while it has comments not yet shown; otherwise Migu's latest.
  /// An empty result is returned as empty: old comments are never replayed.
  async comments(match: LiveMatch, channels: MatchSource[], excluding: ReadonlySet<string> = new Set()): Promise<SportsComment[]> {
    const mid = candidateMID(match, channels);
    if (mid) {
      try {
        const verificationKey = matchKey(match) + mid;
        if (!this.verifiedTencent.has(verificationKey)) {
          await this.tencentVerify(match, mid);
          if (this.verifiedTencent.size > CACHE_LIMIT) this.verifiedTencent.clear();
          this.verifiedTencent.add(verificationKey);
        }
        const rows = parseTencentComments(tencentData(await this.fetchText(liveCommentsURL(mid))), mid, this.now())
          .map((c) => ({ ...c, id: `tencent:${c.id}` }))
          .filter((c) => !excluding.has(c.id));
        if (rows.length) return rows;
      } catch { /* try Migu */ }
    }
    const id = await this.miguID(match);
    return miguComments(await this.json(miguCommentsURL(id)), id, this.now()).filter((c) => !excluding.has(c.id));
  }

  async miguID(match: LiveMatch): Promise<string> {
    const key = matchKey(match);
    const cached = this.miguIDs.get(key);
    if (cached) return cached;
    const league = match.league.toUpperCase();
    if (league !== "NBA" && league !== "CBA") throw new SportsDataError();
    const rows = await this.catalog(league);
    const id = miguIDFromCatalog(rows, match, this.now());
    if (!id) throw new SportsDataError();
    remember(this.miguIDs, key, id);
    return id;
  }

  private async catalog(league: string): Promise<JsonObject[]> {
    const cached = this.catalogs.get(league);
    if (cached && this.now() - cached.at < CATALOG_TTL_MS) return cached.rows;
    let request = this.pending.get(league);
    if (!request) {
      request = this.fetchText(miguCatalogURL(league)).then((html) => {
        const rows = catalogRows(html);
        this.catalogs.set(league, { at: this.now(), rows });
        return rows;
      }).finally(() => this.pending.delete(league));
      this.pending.set(league, request);
    }
    return request;
  }

  async espnID(match: LiveMatch): Promise<string> {
    const key = matchKey(match);
    const cached = this.espnIDs.get(key);
    if (cached) return cached;
    const start = kickoff(match.time, this.now());
    if (match.league.toUpperCase() !== "NBA" || start === undefined) throw new SportsDataError();
    const root = await this.json(espnScoreboardURL(newYorkDate(start)));
    const id = espnIDFromScoreboard(root, match, this.now());
    if (!id) throw new SportsDataError();
    remember(this.espnIDs, key, id);
    return id;
  }
}

let shared: MultiSportsClient | undefined;
/** One client per page, so the stats panel and the danmaku overlay share id/catalog caches. */
export function sharedSportsClient(): MultiSportsClient {
  shared ??= new MultiSportsClient();
  return shared;
}
