// Mirrors App/Tests/TencentSportsTests.swift + MultiSportsTests.swift and
// Android TencentSportsTest/MultiSportsTest against the shared contracts.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { playbackPriority, type LiveMatch, type MatchSource } from "../src/core/models";
import { statComparison } from "../src/sports/comparison";
import {
  catalogRows, compactCatalog, complete, espnStatistics, miguComments, miguIDFromCatalog, miguStatistics, select,
} from "../src/sports/multi";
import { canonical, teamsAndStartMatch } from "../src/sports/teams";
import { candidateMID, parseTencentComments, parseTencentStatistics, tencentMatches } from "../src/sports/tencent";
import { comparisonTable, periodTable, playerTables, type JsonObject, type SportsSnapshot } from "../src/sports/types";

type Fixture = Record<string, any>;
const contract = (name: string): Fixture =>
  JSON.parse(readFileSync(new URL(`../../contracts/${name}`, import.meta.url), "utf8"));
const tencent = contract("tencent-sports.json");
const multi = contract("multi-sports.json");

const MID = "100000:10022600102";
function game(home = "湖人", away = "快船", time = "10-24 10:00", league = "NBA", id = "3931544,2,3931544"): LiveMatch {
  return { id, league, time, homeTeam: home, awayTeam: away, isHot: false, sources: [] };
}
const source = (name: string, pageURL: string): MatchSource => ({ id: "shared", name, pageURL });

describe("tencent contract (testSharedAndroidAppleContract)", () => {
  it("channel priority and Tencent event ids", () => {
    for (const row of tencent.channels) {
      const s = source(row.name, row.url);
      expect(playbackPriority(s), row.name).toBe(row.priority);
      expect(candidateMID(game(), [s]) ?? null, row.name).toBe(row.mid);
    }
  });

  it("statistics keep missing as — and zero as 0", () => {
    const snapshot = parseTencentStatistics(tencent.statistics, MID);
    expect(snapshot.score).toBe("0 : —");
    expect(snapshot.tables).toHaveLength(4);
    expect(snapshot.tables[1].rows[1]).toEqual(["篮板", "—", "1"]);
    expect(playerTables(snapshot)[0].rows).toEqual([["77 球员甲", "1'00", "0"]]);
    expect(snapshot.tables[0].rows[0]).toEqual(["快船", "0", "0"]);
    expect(snapshot.sourceName).toBe("腾讯体育");
  });

  it("comments filter duplicates, stale, wrong match, gifts, future, markup", () => {
    const comments = parseTencentComments(tencent.comments, MID, tencent.nowMs);
    expect(comments.map((c) => c.id)).toEqual(["keep"]);
    expect(comments[0].text).toBe("好球");
  });

  it("rejects an empty payload", () => {
    expect(() => parseTencentStatistics({}, MID)).toThrow();
  });
});

describe("tencent mapping and matching", () => {
  const kbs = (id: string) => source("中文高清", `https://play.example/play/kbs/?id=${id}&id2=`);
  it("uses one source event id and rejects conflicts", () => {
    expect(candidateMID(game(), [kbs("10022600102")])).toBe(MID);
    expect(candidateMID(game(), [kbs("10022600102"), kbs("10022600103")])).toBeUndefined();
    expect(candidateMID(game(), [kbs("439")])).toBeUndefined();
    expect(candidateMID(game(), [source("中文高清⑤", "https://play.example/play/txf/?id=10022600101&id2=")])).toBe("100000:10022600101");
    expect(candidateMID(game("上海", "福建", "10-24 19:35", "CBA"), [kbs("10011111111")])).toBe("100008:10011111111");
    expect(candidateMID(game("A", "B", "10-24 19:35", "英超"), [kbs("10011111111")])).toBeUndefined();
  });

  it("requires teams, start time and the exact event id", () => {
    const now = Date.parse("2026-10-24T02:00:00Z");
    const info: JsonObject = { mid: MID, leftName: "快船", rightName: "湖人", startTime: "2026-10-24 10:00:00" };
    expect(tencentMatches(info, game(), MID, now)).toBe(true);
    expect(tencentMatches({ ...info, rightName: "勇士" }, game(), MID, now)).toBe(false);
    expect(tencentMatches({ ...info, startTime: "2026-10-25 10:00:00" }, game(), MID, now)).toBe(false);
    expect(tencentMatches({ ...info, mid: "100000:other" }, game(), MID, now)).toBe(false);
  });

  it("comment filter (testCommentsFilterWrongMatchStaleGiftsDuplicatesAndMarkup)", () => {
    const now = 1_000_000;
    const c = (id: string, stamp: string, event = MID, type = "0") =>
      ({ commentId: id, postTime: stamp, mid: event, type, content: "<b>好球</b>[打call/]\n" });
    const parsed = parseTencentComments({ list: [c("ok", "990"), c("ok", "990"), c("old", "100"),
      c("wrong", "990", "another"), c("gift", "990", MID, "2"), c("future", "2000")] }, MID, now);
    expect(parsed).toHaveLength(1);
    expect(parsed[0].text).toBe("好球");
    expect(parsed[0].postedAt).toBe(990_000);
  });
});

describe("comparison bars", () => {
  it("preserve zeros and reject missing/invalid", () => {
    expect(statComparison(["得分", "60", "40"])?.leftShare).toBeCloseTo(0.6);
    expect(statComparison(["命中率", "40% (4/10)", "60% (6/10)"])?.leftShare).toBeCloseTo(0.4);
    expect(statComparison(["得分", "0", "0"])?.leftShare).toBe(0.5);
    expect(statComparison(["得分", "—", "0"])).toBeUndefined();
    expect(statComparison(["得分", "NaN", "4"])).toBeUndefined();
  });
});

describe("CBA aliases (testCBAClubNamesMatchShanghaiFujianWithoutMergingDistinctClubs)", () => {
  const row = multi.shanghai;
  const match = game(row.home ?? "上海", row.away ?? "福建", row.time ?? "10-24 19:35", "CBA", "3941097");
  const now: number = row.nowMs;

  it("maps every contract alias and keeps distinct clubs distinct", () => {
    for (const [name, expected] of Object.entries(multi.cbaAliases as Record<string, string>)) {
      expect(canonical(name), name).toBe(expected);
    }
    expect(canonical("上海申花")).toBe("上海申花");
    expect(canonical("北京首钢")).not.toBe(canonical("北京控股"));
    expect(canonical("浙江稠州金租")).not.toBe(canonical("浙江浙商证券"));
    expect(canonical("lal")).toBe("湖人");
  });

  it("Migu statistics and both comment shapes", () => {
    const value = miguStatistics(row.statistics, row.id, match, now);
    expect(playerTables(value)).toHaveLength(2);
    expect(miguComments(row.comments, row.id, now).map((c) => c.id)).toEqual(["migu:legacy-keep", "migu:app-keep"]);
  });

  it("schedule and Tencent matching through the shared alias map", () => {
    expect(teamsAndStartMatch(["上海久事", "福建晋江文旅"], "202610241915", "yyyyMMddHHmm", match, now)).toBe(true);
    expect(teamsAndStartMatch(["上海久事", "北京控股"], "202610241915", "yyyyMMddHHmm", match, now)).toBe(false);
    expect(teamsAndStartMatch(["上海久事", "福建晋江文旅"], "202610251915", "yyyyMMddHHmm", match, now)).toBe(false);
    const mid = "100008:10011111111";
    const info = { mid, leftName: "上海久事", rightName: "福建晋江文旅", startTime: "2026-10-24 19:35:00" };
    expect(tencentMatches(info, match, mid, now)).toBe(true);
    expect(tencentMatches(info, match, "wrong", now)).toBe(false);
  });

  it("uses the contract's catalog row for the Shanghai id", () => {
    if (!row.catalog) return;
    const html = `<script>window.__INITIAL_GROUPS_STATE__ = {"rows":[${JSON.stringify(row.catalog)}]};</script>`;
    expect(miguIDFromCatalog(catalogRows(html), match, now)).toBe(row.id);
  });
});

describe("Migu / ESPN contract (testSharedMiguEspnAndCommentContractRejectsWrongMatch)", () => {
  const now: number = multi.nowMs;
  it("parses Migu and rejects the wrong match", () => {
    const m = miguStatistics(multi.migu, "120000588273", game(), now);
    expect(m.sourceName).toBe("咪咕视频");
    expect(m.score).toBe("125 : 117");
    expect(playerTables(m)).toHaveLength(2);
    expect(playerTables(m)[0].rows[0]).toEqual(["凯斯勒", "34:53", "22", "8", "3", "3", "—", "1", "18", "67.9%"]);
    // No synthesized rating column: raw provider metrics only.
    expect(playerTables(m)[0].headers).not.toContain("评分");
    expect(playerTables(m)[0].headers.at(-1)).toBe("真实命中率");
    expect(miguComments(multi.comments, "120000588273", now).map((c) => c.id)).toEqual(["migu:keep"]);
    expect(() => miguStatistics(multi.migu, "120000588273", game("勇士"), now)).toThrow();
  });

  it("parses ESPN and rejects a wrong id", () => {
    const e = espnStatistics(multi.espn, multi.espnID, game("雄鹿", "公牛", "10-24 04:00"), now);
    expect(e.sourceName).toBe("ESPN");
    expect(playerTables(e)).toHaveLength(2);
    expect(playerTables(e)[0].headers[2]).toBe("得分");
    expect(periodTable(e)?.rows[0][0]).toBe("雄鹿");
    expect(() => espnStatistics(multi.espn, "wrong", game("雄鹿", "公牛", "10-24 04:00"), now)).toThrow();
    expect(() => espnStatistics(multi.espn, multi.espnID, game("雄鹿", "公牛", "10-25 04:00"), now)).toThrow();
  });

  it("schedule matching rejects wrong team / day", () => {
    expect(teamsAndStartMatch(["湖人", "勇士"], "202610240945", "yyyyMMddHHmm", game(), now)).toBe(false);
    expect(teamsAndStartMatch(["湖人", "快船"], "202610250945", "yyyyMMddHHmm", game(), now)).toBe(false);
    expect(teamsAndStartMatch(["湖人", "快船"], "202610240945", "yyyyMMddHHmm", game(), now)).toBe(true);
  });
});

describe("catalog + whole-table fill (testCatalogUsesBalancedJSONAndWholeTableFallbackPreservesZeroAndOrientation)", () => {
  const now: number = multi.nowMs;
  const row = JSON.stringify(multi.catalog);

  it("extracts rows from balanced JSON state", () => {
    const html = `<script>window.__INITIAL_GROUPS_STATE__ = {"nested":[${row}], "s":"}{\\"x"};window.__INITIAL_COMPS_STATE__ = {};</script>`;
    const rows = catalogRows(html);
    expect(rows).toHaveLength(1);
    expect(miguIDFromCatalog(rows, game(), now)).toBe("120000588273");
    expect(miguIDFromCatalog(rows, game("湖人", "勇士"), now)).toBeUndefined();
    // Two candidate ids for one fixture: ambiguous, so no id.
    const twin = { ...multi.catalog, pID: "120000588274" };
    expect(miguIDFromCatalog([...rows, twin], game(), now)).toBeUndefined();
    // The Worker's compact catalog parses to the same rows.
    expect(catalogRows(compactCatalog(rows))).toEqual([multi.catalog]);
  });

  it("fills missing whole tables, labels sources, keeps the preferred scoreboard and zero", () => {
    const m = miguStatistics(multi.migu, "120000588273", game(), now);
    const t: SportsSnapshot = { mid: "tencent", left: "湖人", right: "快船", score: "0 : —", period: "", updatedAt: now,
      sourceName: "腾讯体育", tables: [{ title: "球队技术统计", headers: ["项目", "湖人", "快船"], rows: [["得分", "0", "—"]], sourceName: "" }] };
    const result = select([t, m])!;
    expect(result.score).toBe("0 : —");
    expect(comparisonTable(result)?.rows[0][1]).toBe("0");
    expect(comparisonTable(result)?.rows).toHaveLength(1); // no cell mixing from Migu
    expect(comparisonTable(result)?.sourceName).toBe("腾讯体育");
    expect(playerTables(result)[0].sourceName).toBe("咪咕视频");
    expect(periodTable(result)?.sourceName).toBe("咪咕视频");
    expect(result.scoreSourceName).toBe("腾讯体育");
    expect(result.sourceName).toBe("腾讯体育 · 咪咕视频");
    expect(complete(result)).toBe(true);

    const reverse: SportsSnapshot = { mid: "t", left: "快船", right: "湖人", score: "— : —", period: "", tables: [], updatedAt: now, sourceName: "腾讯体育" };
    const reoriented = select([reverse, m])!;
    expect(comparisonTable(reoriented)?.headers[1]).toBe("快船");
    expect(comparisonTable(reoriented)?.rows[0][1]).toBe(comparisonTable(m)?.rows[0][2]);
    expect(periodTable(reoriented)?.rows[0][0]).toBe("快船");
    expect(reoriented.score).toBe("— : —");
  });

  it("treats an all-missing table as missing and skips other fixtures", () => {
    const m = miguStatistics(multi.migu, "120000588273", game(), now);
    const empty: SportsSnapshot = { mid: "t", left: "湖人", right: "快船", score: "— : —", period: "", updatedAt: now, sourceName: "腾讯体育",
      tables: [{ title: "球队技术统计", headers: ["项目", "湖人", "快船"], rows: [["得分", "—", ""]], sourceName: "" }] };
    expect(comparisonTable(select([empty, m])!)?.sourceName).toBe("咪咕视频");
    const other: SportsSnapshot = { ...m, left: "勇士", right: "快船" };
    expect(select([empty, other])!.tables).toHaveLength(0);
  });
});
