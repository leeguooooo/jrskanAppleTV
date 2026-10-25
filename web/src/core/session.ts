import { api, ApiError, setSignedOutHandler, type Me } from "./api";
import { appConfig } from "./config";
import { Observable } from "./store";

export const ACCOUNT_CENTER = "https://account.leeguoo.com";
export const MANAGE_URL = `${ACCOUNT_CENTER}/account`;
/// Hosted purchase page: signs in if needed, then hands off to 爱发电.
export const MEMBERSHIP_URL = `${ACCOUNT_CENTER}/membership/jrkan`;

export class SessionStore extends Observable {
  state: "loading" | "signedIn" | "signedOut" | "error" = "loading";
  me?: Me;
  error?: string;

  constructor() {
    super();
    setSignedOutHandler(() => this.signedOut());
  }

  private signedOut() {
    if (this.state === "signedOut") return;
    this.state = "signedOut";
    this.me = undefined;
    appConfig.setMember(false);
    this.changed();
  }

  async load() {
    try {
      this.me = await api.me();
      this.state = "signedIn";
      appConfig.setMember(this.me.membership.active);
    } catch (error) {
      if (error instanceof ApiError && error.status === 401) return this.signedOut();
      // Offline or the Worker failing: keep a signed-in view if we had one.
      if (this.state !== "signedIn") {
        this.state = "error";
        this.error = error instanceof Error ? error.message : String(error);
      }
    }
    this.changed();
  }

  signIn() {
    const next = location.pathname + location.search;
    location.href = `/auth/login?next=${encodeURIComponent(next)}`;
  }

  async signOut() {
    await api.logout();
    this.signedOut();
  }
}

export const session = new SessionStore();
