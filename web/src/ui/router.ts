import { useEffect, useState } from "preact/hooks";

export type Route = { name: "list" } | { name: "match"; id: string } | { name: "settings" };

export function parseRoute(path: string): Route {
  const match = /^\/match\/([^/]+)\/?$/.exec(path);
  if (match) {
    try {
      return { name: "match", id: decodeURIComponent(match[1]) };
    } catch {
      return { name: "list" };
    }
  }
  if (path === "/settings") return { name: "settings" };
  return { name: "list" };
}

export function matchPath(id: string) {
  return `/match/${encodeURIComponent(id)}`;
}

export function navigate(path: string, replace = false) {
  if (path === location.pathname) return;
  if (replace) history.replaceState(history.state, "", path);
  else history.pushState({ inApp: true }, "", path);
  dispatchEvent(new PopStateEvent("popstate"));
}

/** Back to where the viewer came from inside the app, else the list. */
export function goBack() {
  if (history.state?.inApp) history.back();
  else navigate("/", true);
}

export function useRoute(): Route {
  const [route, setRoute] = useState(() => parseRoute(location.pathname));
  useEffect(() => {
    const update = () => setRoute(parseRoute(location.pathname));
    addEventListener("popstate", update);
    return () => removeEventListener("popstate", update);
  }, []);
  return route;
}

/** Plain anchors that route in-app on a normal click. */
export function linkHandler(path: string) {
  return (event: MouseEvent) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    navigate(path);
  };
}
