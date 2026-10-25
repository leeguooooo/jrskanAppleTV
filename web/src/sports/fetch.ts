// Every sports request goes through the same-origin Worker proxy
// (worker/sports.ts), which holds the host allowlist and provider headers.

export class SportsFetchError extends Error {
  constructor(readonly status: number) {
    super(`sports proxy ${status}`);
  }
}

export async function sportsFetch(url: string): Promise<string> {
  const response = await fetch(`/api/sports?url=${encodeURIComponent(url)}`, {
    method: "GET",
    credentials: "same-origin",
    cache: "no-store",
  });
  if (!response.ok) throw new SportsFetchError(response.status);
  return response.text();
}
