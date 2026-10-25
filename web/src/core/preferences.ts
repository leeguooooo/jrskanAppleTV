// Port of App/Sources/Shared/Preferences.swift. Everything stays in this
// browser's localStorage, like UserDefaults on the device.
import { playbackPriority, type LiveMatch, type MatchSource, type SportFilter, ALL_FILTERS } from "./models";
import { Observable, storage } from "./store";

export interface LastChannel { name: string; index: number; watchedAt: number }
export interface RecentWatch { match: LiveMatch; channelName: string; watchedAt: number }
export interface ChannelPerformance {
  successes: number;
  failures: number;
  averageStartup: number;
  lastFailure?: number;
  updatedAt: number;
}

const DAY = 86400_000;
const KEYS = {
  favoriteTeams: "favoriteTeams",
  autoRefresh: "autoRefresh",
  autoNextChannel: "autoNextChannel",
  danmaku: "danmaku",
  lastFilter: "lastFilter",
  lastChannels: "lastChannels",
  recentWatches: "recentWatches",
  channelPerformance: "channelPerformance",
};

function reliability(p: ChannelPerformance): number {
  return (p.successes + 1) / (p.successes + p.failures + 2);
}

function freshPerformance(now: number): ChannelPerformance {
  return { successes: 0, failures: 0, averageStartup: 20, updatedAt: now };
}

export class Preferences extends Observable {
  favoriteTeams: Set<string>;
  /** Re-fetch the schedule every few minutes while the list is on screen. */
  autoRefresh: boolean;
  /** When a channel fails to resolve or never shows a picture, move on to the next one. */
  autoNextChannel: boolean;
  /** Live comments over the video (Tencent / Migu). */
  danmaku: boolean;
  lastFilter: SportFilter;
  lastChannels: Record<string, LastChannel>;
  recentWatches: RecentWatch[];
  channelPerformance: Record<string, ChannelPerformance>;

  constructor(now = Date.now()) {
    super();
    this.favoriteTeams = new Set(storage.get<string[]>(KEYS.favoriteTeams, []));
    this.autoRefresh = storage.get(KEYS.autoRefresh, true);
    this.autoNextChannel = storage.get(KEYS.autoNextChannel, true);
    this.danmaku = storage.get(KEYS.danmaku, true);
    const filter = storage.get<string>(KEYS.lastFilter, "全部");
    this.lastFilter = (ALL_FILTERS as string[]).includes(filter) ? (filter as SportFilter) : "全部";
    // Match IDs are per fixture; anything older than a week is long over.
    this.lastChannels = Object.fromEntries(Object.entries(storage.get<Record<string, LastChannel>>(KEYS.lastChannels, {}))
      .filter(([, v]) => now - v.watchedAt < 7 * DAY));
    this.recentWatches = storage.get<RecentWatch[]>(KEYS.recentWatches, [])
      .filter((r) => now - r.watchedAt < 7 * DAY).slice(0, 10);
    this.channelPerformance = Object.fromEntries(Object.entries(storage.get<Record<string, ChannelPerformance>>(KEYS.channelPerformance, {}))
      .filter(([, v]) => now - v.updatedAt < 30 * DAY));
  }

  private save() {
    storage.set(KEYS.favoriteTeams, [...this.favoriteTeams].sort());
    storage.set(KEYS.autoRefresh, this.autoRefresh);
    storage.set(KEYS.autoNextChannel, this.autoNextChannel);
    storage.set(KEYS.danmaku, this.danmaku);
    storage.set(KEYS.lastFilter, this.lastFilter);
    storage.set(KEYS.lastChannels, this.lastChannels);
    storage.set(KEYS.recentWatches, this.recentWatches);
    storage.set(KEYS.channelPerformance, this.channelPerformance);
    this.changed();
  }

  set<K extends "autoRefresh" | "autoNextChannel" | "danmaku" | "lastFilter">(key: K, value: this[K]) {
    this[key] = value;
    this.save();
  }

  // MARK: Favorites

  isFavorite(team: string) {
    return this.favoriteTeams.has(team);
  }

  toggleFavorite(team: string) {
    if (this.favoriteTeams.has(team)) this.favoriteTeams.delete(team);
    else this.favoriteTeams.add(team);
    this.save();
  }

  follows(match: LiveMatch) {
    return this.favoriteTeams.has(match.homeTeam) || this.favoriteTeams.has(match.awayTeam);
  }

  // MARK: Watch history

  recordPlaybackSuccess(match: LiveMatch, source: MatchSource, index: number, startup: number, now = Date.now()) {
    this.lastChannels[match.id] = { name: source.name, index, watchedAt: now };
    // History never pretends old live data is current.
    const saved: LiveMatch = { ...match, providerState: undefined };
    this.recentWatches = [
      { match: saved, channelName: source.name, watchedAt: now },
      ...this.recentWatches.filter((r) => r.match.id !== match.id && now - r.watchedAt < 7 * DAY),
    ].slice(0, 10);
    const performance = { ...(this.channelPerformance[source.pageURL] ?? freshPerformance(now)) };
    const elapsed = Math.min(120, Math.max(0, startup));
    performance.averageStartup = performance.successes === 0 ? elapsed : performance.averageStartup * 0.7 + elapsed * 0.3;
    performance.successes += 1;
    performance.lastFailure = undefined;
    performance.updatedAt = now;
    this.channelPerformance[source.pageURL] = performance;
    this.prunePerformance(now);
    this.save();
  }

  recordPlaybackFailure(source: MatchSource, now = Date.now()) {
    const performance = { ...(this.channelPerformance[source.pageURL] ?? freshPerformance(now)) };
    performance.failures += 1;
    performance.lastFailure = now;
    performance.updatedAt = now;
    this.channelPerformance[source.pageURL] = performance;
    this.prunePerformance(now);
    this.save();
  }

  private prunePerformance(now: number) {
    this.channelPerformance = Object.fromEntries(Object.entries(this.channelPerformance)
      .filter(([, v]) => now - v.updatedAt < 30 * DAY)
      .sort((a, b) => b[1].updatedAt - a[1].updatedAt)
      .slice(0, 300));
  }

  rankedIndices(sources: MatchSource[], matchID: string, now = Date.now()): number[] {
    const last = this.lastChannels[matchID]?.name;
    return sources.map((_, i) => i).sort((lhs, rhs) => {
      const pa = playbackPriority(sources[lhs]), pb = playbackPriority(sources[rhs]);
      if (pa !== pb) return pa - pb;
      const a = this.channelPerformance[sources[lhs].pageURL] ?? freshPerformance(now);
      const b = this.channelPerformance[sources[rhs].pageURL] ?? freshPerformance(now);
      const aCooling = a.lastFailure !== undefined && now - a.lastFailure < 300_000;
      const bCooling = b.lastFailure !== undefined && now - b.lastFailure < 300_000;
      if (aCooling !== bCooling) return aCooling ? 1 : -1;
      const aRemembered = a.successes > 0 && sources[lhs].name === last;
      const bRemembered = b.successes > 0 && sources[rhs].name === last;
      if (aRemembered !== bRemembered) return aRemembered ? -1 : 1;
      if (reliability(a) !== reliability(b)) return reliability(b) - reliability(a);
      if (a.averageStartup !== b.averageStartup) return a.averageStartup - b.averageStartup;
      return lhs - rhs;
    });
  }

  get hasHistory() {
    return this.favoriteTeams.size > 0 || Object.keys(this.lastChannels).length > 0
      || this.recentWatches.length > 0 || Object.keys(this.channelPerformance).length > 0;
  }

  clearHistory() {
    this.favoriteTeams = new Set();
    this.lastChannels = {};
    this.recentWatches = [];
    this.channelPerformance = {};
    this.lastFilter = "全部";
    this.save();
  }
}

export const preferences = new Preferences();
