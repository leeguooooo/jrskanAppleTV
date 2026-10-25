// The web counterpart of iOS PlayerSession + TouchPlayerScreen: plays the
// resolved m3u8 (hls.js, or native HLS where MSE is missing), samples health
// like PlaybackHealthMonitor, and reports confirmations/stalls to the model.
import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { appConfig, type Watermark } from "../core/config";
import { PlaybackHealthMonitor } from "../core/health";
import type { MatchPlaybackModel } from "../core/playbackModel";
import { useStore } from "../core/store";
import { Icon } from "./icons";

function Watermark({ settings }: { settings: Watermark }) {
  const ref = useRef<HTMLDivElement>(null);
  const [text, setText] = useState(settings.texts[0]);
  useEffect(() => {
    const label = ref.current;
    const box = label?.parentElement;
    if (!label || !box) return;
    let index = 0;
    // Inside the frame with a margin, clear of the control bands at the top and bottom.
    const place = () => {
      const w = box.clientWidth, h = box.clientHeight;
      const lw = label.offsetWidth, lh = label.offsetHeight;
      if (settings.motion === "fixed") return { x: w - lw - 20, y: h - lh - 20 - h * 0.12 };
      const top = 20 + (h - 40) * 0.15, bottom = h - 20 - (h - 40) * 0.2;
      return {
        x: 20 + Math.random() * Math.max(0, w - 40 - lw),
        y: top + Math.random() * Math.max(0, bottom - top - lh),
      };
    };
    const move = (animate: boolean) => {
      const { x, y } = place();
      label.style.transition = animate && settings.motion === "drift" ? `transform ${settings.interval}s linear` : "none";
      label.style.transform = `translate(${x}px, ${y}px)`;
    };
    const advance = () => {
      if (settings.texts.length < 2) return;
      index = (index + 1) % settings.texts.length;
      setText(settings.texts[index]);
    };
    label.style.opacity = String(settings.opacity);
    move(false);
    if (settings.motion === "drift") requestAnimationFrame(() => move(true));
    const timer = settings.motion === "fixed" ? undefined : setInterval(() => {
      if (settings.motion === "drift") {
        advance();
        move(true);
      } else {
        label.style.transition = "opacity 0.6s";
        label.style.opacity = "0";
        setTimeout(() => {
          advance();
          move(false);
          label.style.transition = "opacity 0.6s";
          label.style.opacity = String(settings.opacity);
        }, 600);
      }
    }, settings.interval * 1000);
    const resize = new ResizeObserver(() => move(false));
    resize.observe(box);
    return () => {
      clearInterval(timer);
      resize.disconnect();
    };
  }, [settings]);
  return <div ref={ref} class="watermark" aria-hidden="true">{text}</div>;
}

interface FrameStatus { t: number; paused: boolean; rs: number; w: number; fatal: boolean; blocked: boolean }

export function Player({ model, onClose, overlay, danmaku }: {
  model: MatchPlaybackModel;
  onClose: () => void;
  danmaku?: { enabled: boolean; toggle: () => void };
  /** Rendered above the video, below the controls (the danmaku layer). */
  overlay?: ComponentChildren;
}) {
  useStore(model);
  const config = useStore(appConfig);
  const frame = useRef<HTMLDivElement>(null);
  const iframe = useRef<HTMLIFrameElement>(null);
  const [frameReady, setFrameReady] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [idle, setIdle] = useState(false);
  const request = model.playback;
  const watermark = config.watermark;

  // The <video> lives in a sandboxed, opaque-origin iframe (public/player.html):
  // stream CDNs then see `Origin: null` and no Referer, never this site.
  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      if (event.source === iframe.current?.contentWindow && event.data?.type === "ready") setFrameReady(true);
    };
    addEventListener("message", onMessage);
    return () => removeEventListener("message", onMessage);
  }, []);

  useEffect(() => {
    const target = iframe.current?.contentWindow;
    if (!target || !frameReady || !request) return;
    let latest: FrameStatus | undefined;
    const onMessage = (event: MessageEvent) => {
      if (event.source !== target || event.data?.id !== request.id) return;
      if (event.data.type === "status") latest = event.data as FrameStatus;
      if (event.data.type === "ended") model.handleStall("播放已停止，请重试或切换线路。", request.id);
    };
    addEventListener("message", onMessage);
    target.postMessage({ type: "load", id: request.id, url: request.url }, "*");

    const health = new PlaybackHealthMonitor(performance.now() / 1000);
    const watchdog = setInterval(() => {
      if (model.playback?.id !== request.id) return;
      const s = latest;
      const event = health.sample(performance.now() / 1000, s?.t ?? Number.NaN,
        !!s && !s.paused && s.rs >= 3,
        !!s && (s.blocked || (s.paused && s.rs > 0)),
        !!s && s.rs >= 2 && s.w > 0, s?.fatal ?? false);
      if (event?.kind === "confirmed") model.confirmPlayback(request.id, event.startupSeconds);
      if (event?.kind === "stalled") {
        clearInterval(watchdog);
        model.handleStall(health.confirmed ? "播放中断，暂时无法恢复。" : "20 秒内没有出现画面。", request.id);
      }
    }, 1000);

    return () => {
      clearInterval(watchdog);
      removeEventListener("message", onMessage);
      target.postMessage({ type: "stop" }, "*");
    };
  }, [request?.id, frameReady]);

  // Hide the tool buttons after a few seconds without pointer movement.
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    const node = frame.current;
    const wake = () => {
      setIdle(false);
      clearTimeout(timer);
      timer = setTimeout(() => setIdle(true), 3000);
    };
    const fromFrame = (event: MessageEvent) => {
      if (event.source === iframe.current?.contentWindow && event.data?.type === "activity") wake();
    };
    wake();
    node?.addEventListener("pointermove", wake);
    node?.addEventListener("pointerdown", wake);
    addEventListener("message", fromFrame);
    return () => {
      clearTimeout(timer);
      node?.removeEventListener("pointermove", wake);
      node?.removeEventListener("pointerdown", wake);
      removeEventListener("message", fromFrame);
    };
  }, []);

  const toggleFullscreen = async () => {
    const node = frame.current;
    if (!node) return;
    if (document.fullscreenElement) {
      await document.exitFullscreen().catch(() => undefined);
      return;
    }
    await node.requestFullscreen().catch(() => undefined);
    // Phones: turn to landscape like the apps do; unsupported elsewhere.
    await (screen.orientation as ScreenOrientation & { lock?: (o: string) => Promise<void> }).lock?.("landscape").catch(() => undefined);
  };

  const channels = model.resolvedChannels;
  const status = model.resolvingIndex !== undefined ? "正在恢复播放…" : undefined;

  return (
    <div ref={frame} class={`player${idle && !menuOpen ? " idle" : ""}`}>
      {/* Picture-in-picture comes from the video's own controls inside the frame. */}
      <iframe ref={iframe} class="player-frame" src="/player.html" title="视频" sandbox="allow-scripts"
        allow="autoplay; picture-in-picture" referrerpolicy="no-referrer" onLoad={() => setFrameReady(true)} />
      {overlay}
      {watermark && <Watermark settings={watermark} />}
      <div class="overlay-top">
        <div style={{ display: "flex", flexDirection: "column", gap: "6px", alignItems: "flex-start" }}>
          {request && <span class="capsule">{`线路 ${request.index + 1} · ${request.sourceName}`}</span>}
          {model.notice && <span class="capsule">{model.notice}</span>}
          {status && <span class="capsule">{status}</span>}
        </div>
        <div class="tools">
          {channels.length > 1 && (
            <button type="button" aria-label="切换线路" aria-expanded={menuOpen} onClick={() => setMenuOpen(!menuOpen)}><Icon name="list" /></button>
          )}
          {danmaku && (
            <button type="button" aria-label={danmaku.enabled ? "关闭弹幕" : "开启弹幕"} aria-pressed={danmaku.enabled}
              onClick={danmaku.toggle} style={{ opacity: danmaku.enabled ? 1 : 0.6 }}><Icon name="chat" /></button>
          )}
          {document.fullscreenEnabled && (
            <button type="button" aria-label="全屏" onClick={() => void toggleFullscreen()}><Icon name="fullscreen" /></button>
          )}
          <button type="button" aria-label="关闭播放" onClick={onClose}><Icon name="close" /></button>
        </div>
      </div>
      {menuOpen && (
        <div class="menu" role="menu">
          {channels.map((source, index) => (
            <button key={source.id} type="button" role="menuitem" aria-current={request?.index === index}
              disabled={model.resolvingIndex !== undefined}
              onClick={() => { setMenuOpen(false); void model.startPlayback(index); }}>
              <span class="tabular faint">{index + 1}</span>
              <span style={{ flex: 1 }}>{source.name}</span>
              {model.stalledIndices.has(index) && <small class="faint">没有画面</small>}
              {model.failedResolutionIndices.has(index) && <small class="faint">未能播放</small>}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
