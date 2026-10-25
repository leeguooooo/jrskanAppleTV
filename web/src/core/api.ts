// Same-origin calls to the Worker. A 401 anywhere means the session is gone.
import type { EventSnapshot } from "./events";
import type { LiveMatch, MatchSource } from "./models";

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

let onSignedOut: () => void = () => {};
export function setSignedOutHandler(handler: () => void) {
  onSignedOut = handler;
}

async function get<T>(path: string, timeout = 30_000): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, { credentials: "same-origin", signal: AbortSignal.timeout(timeout) });
  } catch {
    throw new ApiError(0, "network", "网络连接失败，请检查网络后重试。");
  }
  const body = await response.json().catch(() => undefined) as { error?: string; message?: string } | undefined;
  if (response.status === 401) {
    onSignedOut();
    throw new ApiError(401, "signed_out", "请先登录 leeguoo 账号。");
  }
  if (!response.ok) throw new ApiError(response.status, body?.error ?? "http", body?.message ?? `服务返回 ${response.status}`);
  return body as T;
}

export interface Me {
  sub: string;
  name: string | null;
  email: string | null;
  picture: string | null;
  membership: { activeKeys: string[]; validUntil: number | null; isTrial: boolean; active: boolean };
  checkedAt: number;
}

export const api = {
  me: () => get<Me>("/api/me"),
  schedule: () => get<{ matches: LiveMatch[]; hasEvents: boolean; fetchedAt: number }>("/api/schedule"),
  events: () => get<EventSnapshot>("/api/events"),
  channels: (source: MatchSource) =>
    get<{ channels: MatchSource[] }>(`/api/channels?url=${encodeURIComponent(source.pageURL)}&sig=${source.sig ?? ""}`),
  resolve: (source: MatchSource, fresh = false) =>
    get<{ url: string }>(`/api/resolve?url=${encodeURIComponent(source.pageURL)}&sig=${source.sig ?? ""}${fresh ? "&fresh=1" : ""}`, 60_000),
  async logout() {
    await fetch("/auth/logout", { method: "POST", credentials: "same-origin" }).catch(() => undefined);
  },
};
