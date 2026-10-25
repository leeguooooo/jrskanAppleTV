// Port of App/Sources/Shared/MatchListModel.swift.
import { api } from "./api";
import { applyEvents } from "./events";
import {
  ALL_FILTERS, filterIncludes, kickoff, matchStatus, sectionTitle, statusRank,
  type LiveMatch, type MatchStatus, type ProviderMatchState, type SportFilter,
} from "./models";
import { preferences, type Preferences } from "./preferences";
import { Observable } from "./store";

export interface MatchSection {
  status: MatchStatus;
  matches: LiveMatch[];
  title: string;
}

/** How often the schedule re-fetches itself while the list is on screen. */
export const AUTO_REFRESH_INTERVAL = 5 * 60_000;
export const SCORE_REFRESH_INTERVAL = 30_000;

export class MatchListModel extends Observable {
  matches: LiveMatch[] = [];
  isLoading = false;
  lastUpdated?: number;
  scoresUpdatedAt?: number;
  scoreNotice?: string;
  isRefreshingScores = false;
  errorMessage?: string;
  searchText = "";
  filter: SportFilter;

  private scheduleMatches: LiveMatch[] = [];
  private hasEvents = false;
  private scoreFailures = 0;
  private lastScoreAttempt?: number;
  private timer?: ReturnType<typeof setInterval>;

  constructor(readonly preferences: Preferences) {
    super();
    this.filter = preferences.lastFilter === "最近观看" && preferences.recentWatches.length === 0 ? "全部" : preferences.lastFilter;
    preferences.subscribe(() => this.changed());
  }

  setFilter(filter: SportFilter) {
    this.filter = filter;
    this.preferences.set("lastFilter", filter);
    this.changed();
  }

  setSearch(text: string) {
    this.searchText = text;
    this.changed();
  }

  // MARK: - Derived lists

  /// Live first, then upcoming by kickoff, then finished (latest first).
  sortedMatches(now = Date.now()): LiveMatch[] {
    return this.matches
      .map((match) => ({ match, status: matchStatus(match, now), start: kickoff(match.time, now) ?? Number.MAX_SAFE_INTEGER }))
      .sort((l, r) => {
        const lr = statusRank(l.status), rr = statusRank(r.status);
        if (lr !== rr) return lr - rr;
        // A live match with no channel cannot be watched; keep the ones
        // that can be opened ahead of it inside the same section.
        const lp = l.match.sources.length > 0, rp = r.match.sources.length > 0;
        if (lp !== rp) return lp ? -1 : 1;
        if (l.status.kind === "finished") return r.start - l.start;
        return l.start - r.start;
      })
      .map((entry) => entry.match);
  }

  searchResults(now = Date.now()): LiveMatch[] {
    const query = this.searchText.trim().toLowerCase();
    if (!query) return [];
    return this.sortedMatches(now).filter((m) =>
      [m.league, m.homeTeam, m.awayTeam].some((v) => v.toLowerCase().includes(query)));
  }

  get recentMatches(): LiveMatch[] {
    return this.preferences.recentWatches.map((saved) => this.matches.find((m) => m.id === saved.match.id) ?? saved.match);
  }

  get continueMatch(): LiveMatch | undefined {
    return this.recentMatches.find((recent) =>
      this.matches.some((m) => m.id === recent.id) && recent.sources.length > 0 && matchStatus(recent).kind !== "finished");
  }

  filteredMatches(now = Date.now()): LiveMatch[] {
    if (this.filter === "最近观看") return this.recentMatches;
    return this.sortedMatches(now).filter((m) => filterIncludes(this.filter, m, this.preferences.favoriteTeams));
  }

  /// The current filter split into "on now / up next / over" groups.
  sections(now = Date.now()): MatchSection[] {
    if (this.filter === "最近观看") {
      const recent = this.recentMatches;
      return recent.length ? [{ status: { kind: "unknown" }, matches: recent, title: "最近观看" }] : [];
    }
    const groups = new Map<number, { status: MatchStatus; matches: LiveMatch[] }>();
    for (const match of this.filteredMatches(now)) {
      const status = matchStatus(match, now);
      const rank = statusRank(status);
      const group = groups.get(rank) ?? { status, matches: [] };
      group.matches.push(match);
      groups.set(rank, group);
    }
    return [...groups.entries()].sort((a, b) => a[0] - b[0])
      .map(([, g]) => ({ status: g.status, matches: g.matches, title: sectionTitle(g.status) }));
  }

  /// "关注" and "最近观看" only earn a chip once there is something in them.
  get availableFilters(): SportFilter[] {
    return ALL_FILTERS.filter((f) => (f !== "关注" || this.preferences.favoriteTeams.size > 0)
      && (f !== "最近观看" || this.preferences.recentWatches.length > 0));
  }

  categoryCount(filter: SportFilter): number {
    if (filter === "最近观看") return this.recentMatches.length;
    return this.matches.filter((m) => filterIncludes(filter, m, this.preferences.favoriteTeams)).length;
  }

  liveCount(now = Date.now()): number {
    return this.matches.filter((m) => matchStatus(m, now).kind === "live").length;
  }

  /** Distinct league names, for search suggestions. */
  get leagueNames(): string[] {
    return [...new Set(this.matches.map((m) => m.league))];
  }

  match(id: string): LiveMatch | undefined {
    return this.matches.find((m) => m.id === id) ?? this.recentMatches.find((m) => m.id === id);
  }

  // MARK: - Loading

  async loadIfNeeded() {
    if (this.matches.length === 0) await this.refresh();
  }

  /// Foreground return: only re-fetch when the data is old enough to matter.
  async refreshIfStale(maxAge = 120_000) {
    const now = Date.now();
    if (this.lastUpdated !== undefined && now - this.lastUpdated < maxAge) {
      if (this.scoresUpdatedAt === undefined || now - this.scoresUpdatedAt >= SCORE_REFRESH_INTERVAL) await this.refreshScores();
    } else {
      await this.refresh();
    }
  }

  async refresh() {
    if (this.isLoading) return;
    this.isLoading = true;
    this.errorMessage = undefined;
    this.changed();
    try {
      const schedule = await api.schedule();
      this.scheduleMatches = schedule.matches;
      this.hasEvents = schedule.hasEvents;
      // Keep the last known scores while the independent event request runs
      // or fails. Their source timestamp does not change with the schedule.
      const previous = new Map<string, ProviderMatchState>();
      for (const m of this.matches) if (m.providerState) previous.set(m.id, m.providerState);
      this.matches = this.scheduleMatches.map((m) => ({ ...m, providerState: previous.get(m.id) }));
      this.lastUpdated = Date.now();
    } catch (error) {
      this.errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      this.isLoading = false;
      this.changed();
    }
    await this.refreshScores();
  }

  async refreshScores() {
    if (this.isRefreshingScores) return;
    if (!this.hasEvents) {
      this.scoreNotice = "比分暂不可用";
      this.changed();
      return;
    }
    this.isRefreshingScores = true;
    this.lastScoreAttempt = Date.now();
    this.changed();
    try {
      const snapshot = await api.events();
      // An older CDN response must not overwrite a newer score snapshot.
      if (this.scoresUpdatedAt === undefined || snapshot.updatedAt >= this.scoresUpdatedAt) {
        this.matches = applyEvents(snapshot, this.scheduleMatches);
        this.scoresUpdatedAt = snapshot.updatedAt;
        this.scoreNotice = undefined;
        this.scoreFailures = 0;
      }
    } catch {
      this.scoreFailures += 1;
      this.scoreNotice = this.scoresUpdatedAt === undefined ? "比分暂不可用" : "比分更新失败，显示上次数据";
    } finally {
      this.isRefreshingScores = false;
      this.changed();
    }
  }

  scoreUpdateText(now = Date.now()): string {
    if (this.isRefreshingScores && this.scoresUpdatedAt === undefined) return "正在载入比分…";
    const timestamp = this.scoresUpdatedAt === undefined ? undefined
      : new Date(this.scoresUpdatedAt).toLocaleTimeString("zh-CN", { hour12: false });
    if (this.scoreNotice) return this.scoreNotice + (timestamp ? ` · ${timestamp}` : "");
    if (this.scoresUpdatedAt === undefined || !timestamp) return "比分暂不可用";
    return (now - this.scoresUpdatedAt > 120_000 ? "比分数据较旧 · " : "比分更新 · ") + timestamp;
  }

  startAutoRefresh() {
    if (this.timer) return;
    this.timer = setInterval(() => {
      if (!this.preferences.autoRefresh || document.visibilityState === "hidden") return;
      const now = Date.now();
      if (this.lastUpdated === undefined || now - this.lastUpdated >= AUTO_REFRESH_INTERVAL) {
        void this.refresh();
      } else {
        const delay = Math.min(AUTO_REFRESH_INTERVAL, SCORE_REFRESH_INTERVAL * 2 ** Math.min(this.scoreFailures, 4));
        if (this.lastScoreAttempt === undefined || now - this.lastScoreAttempt >= delay) void this.refreshScores();
      }
    }, SCORE_REFRESH_INTERVAL);
  }

  stopAutoRefresh() {
    clearInterval(this.timer);
    this.timer = undefined;
  }
}

export const listModel = new MatchListModel(preferences);
