// Port of App/Tests/MatchScheduleTests.swift (MatchScheduleTests + EventSnapshotTests)
// and the pure provider-state assertions of ExperienceTests.testStatisticsAndContinueUseLatestEventSnapshot.
import { createCipheriv, createDecipheriv } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import {
  applyEvents, eventConfigURL, eventFeedURL, parseEvents, type EventSnapshot,
} from "../src/core/events";
import {
  ALL_FILTERS, basketballSummary, cornersText, displayTime, filterIncludes, halftimeText, kickoff,
  matchStatus, providerStatus, scoreText, type LiveMatch, type ProviderMatchState,
} from "../src/core/models";

/** "yyyy-MM-dd HH:mm" in Asia/Shanghai (UTC+8, no DST) → epoch ms. */
function date(value: string): number {
  const [d, t] = value.split(" ");
  const [y, mo, da] = d.split("-").map(Number);
  const [h, mi] = t.split(":").map(Number);
  return Date.UTC(y, mo - 1, da, h, mi) - 8 * 3600_000;
}

function liveMatch(id: string, league: string, time = "09-05 20:00", extra: Partial<LiveMatch> = {}): LiveMatch {
  return { id, league, time, homeTeam: "A", awayTeam: "B", isHot: false, sources: [], ...extra };
}

function state(fields: Partial<ProviderMatchState> & Pick<ProviderMatchState, "sportID" | "code" | "periodStartedAt" | "updatedAt">): ProviderMatchState {
  return { matchType: 0, ...fields };
}

describe("MatchScheduleTests", () => {
  const originalTZ = process.env.TZ;
  afterEach(() => {
    if (originalTZ === undefined) delete process.env.TZ;
    else process.env.TZ = originalTZ;
  });

  it("testKickoffUsesCurrentYearInBeijingTime", () => {
    const now = date("2026-09-05 18:00");
    expect(kickoff("09-05 20:00", now)).toBe(date("2026-09-05 20:00"));
  });

  it("testKickoffSnapsAcrossNewYear", () => {
    expect(kickoff("01-02 03:00", date("2026-12-31 23:00"))).toBe(date("2027-01-02 03:00"));
    expect(kickoff("12-31 23:00", date("2027-01-01 01:00"))).toBe(date("2026-12-31 23:00"));
  });

  it("testStatusBuckets", () => {
    const now = date("2026-09-05 20:30");
    const status = (time: string) => matchStatus(liveMatch("x", "", time), now);
    expect(status("09-05 20:00")).toEqual({ kind: "unknown" });
    expect(status("09-05 21:15")).toEqual({ kind: "upcoming", startsInMinutes: 45 });
    expect(status("09-05 16:00")).toEqual({ kind: "unknown" });
    expect(status("待定")).toEqual({ kind: "unknown" });
  });

  // Swift passes the viewer zone explicitly; the TS port reads the process
  // zone, so the test switches process.env.TZ (Node applies it immediately).
  it("testDisplayTimeConvertsToViewerZone", () => {
    const now = date("2026-09-05 18:00");
    process.env.TZ = "Asia/Tokyo";
    const shown = displayTime("09-05 23:30", now);
    expect(shown.day).toBe("明天");
    expect(shown.clock).toBe("00:30");

    process.env.TZ = "Asia/Shanghai";
    const local = displayTime("09-05 23:30", now);
    expect(local.day).toBe("今天");
    expect(local.clock).toBe("23:30");
  });

  it("testFollowedFilterMatchesEitherTeam", () => {
    const match: LiveMatch = {
      id: "1", league: "NBA", time: "09-05 20:00", homeTeam: "湖人", awayTeam: "凯尔特人", isHot: false, sources: [],
    };
    expect(filterIncludes("关注", match, new Set(["凯尔特人"]))).toBe(true);
    expect(filterIncludes("关注", match, new Set(["勇士"]))).toBe(false);
  });

  it("testBadmintonComesFromListingSportCode", () => {
    const badminton = liveMatch("7001,131,7001", "印尼公开赛");
    expect(filterIncludes("羽毛球", badminton)).toBe(true);
    expect(filterIncludes("足球", badminton)).toBe(false);
    expect(filterIncludes("羽毛球", liveMatch("7002", "BWF世界巡回赛"))).toBe(true);
    expect(filterIncludes("羽毛球", liveMatch("4644105,1,4644105", "蒙古超"))).toBe(false);
    const youthBasketball = liveMatch("3944800,2,3944800", "U18女亚洲杯");
    expect(filterIncludes("篮球", youthBasketball)).toBe(true);
    expect(filterIncludes("足球", youthBasketball)).toBe(false);
    // Swift: SportFilter.tabs == [.all, .basketball, .badminton, .football]. TS has no
    // `tabs`; the sport tabs are the leading entries of ALL_FILTERS.
    expect(ALL_FILTERS.slice(0, 4)).toEqual(["全部", "篮球", "羽毛球", "足球"]);
  });

  it("testElapsedKickoffNeverProvesLiveOrFinished", () => {
    const now = date("2026-09-05 22:50");
    for (const league of ["美职联", "NBA", "未知联赛"]) {
      expect(matchStatus(liveMatch("x", league, "09-05 20:30"), now)).toEqual({ kind: "unknown" });
    }
  });

  it("testProviderStateOverridesElapsedKickoffForOvertimeAndPostponement", () => {
    const now = date("2026-09-06 10:30");
    const base: LiveMatch = {
      id: "one", league: "美职联", time: "09-06 07:30", homeTeam: "Home", awayTeam: "Away", isHot: false, sources: [],
    };
    const with_ = (code: number, sport = 1) =>
      matchStatus({ ...base, providerState: state({ sportID: sport, code, periodStartedAt: now, updatedAt: now }) }, now);
    expect(with_(4)).toEqual({ kind: "live", label: "加时赛" });
    expect(with_(6)).toEqual({ kind: "live", label: "点球大战" });
    expect(with_(8)).toEqual({ kind: "interrupted", label: "推迟" });
    expect(with_(7)).toEqual({ kind: "finished" });
    expect(with_(8, 2)).toEqual({ kind: "live", label: "加时" });
    expect(with_(9, 2)).toEqual({ kind: "finished" });
    expect(with_(0)).toEqual({ kind: "scheduled" });
  });

  it("testPeriodClockUsesSecondHalfStartAndExpiresWhenStale", () => {
    const now = date("2026-09-06 10:30");
    const second = state({ sportID: 1, code: 3, periodStartedAt: now - 8 * 60_000, updatedAt: now });
    expect(providerStatus(second, now)).toEqual({ kind: "live", label: "53′" });
    expect(providerStatus(second, now + 10 * 60_000)).toBeUndefined();
    const stoppage = state({ sportID: 1, code: 3, periodStartedAt: now - 51 * 60_000, updatedAt: now });
    expect(providerStatus(stoppage, now)).toEqual({ kind: "live", label: "90+" });
    expect(providerStatus(state({ sportID: 1, code: 2, periodStartedAt: now, updatedAt: now }), now))
      .toEqual({ kind: "live", label: "中场休息" });
  });
});

const KEY = Buffer.from("abcdabcdabcdabcd");
function decrypt(ciphertext: Uint8Array, key: Uint8Array): string {
  const decipher = createDecipheriv("aes-128-ecb", key, null);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
}
function encrypt(plaintext: string): string {
  const cipher = createCipheriv("aes-128-ecb", KEY, null);
  return Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]).toString("base64");
}

describe("EventSnapshotTests", () => {
  const now = 1_788_663_314 * 1000;

  const payloadJSON = (rows: unknown[][], timestamp = 1_788_663_314) => JSON.stringify({
    success: true, time: timestamp,
    list: { fields: ["id", "sportid", "status", "st_first", "st_second"], values: rows },
  });
  const payload = (rows: unknown[][], timestamp = 1_788_663_314) => `jrkanEvents(${payloadJSON(rows, timestamp)});`;

  const match = (id: string): LiveMatch => ({
    id, league: "Test", time: "09-06 07:30", homeTeam: "Home", awayTeam: "Away", isHot: false,
    sources: [{ id: "one", name: "Channel", pageURL: "https://fixture.example/play" }],
  });
  const score = (m: LiveMatch) => scoreText(m.providerState);

  it("testScoresRefreshWithTheEventSnapshotAndDoNotInventZeros", () => {
    const snapshot = (home: unknown, away: unknown, code = 3): EventSnapshot => parseEvents(JSON.stringify({
      success: true, time: now / 1000,
      list: {
        fields: ["id", "sportid", "status", "st_first", "st_second", "s1", "s2"],
        values: [[101, 1, code, 1_788_658_800_000, 1_788_662_771_000, home, away]],
      },
    }), decrypt, now);
    const input = [match("101,1,101")];
    const first = applyEvents(snapshot(0, 0), input);
    expect(score(first[0])).toBe("0 - 0");
    const updated = applyEvents(snapshot(1, 2), first);
    expect(score(updated[0])).toBe("1 - 2");
    expect(score(applyEvents(snapshot(1, 2, 7), input)[0])).toBe("1 - 2");
    expect(score(applyEvents(snapshot(0, 0, 0), input)[0])).toBeUndefined();
    expect(score(applyEvents(snapshot(null, 2), input)[0])).toBeUndefined();
    expect(score(applyEvents(snapshot(-1, 2), input)[0])).toBeUndefined();
    const basketball = state({ sportID: 2, code: 7, periodStartedAt: now, updatedAt: now, homeScore: 112, awayScore: 105 });
    expect(scoreText(basketball)).toBe("112 - 105");
  });

  it("testEventSnapshotMatchesCompositeIDsAndKeepsChannelChoices", () => {
    const response = payload([
      [101, 1, 3, 1_788_658_800_000, 1_788_662_771_000],
      [101, 2, 0, 1_788_663_600_000, 1_788_663_600_000],
    ]);
    const snapshot = parseEvents(response, decrypt, now);
    const input = [match("101,1,101"), match("101,2,101"), match("102,1,102"), match("other")];
    const output = applyEvents(snapshot, input);
    expect(output.map((m) => m.id)).toEqual(["101,1,101", "101,2,101", "other"]);
    expect(output[0].providerState?.code).toBe(3);
    expect(output[1].providerState?.code).toBe(0);
    expect(output[0].sources).toEqual(input[0].sources);
    expect(output[1].time).toBe("09-06 11:00");
  });

  it("testRejectsStaleOrMalformedSnapshotInsteadOfClearingSchedule", () => {
    expect(() => parseEvents(payload([], now / 1000 - 601), decrypt, now)).toThrow();
    expect(() => parseEvents(payload([[101, 1]]), decrypt, now)).toThrow();
    expect(() => parseEvents('jrkanEvents({"success":false})', decrypt, now)).toThrow();
    expect(() => parseEvents('jrkanEvents(["invalid","UMY="])', decrypt, now)).toThrow();
  });

  it("testDiscoversWebsiteConfigurationWithoutHardcodingItsHost", () => {
    const base = "https://site.example/";
    const html = `document.write("<script src='//data.example/tmp/njs.js?_t="+Math.random());`;
    expect(eventConfigURL(html, base)).toBe("https://data.example/tmp/njs.js");
    const config = `{"config":{"base_zqlq_url":"//data.example/tmp/event?type=zqlq"}}`;
    expect(eventFeedURL(config, base)).toBe("https://data.example/tmp/event?type=zqlq&callback=jrkanEvents");
  });

  it("testDecodesWebsiteEncryptedEnvelope", () => {
    const encrypted = "3N36qZhpphxYmdWBDeQb08YkwJCCunTowCuPexJi40p9eZeQ32NEFTUBghA5sSC4b2noY5MLY2WjkwUAvkRy6KLPB5+G9kKXmIC077s4DEi7jwJnkLKgDQzLC64ogCWZ2Fh25qmtgtzKgbriuGiI/RfJesyAipD00k9K14zZyCn4RsmL6+gcDnW2QCFTDbZQf0h5TdTgaJEM0gIam3iWeA==";
    const snapshot = parseEvents(`jrkanEvents(["${encrypted}","UMY="])`, decrypt, now);
    expect(snapshot.events["1,101"]?.state.code).toBe(3);
    expect(providerStatus(snapshot.events["1,101"]!.state, now)).toEqual({ kind: "live", label: "54′" });

    // TS-only extra: an envelope built with createCipheriv round-trips too.
    const built = encrypt(payloadJSON([[202, 2, 9, 1_788_658_800_000, 1_788_662_771_000]]));
    const roundTrip = parseEvents(`jrkanEvents(["${built}","UMY="]);`, decrypt, now);
    expect(roundTrip.events["2,202"]?.state.code).toBe(9);
  });
});

describe("ExperienceTests", () => {
  // Only the ProviderMatchState assertions; the MatchListModel/network half is not ported.
  it("testStatisticsAndContinueUseLatestEventSnapshot (provider-state part)", () => {
    const time = now() / 1000;
    const snapshot = parseEvents(JSON.stringify({
      success: true, time,
      list: {
        fields: ["id", "sportid", "status", "st_first", "st_second", "s1", "s2", "hs1", "hs2", "corner1", "corner2"],
        values: [[1, 1, 3, (time - 3600) * 1000, (time - 600) * 1000, 2, 0, 1, 0, 6, 3]],
      },
    }), decrypt, time * 1000);
    const event = snapshot.events["1,1"]!.state;
    expect(scoreText(event)).toBe("2 - 0");
    expect(halftimeText(event)).toBe("1 - 0");
    expect(cornersText(event)).toBe("6 - 3");

    const firstHalf = state({
      sportID: 1, code: 1, periodStartedAt: now(), updatedAt: now(),
      homeHalfScore: 1, awayHalfScore: 0, homeCorners: -1, awayCorners: 0,
    });
    expect(halftimeText(firstHalf)).toBeUndefined();
    expect(cornersText(firstHalf)).toBeUndefined();
    const basketball = state({
      sportID: 2, code: 5, periodStartedAt: now(), updatedAt: now(),
      homeScore: 54, awayScore: 58, homeHalfScore: 0, awayHalfScore: 0,
    });
    expect(halftimeText(basketball)).toBeUndefined();
    expect(basketballSummary(basketball)?.difference).toBe(4);
    expect(basketballSummary(basketball)?.total).toBe(112);
  });

  function now() {
    return Date.now();
  }
});
