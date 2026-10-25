// Port of the sports-insight value types in App/Sources/Shared/TencentSports.swift
// (Android: data/TencentSports.kt). Timestamps are epoch milliseconds.

export interface SportsComment {
  id: string;
  text: string;
  postedAt: number;
}

export interface SportsTable {
  title: string;
  headers: string[];
  rows: string[][];
  /** Provider label for this whole table, e.g. "咪咕视频". Empty until `select` assigns it. */
  sourceName: string;
}

export interface SportsSnapshot {
  mid: string;
  left: string;
  right: string;
  /** "left : right", "—" for a missing side. */
  score: string;
  period: string;
  tables: SportsTable[];
  updatedAt: number;
  leftBadge?: string;
  rightBadge?: string;
  /** "腾讯体育" · "咪咕视频" · "ESPN", joined with " · " after `select`. */
  sourceName: string;
  /** The provider of score/period/teams (the first, preferred snapshot). */
  scoreSourceName?: string;
}

export const PERIOD_TITLE = "分节得分";
export const COMPARISON_TITLE = "球队技术统计";
export const PLAYER_SUFFIX = "球员技术统计";

export function periodTable(s: SportsSnapshot): SportsTable | undefined {
  return s.tables.find((t) => t.title === PERIOD_TITLE);
}
export function comparisonTable(s: SportsSnapshot): SportsTable | undefined {
  return s.tables.find((t) => t.title === COMPARISON_TITLE);
}
export function playerTables(s: SportsSnapshot): SportsTable[] {
  return s.tables.filter((t) => t.title.endsWith(PLAYER_SUFFIX));
}

export class SportsDataError extends Error {
  constructor(message = "本场比赛数据暂不可用") {
    super(message);
  }
}

/** JSON-ish value as the providers send it. */
export type Json = unknown;
export type JsonObject = Record<string, unknown>;

export function obj(value: Json): JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? (value as JsonObject) : {};
}
export function isObj(value: Json): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
export function objects(value: Json): JsonObject[] {
  return Array.isArray(value) ? value.filter(isObj) : [];
}

/** Swift `text(_:missing:)`: non-empty strings and numbers (and booleans, as Kotlin's JsonPrimitive.content). */
export function text(value: Json, missing = ""): string {
  if (typeof value === "string") return value.length > 0 ? value : missing;
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : missing;
  if (typeof value === "boolean") return String(value);
  return missing;
}

/** Strings-only array (Kotlin `strings()`); undefined when any element is not a primitive. */
export function strings(value: Json): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  if (!value.every((v) => v === null || ["string", "number", "boolean"].includes(typeof v))) return undefined;
  return value.map((v) => text(v));
}

export function parseJSONObject(body: string): JsonObject {
  let root: unknown;
  try {
    root = JSON.parse(body);
  } catch {
    throw new SportsDataError();
  }
  if (!isObj(root)) throw new SportsDataError();
  return root;
}

/** Strip markup and control characters, trim, cap at 80 code points. */
export function cleanCommentText(raw: string, stripEmoticons: boolean): string {
  let value = raw;
  if (stripEmoticons) value = value.replace(/\[[^\]]{1,30}\/\]/g, "");
  value = value.replace(/<[^>]*>/g, "").replace(/\p{Cc}/gu, "").trim();
  return Array.from(value).slice(0, 80).join("");
}
