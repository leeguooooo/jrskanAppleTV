// Port of PlaybackHealthMonitor (App/Sources/Shared/PlaybackHealth.swift).
// Samples media progress throughout playback. A paused player is not a stall.
export type HealthEvent = { kind: "confirmed"; startupSeconds: number } | { kind: "stalled" };

export class PlaybackHealthMonitor {
  private lastSample: number;
  private lastProgress: number;
  private lastMediaTime?: number;
  private activeElapsed = 0;
  private firstFrameElapsed?: number;
  private stablePlayback = 0;
  private wasAdvancing = false;
  confirmed = false;
  private failed = false;
  startupTimeout = 20;
  stallTimeout = 12;

  /** `now` in seconds. */
  constructor(now: number) {
    this.lastSample = now;
    this.lastProgress = now;
  }

  sample(now: number, mediaTime: number, playing: boolean, paused: boolean, ready: boolean, itemFailed: boolean): HealthEvent | undefined {
    if (this.failed) return undefined;
    const delta = Math.max(0, now - this.lastSample);
    this.lastSample = now;
    if (itemFailed) {
      this.failed = true;
      return { kind: "stalled" };
    }
    if (paused) {
      this.lastProgress = now;
      this.lastMediaTime = Number.isFinite(mediaTime) ? mediaTime : undefined;
      this.stablePlayback = 0;
      this.wasAdvancing = false;
      return undefined;
    }
    this.activeElapsed += delta;
    const advancing = Number.isFinite(mediaTime) && this.lastMediaTime !== undefined && Math.abs(mediaTime - this.lastMediaTime) > 0.05;
    if (Number.isFinite(mediaTime)) this.lastMediaTime = mediaTime;
    if (playing && ready && advancing) {
      this.lastProgress = now;
      this.stablePlayback = this.wasAdvancing ? this.stablePlayback + Math.min(delta, 1) : 0;
      this.wasAdvancing = true;
      if (this.firstFrameElapsed === undefined) this.firstFrameElapsed = this.activeElapsed;
      if (!this.confirmed && this.stablePlayback >= 2) {
        this.confirmed = true;
        return { kind: "confirmed", startupSeconds: this.firstFrameElapsed ?? this.activeElapsed };
      }
    } else {
      this.stablePlayback = 0;
      this.wasAdvancing = false;
    }
    if ((this.firstFrameElapsed === undefined && this.activeElapsed >= this.startupTimeout)
      || (this.firstFrameElapsed !== undefined && now - this.lastProgress >= this.stallTimeout)) {
      this.failed = true;
      return { kind: "stalled" };
    }
    return undefined;
  }
}
