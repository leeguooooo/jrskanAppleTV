// Port of TencentSportsClient (App/Sources/Shared/TencentSports.swift,
// android data/TencentSports.kt). Public read-only endpoints only.
import type { LiveMatch, MatchSource } from "../core/models";
import { matchTeams, nearKickoff, sameTeams, shanghaiTime } from "./teams";
import {
  cleanCommentText, objects, obj, parseJSONObject, SportsDataError, strings, text,
  type JsonObject, type SportsComment, type SportsSnapshot, type SportsTable,
} from "./types";

export const TENCENT_SOURCE = "腾讯体育";
const COMPETITIONS: Record<string, string> = { NBA: "100000", CBA: "100008" };

/// The channel exposes Tencent's event ID. No fuzzy search for unrelated
/// leagues or names: exactly one distinct kbs/vxt/txf id, else nothing.
export function candidateMID(match: LiveMatch, channels: Pick<MatchSource, "pageURL">[]): string | undefined {
  const competition = COMPETITIONS[match.league.toUpperCase()];
  if (!competition) return undefined;
  const ids = new Set<string>();
  for (const source of channels) {
    let url: URL;
    try {
      url = new URL(source.pageURL);
    } catch {
      continue;
    }
    const last = url.pathname.split("/").filter(Boolean).pop() ?? "";
    if (!["kbs", "vxt", "txf"].includes(last)) continue;
    const id = url.searchParams.get("id");
    if (id && /^[0-9]{10,12}$/.test(id)) ids.add(id);
  }
  return ids.size === 1 ? `${competition}:${[...ids][0]}` : undefined;
}

/** Event ID, both teams (canonical) and kickoff (±30 min) must agree. */
export function tencentMatches(info: JsonObject, match: LiveMatch, mid: string, now: number = Date.now()): boolean {
  if (text(info.mid) !== mid) return false;
  if (!sameTeams([text(info.leftName), text(info.rightName)], matchTeams(match))) return false;
  return nearKickoff(shanghaiTime(text(info.startTime), "yyyy-MM-dd HH:mm:ss"), match, now);
}

/** Sorted query, as both apps build it. `_t` is left to the Worker proxy (see worker/sports.ts). */
export function tencentURL(host: "matchweb.sports.qq.com" | "app.sports.qq.com", path: string, query: Record<string, string>): string {
  const params = new URLSearchParams();
  for (const key of Object.keys(query).sort()) params.set(key, query[key]);
  return `https://${host}${path}?${params.toString()}`;
}
export const matchDetailURL = (mid: string) => tencentURL("matchweb.sports.qq.com", "/kbs/matchDetail", { mid });
export const matchStatURL = (mid: string) => tencentURL("matchweb.sports.qq.com", "/kbs/matchStat", { mid });
export const liveCommentsURL = (mid: string) =>
  tencentURL("app.sports.qq.com", "/dmComment/liveList", { mid, topN: "20", commentId: "0" });

/** `{code: 0, data: {...}}` envelope. */
export function tencentData(body: string): JsonObject {
  const root = parseJSONObject(body);
  if (text(root.code) !== "0") throw new SportsDataError("腾讯体育数据暂不可用。");
  const data = root.data;
  if (data === null || typeof data !== "object" || Array.isArray(data)) throw new SportsDataError("腾讯体育数据暂不可用。");
  return data as JsonObject;
}

function badge(raw: string): string | undefined {
  try {
    const url = new URL(raw);
    return url.protocol === "https:" || url.protocol === "http:" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

export function parseTencentStatistics(data: JsonObject, mid: string, now: number = Date.now()): SportsSnapshot {
  const info = data.teamInfo;
  if (info === null || typeof info !== "object" || Array.isArray(info)) throw new SportsDataError();
  const team = info as JsonObject;
  const left = text(team.leftName), right = text(team.rightName);
  if (!left || !right) throw new SportsDataError();
  const tables: SportsTable[] = [];
  const periods = obj(data.periodGoals);
  const headers = strings(periods.head);
  const rows = Array.isArray(periods.rows) ? periods.rows.map(strings) : undefined;
  // Kotlin's stricter shape check: every row is name + one cell per header.
  if (headers && rows && rows.length === 2 && rows.every((r) => r && r.length === headers.length + 1)) {
    tables.push({
      title: "分节得分", headers: ["球队", ...headers], sourceName: "",
      rows: [left, right].map((name, i) => [name, ...(rows[i] as string[]).slice(1)]),
    });
  }
  const comparison = objects(data.teamStats).flatMap((stat) => {
    const label = text(stat.text);
    if (!label) return [];
    const value = (side: string) => {
      const base = text(stat[`${side}Val`], "—");
      const extra = text(stat[`${side}Ext`]);
      return extra ? `${base} (${extra})` : base;
    };
    return [[label, value("left"), value("right")]];
  });
  if (comparison.length) tables.push({ title: "球队技术统计", headers: ["项目", left, right], rows: comparison, sourceName: "" });
  const players = obj(data.playerStats);
  for (const [side, name] of [["left", left], ["right", right]] as const) {
    const entries = objects(players[side]);
    const head = strings(entries[0]?.head);
    if (!head || head.length === 0) continue;
    const playerRows = entries.flatMap((entry) => {
      const row = strings(entry.row);
      if (!row || row.length !== head.length + 1) return [];
      return [[[row[0], row[1]].filter(Boolean).join(" "), ...row.slice(2)]];
    });
    if (playerRows.length) tables.push({ title: `${name} · 球员技术统计`, headers: head, rows: playerRows, sourceName: "" });
  }
  return {
    mid, left, right,
    score: `${text(team.leftGoal, "—")} : ${text(team.rightGoal, "—")}`,
    period: text(team.quarterDesc), tables, updatedAt: now,
    leftBadge: badge(text(team.leftBadge)), rightBadge: badge(text(team.rightBadge)),
    sourceName: TENCENT_SOURCE,
  };
}

/** Only type-0 text comments of this event, posted in the last 120 s (and < 30 s ahead). */
export function parseTencentComments(data: JsonObject, mid: string, now: number = Date.now()): SportsComment[] {
  const seen = new Set<string>();
  const out: SportsComment[] = [];
  for (const row of objects(data.list)) {
    const id = text(row.commentId);
    if (text(row.mid) !== mid || text(row.type) !== "0" || !id || seen.has(id)) continue;
    seen.add(id);
    const seconds = Number(text(row.postTime));
    if (!text(row.postTime) || !Number.isFinite(seconds) || seconds < 0) continue;
    const posted = Math.round(seconds * 1000);
    if (now - posted >= 120_000 || posted - now >= 30_000) continue;
    const message = cleanCommentText(text(row.content), true);
    if (!message) continue;
    out.push({ id, text: message, postedAt: posted });
  }
  return out.sort((a, b) => a.postedAt - b.postedAt);
}
