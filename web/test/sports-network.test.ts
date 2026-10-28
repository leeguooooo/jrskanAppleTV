// Network-flow ports of MultiSportsTests (fallback + preferred-source recovery,
// Tencent batch already shown → Migu), the polling controller, the danmaku
// queue and the Worker allowlist.
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { LiveMatch, MatchSource } from "../src/core/models";
import { MultiSportsClient } from "../src/sports/client";
import { DanmakuQueue, MatchInsightsController, STATUS } from "../src/sports/controller";
import { allowSportsURL, handleSportsProxy } from "../worker/sports";
import { configureEgress } from "../worker/egress";

type Fixture = Record<string, any>;
const contract = (name: string): Fixture =>
  JSON.parse(readFileSync(new URL(`../../contracts/${name}`, import.meta.url), "utf8"));
const multi = contract("multi-sports.json");
const tencentFixture = contract("tencent-sports.json");

const MID = "100000:10022600102";
const game = (home = "湖人", away = "快船", time = "10-24 10:00"): LiveMatch =>
  ({ id: "test", league: "NBA", time, homeTeam: home, awayTeam: away, isHot: false, sources: [] });
const channels: MatchSource[] = [{ id: "t", name: "中文高清Q", pageURL: "https://fixture.example/play/kbs/?id=10022600102" }];
const catalogHTML = () => `<script>window.__INITIAL_GROUPS_STATE__ = {"rows":[${JSON.stringify(multi.catalog)}]};</script>`;

type Handler = (url: URL) => string | undefined;
function client(handler: () => Handler, now: () => number) {
  const calls: string[] = [];
  const fetchText = async (raw: string) => {
    calls.push(raw);
    const body = handler()(new URL(raw));
    if (body === undefined) throw new Error("offline");
    return body;
  };
  return { client: new MultiSportsClient({ fetchText, now }), calls };
}

describe("MultiSportsClient comments (testAlreadyDisplayedTencentBatchAllowsFreshMiguComments)", () => {
  it("prefers unseen Tencent, then Migu, then nothing — never replays", async () => {
    const now = Date.parse("2026-10-24T02:00:00Z");
    const detail = { code: 0, data: { matchInfo: { mid: MID, leftName: "湖人", rightName: "快船", startTime: "2026-10-24 10:00:00" } } };
    const comments = { code: 0, data: { list: [{ commentId: "one", mid: MID, type: "0", postTime: (now - 1000) / 1000, content: "腾讯新评论" }] } };
    const migu = { code: 200, body: { commentInfoList: [{ commentId: "two", contentId: "120000588273", objectId: "120000588273",
      createTime: now - 1000, body: "咪咕新评论", top: false }] } };
    const { client: c, calls } = client(() => (url) => {
      if (url.pathname === "/kbs/matchDetail") return JSON.stringify(detail);
      if (url.pathname === "/dmComment/liveList") return JSON.stringify(comments);
      if (url.pathname.startsWith("/p/home/")) return catalogHTML();
      if (url.pathname.includes("/comment/")) return JSON.stringify(migu);
      return undefined;
    }, () => now);
    expect((await c.comments(game(), channels)).map((x) => x.id)).toEqual(["tencent:one"]);
    expect((await c.comments(game(), channels, new Set(["tencent:one"]))).map((x) => x.id)).toEqual(["migu:two"]);
    expect(await c.comments(game(), channels, new Set(["tencent:one", "migu:two"]))).toEqual([]);
    // Tencent verification happens once per match; the catalog is fetched once.
    expect(calls.filter((u) => u.includes("/kbs/matchDetail"))).toHaveLength(1);
    expect(calls.filter((u) => u.includes("/p/home/"))).toHaveLength(1);
    expect(calls.find((u) => u.includes("/dmComment/"))).toBe(
      "https://app.sports.qq.com/dmComment/liveList?commentId=0&mid=100000%3A10022600102&topN=20");
  });

  it("does not show Tencent comments when matchDetail disagrees", async () => {
    const now = Date.parse("2026-10-24T02:00:00Z");
    const detail = { code: 0, data: { matchInfo: { mid: MID, leftName: "湖人", rightName: "勇士", startTime: "2026-10-24 10:00:00" } } };
    const comments = { code: 0, data: { list: [{ commentId: "one", mid: MID, type: "0", postTime: (now - 1000) / 1000, content: "x" }] } };
    const { client: c } = client(() => (url) => {
      if (url.pathname === "/kbs/matchDetail") return JSON.stringify(detail);
      if (url.pathname === "/dmComment/liveList") return JSON.stringify(comments);
      if (url.pathname.startsWith("/p/home/")) return catalogHTML();
      if (url.pathname.includes("/comment/")) return JSON.stringify({ code: 200, body: { commentInfoList: [] } });
      return undefined;
    }, () => now);
    expect(await c.comments(game(), channels)).toEqual([]);
  });
});

describe("MultiSportsClient statistics (testNetworkFallbackWithoutTencentIDAndPreferredSourceRecovery)", () => {
  it("falls back to Migu, recovers Tencent next poll without touching fallbacks, works with no Tencent id", async () => {
    const now = multi.nowMs as number;
    const preferred = structuredClone(tencentFixture.statistics);
    preferred.teamInfo.startTime = "2026-10-24 10:00:00";
    let handler: Handler = (url) => {
      if (url.pathname.startsWith("/p/home/")) return catalogHTML();
      if (url.pathname.includes("/live/statistics/")) return JSON.stringify(multi.migu);
      return "{}";
    };
    const { client: c, calls } = client(() => handler, () => now);
    const first = await c.statistics(game(), channels);
    expect(first.sourceName).toBe("咪咕视频");

    calls.length = 0;
    handler = (url) => (url.hostname === "matchweb.sports.qq.com" ? JSON.stringify({ code: 0, data: preferred }) : undefined);
    const partials: string[] = [];
    const restored = await c.statistics(game(), channels, (p) => partials.push(p.sourceName));
    expect(restored.sourceName).toBe("腾讯体育");
    expect(restored.scoreSourceName).toBe("腾讯体育");
    expect(calls.every((u) => u.startsWith("https://matchweb.sports.qq.com/kbs/matchStat?mid="))).toBe(true);
    expect(partials).toEqual(["腾讯体育"]);

    handler = (url) => (url.pathname.includes("/live/statistics/") ? JSON.stringify(multi.migu) : "{}");
    expect((await c.statistics(game(), [])).sourceName).toBe("咪咕视频");
  });

  it("throws when no provider matches", async () => {
    const { client: c } = client(() => () => "{}", () => multi.nowMs);
    await expect(c.statistics(game(), [])).rejects.toThrow();
  });
});

describe("MatchInsightsController", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("polls statistics every 10 s only while started", async () => {
    let count = 0;
    const fake = { statistics: async () => { count++; throw new Error("down"); }, comments: async () => [] } as unknown as MultiSportsClient;
    const ctl = new MatchInsightsController(game(), channels, { client: fake });
    const statuses: string[] = [];
    ctl.subscribe((s) => statuses.push(s.status));
    ctl.start();
    ctl.start(); // idempotent
    await vi.advanceTimersByTimeAsync(0);
    expect(count).toBe(1);
    expect(ctl.state.status).toBe(STATUS.unavailable);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(count).toBe(2);
    ctl.stop();
    await vi.advanceTimersByTimeAsync(120_000);
    expect(count).toBe(2);
    expect(statuses[0]).toBe(STATUS.matching);
  });

  it("counts slow requests toward the interval without overlapping or catching up", async () => {
    const starts: number[] = [];
    let duration = 4_000;
    const fake = { statistics: async () => {
      starts.push(Date.now());
      await new Promise((resolve) => setTimeout(resolve, duration));
      throw new Error("down");
    } } as unknown as MultiSportsClient;
    const ctl = new MatchInsightsController(game(), channels, { client: fake });
    const start = Date.now();
    ctl.start();
    await vi.advanceTimersByTimeAsync(9_999);
    expect(starts).toEqual([start]);
    duration = 25_000;
    await vi.advanceTimersByTimeAsync(1);
    expect(starts).toEqual([start, start + 10_000]);
    await vi.advanceTimersByTimeAsync(25_999);
    expect(starts).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(starts).toEqual([start, start + 10_000, start + 36_000]);
    ctl.stop();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(starts).toHaveLength(3);
  });

  it("manual refresh runs immediately, deduplicates in-flight polls and stops when hidden", async () => {
    let calls = 0;
    const fake = { statistics: async () => {
      calls++;
      await new Promise((resolve) => setTimeout(resolve, 4_000));
      throw new Error("offline");
    } } as unknown as MultiSportsClient;
    const ctl = new MatchInsightsController(game(), channels, { client: fake });
    ctl.refresh();
    expect(calls).toBe(0);
    ctl.start();
    expect(ctl.state.refreshing).toBe(true);
    ctl.refresh();
    expect(calls).toBe(1);
    await vi.advanceTimersByTimeAsync(4_000);
    expect(ctl.state.refreshing).toBe(false);
    ctl.refresh();
    expect(calls).toBe(2);
    ctl.refresh();
    expect(calls).toBe(2);
    ctl.stop();
    expect(ctl.state.refreshing).toBe(false);
    await vi.advanceTimersByTimeAsync(60_000);
    ctl.refresh();
    expect(calls).toBe(2);
  });

  it("unsupported leagues never poll", async () => {
    const fake = { statistics: vi.fn(), comments: vi.fn() } as unknown as MultiSportsClient;
    const ctl = new MatchInsightsController({ ...game(), league: "英超" }, [], { client: fake });
    ctl.start(); ctl.startComments();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(ctl.state.status).toBe(STATUS.unsupported);
    expect(ctl.state.key).toBeUndefined();
    expect((fake.statistics as any).mock.calls.length + (fake.comments as any).mock.calls.length).toBe(0);
  });

  it("comments: 10 s polls, ID dedupe, 120 s expiry, stop clears", async () => {
    let now = 1_000_000;
    const batches = [
      [{ id: "a", text: "1", postedAt: now - 1000 }, { id: "a", text: "1", postedAt: now - 1000 }],
      [{ id: "a", text: "1", postedAt: now - 1000 }, { id: "b", text: "2", postedAt: now + 9000 }],
    ];
    const excluded: string[][] = [];
    const fake = {
      statistics: async () => { throw new Error("x"); },
      comments: async (_m: LiveMatch, _c: MatchSource[], excluding: Set<string>) => { excluded.push([...excluding]); return batches.shift() ?? []; },
    } as unknown as MultiSportsClient;
    const ctl = new MatchInsightsController(game(), channels, { client: fake, now: () => now });
    ctl.startComments();
    await vi.advanceTimersByTimeAsync(0);
    expect(ctl.state.comments.map((c) => c.id)).toEqual(["a"]);
    now += 10_000;
    await vi.advanceTimersByTimeAsync(10_000);
    expect(ctl.state.comments.map((c) => c.id)).toEqual(["a", "b"]);
    expect(excluded[1]).toEqual(["a"]);
    now += 120_000;
    await vi.advanceTimersByTimeAsync(10_000);
    expect(ctl.state.comments).toEqual([]);
    ctl.stopComments();
    const calls = excluded.length;
    await vi.advanceTimersByTimeAsync(60_000);
    expect(excluded.length).toBe(calls);
  });
});

describe("DanmakuQueue", () => {
  it("dedupes, caps at 20 newest, skips expired", () => {
    const now = 500_000;
    const q = new DanmakuQueue(() => now);
    const c = (id: string, postedAt = now) => ({ id, text: id, postedAt });
    q.offer([c("x"), c("x")]);
    q.offer([c("x")]);
    expect(q.size).toBe(1);
    q.offer(Array.from({ length: 30 }, (_, i) => c(`n${i}`)));
    expect(q.size).toBe(20);
    expect(q.next()?.id).toBe("n10");
    q.clearPending();
    q.offer([c("old", now - 120_000), c("fresh")]);
    expect(q.next()?.id).toBe("fresh");
    expect(q.next()).toBeUndefined();
    q.offer([c("fresh")]);
    expect(q.size).toBe(0); // shown once, never replayed
  });
});

describe("worker sports proxy allowlist", () => {
  const allowed = [
    "https://matchweb.sports.qq.com/kbs/matchDetail?mid=100000%3A10022600102",
    "https://matchweb.sports.qq.com/kbs/matchStat?mid=100008:10011111111&_t=1",
    "https://app.sports.qq.com/dmComment/liveList?commentId=0&mid=100000%3A10022600102&topN=20",
    "https://www.miguvideo.com/p/home/3cd6ba04967742879aaa40bee02a99a6",
    "https://www.miguvideo.com/p/home/494d21a4d6ee453b8b86bd3bb7658ed6",
    "https://v0-sc.miguvideo.com/oes-sport-static/10/live/statistics/120000588273",
    "https://webapi.miguvideo.com/gateway/interaction/v2/comment/1/20/120000588273/40/NEW?clientType=1",
    "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=20261023",
    "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=401909848",
  ];
  const rejected = [
    "http://matchweb.sports.qq.com/kbs/matchStat?mid=100000:10022600102",
    "https://user:pw@matchweb.sports.qq.com/kbs/matchStat?mid=100000:10022600102",
    "https://matchweb.sports.qq.com:8443/kbs/matchStat?mid=100000:10022600102",
    "https://matchweb.sports.qq.com.evil.com/kbs/matchStat?mid=100000:10022600102",
    "https://evilmatchweb.sports.qq.com/kbs/matchStat?mid=100000:10022600102",
    "https://matchweb.sports.qq.com/kbs/other?mid=100000:10022600102",
    "https://matchweb.sports.qq.com/kbs/matchStat?mid=100000:10022600102&cb=x",
    "https://matchweb.sports.qq.com/kbs/matchStat?mid=999:1",
    "https://matchweb.sports.qq.com/kbs/matchStat",
    "https://matchweb.sports.qq.com/kbs/../admin?mid=100000:10022600102",
    "https://www.miguvideo.com/p/home/other",
    "https://webapi.miguvideo.com/gateway/interaction/v2/comment/1/20/120000588273/40/NEW",
    "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard?dates=20261023",
    "https://example.com/",
    "javascript:alert(1)",
    "",
  ];
  it("accepts exactly the app endpoints", () => {
    for (const url of allowed) expect(allowSportsURL(url), url).toBeDefined();
    for (const url of rejected) expect(allowSportsURL(url), url).toBeUndefined();
    expect(allowSportsURL(allowed[1])?.canonical).toBe("https://matchweb.sports.qq.com/kbs/matchStat?mid=100008%3A10011111111");
  });

  const ctx = { waitUntil() {} };
  const call = (url: string, init?: RequestInit) =>
    handleSportsProxy(new Request(`https://app.test/api/sports?url=${encodeURIComponent(url)}`, init), ctx);

  // These cases stub global fetch; production goes through the relay (test/relay.test.ts).
  beforeEach(() => configureEgress({ EGRESS: "direct" }));
  afterEach(() => vi.unstubAllGlobals());

  it("sets Tencent referer only for qq hosts, strips cookies, passes content-type", async () => {
    const seen: { url: string; headers: Headers; redirect?: string }[] = [];
    vi.stubGlobal("fetch", async (input: string, init: RequestInit) => {
      seen.push({ url: input, headers: new Headers(init.headers), redirect: init.redirect });
      return new Response("{\"code\":0}", { headers: { "content-type": "application/json", "set-cookie": "a=b" } });
    });
    const tencent = await call(allowed[1]);
    expect(tencent.status).toBe(200);
    expect(tencent.headers.get("content-type")).toBe("application/json");
    expect(tencent.headers.get("cache-control")).toBe("private, no-store");
    expect(tencent.headers.get("set-cookie")).toBeNull();
    expect(await tencent.text()).toBe("{\"code\":0}");
    expect(seen[0].headers.get("referer")).toBe("https://sports.qq.com/");
    expect(seen[0].headers.get("user-agent")).toContain("Safari/605.1.15");
    expect(seen[0].headers.get("cookie")).toBeNull();
    expect(seen[0].redirect).toBe("manual");
    expect(new URL(seen[0].url).searchParams.get("_t")).toMatch(/^\d+$/);
    await call(allowed[6]);
    expect(seen[1].headers.get("referer")).toBeNull();
    expect(seen[1].url).toBe(allowed[6]);
  });

  it("400 for disallowed, 405 for non-GET, 502 for upstream errors and oversize", async () => {
    vi.stubGlobal("fetch", async () => new Response("x".repeat(10), { status: 500 }));
    expect((await call("https://example.com/")).status).toBe(400);
    expect((await call(allowed[0], { method: "POST", body: "x" })).status).toBe(405);
    expect((await call(allowed[0])).status).toBe(502);
    vi.stubGlobal("fetch", async () => new Response("x", { status: 302, headers: { location: "https://evil.example/" } }));
    expect((await call(allowed[0])).status).toBe(502);
    vi.stubGlobal("fetch", async () => new Response(new Uint8Array(2 * 1024 * 1024 + 1)));
    expect((await call(allowed[0])).status).toBe(502);
  });

  it("compacts the Migu schedule page", async () => {
    const page = `<html>${"x".repeat(1000)}<script>window.__INITIAL_GROUPS_STATE__ = {"a":[${JSON.stringify({ ...multi.catalog, extra: "y".repeat(500) })}]};</script></html>`;
    vi.stubGlobal("fetch", async () => new Response(page, { headers: { "content-type": "text/html" } }));
    const response = await call(allowed[3]);
    const text = await response.text();
    expect(text.length).toBeLessThan(page.length);
    expect(text).toContain("120000588273");
    expect(text).not.toContain("yyyy");
  });
});
