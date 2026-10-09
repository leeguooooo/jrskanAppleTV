// Remote config for the JRKAN apps: the player watermark and ad slots.
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

  return { config: { version: 1, watermark, slots }, problems };
}
