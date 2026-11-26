import assert from "node:assert/strict";
import { test } from "node:test";
import { DEFAULT_CONFIG, normalize } from "./config.js";

test("empty input gives the defaults", () => {
  assert.deepEqual(normalize({}).config, DEFAULT_CONFIG);
});

test("replay block: defaults, clamps and bad uploaders", () => {
  assert.deepEqual(normalize({}).config.replay, DEFAULT_CONFIG.replay);
  const { config, problems } = normalize({ replay: { enabled: false, uploaders: ["abc"], minDuration: 1, windowHours: 1000 } });
  assert.equal(config.replay.enabled, false);
  assert.deepEqual(config.replay.uploaders, DEFAULT_CONFIG.replay.uploaders);
  assert.equal(config.replay.minDuration, 60);
  assert.equal(config.replay.windowHours, 240);
  assert.equal(problems.length, 1);
  assert.deepEqual(normalize({ replay: { uploaders: [123, "456"] } }).config.replay.uploaders, ["123", "456"]);
});

test("clamps, trims and drops bad values with a problem each", () => {
  const { config, problems } = normalize({
    watermark: { texts: ["  leeguoo.com ", "", 3, "x".repeat(60)], motion: "spin", interval: 1, opacity: 4 },
    slots: {
      home_banner: { enabled: true, title: "世界杯", url: "http://plain.example" },
      pause_card: { enabled: true, title: "暂停广告", url: "https://ad.example/a" },
      "Bad-Id": { enabled: true },
    },
  });
  assert.deepEqual(config.watermark.texts, ["leeguoo.com", "x".repeat(40)]);
  assert.equal(config.watermark.motion, "drift");
  assert.equal(config.watermark.interval, 5);
  assert.equal(config.watermark.opacity, 1);
  assert.equal(config.slots.home_banner.url, "");
  assert.equal(config.slots.home_banner.title, "世界杯");
  assert.deepEqual(config.slots.pause_card, {
    enabled: true, title: "暂停广告", detail: "", url: "https://ad.example/a", hideForMembers: true,
  });
  assert.equal(config.slots["Bad-Id"], undefined);
  assert.equal(problems.length, 3);
});
