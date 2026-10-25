// Port of MatchStatisticsView (App/Sources/Shared/MatchDataViews.swift):
// the listing feed's own half-time / corners / difference / total figures.
import type { JSX } from "preact";
import { basketballSummary, cornersText, halftimeText, type LiveMatch } from "../../core/models";
import "./insights.css";

export function MatchStatistics({ match }: { match: LiveMatch }): JSX.Element | null {
  const state = match.providerState;
  if (!state) return null;
  const items: [string, string][] = [];
  const half = halftimeText(state);
  if (half) items.push(["半场", half]);
  const corners = cornersText(state);
  if (corners) items.push(["角球", corners]);
  const summary = basketballSummary(state);
  if (summary) items.push(["分差", String(summary.difference)], ["总分", String(summary.total)]);
  if (!items.length) return null;
  return (
    <dl class="lg-ins-facts">
      {items.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}
