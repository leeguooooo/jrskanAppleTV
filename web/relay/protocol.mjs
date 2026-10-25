// Wire format between the Worker and the egress relay (relay/relay.mjs). Shared
// by both sides; plain JS + WebCrypto so it runs in Workers and Node 22 alike.
//
// Message = iv(12) ‖ AES-256-GCM(key, frame), frame = u32 header length ‖ header
// JSON ‖ body bytes. The key is HKDF-SHA256(RELAY_SECRET). Requests carry a
// timestamp and nonce so a captured request cannot be replayed.

const encoder = new TextEncoder();
const keys = new Map();

export function relayKey(secret) {
  let key = keys.get(secret);
  if (!key) {
    key = crypto.subtle.importKey("raw", encoder.encode(secret), "HKDF", false, ["deriveKey"]).then((base) =>
      crypto.subtle.deriveKey(
        { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: encoder.encode("leeguoo-sports/relay/v1") },
        base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]));
    keys.set(secret, key);
  }
  return key;
}

/** @returns {Promise<Uint8Array>} */
export async function seal(secret, header, body = new Uint8Array(0)) {
  const head = encoder.encode(JSON.stringify(header));
  const frame = new Uint8Array(4 + head.length + body.length);
  new DataView(frame.buffer).setUint32(0, head.length);
  frame.set(head, 4);
  frame.set(body, 4 + head.length);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await relayKey(secret), frame));
  const out = new Uint8Array(12 + cipher.length);
  out.set(iv, 0);
  out.set(cipher, 12);
  return out;
}

/** @returns {Promise<{ header: any, body: Uint8Array }>} Throws on a bad key or tampering. */
export async function open(secret, message) {
  const bytes = message instanceof Uint8Array ? message : new Uint8Array(message);
  if (bytes.length < 12 + 16 + 4) throw new Error("short message");
  const frame = new Uint8Array(await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: bytes.subarray(0, 12) }, await relayKey(secret), bytes.subarray(12)));
  const length = new DataView(frame.buffer, frame.byteOffset).getUint32(0);
  if (4 + length > frame.length) throw new Error("bad frame");
  const header = JSON.parse(new TextDecoder().decode(frame.subarray(4, 4 + length)));
  return { header, body: frame.subarray(4 + length) };
}

/** Requests older or newer than this are rejected; nonces are remembered at least this long. */
export const MAX_SKEW_MS = 60_000;
