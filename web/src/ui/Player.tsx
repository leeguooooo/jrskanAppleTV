// The web counterpart of iOS PlayerSession + TouchPlayerScreen: plays the
// resolved m3u8 (hls.js, or native HLS where MSE is missing), samples health
// like PlaybackHealthMonitor, and reports confirmations/stalls to the model.
import type Hls from "hls.js";
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
  const video = useRef<HTMLVideoElement>(null);
  const [needsTap, setNeedsTap] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [idle, setIdle] = useState(false);
  const request = model.playback;
  const watermark = config.watermark;

  useEffect(() => {
    const element = video.current;
    if (!element || !request) return;
    let fatal = false;
    let blocked = false;
    let hls: Hls | undefined;
    setNeedsTap(false);
    const start = () => element.play().then(() => {
      blocked = false;
      setNeedsTap(false);
    }).catch((error: DOMException) => {
      // Autoplay with sound refused: wait for a tap, which is a pause, not a stall.
      if (error.name === "NotAllowedError") {
        blocked = true;
        setNeedsTap(true);
      }
    });
    let disposed = false;
    // hls.js wherever MSE exists (desktop, Android, iPadOS, iOS 17.1+ ManagedMediaSource);
    // native HLS otherwise. hls.js loads only when a stream is about to play.
    if ("MediaSource" in window || "ManagedMediaSource" in window) {
      void import("hls.js").then(({ default: HlsClass }) => {
        if (disposed) return;
        if (!HlsClass.isSupported()) {
          element.src = request.url;
          void start();
          return;
        }
        const instance = new HlsClass({ lowLatencyMode: false, backBufferLength: 30, manifestLoadingMaxRetry: 2, levelLoadingMaxRetry: 2, fragLoadingMaxRetry: 3 });
        hls = instance;
        instance.on(HlsClass.Events.ERROR, (_, data) => {
          if (!data.fatal) return;
          if (data.type === HlsClass.ErrorTypes.MEDIA_ERROR) instance.recoverMediaError();
          else fatal = true;
        });
        instance.on(HlsClass.Events.MANIFEST_PARSED, () => void start());
        instance.loadSource(request.url);
        instance.attachMedia(element);
      }, () => { fatal = true; });
    } else {
      element.src = request.url;
      void start();
    }
    const onError = () => { if (!hls) fatal = true; };
    element.addEventListener("error", onError);
    const onEnded = () => model.handleStall("播放已停止，请重试或切换线路。", request.id);
    const onPlaying = () => {
      blocked = false;
      setNeedsTap(false);
    };
    element.addEventListener("ended", onEnded);
    element.addEventListener("playing", onPlaying);

    const health = new PlaybackHealthMonitor(performance.now() / 1000);
    const watchdog = setInterval(() => {
      if (model.playback?.id !== request.id) return;
      const event = health.sample(performance.now() / 1000, element.currentTime,
        !element.paused && element.readyState >= 3,
        blocked || (element.paused && element.readyState > 0),
        element.readyState >= 2 && element.videoWidth > 0, fatal);
      if (event?.kind === "confirmed") model.confirmPlayback(request.id, event.startupSeconds);
      if (event?.kind === "stalled") {
        clearInterval(watchdog);
        model.handleStall(health.confirmed ? "播放中断，暂时无法恢复。" : "20 秒内没有出现画面。", request.id);
      }
    }, 1000);

    return () => {
      clearInterval(watchdog);
      disposed = true;
      element.removeEventListener("ended", onEnded);
      element.removeEventListener("playing", onPlaying);
      element.removeEventListener("error", onError);
      hls?.destroy();
      element.removeAttribute("src");
      element.load();
    };
  }, [request?.id]);

  // Hide the tool buttons after a few seconds without pointer movement.
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    const node = frame.current;
    const wake = () => {
      setIdle(false);
      clearTimeout(timer);
      timer = setTimeout(() => setIdle(true), 3000);
    };
    wake();
    node?.addEventListener("pointermove", wake);
    node?.addEventListener("pointerdown", wake);
    return () => {
      clearTimeout(timer);
      node?.removeEventListener("pointermove", wake);
      node?.removeEventListener("pointerdown", wake);
    };
  }, []);

  const toggleFullscreen = async () => {
    const node = frame.current;
    if (!node) return;
    if (document.fullscreenElement) {
      await document.exitFullscreen().catch(() => undefined);
      return;
    }
    if (node.requestFullscreen) {
      await node.requestFullscreen().catch(() => undefined);
      // Phones: turn to landscape like the apps do; unsupported elsewhere.
      await (screen.orientation as ScreenOrientation & { lock?: (o: string) => Promise<void> }).lock?.("landscape").catch(() => undefined);
    } else {
      // iPhone Safari: only the video element itself can go fullscreen.
      (video.current as HTMLVideoElement & { webkitEnterFullscreen?: () => void })?.webkitEnterFullscreen?.();
    }
  };

  const togglePiP = async () => {
    const element = video.current;
    if (!element) return;
    if (document.pictureInPictureElement) await document.exitPictureInPicture().catch(() => undefined);
    else await element.requestPictureInPicture?.().catch(() => undefined);
  };

  const channels = model.resolvedChannels;
  const status = model.resolvingIndex !== undefined ? "正在恢复播放…" : undefined;

  return (
    <div ref={frame} class={`player${idle && !menuOpen ? " idle" : ""}`}>
      <video ref={video} playsInline controls autoplay />
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
          {"pictureInPictureEnabled" in document && document.pictureInPictureEnabled && (
            <button type="button" aria-label="画中画" onClick={() => void togglePiP()}><Icon name="pip" /></button>
          )}
          <button type="button" aria-label="全屏" onClick={() => void toggleFullscreen()}><Icon name="fullscreen" /></button>
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
      {needsTap && (
        <div class="center-msg" style={{ pointerEvents: "auto" }}>
          <button class="button primary" type="button" onClick={() => void video.current?.play().then(() => setNeedsTap(false)).catch(() => undefined)}>
            <Icon name="play" filled />点击播放
          </button>
        </div>
      )}
    </div>
  );
}
