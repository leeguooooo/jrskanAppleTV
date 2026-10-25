// Port of App/Sources/Shared/AppConfig.swift: watermark and ad slots edited in
// Cloudflare (worker/, KV key `jrkan` behind config.leeguoo.com). Every field
// decodes with a default; a failed fetch keeps the last good copy.
import { Observable, storage } from "./store";

export type WatermarkMotion = "hop" | "drift" | "fixed";

export interface Watermark {
  enabled: boolean;
  texts: string[];
  motion: WatermarkMotion;
  interval: number;
  opacity: number;
  hideForMembers: boolean;
}

export interface Slot {
  enabled: boolean;
  title: string;
  detail: string;
  url: string;
  hideForMembers: boolean;
}

export interface AppConfig {
  watermark: Watermark;
  slots: Record<string, Slot>;
}

const DEFAULT_WATERMARK: Watermark = {
  enabled: true, texts: ["leeguoo.com"], motion: "drift", interval: 8, opacity: 0.55, hideForMembers: false,
};

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const bool = (v: unknown, fallback: boolean) => (typeof v === "boolean" ? v : fallback);
const str = (v: unknown) => (typeof v === "string" ? v : "");
const num = (v: unknown, fallback: number) => (typeof v === "number" && Number.isFinite(v) ? v : fallback);

export function decodeConfig(raw: unknown): AppConfig {
  const object = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const w = (object.watermark && typeof object.watermark === "object" ? object.watermark : {}) as Record<string, unknown>;
  const texts = Array.isArray(w.texts) ? w.texts.filter((t): t is string => typeof t === "string" && t.length > 0) : [];
  const motion = ["hop", "drift", "fixed"].includes(w.motion as string) ? (w.motion as WatermarkMotion) : DEFAULT_WATERMARK.motion;
  const watermark: Watermark = {
    enabled: bool(w.enabled, true),
    texts: texts.length ? texts : DEFAULT_WATERMARK.texts,
    motion,
    interval: clamp(num(w.interval, 8), 5, 600),
    opacity: clamp(num(w.opacity, 0.55), 0.1, 1),
    hideForMembers: bool(w.hideForMembers, false),
  };
  const slots: Record<string, Slot> = {};
  if (object.slots && typeof object.slots === "object") {
    for (const [id, value] of Object.entries(object.slots as Record<string, unknown>)) {
      const s = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
      slots[id] = { enabled: bool(s.enabled, false), title: str(s.title), detail: str(s.detail), url: str(s.url), hideForMembers: bool(s.hideForMembers, true) };
    }
  }
  return { watermark, slots };
}

/** The watermark to draw, or undefined when it is off for this viewer. */
export function visibleWatermark(config: AppConfig, isMember: boolean): Watermark | undefined {
  const { watermark } = config;
  return watermark.enabled && !(watermark.hideForMembers && isMember) ? watermark : undefined;
}

/** A slot worth showing: enabled, has a title, not hidden for members. */
export function visibleSlot(config: AppConfig, id: string, isMember: boolean): Slot | undefined {
  const slot = config.slots[id];
  if (!slot || !slot.enabled || !slot.title || (slot.hideForMembers && isMember)) return undefined;
  return slot;
}

export function slotLink(slot: Slot): string | undefined {
  try {
    return new URL(slot.url).protocol === "https:" ? slot.url : undefined;
  } catch {
    return undefined;
  }
}

export class AppConfigStore extends Observable {
  static readonly endpoint = "https://config.leeguoo.com/v1/jrkan.json";
  static readonly refreshInterval = 10 * 60_000;
  private static readonly cacheKey = "remoteConfig.jrkan";

  config: AppConfig = decodeConfig(storage.get<unknown>(AppConfigStore.cacheKey, {}));
  isMember = false;
  private lastFetch = 0;

  setMember(isMember: boolean) {
    if (this.isMember === isMember) return;
    this.isMember = isMember;
    this.changed();
  }

  get watermark() {
    return visibleWatermark(this.config, this.isMember);
  }

  slot(id: string) {
    return visibleSlot(this.config, id, this.isMember);
  }

  /** Launch and return to the foreground; at most every ten minutes. */
  async refreshIfStale(now = Date.now()) {
    if (now - this.lastFetch < AppConfigStore.refreshInterval) return;
    this.lastFetch = now;
    try {
      const response = await fetch(AppConfigStore.endpoint, { headers: { accept: "application/json" }, cache: "no-cache" });
      if (response.status !== 200) return;
      const raw = await response.json();
      storage.set(AppConfigStore.cacheKey, raw);
      this.config = decodeConfig(raw);
      this.changed();
    } catch {
      // Keep whatever was there.
    }
  }
}

export const appConfig = new AppConfigStore();
