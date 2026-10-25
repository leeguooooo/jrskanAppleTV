// Port of MatchInsightsModel (Swift TencentSports.swift / Kotlin state/MatchInsightsModel.kt)
// and Kotlin's DanmakuQueue. Polling is owned by a visible consumer: callers
// start/stop it, it never touches playback, channel scoring or recording.
import type { LiveMatch, MatchSource } from "../core/models";
import { matchKey, sharedSportsClient, type MultiSportsClient } from "./client";
import type { SportsComment, SportsSnapshot } from "./types";

export const STATS_INTERVAL_MS = 30_000;
export const COMMENT_INTERVAL_MS = 10_000;
export const COMMENT_MAX_AGE_MS = 120_000;
export const DANMAKU_EMIT_MS = 2_500;
export const DANMAKU_QUEUE_LIMIT = 20;
const SEEN_LIMIT = 500;
const COMMENT_BUFFER = 24;

export const STATUS = {
  matching: "正在匹配本场比赛…",
  loading: "正在加载比赛数据…",
  unsupported: "暂无可匹配的本场数据",
  unavailable: "各数据源暂未提供本场统计，稍后自动重试",
  stale: "数据更新暂时中断，显示上次结果",
  empty: "暂无本场技术统计",
} as const;

export interface InsightsState {
  /** Set when the league can be matched (NBA/CBA); the danmaku toggle shows only then. */
  key?: string;
  snapshot?: SportsSnapshot;
  /** Empty when the latest poll succeeded with data. */
  status: string;
  /** Fresh (< 120 s) comments, oldest first, at most 24. */
  comments: SportsComment[];
}

export interface ControllerOptions {
  client?: MultiSportsClient;
  now?: () => number;
  statsIntervalMs?: number;
  commentIntervalMs?: number;
}

export function supportsInsights(match: LiveMatch): boolean {
  return ["NBA", "CBA"].includes(match.league.toUpperCase());
}

export class MatchInsightsController {
  private current: InsightsState;
  private readonly listeners = new Set<(state: InsightsState) => void>();
  private readonly client: MultiSportsClient;
  private readonly now: () => number;
  private readonly statsInterval: number;
  private readonly commentInterval: number;
  private statsGeneration = 0;
  private commentGeneration = 0;
  private statsTimer: ReturnType<typeof setTimeout> | undefined;
  private commentTimer: ReturnType<typeof setTimeout> | undefined;
  private seen: string[] = [];
  private seenSet = new Set<string>();

  constructor(readonly match: LiveMatch, readonly channels: MatchSource[] = [], options: ControllerOptions = {}) {
    this.client = options.client ?? sharedSportsClient();
    this.now = options.now ?? Date.now;
    this.statsInterval = options.statsIntervalMs ?? STATS_INTERVAL_MS;
    this.commentInterval = options.commentIntervalMs ?? COMMENT_INTERVAL_MS;
    this.current = supportsInsights(match)
      ? { key: matchKey(match), status: STATUS.matching, comments: [] }
      : { status: STATUS.unsupported, comments: [] };
  }

  get state(): InsightsState {
    return this.current;
  }

  subscribe(listener: (state: InsightsState) => void): () => void {
    this.listeners.add(listener);
    listener(this.current);
    return () => { this.listeners.delete(listener); };
  }

  private update(patch: Partial<InsightsState>) {
    this.current = { ...this.current, ...patch };
    for (const listener of [...this.listeners]) listener(this.current);
  }

  get statisticsRunning(): boolean { return this.statsTimer !== undefined || this.statsInFlight; }
  get commentsRunning(): boolean { return this.commentTimer !== undefined || this.commentsInFlight; }
  private statsInFlight = false;
  private commentsInFlight = false;

  /** Start statistics polling (30 s). Idempotent. */
  start(): void {
    if (!this.current.key || this.statisticsRunning) return;
    const generation = ++this.statsGeneration;
    if (!this.current.snapshot) this.update({ status: STATUS.loading });
    void this.pollStatistics(generation);
  }

  stop(): void {
    this.statsGeneration++;
    clearTimeout(this.statsTimer);
    this.statsTimer = undefined;
    this.statsInFlight = false;
  }

  private async pollStatistics(generation: number) {
    this.statsTimer = undefined;
    this.statsInFlight = true;
    try {
      const value = await this.client.statistics(this.match, this.channels, (partial) => {
        if (generation === this.statsGeneration) this.update({ snapshot: partial, status: "" });
      });
      if (generation !== this.statsGeneration) return;
      this.update({ snapshot: value, status: value.tables.length ? "" : STATUS.empty });
    } catch {
      if (generation !== this.statsGeneration) return;
      this.update({ status: this.current.snapshot ? STATUS.stale : STATUS.unavailable });
    } finally {
      if (generation === this.statsGeneration) {
        this.statsInFlight = false;
        this.statsTimer = setTimeout(() => void this.pollStatistics(generation), this.statsInterval);
      }
    }
  }

  /** Start comment polling (10 s). Starts from an empty stream; seen IDs persist so nothing replays. */
  startComments(): void {
    if (!this.current.key || this.commentsRunning) return;
    const generation = ++this.commentGeneration;
    this.update({ comments: [] });
    void this.pollComments(generation);
  }

  stopComments(): void {
    this.commentGeneration++;
    clearTimeout(this.commentTimer);
    this.commentTimer = undefined;
    this.commentsInFlight = false;
    if (this.current.comments.length) this.update({ comments: [] });
  }

  private async pollComments(generation: number) {
    this.commentTimer = undefined;
    this.commentsInFlight = true;
    try {
      const batch = await this.client.comments(this.match, this.channels, this.seenSet);
      if (generation !== this.commentGeneration) return;
      const added = batch.filter((c) => {
        if (this.seenSet.has(c.id)) return false;
        this.seenSet.add(c.id);
        this.seen.push(c.id);
        return true;
      });
      if (this.seen.length > SEEN_LIMIT) {
        this.seen = this.seen.slice(-SEEN_LIMIT);
        this.seenSet = new Set(this.seen);
      }
      const now = this.now();
      const comments = [...this.current.comments, ...added].filter((c) => now - c.postedAt < COMMENT_MAX_AGE_MS).slice(-COMMENT_BUFFER);
      this.update({ comments });
    } catch {
      // A comment outage never reaches the stream or the statistics state.
    } finally {
      if (generation === this.commentGeneration) {
        this.commentsInFlight = false;
        this.commentTimer = setTimeout(() => void this.pollComments(generation), this.commentInterval);
      }
    }
  }

  dispose(): void {
    this.stop();
    this.stopComments();
    this.listeners.clear();
  }
}

/** Bounded queue for the three-lane renderer: ID dedupe, newest 20 kept, expired skipped at emit. */
export class DanmakuQueue {
  private seen: string[] = [];
  private seenSet = new Set<string>();
  private queue: SportsComment[] = [];

  constructor(private readonly now: () => number = Date.now) {}

  get size(): number { return this.queue.length; }

  offer(comments: SportsComment[]): void {
    for (const c of comments) {
      if (this.seenSet.has(c.id)) continue;
      this.seenSet.add(c.id);
      this.seen.push(c.id);
      this.queue.push(c);
    }
    if (this.queue.length > DANMAKU_QUEUE_LIMIT) this.queue = this.queue.slice(-DANMAKU_QUEUE_LIMIT);
    if (this.seen.length > SEEN_LIMIT) {
      this.seen = this.seen.slice(-SEEN_LIMIT);
      this.seenSet = new Set(this.seen);
    }
  }

  next(): SportsComment | undefined {
    while (this.queue.length) {
      const c = this.queue.shift() as SportsComment;
      if (this.now() - c.postedAt < COMMENT_MAX_AGE_MS) return c;
    }
    return undefined;
  }

  clearPending(): void {
    this.queue = [];
  }
}
