export function relayKey(secret: string): Promise<CryptoKey>;
export function seal(secret: string, header: unknown, body?: Uint8Array): Promise<Uint8Array<ArrayBuffer>>;
export function open(secret: string, message: Uint8Array | ArrayBuffer): Promise<{ header: unknown; body: Uint8Array }>;
export const MAX_SKEW_MS: number;
