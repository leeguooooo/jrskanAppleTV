// The sandboxed player frame (public/player.html) loads hls.js as a classic
// script from /vendor, so copy the pinned dependency's UMD build there.
import { copyFileSync, mkdirSync } from "node:fs";

const target = new URL("../public/vendor/", import.meta.url);
mkdirSync(target, { recursive: true });
copyFileSync(new URL("../node_modules/hls.js/dist/hls.min.js", import.meta.url), new URL("hls.min.js", target));
