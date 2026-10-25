// Port of App/Sources/Shared/MatchPlaybackModel.swift: which channels exist,
// which one is being resolved, what is playing, what failed, what to try next.
import { api, ApiError } from "./api";
import { playbackOrdered, type LiveMatch, type MatchSource } from "./models";
import type { Preferences } from "./preferences";
import { Observable } from "./store";

/// A stream that has already been resolved to a playable URL. Resolution
/// happens before the player appears, so a dead link is an error on the
/// detail screen rather than an unexplained black player.
export interface PlaybackRequest {
  id: number;
  url: string;
  sourceName: string;
  index: number;
}

let requestCounter = 0;

export class MatchPlaybackModel extends Observable {
  /** Second-level channels; undefined while loading, empty when the page gave nothing usable. */
  channels?: MatchSource[];
  channelNotice?: string;
  playback?: PlaybackRequest;
  resolvingIndex?: number;
  errorMessage?: string;
  notice?: string;
  /** Channels that connected but never produced a picture this visit. */
  stalledIndices = new Set<number>();
  failedResolutionIndices = new Set<number>();

  private requestGeneration = 0;
  private confirmedRequestID?: number;
  private handledFailureID?: number;
  private lastReconnect = new Map<number, number>();
  private recoveryTimer?: ReturnType<typeof setTimeout>;
  private resolutionDuration = 0;
  private loadGeneration = 0;

  constructor(readonly match: LiveMatch, readonly preferences: Preferences) {
    super();
  }

  // MARK: - Channels

  /// Parsed channels when the source page gave any, otherwise the homepage
  /// entries as a fallback so the screen is never a dead end.
  get resolvedChannels(): MatchSource[] {
    if (this.channels && this.channels.length) return playbackOrdered(this.channels);
    return playbackOrdered(this.match.sources);
  }

  get isLoadingChannels() {
    return this.channels === undefined;
  }

  get rememberedChannel(): MatchSource | undefined {
    const remembered = this.preferences.recentWatches.find((r) => r.match.id === this.match.id);
    return remembered && this.resolvedChannels.find((c) => c.name === remembered.channelName);
  }

  /// Where the first tap should land: last time's channel, else the first.
  get suggestedChannel(): MatchSource | undefined {
    const index = this.preferences.rankedIndices(this.resolvedChannels, this.match.id)[0];
    return index === undefined ? undefined : this.resolvedChannels[index];
  }

  async startSuggestedPlayback() {
    const source = this.suggestedChannel;
    if (!source) return;
    await this.startPlayback(this.resolvedChannels.indexOf(source));
  }

  get automaticFallbackEnabled() {
    return this.preferences.autoNextChannel && this.resolvedChannels.length > 1;
  }

  subtitle(source: MatchSource, index: number): string {
    if (this.resolvingIndex === index) return "正在解析线路…";
    if (this.stalledIndices.has(index)) return "刚才没有画面";
    if (this.failedResolutionIndices.has(index)) return "刚才未能播放";
    if (this.suggestedChannel?.id === source.id && (this.preferences.channelPerformance[source.pageURL]?.successes ?? 0) > 0) {
      return "推荐 · 曾播放成功";
    }
    if (!this.channels || this.channels.length === 0) return "备用入口 · 直接尝试播放";
    if (source.name.includes("高清")) return "高清频道";
    return "主播解说";
  }

  /// The highest-ranked remaining channel; undefined when this visit has
  /// exhausted every alternative.
  nextUntriedIndex(after: number): number | undefined {
    return this.preferences.rankedIndices(this.resolvedChannels, this.match.id)
      .find((c) => c !== after && !this.stalledIndices.has(c) && !this.failedResolutionIndices.has(c));
  }

  get retryActionTitle(): string {
    const current = this.playback?.index ?? this.resolvingIndex ?? -1;
    const next = this.nextUntriedIndex(current);
    return next === undefined ? "重试" : `试线路 ${next + 1}`;
  }

  async retryAfterError() {
    const current = this.playback?.index ?? -1;
    await this.startPlayback(this.nextUntriedIndex(current) ?? 0);
  }

  async loadChannels() {
    const generation = ++this.loadGeneration;
    this.channels = undefined;
    this.channelNotice = undefined;
    this.changed();
    for (const source of this.match.sources) {
      try {
        const { channels } = await api.channels(source);
        if (generation !== this.loadGeneration) return;
        if (channels.length) {
          this.channels = channels;
          this.changed();
          return;
        }
      } catch {
        if (generation !== this.loadGeneration) return;
      }
    }
    this.channels = [];
    // With no homepage entries at all there is nothing to fall back to.
    if (this.match.sources.length) this.channelNotice = "没能读取具体频道，下面是首页备用入口。";
    this.changed();
  }

  // MARK: - Playback

  /// Resolve first, present second. With automatic fallback on, a link that
  /// fails to resolve moves straight on to the next channel.
  async startPlayback(startIndex: number, resetStalls = true, fresh = false) {
    const channels = this.resolvedChannels;
    if (startIndex < 0 || startIndex >= channels.length) return;
    const generation = ++this.requestGeneration;
    if (resetStalls) {
      clearTimeout(this.recoveryTimer);
      this.lastReconnect.clear();
      this.stalledIndices = new Set();
      this.failedResolutionIndices = new Set();
    }
    this.errorMessage = undefined;
    this.notice = undefined;

    const tryOthers = this.preferences.autoNextChannel && channels.length > 1;
    let index = startIndex;
    let attempts = 0;
    const failures: string[] = [];

    try {
      while (index >= 0 && index < channels.length && attempts < channels.length) {
        const source = channels[index];
        this.resolvingIndex = index;
        this.changed();
        const started = performance.now();
        try {
          // A reconnect after a stall must not get the cached URL that just died.
          const { url } = await api.resolve(source, fresh || !resetStalls);
          if (generation !== this.requestGeneration) return;
          this.resolutionDuration = (performance.now() - started) / 1000;
          this.confirmedRequestID = undefined;
          this.handledFailureID = undefined;
          if (index !== startIndex) {
            this.notice = `线路 ${startIndex + 1} 暂不可用，已自动改用线路 ${index + 1}「${source.name}」。`;
          }
          this.playback = { id: ++requestCounter, url, sourceName: source.name, index };
          return;
        } catch (error) {
          if (generation !== this.requestGeneration) return;
          if (error instanceof ApiError && error.status === 401) return;
          this.failedResolutionIndices.add(index);
          this.preferences.recordPlaybackFailure(source);
          failures.push(`线路 ${index + 1}：${error instanceof Error ? error.message : String(error)}`);
          attempts += 1;
          const next = tryOthers ? this.nextUntriedIndex(index) : undefined;
          if (next === undefined) break;
          index = next;
        }
      }
      this.playback = undefined;
      if (this.stalledIndices.size) {
        this.errorMessage = `当前线路都未能播放：${this.stalledIndices.size} 条没有画面，${this.failedResolutionIndices.size} 条暂不可用。可以稍后重试。`;
      } else {
        this.errorMessage = failures.length > 1 ? `试过 ${failures.length} 条线路，暂时都无法播放。${failures[failures.length - 1]}` : failures[0];
      }
    } finally {
      if (this.requestGeneration === generation) this.resolvingIndex = undefined;
      this.changed();
    }
  }

  confirmPlayback(requestID: number, startupSeconds: number) {
    const request = this.playback;
    if (!request || request.id !== requestID || this.confirmedRequestID === requestID) return;
    const source = this.resolvedChannels[request.index];
    if (!source) return;
    this.confirmedRequestID = requestID;
    this.preferences.recordPlaybackSuccess(this.match, source, request.index, this.resolutionDuration + startupSeconds);
  }

  /// A confirmed stream gets one same-channel reconnect per two minutes
  /// before trying other sources.
  handleStall(message: string, requestID?: number, now = Date.now()) {
    const request = this.playback;
    if (!request || (requestID !== undefined && request.id !== requestID) || this.handledFailureID === request.id) return;
    const source = this.resolvedChannels[request.index];
    if (!source) return;
    this.handledFailureID = request.id;
    const index = request.index;
    this.preferences.recordPlaybackFailure(source, now);
    const last = this.lastReconnect.get(index);
    const shouldReconnect = this.confirmedRequestID === request.id && (last === undefined || now - last >= 120_000);
    let next: number;
    if (shouldReconnect) {
      this.lastReconnect.set(index, now);
      next = index;
      this.notice = `直播中断，正在重新连接线路 ${index + 1}…`;
    } else {
      this.stalledIndices.add(index);
      const candidate = this.preferences.autoNextChannel ? this.nextUntriedIndex(index) : undefined;
      if (candidate === undefined) {
        this.playback = undefined;
        this.errorMessage = message;
        this.changed();
        return;
      }
      next = candidate;
      this.notice = `线路 ${index + 1} 中断，正在尝试线路 ${next + 1}…`;
    }
    this.changed();
    const generation = this.requestGeneration;
    clearTimeout(this.recoveryTimer);
    this.recoveryTimer = setTimeout(() => {
      if (generation === this.requestGeneration) void this.startPlayback(next, false);
    }, 0);
  }

  stopPlayback() {
    clearTimeout(this.recoveryTimer);
    this.recoveryTimer = undefined;
    this.requestGeneration += 1;
    this.resolvingIndex = undefined;
    this.playback = undefined;
    this.changed();
  }

  /** Leaving the match: also drop an in-flight channel load. */
  dispose() {
    this.loadGeneration += 1;
    this.stopPlayback();
  }
}
