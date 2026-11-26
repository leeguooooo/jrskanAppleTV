// Remote config for the JRKAN apps: the player watermark, ad slots and the
// Weibo replay (回看) knobs.
//
// Shared by the Worker (which normalizes whatever is stored in KV before
// serving it) and scripts/config.mjs (which validates a file before it is
// written). Normalizing on read means a hand edit in the Cloudflare
// dashboard can never hand the apps a shape they cannot parse.

export const DEFAULT_CONFIG = {
  version: 1,
  watermark: {
    enabled: true,
    // Shown in turn, one per hop; a second entry turns the watermark into a rotating ad.
    texts: ["leeguoo.com"],
    // drift: keeps gliding to a new random spot · hop: fade out, reappear elsewhere · fixed: bottom-right
    motion: "drift",
    interval: 8,
    opacity: 0.55,
    hideForMembers: false,
  },
  slots: {
    // A card at the top of the match list (iPhone / iPad / Mac / Android).
    home_banner: {
      enabled: false,
      title: "",
      detail: "",
      url: "",
      hideForMembers: true,
    },
    // Burned into exported recordings: a strip in the bottom-left corner.
    recording_banner: {
      enabled: false,
      title: "",
      detail: "",
      url: "",
      hideForMembers: true,
    },
  },
  // 回看: match recordings fetched from Weibo by the apps themselves. The apps
  // carry these same defaults, so this block only matters to switch it off or
  // retune it when Weibo changes.
  replay: {
    enabled: true,
    // Weibo uids whose video feeds make up the 回看 list.
    uploaders: ["7551290258", "2358578625"],
    // Appended to "主队vs客队" for a match's own search.
    searchSuffix: " 回放",
    minDuration: 600,
    fullDuration: 5400,
    windowHours: 48,
  },
};

const MOTIONS = ["hop", "drift", "fixed"];

const text = (value, max, fallback = "") =>
  typeof value === "string" ? value.trim().slice(0, max) : fallback;

const number = (value, min, max, fallback) =>
  typeof value === "number" && Number.isFinite(value) ? Math.min(max, Math.max(min, value)) : fallback;

const bool = (value, fallback) => (typeof value === "boolean" ? value : fallback);

const httpsURL = (value) => {
  const raw = text(value, 500);
  if (!raw) return "";
  try {
    return new URL(raw).protocol === "https:" ? raw : "";
  } catch {
    return "";
  }
};

/** Returns { config, problems }: a complete config plus what had to be fixed. */
export function normalize(input) {
  const problems = [];
  const source = input && typeof input === "object" ? input : (problems.push("not an object"), {});
  const base = DEFAULT_CONFIG;

  const w = source.watermark && typeof source.watermark === "object" ? source.watermark : {};
  let texts = Array.isArray(w.texts) ? w.texts.map((t) => text(t, 40)).filter(Boolean).slice(0, 10) : null;
  if (!texts || texts.length === 0) {
    if (w.texts !== undefined) problems.push("watermark.texts must be a non-empty string array");
    texts = base.watermark.texts;
  }
  let motion = w.motion;
  if (!MOTIONS.includes(motion)) {
    if (motion !== undefined) problems.push(`watermark.motion must be one of ${MOTIONS.join(", ")}`);
    motion = base.watermark.motion;
  }
  const watermark = {
    enabled: bool(w.enabled, base.watermark.enabled),
    texts,
    motion,
    interval: number(w.interval, 5, 600, base.watermark.interval),
    opacity: number(w.opacity, 0.1, 1, base.watermark.opacity),
    hideForMembers: bool(w.hideForMembers, base.watermark.hideForMembers),
  };

  // Unknown slot ids pass through with the generic shape, so a new slot only
  // needs client support, not a Worker deploy.
  const slots = {};
  const inputSlots = source.slots && typeof source.slots === "object" ? source.slots : {};
  for (const id of new Set([...Object.keys(base.slots), ...Object.keys(inputSlots)])) {
    if (!/^[a-z][a-z0-9_]{0,31}$/.test(id)) {
      problems.push(`slot id "${id}" ignored`);
      continue;
    }
    const s = inputSlots[id] && typeof inputSlots[id] === "object" ? inputSlots[id] : {};
    const d = base.slots[id] ?? { enabled: false, title: "", detail: "", url: "", hideForMembers: true };
    const url = httpsURL(s.url);
    if (s.url && !url) problems.push(`slots.${id}.url must be an https URL`);
    slots[id] = {
      enabled: bool(s.enabled, d.enabled),
      title: text(s.title, 40, d.title),
      detail: text(s.detail, 80, d.detail),
      url: url || (s.url === undefined ? d.url : ""),
      hideForMembers: bool(s.hideForMembers, d.hideForMembers),
    };
  }

  const r = source.replay && typeof source.replay === "object" ? source.replay : {};
  let uploaders = Array.isArray(r.uploaders)
    ? r.uploaders.map((u) => (typeof u === "number" ? String(u) : text(u, 20))).filter((u) => /^\d+$/.test(u)).slice(0, 10)
    : null;
  if (!uploaders || uploaders.length === 0) {
    if (r.uploaders !== undefined) problems.push("replay.uploaders must be a non-empty array of numeric Weibo uids");
    uploaders = base.replay.uploaders;
  }
  const replay = {
    enabled: bool(r.enabled, base.replay.enabled),
    uploaders,
    searchSuffix: typeof r.searchSuffix === "string" ? r.searchSuffix.slice(0, 20) : base.replay.searchSuffix,
    minDuration: number(r.minDuration, 60, 3600, base.replay.minDuration),
    fullDuration: number(r.fullDuration, 1800, 14400, base.replay.fullDuration),
    windowHours: number(r.windowHours, 6, 240, base.replay.windowHours),
  };

  return { config: { version: 1, watermark, slots, replay }, problems };
}
