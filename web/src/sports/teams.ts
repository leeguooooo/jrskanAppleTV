// Canonical team names shared by Tencent, Migu and ESPN matching
// (Swift MultiSportsClient.canonical / Kotlin MultiSportsClient.canonical).
// Only explicit aliases: never strip city prefixes, and keep 北京/北控 and
// 浙江/广厦 apart. Extend contracts/multi-sports.json when names change.
import { FEED_UTC_OFFSET_MS, kickoff, type LiveMatch } from "../core/models";

const ALIASES = new Map<string, string>(Object.entries({
  GS: "勇士", GSW: "勇士", LAL: "湖人", LAC: "快船", MEM: "灰熊", NY: "尼克斯", NYK: "尼克斯", NO: "鹈鹕", NOP: "鹈鹕",
  SA: "马刺", SAS: "马刺", UTAH: "爵士", UTA: "爵士", WSH: "奇才", WAS: "奇才", PHO: "太阳", PHX: "太阳", ATL: "老鹰",
  BOS: "凯尔特人", BKN: "篮网", CHA: "黄蜂", CHI: "公牛", CLE: "骑士", DAL: "独行侠", DEN: "掘金", DET: "活塞", HOU: "火箭",
  IND: "步行者", MIA: "热火", MIL: "雄鹿", MIN: "森林狼", OKC: "雷霆", ORL: "魔术", PHI: "76人", POR: "开拓者", SAC: "国王",
  TOR: "猛龙", 布鲁克林篮网: "篮网", 金州勇士: "勇士", 洛杉矶湖人: "湖人", 洛杉矶快船: "快船", 灰熊队: "灰熊",
  上海久事: "上海", 福建晋江文旅: "福建", 广东东阳光: "广东", 浙江稠州金租: "浙江", 浙江浙商证券: "广厦", 北京控股: "北控",
  北京首钢: "北京", 深圳马可波罗: "深圳", 山西汾酒: "山西", 南京同曦宙光: "同曦", 长白山恩都里: "吉林", 四川锦城: "四川",
  天津先行者: "天津", 山东高速: "山东", 辽宁本钢: "辽宁", 青岛崂山啤酒: "青岛", 新疆广汇能源: "新疆", 江苏肯帝亚: "江苏",
  广州智都集团: "广州", 宁波町渥: "宁波", 北京北汽: "北京", 福建浔兴股份: "福建", 浙江方兴渡: "广厦", 南京头排苏酒: "同曦",
  南京同曦: "同曦", 青岛国信制药: "青岛", 青岛国信水产: "青岛", 新疆伊力特: "新疆", 广州朗肽海本: "广州", 四川丰谷酒业: "四川",
  宁波富邦: "宁波",
}));

export function canonical(name: string): string {
  return ALIASES.get(name.toUpperCase()) ?? ALIASES.get(name) ?? name;
}

export function sameTeams(a: string[], b: string[]): boolean {
  const x = new Set(a.map(canonical));
  const y = new Set(b.map(canonical));
  return x.size === y.size && [...x].every((v) => y.has(v));
}

export function matchTeams(match: LiveMatch): string[] {
  return [match.homeTeam, match.awayTeam];
}

const KICKOFF_WINDOW_MS = 30 * 60_000;

/** "yyyy-MM-dd HH:mm:ss" or "yyyyMMddHHmm" in Asia/Shanghai → epoch ms. */
export function shanghaiTime(raw: string, format: "yyyy-MM-dd HH:mm:ss" | "yyyyMMddHHmm"): number | undefined {
  const m = format === "yyyyMMddHHmm"
    ? /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(raw)
    : /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/.exec(raw);
  if (!m) return undefined;
  const n = [1, 2, 3, 4, 5, 6].map((i) => Number.parseInt(m[i] ?? "0", 10));
  if (n[1] < 1 || n[1] > 12 || n[2] < 1 || n[2] > 31 || n[3] > 23 || n[4] > 59 || n[5] > 59) return undefined;
  const at = Date.UTC(n[0], n[1] - 1, n[2], n[3], n[4], n[5]);
  // Reject roll-over dates such as 02-31 (DateFormatter/LocalDateTime are strict too).
  if (new Date(at).getUTCDate() !== n[2]) return undefined;
  return at - FEED_UTC_OFFSET_MS;
}

/** Within 30 minutes of the listing's kickoff. */
export function nearKickoff(start: number | undefined, match: LiveMatch, now: number): boolean {
  const kick = kickoff(match.time, now);
  if (start === undefined || kick === undefined) return false;
  return Math.abs(start - kick) <= KICKOFF_WINDOW_MS;
}

/** Swift/Kotlin `MultiSportsClient.matches`: two names, same canonical teams, start within 30 min. */
export function teamsAndStartMatch(
  names: string[], start: string, format: "yyyy-MM-dd HH:mm:ss" | "yyyyMMddHHmm", match: LiveMatch, now: number,
): boolean {
  if (names.length !== 2 || !sameTeams(names, matchTeams(match))) return false;
  return nearKickoff(shanghaiTime(start, format), match, now);
}

/** ESPN ISO dates such as "2026-10-23T20:00Z". */
export function isoTime(raw: string): number | undefined {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})$/.test(raw)) return undefined;
  const value = Date.parse(raw);
  return Number.isNaN(value) ? undefined : value;
}

/** yyyyMMdd of an instant in America/New_York (ESPN scoreboard `dates`). */
export function newYorkDate(at: number): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(new Date(at));
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return `${get("year")}${get("month")}${get("day")}`;
}
