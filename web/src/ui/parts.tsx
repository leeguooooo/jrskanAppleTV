import type { ComponentChildren } from "preact";
import { useEffect, useState } from "preact/hooks";
import type { MatchStatus } from "../core/models";

/// Team logo, or the team's first character when the logo is missing or broken.
export function TeamCrest({ url, name, size }: { url?: string; name: string; size: number }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [url]);
  const style = { width: `${size}px`, height: `${size}px`, fontSize: `${Math.round(size * 0.42)}px` };
  if (!url || failed) return <span class="crest" style={style} aria-hidden="true">{[...name][0] ?? "?"}</span>;
  return <img class="crest" style={style} src={url} alt="" loading="lazy" referrerpolicy="no-referrer" onError={() => setFailed(true)} />;
}

export function StatusPill({ status }: { status: MatchStatus }) {
  switch (status.kind) {
    case "live":
      return <span class="pill live"><span class="live-dot" />LIVE · {status.label}</span>;
    case "upcoming":
      // Like the apps: only a near kickoff earns a countdown.
      return status.startsInMinutes <= 90 ? <span class="pill followed">{status.startsInMinutes} 分钟后开赛</span> : null;
    case "scheduled":
      return <span class="pill soft">未开赛</span>;
    case "interrupted":
      return <span class="pill soft">{status.label}</span>;
    case "finished":
      return <span class="pill soft">已结束</span>;
    case "unknown":
      return null;
  }
}

export function Notice({ tone, children, action }: {
  tone: "info" | "error";
  children: ComponentChildren;
  action?: { title: string; run: () => void };
}) {
  return (
    <div class={`notice ${tone}`} role={tone === "error" ? "alert" : "status"}>
      <span>{children}</span>
      {action && <button type="button" onClick={action.run}>{action.title}</button>}
    </div>
  );
}

export function EmptyState({ image, title, message, children }: {
  image: "nomatch" | "nochannel" | "offline" | "search";
  title: string;
  message?: string;
  children?: ComponentChildren;
}) {
  return (
    <div class="empty">
      <img src={`/img/empty-${image}.png`} alt="" />
      <h2>{title}</h2>
      {message && <p>{message}</p>}
      {children}
    </div>
  );
}

/** Re-render every `ms` so relative times and LIVE minutes stay current. */
export function useNow(ms = 30_000): number {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(timer);
  }, [ms]);
  return now;
}
