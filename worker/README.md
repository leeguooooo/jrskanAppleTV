# leeguoo-app-config

Remote config for the JRKAN apps: the player watermark and ad slots. Served at
`https://config.leeguoo.com/v1/jrkan.json` from KV key `jrkan` (namespace `leeguoo-app-config`, account
`leeguooooo`). The apps fetch it at launch and on return to the foreground, at most every 10 minutes, and keep
the last good copy, so a broken edit or an outage never takes the watermark away.

## Changing it

Edit `jrkan.json`, then:

```bash
node worker/config.mjs check worker/jrkan.json   # validate only
node worker/config.mjs put worker/jrkan.json     # validate and store
node worker/config.mjs get                       # what is live
```

Or edit the KV value directly in the Cloudflare dashboard (Workers & Pages → KV → leeguoo-app-config → `jrkan`).
Whatever is stored is normalized on read, so a typo falls back to defaults instead of breaking the apps.
Changes are live within about two minutes (60 s edge cache, 30 s isolate cache and KV propagation), and the apps
pick them up on their next fetch.

## Fields

| field | meaning |
|---|---|
| `watermark.enabled` | show the watermark at all |
| `watermark.texts` | 1–10 strings of up to 40 characters, shown in turn, one per hop; a second entry makes it a rotating ad |
| `watermark.motion` | `drift` (keeps gliding to a new random spot, the default) · `hop` (fade out, reappear elsewhere) · `fixed` (bottom-right) |
| `watermark.interval` | seconds between hops, or the length of one drift leg (5–600) |
| `watermark.opacity` | 0.1–1 |
| `watermark.hideForMembers` | members don't see it |
| `slots.home_banner` | card at the top of the match list on iPhone / iPad / Mac / Android: `enabled`, `title` (≤40), `detail` (≤80), `url` (https only, opens in the browser), `hideForMembers` |

| `slots.recording_banner` | strip burned into the bottom-left of every exported recording (the MP4 people share): `enabled`, `title`, `detail`, `hideForMembers`; `url` is not clickable in a video |

The watermark is burned into exported recordings too, moving the same way it does in the player.

| `replay.enabled` | 回看 on/off (list button and the 回放 section on finished matches) |
| `replay.uploaders` | Weibo uids (numeric strings, up to 10) whose video feeds make up the 回看 list |
| `replay.searchSuffix` | appended to "主队vs客队" for a match's own Weibo search (default `" 回放"`) |
| `replay.minDuration` | seconds; shorter videos are highlights and are skipped (60–3600, default 600) |
| `replay.fullDuration` | seconds; an untitled video this long counts as the whole game (1800–14400, default 5400) |
| `replay.windowHours` | how long after kickoff an undated upload still belongs to the match (6–240, default 48) |

The apps carry the same replay defaults, so a Worker that predates the `replay` block (and drops it) changes nothing.

A new slot id can be added to `slots` without a Worker deploy; it shows up once a client draws it. tvOS only
shows the watermark (no banner).

## Deploy

```bash
cd worker && wrangler-accounts exec leeguooooo -- wrangler deploy
node --test worker/config.test.mjs
```
