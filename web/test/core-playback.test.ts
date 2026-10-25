// Port of the channel-order / playback-model cases of App/Tests/StreamResolverTests.swift
// and the PlaybackHealthTests + playback parts of App/Tests/ExperienceTests.swift.
//
// The Swift model resolves through a StreamResolver over a stubbed URLSession;
// the TS model calls the Worker via `api.resolve`, so that is mocked with the
// same outcomes: UnavailableStreamPage (only .m3u8 paths play),
// ExperienceProtocol (everything plays) and ResolverFixtureProtocol's
// slow.m3u8 (answers after 150 ms).
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { LiveMatch, MatchSource } from "../src/core/models";

const resolveImpl = vi.hoisted(() => ({
  current: (_source: { pageURL: string }): Promise<{ url: string }> => Promise.reject(new Error("unset")),
}));

vi.mock("../src/core/api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/core/api")>();
  return {
    ...actual,
    api: {
      ...actual.api,
      resolve: (source: MatchSource) => resolveImpl.current(source),
      channels: () => Promise.resolve({ channels: [] }),
    },
  };
});

import { PlaybackHealthMonitor } from "../src/core/health";
import { playbackOrdered, playbackPriority } from "../src/core/models";
import { MatchPlaybackModel } from "../src/core/playbackModel";
import { Preferences } from "../src/core/preferences";

/** In-memory localStorage so persistence (Preferences(store:) in Swift) is observable. */
function memoryStorage(): Storage {
  const data = new Map<string, string>();
  return {
    get length() { return data.size; },
    clear: () => data.clear(),
    getItem: (k) => data.get(k) ?? null,
    key: (i) => [...data.keys()][i] ?? null,
    removeItem: (k) => { data.delete(k); },
    setItem: (k, v) => { data.set(k, String(v)); },
  };
}

beforeEach(() => {
  vi.stubGlobal("localStorage", memoryStorage());
});
afterEach(() => {
  vi.unstubAllGlobals();
});

const isM3U8 = (url: string) => new URL(url).pathname.endsWith(".m3u8");
const unavailableStreamPage = (source: { pageURL: string }) =>
  isM3U8(source.pageURL)
    ? Promise.resolve({ url: source.pageURL })
    : Promise.reject(new Error("这条线路暂未提供可播放的视频。"));
const everythingPlays = (source: { pageURL: string }) => Promise.resolve({ url: source.pageURL });
const slowFixture = (source: { pageURL: string }) =>
  new Promise<{ url: string }>((resolve) => setTimeout(() => resolve({ url: source.pageURL }), 150));

const sorted = (set: Set<number>) => [...set].sort((a, b) => a - b);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function waitUntil(predicate: () => boolean) {
  for (let i = 0; i < 200; i++) {
    if (predicate()) return;
    await sleep(10);
  }
  throw new Error("Asynchronous playback transition did not complete");
}

describe("StreamResolverTests (playback model)", () => {
  it("testChannelPriorityHandlesSpacingFullWidthLettersAndStablePeers", () => {
    const names = ["主播解说①", "高清直播⑨", "中文高清 M⑧", "中文高清 Q⑦", "纬来体育⑤", "中文高清Ｑ⑥", "中文高清", "English", "主播中文高清Q"];
    const sources = names.map((name, i) => ({ id: String(i), name, pageURL: `https://fixture.example/${i}` }));
    expect(playbackOrdered(sources).map((s) => s.name)).toEqual(
      ["中文高清 Q⑦", "中文高清Ｑ⑥", "中文高清 M⑧", "纬来体育⑤", "中文高清", "高清直播⑨", "English", "主播解说①", "主播中文高清Q"],
    );
  });

  it("testAutomaticPlaybackExhaustsQThenMBeforeHostRegardlessOfHistory", async () => {
    resolveImpl.current = unavailableStreamPage;
    const prefs = new Preferences();
    const namesAndPaths: [string, string][] = [["主播①", "host.m3u8"], ["中文高清 M①", "first-m.html"],
      ["中文高清 Q①", "q-one.html"], ["中文高清 M②", "second-m.m3u8"],
      ["中文高清 Q②", "q-two.html"], ["中文高清", "other.m3u8"]];
    const sources = namesAndPaths.map(([name, path], i) => ({ id: String(i), name, pageURL: `https://fixture.example/${path}` }));
    const match: LiveMatch = { id: "auto", league: "NBA", time: "10-24 10:00", homeTeam: "湖人", awayTeam: "快船", isHot: false, sources };
    prefs.recordPlaybackSuccess(match, sources[0], 0, 0.1);
    const model = new MatchPlaybackModel(match, prefs);
    expect(model.suggestedChannel && playbackPriority(model.suggestedChannel)).toBe(0);
    await model.startSuggestedPlayback();
    expect(model.playback?.sourceName).toBe("中文高清 M②");
    expect(sorted(model.failedResolutionIndices)).toEqual([0, 1, 2]);
    expect(model.resolvedChannels[model.playback!.index].name).toBe("中文高清 M②");
    expect(model.nextUntriedIndex(model.playback!.index)).toBe(4);
    model.stopPlayback();
  });

  it("testStoppingDuringResolutionDoesNotReopenPlayer", async () => {
    resolveImpl.current = slowFixture;
    const prefs = new Preferences();
    const match: LiveMatch = {
      id: "stop", league: "Test", time: "09-06 07:30", homeTeam: "Home", awayTeam: "Away", isHot: false,
      sources: [{ id: "one", name: "Line", pageURL: "https://fixture.example/slow.m3u8" }],
    };
    const model = new MatchPlaybackModel(match, prefs);
    const task = model.startPlayback(0);
    await sleep(30);
    expect(model.resolvingIndex).toBe(0);
    model.stopPlayback();
    await task;
    expect(model.playback).toBeUndefined();
    expect(model.resolvingIndex).toBeUndefined();
  });

  it("testFallbackDoesNotRetryFailedChannelsAfterOtherChannelsStalled", async () => {
    resolveImpl.current = unavailableStreamPage;
    const prefs = new Preferences();
    prefs.autoNextChannel = true;
    const channels = [0, 1, 2, 3, 4].map((index) => ({
      id: String(index), name: `Line ${index}`,
      pageURL: index < 3 ? `https://fixture.example/${index}.html` : `https://fixture.example/${index}.m3u8`,
    }));
    const match: LiveMatch = {
      id: "fallback", league: "Test", time: "09-06 07:30", homeTeam: "Home", awayTeam: "Away", isHot: false, sources: channels,
    };
    const model = new MatchPlaybackModel(match, prefs);

    await model.startPlayback(3);
    expect(model.playback?.index).toBe(3);
    prefs.autoNextChannel = false;
    model.handleStall("No picture");
    await model.startPlayback(4, false);
    model.handleStall("No picture");
    prefs.autoNextChannel = true;
    await model.startPlayback(0, false);

    expect(sorted(model.failedResolutionIndices)).toEqual([0, 1, 2]);
    expect(sorted(model.stalledIndices)).toEqual([3, 4]);
    expect(model.nextUntriedIndex(2)).toBeUndefined();
    expect(model.retryActionTitle).toBe("重试");
    expect(model.errorMessage?.includes("2 条没有画面，3 条暂不可用")).toBe(true);

    await model.startPlayback(3);
    expect(model.failedResolutionIndices.size).toBe(0);
    expect(model.stalledIndices.size).toBe(0);
    expect(model.playback?.index).toBe(3);
  });

  it("testSelectedHDTriesAnotherHDBeforeSuccessfulHostChannel", () => {
    const prefs = new Preferences();
    const sources = ["主播解说①", "中文高清 Q②", "中文高清 M③"].map((name, i) => ({
      id: String(i), name, pageURL: `https://fixture.example/${i}.html`,
    }));
    const match: LiveMatch = { id: "hd", league: "NBA", time: "10-24 10:00", homeTeam: "湖人", awayTeam: "快船", isHot: false, sources };
    prefs.recordPlaybackSuccess(match, sources[0], 0, 1);
    const model = new MatchPlaybackModel(match, prefs);
    expect(model.resolvedChannels.map((c) => c.name)).toEqual(["中文高清 Q②", "中文高清 M③", "主播解说①"]);
    expect(model.nextUntriedIndex(0)).toBe(1);
    expect(model.nextUntriedIndex(2)).toBe(0);
  });
});

describe("PlaybackHealthTests", () => {
  it("testLateFirstFrameCanFinishConfirmationAfterStartupDeadline", () => {
    const monitor = new PlaybackHealthMonitor(0);
    for (let halfSecond = 1; halfSecond <= 37; halfSecond++) {
      expect(monitor.sample(halfSecond / 2, 0, false, false, false, false)).toBeUndefined();
    }
    for (let halfSecond = 38; halfSecond <= 41; halfSecond++) {
      expect(monitor.sample(halfSecond / 2, (halfSecond - 37) / 2, true, false, true, false)).toBeUndefined();
    }
    expect(monitor.sample(21, 2.5, true, false, true, false)).toEqual({ kind: "confirmed", startupSeconds: 19 });
  });

  it("testContinuesMonitoringAfterFirstFrameAndDetectsFrozenPlayback", () => {
    const monitor = new PlaybackHealthMonitor(0);
    let confirmations = 0;
    for (let second = 1; second <= 5; second++) {
      if (monitor.sample(second, second, true, false, true, false)?.kind === "confirmed") confirmations += 1;
    }
    expect(confirmations).toBe(1);
    expect(monitor.confirmed).toBe(true);
    expect(monitor.sample(16, 5, true, false, true, false)).toBeUndefined();
    expect(monitor.sample(17, 5, true, false, true, false)).toEqual({ kind: "stalled" });
    expect(monitor.sample(18, 5, true, false, true, false)).toBeUndefined();
  });

  it("testPauseIsNotAStallAndResumeRestartsTheWaitingWindow", () => {
    const monitor = new PlaybackHealthMonitor(0);
    for (let second = 1; second <= 4; second++) monitor.sample(second, second, true, false, true, false);
    expect(monitor.sample(100, 4, false, true, true, false)).toBeUndefined();
    expect(monitor.sample(1000, 4, false, true, true, false)).toBeUndefined();
    expect(monitor.sample(1001, 5, true, false, true, false)).toBeUndefined();
    expect(monitor.sample(1012, 5, false, false, true, false)).toBeUndefined();
    expect(monitor.sample(1013, 5, false, false, true, false)).toEqual({ kind: "stalled" });
  });

  it("testStartupNeedsActualVideoAndFailureIsImmediate", () => {
    const monitor = new PlaybackHealthMonitor(0);
    expect(monitor.sample(19, 19, true, false, false, false)).toBeUndefined();
    expect(monitor.sample(20, 20, true, false, false, false)).toEqual({ kind: "stalled" });
    const failed = new PlaybackHealthMonitor(0);
    expect(failed.sample(1, Number.NaN, false, true, false, true)).toEqual({ kind: "stalled" });
  });
});

describe("ExperienceTests", () => {
  const source = (index: number): MatchSource => ({
    id: String(index), name: `Line ${index}`, pageURL: `https://experience.example/${index}.m3u8`,
  });
  const match = (id = "1,1,1"): LiveMatch => ({
    id, league: "League", time: "09-06 12:00", homeTeam: "Home", awayTeam: "Away", isHot: false,
    sources: [source(0), source(1), source(2)],
  });

  it("testRankingUsesSuccessLatencyAndTemporaryFailureCooldown", () => {
    const prefs = new Preferences();
    const sources = [source(0), source(1), source(2)];
    prefs.recordPlaybackFailure(sources[0]);
    expect(prefs.rankedIndices(sources, "new")[0]).toBe(1);
    prefs.recordPlaybackSuccess(match("a"), sources[1], 1, 8);
    prefs.recordPlaybackSuccess(match("b"), sources[2], 2, 2);
    expect(prefs.rankedIndices(sources, "new")[0]).toBe(2);
    expect(prefs.rankedIndices(sources, "a")[0]).toBe(1);
    prefs.recordPlaybackFailure(sources[1]);
    expect(prefs.rankedIndices(sources, "a")[0]).toBe(2);
  });

  it("testHistoryPersistsOnlyMatchEntrancesAndIsBoundedAndClearable", () => {
    const prefs = new Preferences();
    for (let index = 0; index < 12; index++) {
      const item: LiveMatch = {
        ...match(String(index)),
        providerState: { sportID: 1, code: 3, periodStartedAt: Date.now(), updatedAt: Date.now(), matchType: 0 },
      };
      prefs.recordPlaybackSuccess(item, source(0), 0, 1);
    }
    const restored = new Preferences();
    expect(restored.recentWatches.length).toBe(10);
    expect(restored.recentWatches[0]?.match.id).toBe("11");
    expect(restored.recentWatches[0]?.match.providerState).toBeUndefined();
    expect(restored.recentWatches[0]?.match.sources).toEqual(match().sources);
    restored.clearHistory();
    expect(restored.hasHistory).toBe(false);
    expect(new Preferences().recentWatches.length).toBe(0);
  });

  it("testResolutionAloneDoesNotCreateHistoryAndConfirmedCallbacksAreIdempotent", async () => {
    resolveImpl.current = everythingPlays;
    const prefs = new Preferences();
    const model = new MatchPlaybackModel(match(), prefs);
    await model.startPlayback(0);
    expect(model.playback).toBeDefined();
    expect(prefs.recentWatches.length).toBe(0);
    expect(prefs.lastChannels[match().id]).toBeUndefined();
    model.confirmPlayback(-1, 1); // Swift: a fresh UUID() that is not the current request.
    expect(prefs.recentWatches.length).toBe(0);
    const id = model.playback!.id;
    model.confirmPlayback(id, 1);
    model.confirmPlayback(id, 1);
    expect(prefs.recentWatches.length).toBe(1);
    expect(prefs.channelPerformance[source(0).pageURL]?.successes).toBe(1);
    model.stopPlayback();
  });

  it("testMidstreamFailureReconnectsOnceThenSwitchesAndIgnoresOldCallbacks", async () => {
    resolveImpl.current = everythingPlays;
    const prefs = new Preferences();
    const model = new MatchPlaybackModel(match(), prefs);
    await model.startPlayback(0);
    const first = model.playback!;
    expect(first).toBeDefined();
    model.confirmPlayback(first.id, 1);
    const now = Date.now();
    model.handleStall("Disconnected", first.id, now);
    await waitUntil(() => model.playback !== undefined && model.playback.id !== first.id);
    const reconnected = model.playback!;
    expect(reconnected.index).toBe(0);
    model.confirmPlayback(reconnected.id, 1);
    model.handleStall("Disconnected again", reconnected.id, now + 10_000);
    await waitUntil(() => model.playback?.index === 1);
    const next = model.playback!;
    model.handleStall("Late old event", reconnected.id);
    expect(model.playback?.id).toBe(next.id);
    model.stopPlayback();
  });
});
