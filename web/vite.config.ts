import { defineConfig } from "vite";
import preact from "@preact/preset-vite";

export default defineConfig({
  plugins: [preact()],
  build: { outDir: "dist", sourcemap: false },
  server: {
    // `npm run dev` serves the UI; run `wrangler dev` on 8787 for /api and /auth.
    proxy: { "/api": "http://localhost:8787", "/auth": "http://localhost:8787" },
  },
});
