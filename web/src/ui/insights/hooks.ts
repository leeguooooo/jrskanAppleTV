import { useEffect, useMemo, useState } from "preact/hooks";
import type { LiveMatch, MatchSource } from "../../core/models";
import { MatchInsightsController, type InsightsState } from "../../sports/controller";
import { matchKey } from "../../sports/client";

/** False while the tab is hidden (background), so nothing polls off-screen. */
export function usePageVisible(): boolean {
  const read = () => typeof document === "undefined" || document.visibilityState !== "hidden";
  const [visible, setVisible] = useState(read);
  useEffect(() => {
    const onChange = () => setVisible(read());
    document.addEventListener("visibilitychange", onChange);
    return () => document.removeEventListener("visibilitychange", onChange);
  }, []);
  return visible;
}

/** True while a video on this page is in picture-in-picture (comments pause, as on Apple/Android). */
export function usePictureInPicture(): boolean {
  const read = () => typeof document !== "undefined" && !!document.pictureInPictureElement;
  const [pip, setPip] = useState(read);
  useEffect(() => {
    const onChange = () => setPip(read());
    // enter/leavepictureinpicture bubble from the <video>; capture to be safe.
    document.addEventListener("enterpictureinpicture", onChange, true);
    document.addEventListener("leavepictureinpicture", onChange, true);
    return () => {
      document.removeEventListener("enterpictureinpicture", onChange, true);
      document.removeEventListener("leavepictureinpicture", onChange, true);
    };
  }, []);
  return pip;
}

function routeKey(match: LiveMatch, channels: MatchSource[]): string {
  return `${match.id}|${matchKey(match)}|${channels.map((c) => c.pageURL).sort().join(",")}`;
}

/** One controller per match + channel set; disposed when either changes or on unmount. */
export function useInsightsController(match: LiveMatch, channels: MatchSource[]): [MatchInsightsController, InsightsState] {
  const key = routeKey(match, channels);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const controller = useMemo(() => new MatchInsightsController(match, channels), [key]);
  const [held, setHeld] = useState<{ owner: MatchInsightsController; state: InsightsState }>(
    () => ({ owner: controller, state: controller.state }));
  useEffect(() => {
    const unsubscribe = controller.subscribe((state) => setHeld({ owner: controller, state }));
    return () => { unsubscribe(); controller.dispose(); };
  }, [controller]);
  return [controller, held.owner === controller ? held.state : controller.state];
}
