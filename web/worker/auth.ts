// Sign-in through the leeguoo account center (account.leeguoo.com), the same
// identity provider as the apps (App/Sources/Shared/Account/AccountAPI.swift).
// The Worker is the OAuth client (public, PKCE). The browser only ever holds an
// encrypted, HttpOnly session cookie; tokens never reach page JavaScript.
//
// Cost: no KV/D1. The session lives in the cookie; the account center is called
// at sign-in and at most once an hour per viewer from /api/me.

export interface Env {
  ASSETS: Fetcher;
  ISSUER: string;
  CLIENT_ID: string;
  PUBLIC_ORIGIN: string;
  SESSION_SECRET: string;
  /** Egress relay (see egress.ts): http://<vm>:<port>/f and its shared secret. */
  RELAY_URL?: string;
  RELAY_SECRET?: string;
  EGRESS?: string;
}

const SESSION_COOKIE = "ls_session";
const OAUTH_COOKIE = "ls_oauth";
const SCOPE = "openid profile email";
const SESSION_DAYS = 30;
const RECHECK_MS = 60 * 60_000;
/** Either the cross-app membership or the app's own plan unlocks the perks. */
export const MEMBERSHIP_KEYS = ["membership.all_apps", "jrkan.premium"];

export interface Membership {
  activeKeys: string[];
  /** Epoch seconds; null with active keys means it never lapses. */
  validUntil: number | null;
  isTrial: boolean;
}

export interface Session {
  sub: string;
  name?: string;
  email?: string;
  picture?: string;
  membership: Membership;
  refreshToken: string;
  checkedAt: number;
  expiresAt: number;
}

// MARK: - Crypto helpers

const encoder = new TextEncoder();

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64url(value: string): Uint8Array<ArrayBuffer> {
  const binary = atob(value.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

const keyCache = new Map<string, Promise<CryptoKey>>();

function deriveKey(secret: string, purpose: "enc" | "mac"): Promise<CryptoKey> {
  const id = `${purpose}:${secret}`;
  let key = keyCache.get(id);
  if (!key) {
    key = (async () => {
      const base = await crypto.subtle.importKey("raw", encoder.encode(secret), "HKDF", false, ["deriveKey"]);
      const params = { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode(`leeguoo-sports/${purpose}`) };
      return purpose === "enc"
        ? crypto.subtle.deriveKey(params, base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"])
        : crypto.subtle.deriveKey(params, base, { name: "HMAC", hash: "SHA-256", length: 256 }, false, ["sign", "verify"]);
    })();
    keyCache.set(id, key);
  }
  return key;
}

export async function seal(secret: string, value: unknown): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await deriveKey(secret, "enc"), encoder.encode(JSON.stringify(value)));
  return `${base64url(iv)}.${base64url(new Uint8Array(data))}`;
}

async function unseal<T>(secret: string, token: string | undefined): Promise<T | undefined> {
  if (!token) return undefined;
  const [iv, data] = token.split(".");
  if (!iv || !data) return undefined;
  try {
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromBase64url(iv) }, await deriveKey(secret, "enc"), fromBase64url(data));
    return JSON.parse(new TextDecoder().decode(plain)) as T;
  } catch {
    return undefined;
  }
}

/** Signature that lets the client hand an upstream URL back to /api/channels and /api/resolve. */
export async function signLink(secret: string, url: string): Promise<string> {
  const mac = await crypto.subtle.sign("HMAC", await deriveKey(secret, "mac"), encoder.encode(`link:${url}`));
  return base64url(new Uint8Array(mac).slice(0, 16));
}

export async function verifyLink(secret: string, url: string, sig: string | null): Promise<boolean> {
  if (!sig) return false;
  const expected = await signLink(secret, url);
  if (expected.length !== sig.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  return diff === 0;
}

// MARK: - Cookies

function readCookie(request: Request, name: string): string | undefined {
  const header = request.headers.get("cookie") ?? "";
  for (const part of header.split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return rest.join("=");
  }
  return undefined;
}

function cookie(name: string, value: string, maxAge: number, path = "/"): string {
  return `${name}=${value}; Path=${path}; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Lax`;
}

export async function readSession(request: Request, env: Env): Promise<Session | undefined> {
  const session = await unseal<Session>(env.SESSION_SECRET, readCookie(request, SESSION_COOKIE));
  return session && session.expiresAt > Date.now() ? session : undefined;
}

async function sessionCookie(env: Env, session: Session): Promise<string> {
  return cookie(SESSION_COOKIE, await seal(env.SESSION_SECRET, session), Math.floor((session.expiresAt - Date.now()) / 1000));
}

// MARK: - Account center calls

class AccountError extends Error {
  constructor(readonly endsSession: boolean, message: string) {
    super(message);
  }
}

async function accountJSON<T>(env: Env, path: string, init: RequestInit = {}): Promise<T> {
  let response: Response;
  try {
    response = await fetch(new URL(path, env.ISSUER), {
      ...init,
      headers: { accept: "application/json", ...(init.headers ?? {}) },
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    throw new AccountError(false, "连不上账号中心，请检查网络后重试。");
  }
  const body = await response.json().catch(() => undefined) as Record<string, unknown> | undefined;
  if (!response.ok) {
    // The refresh token is gone for good; only a new sign-in helps.
    const ends = body?.error === "invalid_grant" || response.status === 401;
    const message = (body?.error_description ?? body?.statusMessage ?? body?.message ?? `账号中心返回 ${response.status}`) as string;
    throw new AccountError(ends, message);
  }
  if (!body) throw new AccountError(false, "账号中心暂时不可用，请稍后再试。");
  return body as T;
}

interface TokenPayload {
  access_token: string;
  refresh_token?: string;
  id_token?: string;
  expires_in?: number;
}

function tokenRequest(env: Env, fields: Record<string, string>): Promise<TokenPayload> {
  return accountJSON<TokenPayload>(env, "/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ ...fields, client_id: env.CLIENT_ID }).toString(),
  });
}

interface EntitlementsPayload {
  active_entitlement_keys: string[];
  entitlements: { entitlement_key: string; status: string; valid_to?: number | null; trial?: boolean }[];
}

async function loadAccount(env: Env, accessToken: string): Promise<Pick<Session, "sub" | "name" | "email" | "picture" | "membership">> {
  const auth = { authorization: `Bearer ${accessToken}` };
  const [profile, payload] = await Promise.all([
    accountJSON<{ sub: string; name?: string; email?: string; picture?: string }>(env, "/userinfo", { headers: auth }),
    accountJSON<EntitlementsPayload>(env, "/api/billing/entitlements", { headers: auth }).catch(() => undefined),
  ]);
  const relevant = (payload?.entitlements ?? []).filter((e) => e.status === "granted" && MEMBERSHIP_KEYS.includes(e.entitlement_key));
  const validUntil = relevant.some((e) => e.valid_to == null) ? null
    : relevant.reduce<number | null>((max, e) => (e.valid_to != null && (max === null || e.valid_to > max) ? e.valid_to : max), null);
  // Apple and WeChat sign-ups that shared no email get a placeholder address.
  const email = profile.email && !profile.email.endsWith("@users.account.invalid") ? profile.email : undefined;
  return {
    sub: profile.sub,
    name: profile.name || undefined,
    email,
    picture: profile.picture || undefined,
    membership: {
      activeKeys: payload?.active_entitlement_keys ?? [],
      validUntil,
      isTrial: relevant.length > 0 && relevant.every((e) => e.trial === true),
    },
  };
}

export function isMember(membership: Membership, now = Date.now()): boolean {
  if (!membership.activeKeys.some((k) => MEMBERSHIP_KEYS.includes(k))) return false;
  return membership.validUntil === null || membership.validUntil * 1000 > now;
}

// MARK: - Routes

function redirectURI(env: Env): string {
  return `${env.PUBLIC_ORIGIN}/auth/callback`;
}

function safeNext(value: string | null): string {
  // Only same-site paths; never an absolute or protocol-relative URL.
  return value && value.startsWith("/") && !value.startsWith("//") && !value.startsWith("/\\") ? value : "/";
}

function errorPage(message: string, status = 400): Response {
  const escaped = message.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
  return new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>leeguoo sports</title>`
      + `<body style="font:16px system-ui;background:#0b0d12;color:#e8eaf0;display:grid;place-items:center;min-height:100vh;margin:0">`
      + `<div style="max-width:28rem;padding:24px"><h1 style="font-size:20px">登录没有完成</h1><p>${escaped}</p><p><a style="color:#7aa7ff" href="/auth/login">重新登录</a></p></div>`,
    { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
  );
}

export async function handleAuth(request: Request, env: Env, url: URL): Promise<Response> {
  switch (url.pathname) {
    case "/auth/login": {
      const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)));
      const state = base64url(crypto.getRandomValues(new Uint8Array(16)));
      const challenge = base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(verifier))));
      const pending = { verifier, state, next: safeNext(url.searchParams.get("next")), exp: Date.now() + 10 * 60_000 };
      const authorize = new URL("/authorize", env.ISSUER);
      authorize.search = new URLSearchParams({
        response_type: "code",
        client_id: env.CLIENT_ID,
        redirect_uri: redirectURI(env),
        scope: SCOPE,
        state,
        code_challenge: challenge,
        code_challenge_method: "S256",
      }).toString();
      return new Response(null, {
        status: 302,
        headers: {
          location: authorize.href,
          "set-cookie": cookie(OAUTH_COOKIE, await seal(env.SESSION_SECRET, pending), 600, "/auth"),
          "cache-control": "no-store",
        },
      });
    }
    case "/auth/callback": {
      const pending = await unseal<{ verifier: string; state: string; next: string; exp: number }>(
        env.SESSION_SECRET, readCookie(request, OAUTH_COOKIE));
      const error = url.searchParams.get("error");
      if (error) return errorPage(url.searchParams.get("error_description") ?? error);
      const code = url.searchParams.get("code");
      if (!pending || pending.exp < Date.now() || !code || url.searchParams.get("state") !== pending.state) {
        return errorPage("登录请求已过期或不匹配，请重新登录。");
      }
      try {
        const tokens = await tokenRequest(env, {
          grant_type: "authorization_code",
          code,
          redirect_uri: redirectURI(env),
          code_verifier: pending.verifier,
        });
        if (!tokens.refresh_token) throw new AccountError(false, "账号中心没有返回刷新令牌。");
        const account = await loadAccount(env, tokens.access_token);
        const now = Date.now();
        const session: Session = {
          ...account,
          refreshToken: tokens.refresh_token,
          checkedAt: now,
          expiresAt: now + SESSION_DAYS * 86400_000,
        };
        const headers = new Headers({ location: pending.next, "cache-control": "no-store" });
        headers.append("set-cookie", await sessionCookie(env, session));
        headers.append("set-cookie", cookie(OAUTH_COOKIE, "", 0, "/auth"));
        return new Response(null, { status: 302, headers });
      } catch (err) {
        return errorPage(err instanceof Error ? err.message : "账号中心暂时不可用，请稍后再试。", 502);
      }
    }
    case "/auth/logout": {
      if (request.method !== "POST") return new Response("method not allowed", { status: 405, headers: { allow: "POST" } });
      const session = await readSession(request, env);
      if (session) {
        await fetch(new URL("/revoke", env.ISSUER), {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ token: session.refreshToken, token_type_hint: "refresh_token", client_id: env.CLIENT_ID }).toString(),
          signal: AbortSignal.timeout(10_000),
        }).catch(() => undefined);
      }
      return new Response(null, {
        status: 204,
        headers: { "set-cookie": cookie(SESSION_COOKIE, "", 0), "cache-control": "no-store" },
      });
    }
  }
  return new Response("not found", { status: 404 });
}

/// The viewer's profile and membership. Rechecked with the account center at
/// most hourly; a revoked refresh token ends the session here.
export async function handleMe(request: Request, env: Env, session: Session): Promise<Response> {
  let current = session;
  const headers = new Headers({ "content-type": "application/json; charset=utf-8", "cache-control": "private, no-store" });
  if (Date.now() - session.checkedAt >= RECHECK_MS) {
    try {
      const tokens = await tokenRequest(env, { grant_type: "refresh_token", refresh_token: session.refreshToken });
      current = {
        ...session,
        ...(await loadAccount(env, tokens.access_token)),
        refreshToken: tokens.refresh_token || session.refreshToken,
        checkedAt: Date.now(),
      };
      headers.append("set-cookie", await sessionCookie(env, current));
    } catch (error) {
      if (error instanceof AccountError && error.endsSession) {
        headers.append("set-cookie", cookie(SESSION_COOKIE, "", 0));
        return new Response(JSON.stringify({ error: "signed_out" }), { status: 401, headers });
      }
      // Network trouble: keep the cached profile, like the apps do.
    }
  }
  const body = {
    sub: current.sub,
    name: current.name ?? null,
    email: current.email ?? null,
    picture: current.picture ?? null,
    membership: { ...current.membership, active: isMember(current.membership) },
    checkedAt: current.checkedAt,
  };
  return new Response(JSON.stringify(body), { headers });
}
