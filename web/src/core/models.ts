// Port of App/Sources/Shared/Models.swift. Keep the two in step: a provider
// or ordering fix there belongs here too (see AGENTS.md).

export interface MatchSource {
  id: string;
  name: string;
  /** Upstream page URL. Only the Worker fetches it. */
  pageURL: string;
  /** Worker signature over pageURL; the client hands it back to /api/channels and /api/resolve. */
  sig?: string;
}

export interface ProviderMatchState {
  sportID: number;
  code: number;
  /** Epoch milliseconds. */
  periodStartedAt: number;
  updatedAt: number;
  matchType: number;
  homeScore?: number;
  awayScore?: number;
  homeHalfScore?: number;
  awayHalfScore?: number;
  homeCorners?: number;
  awayCorners?: number;
}

export interface LiveMatch {
  id: string;
  league: string;
  time: string;
  homeTeam: string;
  awayTeam: string;
  homeLogoURL?: string;
  awayLogoURL?: string;
  isHot: boolean;
  sources: MatchSource[];
  providerState?: ProviderMatchState;
}

/** Sport code from the listing id, e.g. "4644105,1,4644105" → 1. */
export function listingSportCode(match: LiveMatch): number | undefined {
  const parts = match.id.split(",");
  if (parts.length !== 3) return undefined;
  const value = Number.parseInt(parts[1], 10);
  return Number.isNaN(value) ? undefined : value;
}

/// Content preference is a hard tier. Reliability/history only reorder
/// alternatives inside that tier, never promote a host over Chinese HD.
export function playbackPriority(source: Pick<MatchSource, "name">): number {
  const label = source.name.normalize("NFKC").toUpperCase();
  if (label.includes("主播")) return 5;
  const chinese = label.includes("中文") || label.includes("腾讯");
  if (chinese && /(?:^|[^A-Z])Q(?:[^A-Z]|$)/.test(label)) return 0;
  if (chinese && /(?:^|[^A-Z])M(?:[^A-Z]|$)/.test(label)) return 1;
  if (chinese || label.includes("纬来") || label.includes("緯來")) return 2;
  if (label.includes("高清") || label.includes("超清")) return 3;
  return 4;
}

export function playbackOrdered<T extends Pick<MatchSource, "name">>(sources: T[]): T[] {
  return sources
    .map((source, offset) => ({ source, offset, priority: playbackPriority(source) }))
    .sort((a, b) => a.priority - b.priority || a.offset - b.offset)
    .map((entry) => entry.source);
}

// MARK: - Provider state

export type MatchStatus =
  | { kind: "live"; label: string }
  | { kind: "upcoming"; startsInMinutes: number }
  | { kind: "scheduled" }
  | { kind: "interrupted"; label: string }
  | { kind: "finished" }
  | { kind: "unknown" };

/** Sort key: what's on now first, then what's next, then what's over. */
export function statusRank(status: MatchStatus): number {
  switch (status.kind) {
    case "live": return 0;
    case "upcoming": case "scheduled": return 1;
    case "unknown": case "interrupted": return 2;
    case "finished": return 3;
  }
}

export function sectionTitle(status: MatchStatus): string {
  switch (status.kind) {
    case "live": return "正在进行";
    case "upcoming": case "scheduled": return "未开赛";
    case "unknown": case "interrupted": return "其他";
    case "finished": return "已结束";
  }
}

function pair(home?: number, away?: number): string | undefined {
  if (home === undefined || away === undefined || home < 0 || away < 0) return undefined;
  return `${home} - ${away}`;
}

export function scoreText(state?: ProviderMatchState): string | undefined {
  if (!state || state.code === 0) return undefined;
  return pair(state.homeScore, state.awayScore);
}

export function halftimeText(state: ProviderMatchState): string | undefined {
  // hs1/hs2 are football fields. The site's basketball columns show
  // score difference and total, not the zero-filled hs placeholders.
  if (state.sportID !== 1 || state.code < 2 || state.code > 7) return undefined;
  return pair(state.homeHalfScore, state.awayHalfScore);
}

export function basketballSummary(state: ProviderMatchState): { difference: number; total: number } | undefined {
  if (state.sportID !== 2 || scoreText(state) === undefined) return undefined;
  const { homeScore, awayScore } = state;
  if (homeScore === undefined || awayScore === undefined) return undefined;
  const total = homeScore + awayScore;
  if (!Number.isSafeInteger(total)) return undefined;
  return { difference: Math.abs(homeScore - awayScore), total };
}

export function cornersText(state: ProviderMatchState): string | undefined {
  if (state.sportID !== 1 || state.code === 0) return undefined;
  return pair(state.homeCorners, state.awayCorners);
}

const BASKETBALL_PERIODS: Record<number, string> = {
  1: "第一节", 2: "第一节结束", 3: "第二节", 4: "第二节结束",
  5: "第三节", 6: "第三节结束", 7: "第四节", 8: "加时",
};

export function providerStatus(state: ProviderMatchState, now: number): MatchStatus | undefined {
  // Do not keep an old live label indefinitely after a refresh failure.
  if (now - state.updatedAt >= 10 * 60_000 || state.updatedAt - now >= 5 * 60_000) return undefined;
  const { code } = state;
  if (code === 0) return { kind: "scheduled" };
  if (state.sportID === 1) {
    switch (code) {
      case 1: case 3: {
        const elapsed = Math.max(0, Math.trunc((now - state.periodStartedAt) / 60_000));
        const minute = code === 1 ? elapsed : Math.max(46, elapsed + 45);
        const limit = code === 1 ? 45 : 90;
        return { kind: "live", label: minute > limit ? `${limit}+` : `${minute}′` };
      }
      case 2: return { kind: "live", label: "中场休息" };
      case 4: case 5: return { kind: "live", label: "加时赛" };
      case 6: return { kind: "live", label: "点球大战" };
      case 7: return { kind: "finished" };
      case 8: return { kind: "interrupted", label: "推迟" };
      case 9: return { kind: "interrupted", label: "中断" };
      case 10: return { kind: "interrupted", label: "腰斩" };
      case 11: return { kind: "interrupted", label: "取消" };
      case 12: return { kind: "interrupted", label: "待定" };
      default: return undefined;
    }
  }
  if (state.sportID === 2) {
    // The website adjusts period labels for two-half competitions.
    const periodCode = state.matchType === 2 && (code === 4 || code === 8) ? code / 2 : code;
    const label = BASKETBALL_PERIODS[periodCode];
    if (label) return { kind: "live", label };
    switch (code) {
      case 9: return { kind: "finished" };
      case 10: return { kind: "interrupted", label: "中断" };
      case 11: return { kind: "interrupted", label: "取消" };
      case 12: return { kind: "interrupted", label: "推迟" };
      case 13: return { kind: "interrupted", label: "腰斩" };
      case 14: return { kind: "interrupted", label: "待定" };
      default: return undefined;
    }
  }
  return undefined;
}

// MARK: - Schedule

/// Schedule times are used for display and upcoming countdowns only.
/// In-progress and final states come from the website's event feed.
export const FEED_UTC_OFFSET_MS = 8 * 3600_000; // Asia/Shanghai, no DST

export const BASKETBALL_LEAGUES = ["NBA", "WNBA", "CBA", "NBL", "篮", "篮球", "欧篮", "韩篮", "菲MPBL"];

function containsFolded(haystack: string, needle: string): boolean {
  return haystack.toLowerCase().includes(needle.toLowerCase());
}

export function isBasketballLeague(league: string): boolean {
  return BASKETBALL_LEAGUES.some((name) => containsFolded(league, name));
}

/// The listing's `data-lid` ("<id>,<sport>,<id>") carries the site's sport
/// code: 1 football, 2 basketball, 131 badminton. The league name covers
/// rows from an older markup.
export function isBadminton(match: LiveMatch): boolean {
  if (listingSportCode(match) === 131) return true;
  return ["羽毛球", "羽球", "BWF"].some((name) => containsFolded(match.league, name));
}

/** "MM-dd HH:mm" in Beijing time → epoch ms, snapped to the year nearest `now`. */
export function kickoff(raw: string, now: number = Date.now()): number | undefined {
  const parts = raw.split(/[  ]+/).filter(Boolean);
  if (parts.length !== 2) return undefined;
  const day = parts[0].split("-").map((v) => Number.parseInt(v, 10));
  const clock = parts[1].split(":").map((v) => Number.parseInt(v, 10));
  if (day.length !== 2 || clock.length !== 2 || [...day, ...clock].some(Number.isNaN)) return undefined;
  const year = new Date(now + FEED_UTC_OFFSET_MS).getUTCFullYear();
  const at = (y: number) => Date.UTC(y, day[0] - 1, day[1], clock[0], clock[1]) - FEED_UTC_OFFSET_MS;
  let date = at(year);
  // No year in the feed. Around New Year the naive guess lands a whole
  // year off, so snap to whichever year puts the date closest to today.
  const halfYear = 182 * 86400_000;
  if (date - now > halfYear) date = at(year - 1);
  else if (now - date > halfYear) date = at(year + 1);
  return date;
}

export function matchStatus(match: LiveMatch, now: number = Date.now()): MatchStatus {
  if (match.providerState) {
    const status = providerStatus(match.providerState, now);
    if (status) {
      if (status.kind === "scheduled") {
        const start = kickoff(match.time, now);
        if (start !== undefined && start > now) {
          return { kind: "upcoming", startsInMinutes: Math.ceil((start - now) / 60_000) };
        }
      }
      return status;
    }
  }
  const start = kickoff(match.time, now);
  if (start === undefined) return { kind: "unknown" };
  if (start > now) return { kind: "upcoming", startsInMinutes: Math.ceil((start - now) / 60_000) };
  return { kind: "unknown" };
}

/// Kickoff rendered in the viewer's own zone: a relative day word plus the clock.
export function displayTime(raw: string, now: number = Date.now()): { day: string; clock: string } {
  const start = kickoff(raw, now);
  if (start === undefined) {
    const index = raw.indexOf(" ");
    return index > 0 ? { day: raw.slice(0, index), clock: raw.slice(index + 1) } : { day: "", clock: raw };
  }
  const date = new Date(start);
  const clock = `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const daysApart = Math.round((startOfDay(date) - startOfDay(new Date(now))) / 86400_000);
  const day = daysApart === 0 ? "今天" : daysApart === 1 ? "明天" : daysApart === -1 ? "昨天"
    : `${date.getMonth() + 1}月${date.getDate()}日`;
  return { day, clock };
}

/** True when the viewer is not on Beijing time, so the raw feed time is worth showing too. */
export function viewerIsOffFeedTime(now: number = Date.now()): boolean {
  return -new Date(now).getTimezoneOffset() * 60_000 !== FEED_UTC_OFFSET_MS;
}

// MARK: - Filters

export type SportFilter = "全部" | "篮球" | "羽毛球" | "足球" | "热门" | "关注" | "最近观看";

// Declaration order is display order: everything first, then the sports.
export const ALL_FILTERS: SportFilter[] = ["全部", "篮球", "羽毛球", "足球", "热门", "关注", "最近观看"];

export function filterIncludes(filter: SportFilter, match: LiveMatch, favorites: Set<string> = new Set()): boolean {
  switch (filter) {
    case "全部": return true;
    case "最近观看": return false; // The list model uses the saved match snapshots for this filter.
    case "关注": return favorites.has(match.homeTeam) || favorites.has(match.awayTeam);
    case "热门": return match.isHot;
    case "篮球": {
      // Sport code 2 is basketball both in the listing id and the event
      // feed; the league name only covers rows that carry neither.
      const code = match.providerState?.sportID ?? listingSportCode(match);
      if (code !== undefined) return code === 2;
      return isBasketballLeague(match.league);
    }
    case "羽毛球": return isBadminton(match);
    case "足球": return !filterIncludes("篮球", match) && !filterIncludes("羽毛球", match);
  }
}
