import { useEffect } from "preact/hooks";
import { appConfig } from "../core/config";
import { listModel } from "../core/listModel";
import { session } from "../core/session";
import { useStore } from "../core/store";
import { DetailPane } from "./DetailPane";
import { Icon } from "./icons";
import { ListPane } from "./ListPane";
import { EmptyState } from "./parts";
import { linkHandler, navigate, useRoute } from "./router";
import { SettingsPane } from "./SettingsPane";

function SignIn() {
  const account = useStore(session);
  return (
    <div class="signin">
      <div class="panel">
        <img class="logo" src="/icon-192.png" alt="" />
        <h1>leeguoo sports</h1>
        <p>赛程、比分、中文直播线路与比赛数据。登录 leeguoo 账号后观看。</p>
        <button type="button" class="button primary" onClick={() => account.signIn()}>登录 leeguoo 账号</button>
        <p class="faint" style={{ fontSize: "12px" }}>与 App 使用同一个账号；支持邮箱、Apple、微信等登录方式。</p>
      </div>
    </div>
  );
}

function TopBar() {
  const model = useStore(listModel);
  return (
    <header class="topbar">
      <a class="brand" href="/" onClick={linkHandler("/")}>
        <img src="/icon-32.png" alt="" />
        <span>leeguoo sports</span>
      </a>
      <span class="spacer" />
      <label class="search">
        <span class="visually-hidden">搜索球队或联赛</span>
        <Icon name="search" />
        <input type="search" list="league-names" placeholder="搜索球队或联赛" value={model.searchText}
          onInput={(e) => {
            model.setSearch((e.target as HTMLInputElement).value);
            if (location.pathname === "/settings") navigate("/");
          }} />
        <datalist id="league-names">{model.leagueNames.map((name) => <option key={name} value={name} />)}</datalist>
      </label>
      <button type="button" class={`icon-button${model.isLoading ? " spin" : ""}`} aria-label="刷新" disabled={model.isLoading}
        onClick={() => void model.refresh()}><Icon name="refresh" /></button>
      <a class="icon-button" href="/settings" aria-label="设置" onClick={linkHandler("/settings")}><Icon name="settings" /></a>
    </header>
  );
}

export function App() {
  const account = useStore(session);
  const route = useRoute();

  useEffect(() => {
    void session.load();
  }, []);

  useEffect(() => {
    if (account.state !== "signedIn") return;
    void listModel.loadIfNeeded();
    void appConfig.refreshIfStale();
    listModel.startAutoRefresh();
    // Back to the page: re-check what is old enough to matter, like the apps on foreground.
    const onVisible = () => {
      if (document.visibilityState !== "visible") return;
      if (listModel.preferences.autoRefresh) void listModel.refreshIfStale();
      void appConfig.refreshIfStale();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      listModel.stopAutoRefresh();
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [account.state]);

  if (account.state === "loading") return <div class="signin"><span class="spinner" /></div>;
  if (account.state === "signedOut") return <SignIn />;
  if (account.state === "error") {
    return (
      <div class="signin">
        <EmptyState image="offline" title="暂时连不上服务" message={account.error}>
          <button type="button" class="button" onClick={() => void session.load()}>重试</button>
        </EmptyState>
      </div>
    );
  }

  return (
    <div class="app">
      <TopBar />
      {route.name === "settings" ? (
        <main class="layout"><div class="pane"><SettingsPane /></div></main>
      ) : (
        <main class={`layout split`}>
          <div class={`pane list-pane${route.name === "match" ? " hidden-narrow" : ""}`}>
            <ListPane selectedID={route.name === "match" ? route.id : undefined} />
          </div>
          <div class={`pane detail-pane${route.name === "match" ? "" : " wide-only"}`}>
            {route.name === "match"
              ? <DetailPane key={route.id} id={route.id} />
              : <div class="wide-only-placeholder"><EmptyState image="nomatch" title="选一场比赛" message="点左边的比赛，直接打开中文高清直播。" /></div>}
          </div>
        </main>
      )}
    </div>
  );
}
