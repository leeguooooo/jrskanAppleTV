import { useEffect, useState } from "preact/hooks";

/** Minimal observable: models call `changed()`, components re-render via `useStore`. */
export class Observable {
  private listeners = new Set<() => void>();

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  protected changed() {
    for (const listener of [...this.listeners]) listener();
  }
}

export function useStore<T extends Observable>(store: T): T {
  const [, setVersion] = useState(0);
  useEffect(() => store.subscribe(() => setVersion((v) => v + 1)), [store]);
  return store;
}

/** localStorage that survives private mode, blocked storage and quota errors. */
export const storage = {
  get<T>(key: string, fallback: T): T {
    try {
      const raw = localStorage.getItem(key);
      return raw === null ? fallback : (JSON.parse(raw) as T);
    } catch {
      return fallback;
    }
  },
  set(key: string, value: unknown) {
    try {
      localStorage.setItem(key, JSON.stringify(value));
    } catch {
      // Storage unavailable: the value lives for this page only.
    }
  },
};
