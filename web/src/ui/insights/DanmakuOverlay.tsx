// Port of SportsDanmakuOverlay / DanmakuView (Swift) and SportsDanmaku.kt:
// display-only, three lanes, one new comment every 2.5 s, queue max 20,
// 7 s linear flight. Runs independently of the <video> element.
import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import type { JSX } from "preact";
import type { LiveMatch, MatchSource } from "../../core/models";
import { DANMAKU_EMIT_MS, DanmakuQueue } from "../../sports/controller";
import { useInsightsController, usePageVisible, usePictureInPicture } from "./hooks";
import "./insights.css";

export interface DanmakuOverlayProps {
  match: LiveMatch;
  /** The player is on screen. */
  active: boolean;
  /** The user's 弹幕 toggle. */
  enabled: boolean;
  /** Resolved channel list (/api/channels); needed for Tencent comments, Migu works without it. */
  channels?: MatchSource[];
}

interface Flight {
  id: string;
  text: string;
  lane: number;
}

export function DanmakuOverlay({ match, active, enabled, channels }: DanmakuOverlayProps): JSX.Element | null {
  const [controller, state] = useInsightsController(match, channels ?? match.sources);
  const visible = usePageVisible();
  const pip = usePictureInPicture();
  const queue = useMemo(() => new DanmakuQueue(), [controller]);
  const [flights, setFlights] = useState<Flight[]>([]);
  const root = useRef<HTMLDivElement>(null);
  const running = !!state.key && active && enabled && visible && !pip;

  useEffect(() => {
    if (running) queue.offer(state.comments);
  }, [queue, running, state.comments]);

  useEffect(() => {
    setFlights([]);
    queue.clearPending();
    if (!running) return;
    controller.startComments();
    let lane = 0;
    const timer = setInterval(() => {
      const width = root.current?.clientWidth ?? 0;
      if (width <= 100) return;
      const next = queue.next();
      if (!next) return;
      const flight = { id: next.id, text: next.text, lane };
      lane = (lane + 1) % 3;
      setFlights((list) => [...list, flight]);
    }, DANMAKU_EMIT_MS);
    return () => {
      clearInterval(timer);
      controller.stopComments();
      queue.clearPending();
      setFlights([]);
    };
  }, [controller, queue, running]);

  if (!state.key || !enabled) return null;
  return (
    <div class="lg-dm" ref={root} aria-hidden="true">
      {flights.map((f) => (
        <span key={f.id} class="lg-dm-item" style={{ "--lane": String(f.lane) }}
          onAnimationEnd={() => setFlights((list) => list.filter((x) => x.id !== f.id))}>
          {f.text}
        </span>
      ))}
    </div>
  );
}
