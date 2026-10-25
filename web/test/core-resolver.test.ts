// Port of the resolver cases in App/Tests/StreamResolverTests.swift. The
// MatchPlaybackModel cases of that file live in core-playback.test.ts.
import RELEASE_SYNC from "@jitl/quickjs-wasmfile-release-sync";
import { newQuickJSWASMModuleFromVariant } from "quickjs-emscripten-core";
import { describe, expect, it } from "vitest";
import { parseSourcePage } from "../src/core/listing";
import {
  StreamResolver, StreamResolverError, evaluateEncryptedHLSURL, extractM3U8URLs, iframeURLs,
  playerScriptResult, type ResolverIO,
} from "../src/core/resolver";

/** A fresh module per sandbox run, as the resolver contract requires. */
const quickJS = () => newQuickJSWASMModuleFromVariant(RELEASE_SYNC);

const extractM3U8URL = (html: string, pageURL: string) => extractM3U8URLs(html, pageURL)[0];

/** Mirrors ResolverFixtureProtocol: status, body and final (redirected) URL per path. */
function fixture(raw: string): { status: number; body: string; url: string } {
  const url = new URL(raw);
  let final = raw;
  let status = 200;
  let body: string;
  switch (url.pathname) {
    case "/siblings.html": body = `<iframe src="bad.html"></iframe><iframe src="good.html"></iframe>`; break;
    case "/script-failure.html": body = `<script>var encodedStr = 'x';</script><script src="pjs.js"></script><iframe src="good.html"></iframe>`; break;
    case "/cycle-parent.html": body = `<iframe src="cycle.html"></iframe><iframe src="good.html"></iframe>`; break;
    case "/cycle.html": body = `<iframe src="cycle.html"></iframe>`; break;
    case "/good.html": body = `<source src="live.m3u8">`; break;
    case "/multiple.html": body = `<source src="expired.m3u8"><source src="live.m3u8">`; break;
    case "/redirect.html":
      final = "https://fixture.example/landed/player.html";
      body = `<source src="live.m3u8"><a class="ok" href="channel.html"><strong>Channel</strong></a>`;
      break;
    case "/bad.html": case "/pjs.js": case "/expired.m3u8": status = 404; body = "Not found"; break;
    case "/fake.m3u8": body = "<html>Offline</html>"; break;
    case "/empty.m3u8": body = "#EXTM3U\n"; break;
    case "/live.m3u8": case "/landed/live.m3u8": case "/slow.m3u8": body = "#EXTM3U\n#EXTINF:5,\nsegment.ts\n"; break;
    default: status = 404; body = "Unknown fixture";
  }
  return { status, body, url: final };
}

/** Like the Worker's fetchText: non-2xx rejects. */
const fixtureIO: ResolverIO = {
  async fetchPage(url) {
    const r = fixture(url);
    if (r.status < 200 || r.status >= 300) throw new Error(`upstream ${r.status}`);
    return { text: r.body, url: r.url };
  },
  async fetchPlaylist(url) {
    const r = fixture(url);
    if (r.status < 200 || r.status >= 300) throw new Error(`upstream ${r.status}`);
    return { text: r.body, url: r.url };
  },
  quickJS,
};

describe("StreamResolverTests", () => {
  it("testExtractsDirectHLSURL", () => {
    const pageURL = "http://play.example/350.html";
    const html = `
<video>
  <source src="https://media.example/live/game.m3u8?token=abc&amp;expires=123">
</video>
`;
    expect(extractM3U8URL(html, pageURL)).toBe("https://media.example/live/game.m3u8?token=abc&expires=123");
  });

  it("testExtractsEscapedAndRelativeMediaURLs", () => {
    const page = "https://fixture.example/player/index.html";
    expect(extractM3U8URL(String.raw`var url = "https:\/\/media.example\/live.m3u8?token=a&expires=2";`, page))
      .toBe("https://media.example/live.m3u8?token=a&expires=2");
    expect(extractM3U8URL(`<source src="../media/live.m3u8?token=a&amp;expires=2">`, page))
      .toBe("https://fixture.example/media/live.m3u8?token=a&expires=2");
  });

  it("testHostAndIDPreserveAllNestedSignatureParameters", () => {
    const page = "https://fixture.example/player.html?id=/live.m3u8?expire=1&sign=a=b";
    expect(extractM3U8URL(`let purl = "https://media.example" + id;`, page))
      .toBe("https://media.example/live.m3u8?expire=1&sign=a=b");
  });

  it("testContinuesAfterBrokenSiblingScriptAndMediaCandidates", async () => {
    const resolver = new StreamResolver(fixtureIO);
    for (const path of ["siblings.html", "script-failure.html", "multiple.html", "cycle-parent.html"]) {
      const result = await resolver.resolve(`https://fixture.example/${path}`);
      expect(result, path).toBe("https://fixture.example/live.m3u8");
    }
  });

  // Swift's SourcePageClient.fetchChannels is the Worker's fetchChannels in TS,
  // which is parseSourcePage(page.text, page.url); the channel half uses that directly.
  it("testUsesFinalPageURLForRelativeMediaAndChannelLinks", async () => {
    const page = "https://fixture.example/redirect.html";
    const stream = await new StreamResolver(fixtureIO).resolve(page);
    expect(stream).toBe("https://fixture.example/landed/live.m3u8");
    const fetched = await fixtureIO.fetchPage(page, page);
    const channels = parseSourcePage(fetched.text, fetched.url);
    expect(channels[0]?.pageURL).toBe("https://fixture.example/landed/channel.html");
  });

  it("testRejectsHTTPErrorHTMLAndEmptyPlaylistsBeforePlayback", async () => {
    for (const path of ["expired.m3u8", "fake.m3u8", "empty.m3u8"]) {
      const error = await new StreamResolver(fixtureIO).resolve(`https://fixture.example/${path}`)
        .then(() => undefined, (e: unknown) => e);
      expect(error, `Accepted unusable stream: ${path}`).toBeInstanceOf(StreamResolverError);
      expect((error as StreamResolverError).code, path).toBe("unavailableStream");
    }
  });

  it("testBuildsHLSURLFromPlayerHostAndID", () => {
    const pageURL = "https://player.example/msss.html?id=/live/123.m3u8?auth_key=abc";
    const html = `var purl = "//hdl.example.com"+id;`;
    expect(extractM3U8URL(html, pageURL)).toBe("https://hdl.example.com/live/123.m3u8?auth_key=abc");
  });

  it("testResolvesProtocolRelativeAndRelativeIframes", () => {
    const pageURL = "http://play.example/play/sm.html?id=350&id2=";
    const html = `
<iframe src="//cloud.example/player.html"></iframe>
<iframe src="/play/350.html"></iframe>
<script>
element.innerHTML = "<iframe src='/play/"+id1+".html'></iframe>";
</script>
`;
    expect(iframeURLs(html, pageURL)).toEqual([
      "https://cloud.example/player.html",
      "http://play.example/play/350.html",
    ]);
  });

  it("testDoesNotTreatPlayerWrapperQueryAsHLSMedia", () => {
    const pageURL = "http://play.example/350.html";
    const html = `
<iframe src="//cloud.example/msss.html?id=/live/123.m3u8?token=abc"></iframe>
`;
    expect(extractM3U8URL(html, pageURL)).toBeUndefined();
  });

  const reversedHostPlayer = `
function restoreStreamUrl(value) {
  const domainParts = value.split(".");
  domainParts[domainParts.length - 2] = domainParts[domainParts.length - 2]
    .split("").reverse().join("");
}
const id = J_get("id");
const purl = restoreStreamUrl(id);
`;

  it("testRestoresPlayerHostAndPreservesCompleteSignedQuery", () => {
    const pageURL = "https://player.example/msss.html?id=//cdn.elpmaxe.com:8443/live/game.m3u8?auth_key=a=b&token=xyz&device=4";
    expect(extractM3U8URL(reversedHostPlayer, pageURL))
      .toBe("https://cdn.example.com:8443/live/game.m3u8?auth_key=a=b&token=xyz&device=4");
  });

  it("testRestoresPercentEncodedPlayerID", () => {
    const pageURL = "https://player.example/msss.html?id=https%3A%2F%2Fcdn.elpmaxe.com%2Flive%2Fgame.m3u8%3Ftoken%3Da%252Bb%26expires%3D123";
    expect(extractM3U8URL(reversedHostPlayer, pageURL))
      .toBe("https://cdn.example.com/live/game.m3u8?token=a%2Bb&expires=123");
  });

  it("testDoesNotRestoreHostWithoutPlayerTransformation", () => {
    const pageURL = "https://player.example/msss.html?id=//cdn.elpmaxe.com/live/game.m3u8";
    expect(extractM3U8URL("const purl = id;", pageURL)).toBeUndefined();
  });

  // Swift's generatedIframeURL(in:playerScript:pageURL:) is playerScriptResult(...).url in TS.
  it("testExtractsIframeGeneratedByEncryptedPlayerScript", async () => {
    const pageURL = "http://play.example/play/kbs/?id=5";
    const html = `var encodedStr = "encrypted-payload";`;
    const playerScript = `
document.getElementById("myElement").innerHTML =
  "<iframe src='https://cloud.example/player/paps.html?id=" + encodedStr + "'></iframe>";
`;
    expect(playerScriptResult(await quickJS(), html, playerScript, pageURL).url)
      .toBe("https://cloud.example/player/paps.html?id=encrypted-payload");
  });

  it("testCreatesConfiguredIframeWithDOMPlayerAndPreservesBase64Payload", async () => {
    const html = `
window.playerConfig = {playerUrlBase64: "aHR0cHM6Ly9wbGF5ZXIuZXhhbXBsZS9wYXBzLmh0bWw/aWQ9"};
var encodedStr = "a+b/c==";
`;
    const script = `
var base = new URL(atob(window.playerConfig.playerUrlBase64));
var frame = document.createElement('iframe');
frame.src = atob(window.playerConfig.playerUrlBase64) + encodedStr;
frame.setAttribute('allow', 'autoplay; fullscreen');
document.getElementById('myElement').appendChild(frame);
`;
    expect(playerScriptResult(await quickJS(), html, script, "https://fixture.example/kbs/").url)
      .toBe("https://player.example/paps.html?id=a+b/c==");
  });

  it("testDataPlayerFetchIsStagedAndCanReplaceContainerChildren", async () => {
    const html = `var playerData = {"en_str":"payload"};`;
    const script = `
async function load() {
    var response = await fetch('https://infozb6.video.qq.com/cgi-bin/getliveinfo?id=' + playerData.en_str);
    var data = await response.json();
    var frame = document.createElement('iframe');
    frame.src = 'https://player.example/paps.html?id=' + encodeURIComponent(data.payload);
    document.getElementById('showcontent').replaceChildren(frame);
}
load();
`;
    const page = "https://fixture.example/vxt/";
    const first = playerScriptResult(await quickJS(), html, script, page);
    expect(first.url).toBeUndefined();
    expect(first.requests[0] && new URL(first.requests[0]).host).toBe("infozb6.video.qq.com");
    const second = playerScriptResult(await quickJS(), html, script, page, [`{"payload":"a+b/c=="}`]);
    expect(second.url).toBe("https://player.example/paps.html?id=a%2Bb%2Fc%3D%3D");
  });

  it("testEvaluatesEncryptedPlayerPageToHLSURL", async () => {
    const pageURL = "https://cloud.example/player/paps.html?id=payload";
    const libraryScript = "var CryptoLibraryLoaded = true;";
    const pageScript = `
var encryptedBase64Str = "payload";
function decryptUrlWithExpiry(value) {
  return CryptoLibraryLoaded && value === "payload"
    ? "https://media.example/live/chinese-hd.m3u8?token=abc"
    : "";
}
`;
    expect(evaluateEncryptedHLSURL(await quickJS(), libraryScript, pageScript, pageURL))
      .toBe("https://media.example/live/chinese-hd.m3u8?token=abc");
  });
});
