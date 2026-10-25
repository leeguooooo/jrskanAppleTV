import { appConfig, slotLink } from "../core/config";
import { listModel } from "../core/listModel";
import {
  displayTime, matchStatus, scoreText, viewerIsOffFeedTime, type LiveMatch, type SportFilter,
} from "../core/models";
import { useStore } from "../core/store";
import { Icon, type IconName } from "./icons";
import { EmptyState, Notice, StatusPill, TeamCrest, useNow } from "./parts";
import { linkHandler, matchPath } from "./router";

const FILTER_ICONS: Partial<Record<SportFilter, IconName>> = { 热门: "flame", 关注: "star", 最近观看: "clock" };

export function MatchRow({ match, now, selected }: { match: LiveMatch; now: number; selected: boolean }) {
  const model = useStore(listModel);
  const status = matchStatus(match, now);
  const shown = displayTime(match.time, now);
  const score = scoreText(match.providerState);
  const followed = model.preferences.follows(match);
  const href = matchPath(match.id);
  return (
    <a class="match-row" href={href} onClick={linkHandler(href)} aria-current={selected ? "page" : undefined}>
      <div class="when tabular">
        <strong>{shown.clock}</strong>
        <span>{shown.day}</span>
      </div>
      <div class="teams">
        <div class="league">
          <span>{match.league}</span>
          {match.isHot && <span class="pill hot">热门</span>}
          {followed && <span class="pill followed">关注</span>}
        </div>
        <div class="team"><TeamCrest url={match.homeLogoURL} name={match.homeTeam} size={22} /><span>{match.homeTeam}</span></div>
        <div class="team"><TeamCrest url={match.awayLogoURL} name={match.awayTeam} size={22} /><span>{match.awayTeam}</span></div>
      </div>
      <div class="score tabular">
        <StatusPill status={status} />
        {score && <span>{score}</span>}
        {match.sources.length === 0 && status.kind !== "finished" && <span class="faint" style={{ fontSize: "12px", fontWeight: 500 }}>暂无线路</span>}
      </div>
    </a>
  );
}

function Skeletons() {
  return (
    <div class="rows" aria-label="正在载入赛程">
      {[0, 1, 2, 3, 4, 5].map((i) => <div key={i} class="skeleton" style={{ height: "86px" }} />)}
    </div>
  );
}

export function ListPane({ selectedID }: { selectedID?: string }) {
  const model = useStore(listModel);
  const config = useStore(appConfig);
  const now = useNow(30_000);
  const searching = model.searchText.trim().length > 0;
  const banner = config.slot("home_banner");
  const bannerLink = banner && slotLink(banner);
  const continueMatch = model.filter === "全部" && !searching ? model.continueMatch : undefined;

  let body;
  if (model.matches.length === 0 && model.isLoading) {
    body = <Skeletons />;
  } else if (model.matches.length === 0 && model.errorMessage) {
    body = (
      <EmptyState image="offline" title="赛程没有载入" message={model.errorMessage}>
        <button class="button" type="button" onClick={() => void model.refresh()}>重试</button>
      </EmptyState>
    );
  } else if (searching) {
    const results = model.searchResults(now);
    body = results.length ? (
      <div class="rows">{results.map((m) => <MatchRow key={m.id} match={m} now={now} selected={m.id === selectedID} />)}</div>
    ) : <EmptyState image="search" title="没有找到比赛" message="换个球队或联赛名称试试。" />;
  } else {
    const sections = model.sections(now);
    body = sections.length ? sections.map((section) => (
      <section key={section.title}>
        <h2 class="section-title">{section.title}<span class="count">{section.matches.length}</span></h2>
        <div class="rows">{section.matches.map((m) => <MatchRow key={m.id} match={m} now={now} selected={m.id === selectedID} />)}</div>
      </section>
    )) : (
      <EmptyState image="nomatch" title={model.filter === "关注" ? "关注的球队暂时没有比赛" : "这个分类暂时没有比赛"}
        message="换个分类看看，赛程每 5 分钟自动更新。" />
    );
  }

  return (
    <div>
      {banner && (
        bannerLink
          ? <a class="card banner" href={bannerLink} target="_blank" rel="noopener"><div><strong>{banner.title}</strong>{banner.detail && <span>{banner.detail}</span>}</div></a>
          : <div class="card banner"><div><strong>{banner.title}</strong>{banner.detail && <span>{banner.detail}</span>}</div></div>
      )}
      {!searching && (
        <div class="chips" role="toolbar" aria-label="分类">
          {model.availableFilters.map((filter) => (
            <button key={filter} type="button" class="chip" aria-pressed={model.filter === filter} onClick={() => model.setFilter(filter)}>
              {FILTER_ICONS[filter] && <Icon name={FILTER_ICONS[filter]!} filled={filter === "关注"} />}
              {filter}
              <span class="count">{model.categoryCount(filter)}</span>
            </button>
          ))}
        </div>
      )}
      {continueMatch && (
        <a class="card continue" href={matchPath(continueMatch.id)} onClick={linkHandler(matchPath(continueMatch.id))} style={{ textDecoration: "none" }}>
          <span style={{ color: "var(--accent)", width: "28px", height: "28px" }}><Icon name="play" filled /></span>
          <div>
            <div class="label">继续观看</div>
            <div>{continueMatch.homeTeam} vs {continueMatch.awayTeam}</div>
          </div>
        </a>
      )}
      {model.errorMessage && model.matches.length > 0 && (
        <Notice tone="error" action={{ title: "重试", run: () => void model.refresh() }}>{model.errorMessage}</Notice>
      )}
      {body}
      {model.matches.length > 0 && (
        <p class="status-line tabular">
          {model.scoreUpdateText(now)}
          {model.lastUpdated && ` · 赛程 ${new Date(model.lastUpdated).toLocaleTimeString("zh-CN", { hour12: false, hour: "2-digit", minute: "2-digit" })}`}
          {viewerIsOffFeedTime(now) && " · 时间已换算为本地时区"}
        </p>
      )}
    </div>
  );
}
