// Port of the pure parts of MultiSportsClient (App/Sources/Shared/MultiSports.swift,
// android data/MultiSports.kt): Migu and ESPN parsing, catalog extraction and
// whole-table source selection.
import type { LiveMatch } from "../core/models";
import { canonical, isoTime, matchTeams, nearKickoff, sameTeams, teamsAndStartMatch } from "./teams";
import {
  cleanCommentText, comparisonTable, obj, objects, periodTable, playerTables, SportsDataError, strings, text,
  type JsonObject, type SportsComment, type SportsSnapshot, type SportsTable,
} from "./types";

export const MIGU_SOURCE = "咪咕视频";
export const ESPN_SOURCE = "ESPN";

/** Public Migu schedule pages per league. */
export const MIGU_CATALOG_PAGES: Record<string, string> = {
  NBA: "3cd6ba04967742879aaa40bee02a99a6",
  CBA: "494d21a4d6ee453b8b86bd3bb7658ed6",
};
export const miguCatalogURL = (league: string) =>
  `https://www.miguvideo.com/p/home/${MIGU_CATALOG_PAGES[league.toUpperCase()] ?? MIGU_CATALOG_PAGES.NBA}`;
export const miguStatisticsURL = (id: string) => `https://v0-sc.miguvideo.com/oes-sport-static/10/live/statistics/${id}`;
export const miguCommentsURL = (id: string) =>
  `https://webapi.miguvideo.com/gateway/interaction/v2/comment/1/20/${id}/40/NEW?clientType=1`;
export const espnScoreboardURL = (yyyymmdd: string) =>
  `https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=${yyyymmdd}`;
export const espnSummaryURL = (id: string) =>
  `https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=${id}`;

export function complete(value: SportsSnapshot): boolean {
  return !!periodTable(value) && !!comparisonTable(value) && playerTables(value).length === 2;
}

function tableKind(title: string): string {
  if (title === "分节得分") return "period";
  if (title === "球队技术统计") return "comparison";
  return "player:" + canonical(title.split(" · ")[0] ?? title);
}

/// Whole tables keep their provider. Never fill individual cells with a
/// second provider's values or overwrite the preferred source's scoreboard.
export function select(values: SportsSnapshot[]): SportsSnapshot | undefined {
  const first = values[0];
  if (!first) return undefined;
  const tables: SportsTable[] = [];
  const used = new Set<string>();
  const sources = [first.sourceName];
  for (const value of values) {
    if (!sameTeams([value.left, value.right], [first.left, first.right])) continue;
    for (const original of value.tables) {
      const kind = tableKind(original.title);
      // A table with no real value (only "" / "—") is missing, not zero.
      if (!original.rows.some((row) => row.slice(1).some((v) => v !== "" && v !== "—")) || used.has(kind)) continue;
      used.add(kind);
      let table: SportsTable = { ...original, sourceName: value.sourceName };
      if (canonical(value.left) !== canonical(first.left)) {
        if (kind === "comparison") {
          table = { ...table, headers: ["项目", first.left, first.right],
            rows: table.rows.map((r) => (r.length === 3 ? [r[0], r[2], r[1]] : r)) };
        }
        if (kind === "period") table = { ...table, rows: [...table.rows].reverse() };
      }
      tables.push(table);
      if (!sources.includes(value.sourceName)) sources.push(value.sourceName);
    }
  }
  return { ...first, tables, sourceName: sources.join(" · "), scoreSourceName: first.sourceName };
}

/// Balanced-brace extraction of `window.__INITIAL_GROUPS_STATE__` /
/// `__INITIAL_COMPS_STATE__`, then every object carrying `teams` + `pID`.
export function catalogRows(html: string): JsonObject[] {
  const rows: JsonObject[] = [];
  const walk = (value: unknown) => {
    if (Array.isArray(value)) { value.forEach(walk); return; }
    if (value === null || typeof value !== "object") return;
    const o = value as JsonObject;
    if (Array.isArray(o.teams) && o.pID !== undefined && o.pID !== null) rows.push(o);
    Object.values(o).forEach(walk);
  };
  for (const marker of ["__INITIAL_GROUPS_STATE__", "__INITIAL_COMPS_STATE__"]) {
    const at = html.indexOf("window." + marker);
    if (at < 0) continue;
    const begin = html.indexOf("{", at);
    if (begin < 0) continue;
    let depth = 0, quoted = false, escaped = false;
    for (let i = begin; i < html.length; i++) {
      const c = html[i];
      if (quoted) {
        if (escaped) escaped = false;
        else if (c === "\\") escaped = true;
        else if (c === "\"") quoted = false;
      } else if (c === "\"") quoted = true;
      else if (c === "{") depth++;
      else if (c === "}") {
        depth--;
        if (depth === 0) {
          try { walk(JSON.parse(html.slice(begin, i + 1))); } catch { /* malformed state: no rows */ }
          break;
        }
      }
    }
  }
  return rows;
}

/** Unique 12-digit Migu id binding league, both teams and tipoff (±30 min). */
export function miguIDFromCatalog(rows: JsonObject[], match: LiveMatch, now: number): string | undefined {
  const ids = new Set<string>();
  for (const row of rows) {
    const names = objects(row.teams).map((t) => text(t.teamName));
    const id = text(row.pID);
    if (text(row.competitionName).toUpperCase() === match.league.toUpperCase()
      && teamsAndStartMatch(names, text(row.startTime), "yyyyMMddHHmm", match, now)
      && /^[0-9]{12}$/.test(id)) ids.add(id);
  }
  return ids.size === 1 ? [...ids][0] : undefined;
}

export function miguStatistics(root: JsonObject, id: string, match: LiveMatch, now: number = Date.now()): SportsSnapshot {
  const bkb = obj(root.BKB), data = obj(bkb.matchData), teams = obj(data.matchTeam);
  const home = obj(teams.home), away = obj(teams.guest);
  const names = [text(home.teamName), text(away.teamName)];
  if (text(root.code) !== "200"
    || text(data.competitionShortName).toUpperCase() !== match.league.toUpperCase()
    || !teamsAndStartMatch(names, text(data.matchDatetime), "yyyy-MM-dd HH:mm:ss", match, now)) throw new SportsDataError();
  const tables: SportsTable[] = [];
  const quarters = objects(data.quarters);
  if (quarters.length) {
    tables.push({
      title: "分节得分", headers: ["球队", ...quarters.map((q) => `第${text(q.quarter)}节`)], sourceName: "",
      rows: [[names[0], ...quarters.map((q) => text(q.homeScore, "—"))], [names[1], ...quarters.map((q) => text(q.visitingScore, "—"))]],
    });
  }
  const stat = (o: JsonObject, key: string) => {
    const field = obj(o[key]);
    const value = text(field.value, "—");
    return value !== "—" && text(field.hasPercentType) === "1" ? `${value}%` : value;
  };
  const columns: [string, string][] = [["points", "得分"], ["rebounds", "篮板"], ["assists", "助攻"], ["steals", "抢断"],
    ["blocks", "盖帽"], ["turnovers", "失误"], ["fieldGoalsPercentage", "投篮命中率"], ["threePointPercentage", "三分命中率"],
    ["trueShootingPct", "真实命中率"]];
  const hs = obj(home.matchTeamStat), as = obj(away.matchTeamStat);
  const comparison = columns.map(([key, label]) => [label, stat(hs, key), stat(as, key)]).filter((r) => r[1] !== "—" || r[2] !== "—");
  if (comparison.length) tables.push({ title: "球队技术统计", headers: ["项目", ...names], rows: comparison, sourceName: "" });
  const players = objects(bkb.matchPlayerStatBeanList);
  const fields = ["seconds", "points", "rebounds", "assists", "steals", "blocks", "turnovers", "plusMinus", "trueShootingPct"];
  [home, away].forEach((team, index) => {
    const teamID = text(team.wcTeamId);
    const rows = players.filter((p) => teamID !== "" && text(p.wcTeamId) === teamID).map((p) => [
      text(p.nickName, "—"),
      ...fields.map((key) => {
        if (key !== "seconds") return stat(p, key);
        const raw = stat(p, key);
        // Kotlin: a non-integer duration is missing ("—"), never a guessed clock.
        if (!/^-?\d+$/.test(raw)) return "—";
        const seconds = Number.parseInt(raw, 10);
        return `${Math.trunc(seconds / 60)}:${String(Math.abs(seconds % 60)).padStart(2, "0")}`;
      }),
    ]);
    // Raw provider metrics only; no synthesized rating column.
    if (rows.length) tables.push({ title: `${names[index]} · 球员技术统计`,
      headers: ["球员", "时间", "得分", "篮板", "助攻", "抢断", "盖帽", "失误", "+/-", "真实命中率"], rows, sourceName: "" });
  });
  return {
    mid: `migu:${id}`, left: names[0], right: names[1],
    score: `${text(home.teamScore, "—")} : ${text(away.teamScore, "—")}`, period: "", tables, updatedAt: now,
    leftBadge: text(home.teamLogo) || undefined, rightBadge: text(away.teamLogo) || undefined, sourceName: MIGU_SOURCE,
  };
}

/// Web comments bind contentId/objectId to the match; APP comments use
/// contentId=100, commentType=5, contentType=40 and bind both mId and
/// objectId. The shared contentId alone is never accepted.
export function miguComments(root: JsonObject, id: string, now: number = Date.now()): SportsComment[] {
  if (text(root.code) !== "200") return [];
  const seen = new Set<string>();
  const out: SportsComment[] = [];
  for (const row of objects(obj(root.body).commentInfoList)) {
    const cid = text(row.commentId);
    const contentID = text(row.contentId), matchID = text(row.mId);
    const legacy = contentID === id && (matchID === "" || matchID === id);
    const app = contentID === "100" && text(row.commentType) === "5" && text(row.contentType) === "40" && matchID === id;
    const pinned = row.top === true || text(row.top) === "true";
    if (text(row.objectId) !== id || !(legacy || app) || pinned || !cid || seen.has(cid)) continue;
    seen.add(cid);
    const stamp = Number(text(row.createTime));
    if (!text(row.createTime) || !Number.isFinite(stamp)) continue;
    if (now - stamp >= 120_000 || stamp - now >= 30_000) continue;
    const value = cleanCommentText(text(row.body), false);
    if (!value || ["观赛群", "扫码", "http"].some((s) => value.includes(s))) continue;
    out.push({ id: `migu:${cid}`, text: value, postedAt: stamp });
  }
  return out.sort((a, b) => a.postedAt - b.postedAt);
}

export function espnMatch(comp: JsonObject, match: LiveMatch, now: number = Date.now()): boolean {
  const competitors = objects(comp.competitors);
  if (competitors.length !== 2) return false;
  const names = competitors.map((c) => text(obj(c.team).abbreviation));
  if (!sameTeams(names, matchTeams(match))) return false;
  return nearKickoff(isoTime(text(comp.date)), match, now);
}

/** Unique numeric ESPN event id on that New York date's scoreboard. */
export function espnIDFromScoreboard(root: JsonObject, match: LiveMatch, now: number): string | undefined {
  const ids = new Set<string>();
  for (const row of objects(root.events)) {
    const comp = objects(row.competitions)[0];
    const id = text(row.id);
    if (comp && espnMatch(comp, match, now) && /^[0-9]+$/.test(id)) ids.add(id);
  }
  return ids.size === 1 ? [...ids][0] : undefined;
}

const ESPN_TEAM_LABELS: Record<string, string> = {
  rebounds: "篮板", assists: "助攻", steals: "抢断", blocks: "盖帽", turnovers: "失误",
  fieldGoalPct: "投篮命中率", threePointFieldGoalPct: "三分命中率", freeThrowPct: "罚球命中率",
};
const ESPN_PLAYER_LABELS: Record<string, string> = {
  MIN: "时间", PTS: "得分", REB: "篮板", AST: "助攻", STL: "抢断", BLK: "盖帽", TO: "失误", PF: "犯规",
  FG: "投篮", "3PT": "三分", FT: "罚球", OREB: "前板", DREB: "后板",
};

export function espnStatistics(root: JsonObject, id: string, match: LiveMatch, now: number = Date.now()): SportsSnapshot {
  const header = obj(root.header);
  const comp = objects(header.competitions)[0];
  if (match.league.toUpperCase() !== "NBA" || text(header.id) !== id || !comp || !espnMatch(comp, match, now)) throw new SportsDataError();
  const competitors = objects(comp.competitors);
  const home = competitors.find((c) => text(c.homeAway) === "home");
  const away = competitors.find((c) => text(c.homeAway) === "away");
  if (!home || !away) throw new SportsDataError();
  const teams = [home, away];
  const names = teams.map((t) => canonical(text(obj(t.team).abbreviation)));
  const tables: SportsTable[] = [];
  const periods = teams.map((t) => objects(t.linescores));
  const count = Math.max(...periods.map((p) => p.length));
  if (count > 0) {
    tables.push({
      title: "分节得分", headers: ["球队", ...Array.from({ length: count }, (_, i) => `第${i + 1}节`)], sourceName: "",
      rows: names.map((name, t) => [name, ...Array.from({ length: count }, (_, i) => text(periods[t][i]?.displayValue, "—"))]),
    });
  }
  const box = obj(root.boxscore);
  const boxes = objects(box.teams);
  const ordered = teams.map((team) => boxes.find((b) => text(obj(b.team).id) === text(team.id)) ?? {});
  const teamRows = Object.keys(ESPN_TEAM_LABELS).sort().map((key) => [
    ESPN_TEAM_LABELS[key],
    ...ordered.map((o) => text(objects(o.statistics).find((s) => text(s.name) === key)?.displayValue, "—")),
  ]).filter((r) => r[1] !== "—" || r[2] !== "—");
  if (teamRows.length) tables.push({ title: "球队技术统计", headers: ["项目", ...names], rows: teamRows, sourceName: "" });
  for (const team of objects(box.players)) {
    const name = canonical(text(obj(team.team).abbreviation));
    if (!names.includes(name)) continue;
    const group = objects(team.statistics)[0];
    const labels = strings(group?.labels);
    if (!group || !labels) continue;
    const rows = objects(group.athletes).flatMap((row) => {
      const stats = strings(row.stats);
      if (!stats || stats.length !== labels.length) return [];
      // ESPN player names keep the provider's own text.
      return [[text(obj(row.athlete).displayName, "—"), ...stats.map((v) => v || "—")]];
    });
    if (rows.length) tables.push({ title: `${name} · 球员技术统计`,
      headers: ["球员", ...labels.map((l) => ESPN_PLAYER_LABELS[l] ?? l)], rows, sourceName: "" });
  }
  const status = obj(obj(comp.status).type);
  return {
    mid: `espn:${id}`, left: names[0], right: names[1],
    score: `${text(home.score, "—")} : ${text(away.score, "—")}`, period: text(status.shortDetail),
    tables, updatedAt: now, sourceName: ESPN_SOURCE,
  };
}

/** Compact catalog the Worker returns instead of the 1–1.5 MB Migu page; `catalogRows` parses both. */
export function compactCatalog(rows: JsonObject[]): string {
  const slim = rows.map((r) => ({
    pID: text(r.pID), competitionName: text(r.competitionName), startTime: text(r.startTime),
    teams: objects(r.teams).map((t) => ({ teamName: text(t.teamName) })),
  }));
  return `<script>window.__INITIAL_GROUPS_STATE__ = ${JSON.stringify({ rows: slim }).replace(/</g, "\\u003c")};</script>`;
}
