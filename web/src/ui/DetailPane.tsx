// Web counterpart of iOS MatchDetailScreen: opens straight into the suggested
// channel (Chinese HD Q first), manual channel choice starts collapsed, and
// closing the player never re-opens it by itself.
import { useEffect, useMemo, useState } from "preact/hooks";
import { listModel } from "../core/listModel";
import {
  basketballSummary, cornersText, displayTime, halftimeText, matchStatus, scoreText, viewerIsOffFeedTime, type LiveMatch,
} from "../core/models";
import { MatchPlaybackModel } from "../core/playbackModel";
import { preferences } from "../core/preferences";
import { useStore } from "../core/store";
import { Icon } from "./icons";
import { supportsInsights } from "../sports/controller";
import { DanmakuOverlay, MatchInsights } from "./insights";
import { EmptyState, Notice, StatusPill, TeamCrest, useNow } from "./parts";
import { Player } from "./Player";
import { goBack } from "./router";

function Statistics({ match }: { match: LiveMatch }) {
  const state = match.providerState;
  if (!state) return null;
  const facts: [string, string][] = [];
  const half = halftimeText(state);
  if (half) facts.push(["半场", half]);
  const corners = cornersText(state);
  if (corners) facts.push(["角球", corners]);
  const summary = basketballSummary(state);
  if (summary) facts.push(["分差", String(summary.difference)], ["总分", String(summary.total)]);
  if (!facts.length) return null;
  return (
    <div class="facts tabular">
      {facts.map(([label, value]) => <span key={label}>{label} <strong style={{ color: "var(--text)" }}>{value}</strong></span>)}
    </div>
  );
}

function FollowButton({ team }: { team: string }) {
  const prefs = useStore(preferences);
  const followed = prefs.isFavorite(team);
  return (
    <button type="button" class="follow" aria-pressed={followed} aria-label={followed ? `取消关注 ${team}` : `关注 ${team}`}
      onClick={() => prefs.toggleFavorite(team)}>
      {followed ? "★ 已关注" : "☆ 关注"}
    </button>
  );
}

function ChannelList({ model }: { model: MatchPlaybackModel }) {
  const channels = model.resolvedChannels;
  const remembered = model.rememberedChannel;
  if (model.match.sources.length === 0) {
    return <EmptyState image="nochannel" title="这场比赛还没有线路" message="开赛前后线路才会陆续上线，稍后回来看看。" />;
  }
  if (model.isLoadingChannels) {
    return <div>{[0, 1, 2].map((i) => <div key={i} class="skeleton" style={{ height: "60px", marginBottom: "8px" }} />)}</div>;
  }
  return (
    <div>
      {channels.map((source, index) => (
        <button key={source.id} type="button" class="channel-row" disabled={model.resolvingIndex !== undefined}
          aria-current={model.playback?.index === index} onClick={() => void model.startPlayback(index)}>
          <span class="num tabular">{index + 1}</span>
          <span>
            {source.name}
            <small>{model.subtitle(source, index)}{remembered?.id === source.id ? " · 上次观看" : ""}</small>
          </span>
          {model.resolvingIndex === index ? <span class="spinner" /> : <Icon name="play" />}
        </button>
      ))}
    </div>
  );
}

export function DetailPane({ id }: { id: string }) {
  const list = useStore(listModel);
  const now = useNow(60_000);
  const live = list.match(id);
  // One model per opened match; the list's live copy supplies fresh scores.
  const model = useMemo(() => (live ? new MatchPlaybackModel(live, preferences) : undefined), [id, !!live]);
  useStore(model ?? list);
  useStore(preferences);
  const [opening, setOpening] = useState(true);

  useEffect(() => {
    if (!model) return;
    let cancelled = false;
    setOpening(true);
    void (async () => {
      await model.loadChannels();
      if (cancelled) return;
      await model.startSuggestedPlayback();
      if (!cancelled) setOpening(false);
    })();
    return () => {
      cancelled = true;
      model.dispose();
    };
  }, [model]);

  if (!live || !model) {
    if (list.isLoading || list.matches.length === 0) {
      return <div class="detail"><div class="skeleton" style={{ height: "220px" }} /></div>;
    }
    return (
      <div class="detail">
        <button type="button" class="back-link" onClick={goBack}><Icon name="back" />赛程</button>
        <EmptyState image="nomatch" title="这场比赛不在当前赛程里" message="可能已经结束并从列表移除，回到赛程看看其他比赛。" />
      </div>
    );
  }

  const match = list.matches.find((m) => m.id === id) ?? { ...live, providerState: undefined };
  const status = matchStatus(match, now);
  const shown = displayTime(match.time, now);
  const score = scoreText(match.providerState);
  const busy = opening || model.resolvingIndex !== undefined;
  const openingName = model.resolvingIndex !== undefined
    ? model.resolvedChannels[model.resolvingIndex]?.name : model.suggestedChannel?.name;

  return (
    <div class="detail">
      <button type="button" class="back-link" onClick={goBack}><Icon name="back" />赛程</button>

      {model.playback && (
        <Player model={model} onClose={() => model.stopPlayback()}
          danmaku={supportsInsights(match)
            ? { enabled: preferences.danmaku, toggle: () => preferences.set("danmaku", !preferences.danmaku) } : undefined}
          overlay={<DanmakuOverlay match={match} active={!!model.playback} enabled={preferences.danmaku} channels={model.resolvedChannels} />} />
      )}

      <div class="card hero">
        <div class="meta">
          <span>{match.league}</span>
          {match.isHot && <span class="pill hot">热门</span>}
          <StatusPill status={status} />
        </div>
        <div class="versus">
          <div class="team">
            <TeamCrest url={match.homeLogoURL} name={match.homeTeam} size={64} />
            <span class="name">{match.homeTeam}</span>
            <FollowButton team={match.homeTeam} />
          </div>
          <div class="center tabular">
            <span class="big" style={{ color: score ? "var(--text)" : "var(--faint)" }}>{score ?? "VS"}</span>
            <span class="muted" style={{ fontSize: "13px" }}>{shown.day ? `${shown.day} ${shown.clock}` : shown.clock}</span>
            {viewerIsOffFeedTime(now) && <span class="faint" style={{ fontSize: "11px" }}>北京 {match.time}</span>}
          </div>
          <div class="team">
            <TeamCrest url={match.awayLogoURL} name={match.awayTeam} size={64} />
            <span class="name">{match.awayTeam}</span>
            <FollowButton team={match.awayTeam} />
          </div>
        </div>
        <Statistics match={match} />
        <p class="faint" style={{ margin: 0, fontSize: "12px", textAlign: "center" }}>
          {match.providerState ? list.scoreUpdateText(now) : "本场实时数据暂不可用"}
        </p>
      </div>

      {busy ? (
        <div class="opening"><span class="spinner" />{model.isLoadingChannels ? "正在寻找中文高清…" : `正在打开${openingName ?? "直播"}…`}</div>
      ) : match.sources.length === 0 ? (
        <p class="muted">这场比赛还没有直播线路，开赛前后再试。</p>
      ) : !model.playback && (
        <div>
          {model.errorMessage && <Notice tone="error">{model.errorMessage}</Notice>}
          <button type="button" class="button primary" style={{ width: "100%" }} onClick={() => void model.startSuggestedPlayback()}>
            <Icon name="play" filled />{model.errorMessage ? "重新播放" : "播放比赛"}
          </button>
        </div>
      )}

      <details class="channels">
        <summary><Icon name="chevron" />手动切换线路</summary>
        <div class="channel-head">
          <h3>选择线路</h3>
          {model.channels && model.channels.length > 0 && <span class="muted" style={{ fontSize: "13px" }}>{model.channels.length} 条可用</span>}
          <span style={{ flex: 1 }} />
          {model.automaticFallbackEnabled && <span class="faint" style={{ fontSize: "12px" }}>失效自动换</span>}
        </div>
        {model.channelNotice && <Notice tone="info">{model.channelNotice}</Notice>}
        {model.notice && <Notice tone="info">{model.notice}</Notice>}
        {model.errorMessage && (
          <Notice tone="error" action={{ title: model.retryActionTitle, run: () => void model.retryAfterError() }}>{model.errorMessage}</Notice>
        )}
        <ChannelList model={model} />
      </details>

      <MatchInsights match={match} active={true} channels={model.resolvedChannels} />
    </div>
  );
}
