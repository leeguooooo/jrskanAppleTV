import { useState } from "preact/hooks";
import { listModel } from "../core/listModel";
import { preferences } from "../core/preferences";
import { MANAGE_URL, MEMBERSHIP_URL, session } from "../core/session";
import { useStore } from "../core/store";
import { Icon } from "./icons";
import { goBack } from "./router";

function Toggle({ label, detail, checked, onChange }: { label: string; detail: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label class="item">
      <span class="text">{label}<small>{detail}</small></span>
      <span class="switch">
        <input type="checkbox" role="switch" checked={checked} onChange={(e) => onChange((e.target as HTMLInputElement).checked)} />
        <span />
      </span>
    </label>
  );
}

function membershipText(m: { active: boolean; validUntil: number | null; isTrial: boolean }): string {
  if (!m.active) return "未开通会员";
  if (m.validUntil === null) return m.isTrial ? "试用会员" : "会员 · 长期有效";
  const date = new Date(m.validUntil * 1000).toLocaleDateString("zh-CN");
  return `${m.isTrial ? "试用会员" : "会员"} · 有效期至 ${date}`;
}

export function SettingsPane() {
  const prefs = useStore(preferences);
  const account = useStore(session);
  const [cleared, setCleared] = useState(false);
  const me = account.me;
  const name = me?.name || me?.email || "leeguoo 账号";

  return (
    <div class="settings">
      <button type="button" class="back-link" style={{ display: "inline-flex" }} onClick={goBack}><Icon name="back" />赛程</button>
      <h1>设置</h1>

      <section class="group">
        <h2>账号</h2>
        <div class="card">
          <div class="item">
            {me?.picture ? <img class="avatar" src={me.picture} alt="" referrerpolicy="no-referrer" /> : <span class="avatar">{[...name][0]}</span>}
            <span class="text">{name}<small>{me ? membershipText(me.membership) : "正在读取账号…"}</small></span>
          </div>
          <div class="item" style={{ flexWrap: "wrap" }}>
            {me && !me.membership.active && <a class="button primary" href={MEMBERSHIP_URL} target="_blank" rel="noopener">开通会员</a>}
            <a class="button" href={MANAGE_URL} target="_blank" rel="noopener">管理账号<Icon name="external" /></a>
            <button type="button" class="button danger" onClick={() => void account.signOut()}>退出登录</button>
          </div>
        </div>
      </section>

      <section class="group">
        <h2>播放与刷新</h2>
        <div class="card">
          <Toggle label="线路失效时自动换线" detail="无画面或恢复失败时自动换线，正常暂停不受影响。"
            checked={prefs.autoNextChannel} onChange={(v) => prefs.set("autoNextChannel", v)} />
          <Toggle label="自动刷新赛程与比分" detail="赛程每 5 分钟、比分每 30 秒检查；回到页面也会检查。"
            checked={prefs.autoRefresh} onChange={(v) => prefs.set("autoRefresh", v)} />
        </div>
      </section>

      <section class="group">
        <h2>关注与记录</h2>
        <div class="card">
          <div class="item" style={{ display: "block" }}>
            {prefs.favoriteTeams.size === 0
              ? <span class="muted">还没有关注球队，在比赛详情里点「关注」添加。</span>
              : [...prefs.favoriteTeams].sort().map((team) => (
                <span key={team} class="team-chip">★ {team}
                  <button type="button" aria-label={`取消关注 ${team}`} onClick={() => prefs.toggleFavorite(team)}>×</button>
                </span>
              ))}
          </div>
          <div class="item">
            <button type="button" class="button danger" disabled={!prefs.hasHistory} onClick={() => {
              prefs.clearHistory();
              listModel.setFilter("全部");
              setCleared(true);
            }}>{cleared ? "已清除" : "清除关注与观看记录"}</button>
          </div>
        </div>
      </section>

      <section class="group">
        <h2>关于</h2>
        <div class="card">
          <div class="item"><span class="text">内容来源<small>只读取公开网页上的赛程与线路，不托管、不重新分发任何视频，也不绕过登录、DRM、付费墙或地域限制。线路由第三方维护，可能随时失效。</small></span></div>
          <div class="item"><span class="text">隐私<small>网页版需要登录 leeguoo 账号；账号中心保存你的邮箱与登录方式。不接入分析或广告 SDK，关注与观看记录只存在这个浏览器里。</small></span></div>
          <div class="item"><span class="text">平台差异<small>网页版不提供录像与导出，也不支持 AirPlay；其余赛程、线路、比分、数据与弹幕和 App 一致。</small></span></div>
        </div>
        <p class="faint" style={{ fontSize: "12px", margin: "10px 4px" }}>leeguoo sports · 网页版</p>
      </section>
    </div>
  );
}
