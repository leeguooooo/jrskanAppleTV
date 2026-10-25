// Port of SportsStatsContent (App/Sources/Shared/SportsInsightsViews.swift,
// android ui/SportsInsights.kt): 本场概况 / 技术统计, per-quarter scores, team
// comparison, both teams' player tables with a fixed name column.
import { useEffect, useState } from "preact/hooks";
import type { JSX } from "preact";
import type { LiveMatch, MatchSource } from "../../core/models";
import { statComparison } from "../../sports/comparison";
import { STATUS } from "../../sports/controller";
import { comparisonTable, periodTable, playerTables, type SportsSnapshot, type SportsTable } from "../../sports/types";
import { useInsightsController, usePageVisible } from "./hooks";
import "./insights.css";

export interface MatchInsightsProps {
  match: LiveMatch;
  /** Poll only while true (panel/screen shown). Hidden tabs never poll either. */
  active: boolean;
  /** Resolved channel list (/api/channels). Needed for the Tencent event id; Migu/ESPN work without it. */
  channels?: MatchSource[];
}

type Tab = "overview" | "players";
const TABS: [Tab, string][] = [["overview", "本场概况"], ["players", "技术统计"]];

export function MatchInsights({ match, active, channels }: MatchInsightsProps): JSX.Element {
  const [controller, state] = useInsightsController(match, channels ?? match.sources);
  const visible = usePageVisible();
  const [tab, setTab] = useState<Tab>("overview");
  const running = active && visible;

  useEffect(() => {
    if (running) controller.start();
    else controller.stop();
    return () => controller.stop();
  }, [controller, running]);

  const snapshot = state.snapshot;
  if (!snapshot) {
    return (
      <section class="lg-ins" aria-live="polite">
        <div class="lg-ins-empty">
          <ChartIcon />
          <p>{state.status}</p>
        </div>
      </section>
    );
  }
  const periods = periodTable(snapshot);
  const comparison = comparisonTable(snapshot);
  return (
    <section class="lg-ins">
      <Scoreboard snapshot={snapshot} />
      {snapshot.scoreSourceName && snapshot.scoreSourceName !== snapshot.sourceName && (
        <p class="lg-ins-caption">比分来源：{snapshot.scoreSourceName}</p>
      )}
      <div class="lg-ins-tabs" role="tablist">
        {TABS.map(([id, label]) => (
          <button type="button" role="tab" aria-selected={tab === id} class={tab === id ? "is-selected" : ""}
            onClick={() => setTab(id)} key={id}>
            {label}
          </button>
        ))}
      </div>
      {tab === "overview" ? (
        <div class="lg-ins-pane" role="tabpanel">
          {periods && <PeriodScores table={periods} />}
          {comparison && <TeamComparison table={comparison} snapshot={snapshot} />}
          {!periods && !comparison && <NoStatistics />}
        </div>
      ) : (
        <div class="lg-ins-pane" role="tabpanel">
          <PlayerStatistics tables={playerTables(snapshot)} />
        </div>
      )}
      <p class="lg-ins-caption lg-ins-updated">
        <CheckIcon />
        {`${snapshot.sourceName}  ${formatClock(snapshot.updatedAt)} 更新`}
      </p>
      {state.status && state.status !== STATUS.empty && (
        <p class="lg-ins-caption lg-ins-status" aria-live="polite">{state.status}</p>
      )}
    </section>
  );
}

function formatClock(at: number): string {
  return new Date(at).toLocaleTimeString("zh-CN", { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function splitScore(score: string): [string, string] {
  const parts = score.split(":").map((s) => s.trim());
  return [parts[0] || "—", parts[1] || "—"];
}

function Scoreboard({ snapshot }: { snapshot: SportsSnapshot }) {
  const [left, right] = splitScore(snapshot.score);
  return (
    <div class="lg-ins-board">
      {snapshot.period && <div class="lg-ins-period">{snapshot.period}</div>}
      <div class="lg-ins-board-row">
        <ScoreTeam name={snapshot.left} badge={snapshot.leftBadge} side="left" />
        <div class="lg-ins-score" aria-label={`比分 ${snapshot.score}`}>
          <span>{left}</span><span class="lg-ins-colon">:</span><span>{right}</span>
        </div>
        <ScoreTeam name={snapshot.right} badge={snapshot.rightBadge} side="right" />
      </div>
    </div>
  );
}

function ScoreTeam({ name, badge, side }: { name: string; badge?: string; side: "left" | "right" }) {
  return (
    <div class="lg-ins-team">
      <TeamCrest url={badge} name={name} />
      <span class="lg-ins-team-name">{name}</span>
      <span class={`lg-ins-team-bar is-${side}`} />
    </div>
  );
}

function TeamCrest({ url, name }: { url?: string; name: string }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [url]);
  if (!url || failed) return <span class="lg-ins-crest is-fallback" aria-hidden="true">{Array.from(name)[0] ?? "?"}</span>;
  return <img class="lg-ins-crest" src={url} alt="" loading="lazy" referrerpolicy="no-referrer" onError={() => setFailed(true)} />;
}

function SectionTitle({ children }: { children: string }) {
  return <h3 class="lg-ins-section">{children}</h3>;
}

function TableSource({ table }: { table: SportsTable }) {
  return table.sourceName ? <p class="lg-ins-caption">来源：{table.sourceName}</p> : null;
}

const cell = (value: string | undefined) => (value === undefined || value === "" ? "—" : value);

function PeriodScores({ table }: { table: SportsTable }) {
  const last = table.headers.length - 1;
  return (
    <div class="lg-ins-block">
      <SectionTitle>分节得分</SectionTitle>
      <div class="lg-ins-scroll">
        <table class="lg-ins-periods">
          <thead>
            <tr>{table.headers.map((h, i) => <th class={i === last ? "is-total" : ""} key={i}>{h}</th>)}</tr>
          </thead>
          <tbody>
            {table.rows.map((row, r) => (
              <tr key={r}>
                {table.headers.map((_, i) => i === 0
                  ? <th scope="row" key={i}>{cell(row[i])}</th>
                  : <td class={i === last ? "is-total" : ""} key={i}>{cell(row[i])}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <TableSource table={table} />
    </div>
  );
}

function TeamComparison({ table, snapshot }: { table: SportsTable; snapshot: SportsSnapshot }) {
  return (
    <div class="lg-ins-block">
      <SectionTitle>球队对比</SectionTitle>
      <div class="lg-ins-legend">
        <span class="is-left">{snapshot.left}</span>
        <span class="is-right">{snapshot.right}</span>
      </div>
      <ul class="lg-ins-compare">
        {table.rows.map((row, i) => {
          const metric = statComparison(row);
          return (
            <li key={i}>
              <div class="lg-ins-compare-row">
                <span class="is-left">{cell(row[1])}</span>
                <span class="lg-ins-compare-label">{row[0] ?? ""}</span>
                <span class="is-right">{cell(row[2])}</span>
              </div>
              {metric && (
                <div class="lg-ins-bar" aria-hidden="true">
                  <span class="is-left" style={{ flexGrow: metric.leftShare }} />
                  <span class="is-right" style={{ flexGrow: 1 - metric.leftShare }} />
                </div>
              )}
            </li>
          );
        })}
      </ul>
      <TableSource table={table} />
    </div>
  );
}

function PlayerStatistics({ tables }: { tables: SportsTable[] }) {
  const [selected, setSelected] = useState(0);
  if (!tables.length) return <NoStatistics />;
  const index = Math.min(selected, tables.length - 1);
  const table = tables[index];
  return (
    <div class="lg-ins-block">
      <div class="lg-ins-chips" role="group">
        {tables.map((t, i) => (
          <button type="button" key={t.title} class={i === index ? "is-selected" : ""} aria-pressed={i === index}
            onClick={() => setSelected(i)}>
            {t.title.split(" · ")[0] ?? t.title}
          </button>
        ))}
      </div>
      <TableSource table={table} />
      <div class="lg-ins-scroll lg-ins-players-wrap">
        <table class="lg-ins-players">
          <thead>
            <tr>{table.headers.map((h, i) => <th class={i === 0 ? "is-name" : ""} key={i}>{i === 0 ? (h || "球员") : h}</th>)}</tr>
          </thead>
          <tbody>
            {table.rows.map((row, r) => (
              <tr key={r} class={row[0] === "统计" ? "is-total" : ""}>
                {table.headers.map((_, i) => i === 0
                  ? <th scope="row" class="is-name" key={i}>{cell(row[0])}</th>
                  : <td class={i === 2 ? "is-key" : ""} key={i}>{cell(row[i])}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p class="lg-ins-caption">球员姓名固定，左右滚动查看其余统计</p>
    </div>
  );
}

function NoStatistics() {
  return <p class="lg-ins-none">暂无本场技术统计</p>;
}

function ChartIcon() {
  return (
    <svg class="lg-ins-icon" viewBox="0 0 24 24" width="36" height="36" aria-hidden="true">
      <path d="M4 20V10M10 20V4M16 20v-7M22 20H2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true">
      <circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2" />
      <path d="M8 12.5l2.5 2.5L16 9.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
    </svg>
  );
}
