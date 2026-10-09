#!/usr/bin/env node
// Read or replace the JRKAN remote config in KV.
//
//   node worker/config.mjs get              print what is stored (normalized)
//   node worker/config.mjs put file.json    validate, then write it
//   node worker/config.mjs check file.json  validate only
//
// Writes go through wrangler-accounts (profile leeguooooo), so no admin
// token exists anywhere. The dashboard's KV editor works too: whatever is
// stored is normalized on read, and bad values fall back to defaults.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { normalize } from "./config.js";

const here = dirname(fileURLToPath(import.meta.url));
const [command, file] = process.argv.slice(2);
const wrangler = (...args) =>
  execFileSync("wrangler-accounts", ["exec", "leeguooooo", "--", "wrangler", ...args], {
    cwd: here,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  });

function load(path) {
  const { config, problems } = normalize(JSON.parse(readFileSync(path, "utf8")));
  if (problems.length) {
    console.error(`problems:\n  ${problems.join("\n  ")}`);
    process.exit(1);
  }
  return config;
}

switch (command) {
  case "get": {
    const raw = wrangler("kv", "key", "get", "jrkan", "--binding", "CONFIG", "--remote");
    console.log(JSON.stringify(normalize(JSON.parse(raw)).config, null, 2));
    break;
  }
  case "check":
    console.log(JSON.stringify(load(file), null, 2));
    break;
  case "put": {
    const config = load(file);
    wrangler("kv", "key", "put", "jrkan", JSON.stringify(config), "--binding", "CONFIG", "--remote");
    console.log("stored; live within about two minutes");
    break;
  }
  default:
    console.error("usage: config.mjs get | check <file> | put <file>");
    process.exit(2);
}
