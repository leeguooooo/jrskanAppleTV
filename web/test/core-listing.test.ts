// Port of App/Tests/JRSListingParserTests.swift. Fixtures are kept verbatim.
import { describe, expect, it } from "vitest";
import { parseListing, parseSourcePage, playHosts } from "../src/core/listing";

describe("JRSListingParserTests", () => {
  it("testParsesMatchAndPlayableSources", () => {
    const script = String.raw`
document.write('<ul class="item play d-touch active hot" data-lid="3909068,2,3909068" data-stype="zqlq">');
document.write('<li class="lab_events"><span class="name">WNBA</span></li>');
document.write('<li class="lab_time">07-31 10:00</li>');
document.write('<li class="lab_team_home"><strong class="name">王牌</strong><span class="avatar"><img src="https://img.example/home.png"></span></li>');
document.write('<li class="lab_team_away"><strong class="name">自由人</strong><span class="avatar"><img src="https://img.example/away.png"></span></li>');
document.write('<li class="lab_channel">');
document.write('<a class="item ok_kqt" href="javascript:void(0)"><strong>广告</strong></a>');
document.write('<a class="item ok type1 me" data-play="http://play.example/play/1.html" href="http://backup.example/1.html"><strong>直播①</strong></a>');
document.write('</li>');
document.write('</ul>');
`;
    const matches = parseListing(script, "https://www.jrs03.com/");
    expect(matches.length).toBe(1);
    expect(matches[0].league).toBe("WNBA");
    expect(matches[0].homeTeam).toBe("王牌");
    expect(matches[0].awayTeam).toBe("自由人");
    expect(matches[0].time).toBe("07-31 10:00");
    expect(matches[0].isHot).toBe(true);
    expect(matches[0].sources.length).toBe(1);
    expect(matches[0].sources[0].name).toBe("直播①");
    expect(matches[0].sources[0].pageURL).toBe("http://backup.example/1.html");
  });

  it("testPreservesEverySelectableCommentarySource", () => {
    const script = String.raw`
document.write('<ul class="item play active" data-lid="wnba-0801">');
document.write('<li class="lab_events"><span class="name">WNBA</span></li>');
document.write('<li class="lab_time">08-01 10:00</li>');
document.write('<li class="lab_team_home"><strong class="name">火焰</strong><img src="https://img.example/fire.png"></li>');
document.write('<li class="lab_team_away"><strong class="name">狂热</strong><img src="https://img.example/fever.png"></li>');
document.write('<li class="lab_channel">');
document.write('<a class="item ok type1" href="https://play.example/1.html"><strong>主播解说①</strong></a>');
document.write('<a class="item ok type1" href="https://play.example/2.html"><strong>主播解说②</strong></a>');
document.write('<a class="item ok type1" href="https://play.example/3.html"><strong>主播解说③</strong></a>');
document.write('<a class="item ok type1" href="https://play.example/4.html"><strong>主播解说④</strong></a>');
document.write('<a class="item ok type1" href="https://play.example/5.html"><strong>中文高清 Q ⑤</strong></a>');
document.write('<a class="item ok type1" href="https://play.example/6.html"><strong>高清直播⑥</strong></a>');
document.write('</li>');
document.write('</ul>');
`;
    const matches = parseListing(script, "https://www.jrs03.com/");
    expect(matches.length).toBe(1);
    expect(matches[0].sources.map((s) => s.name)).toEqual(
      ["主播解说①", "主播解说②", "主播解说③", "主播解说④", "中文高清 Q ⑤", "高清直播⑥"],
    );
    expect(matches[0].sources.length).toBe(6);
  });

  it("testParsesSecondLevelCommentaryChannelsFromSourcePage", () => {
    const html = String.raw`
<iframe class="sub_player" src="/play/sm.html?id=330&id2="></iframe>
<div class="sub_channel" data-lid="3909034,2,3909034">
  <a class="item play ok me" data-play="/play/sm.html?id=330&id2=" href=""><strong>主播解说①</strong></a>
  <a class="item ok me" data-play="/play/sm.html?id=157&id2=" href=""><strong>主播解说②</strong></a>
  <a class="item ok me" data-play="/play/sm.html?id=439&id2=" href=""><strong>主播解说③</strong></a>
  <a class="item ok me" data-play="/play/sm.html?id=329&id2=" href=""><strong>主播解说④</strong></a>
  <a class="item ok me" data-play="/play/kbs/?id=11022600215&amp;id2=" href=""><strong>中文高清 Q ⑤</strong></a>
  <a class="item ok me" data-play="/play/pao/?id=39090342&amp;id2=" href=""><strong>高清直播⑥</strong></a>
  <!-- <a class="item ok me" data-play="=&amp;id2=" href=""><strong>⑦</strong></a> -->
</div>
`;
    const channels = parseSourcePage(html, "http://play.example/play/game.html");
    expect(channels.map((c) => c.name)).toEqual(
      ["主播解说①", "主播解说②", "主播解说③", "主播解说④", "中文高清 Q ⑤", "高清直播⑥"],
    );
    expect(channels.length).toBe(6);
    expect(channels[4].pageURL).toBe("http://play.example/play/kbs/?id=11022600215&id2=");
  });

  it("testBuildsSourceURLsFromGetPlayUrlAnchors", () => {
    const homepage = String.raw`
<script>
window.PLAY_HOSTS = {
    line1: atob("aHR0cDovL3BsYXkuc3BvcnRzdGVhbTM2OC5jb20="),
    line2: atob("aHR0cDovL3BsYXkuamdkaGRzLmNvbQ==")
};
function getPlayUrl(line, id) { return window.PLAY_HOSTS[line] + "/play/steam" + id + ".html"; }
</script>
`;
    const hosts = playHosts(homepage);
    expect(hosts).toEqual({ line1: "http://play.sportsteam368.com", line2: "http://play.jgdhds.com" });

    const script = String.raw`
document.write('<ul class="item play d-touch active" data-lid="821720">');
document.write('<li class="lab_events"><span class="name">英超</span></li>');
document.write('<li class="lab_time">09-05 20:30</li>');
document.write('<li class="lab_team_home"><strong class="name">纽卡斯尔联</strong><img src="https://img.example/h.png"></li>');
document.write('<li class="lab_team_away"><strong class="name">伯恩茅斯</strong><img src="https://img.example/a.png"></li>');
document.write('<li class="lab_channel">');
document.write('<a class="item ok_kqt type1" data-group="直播①" href="javascript:void(0)" onclick="openRandomUrl1()"><strong>直播①</strong></a>');
document.write('<a class="item ok type1 me" target="_blank" data-group="直播①" href="' + getPlayUrl("line1", "821720") + '" data-play=""><em class="icon-play-circle"></em><strong>直播①</strong></a>');
document.write('<a class="item ok type1 me" target="_blank" data-group="直播①" href="' + getPlayUrl("line2", "821720") + '" data-play=""><em class="icon-play-circle"></em><strong>直播②</strong></a>');
document.write('<a class="item ok type1 me" target="_blank" data-group="直播①" href="' + getPlayUrl("line3", "821720") + '" data-play=".html"><em class="icon-play-circle"></em><strong>直播③</strong></a>');
document.write('</li>');
document.write('</ul>');
`;
    const matches = parseListing(script, "https://www.jrs03.com/", hosts);
    expect(matches.length).toBe(1);
    expect(matches[0].sources.map((s) => s.name)).toEqual(["直播①", "直播②"]);
    expect(matches[0].sources.map((s) => s.pageURL)).toEqual([
      "http://play.sportsteam368.com/play/steam821720.html",
      "http://play.jgdhds.com/play/steam821720.html",
    ]);
  });

  it("testSkipsPlaceholderChannelAnchorsOnSourcePage", () => {
    const html = String.raw`
<div class="sub_channel">
<a class="item play ok me" target="myplayer" data-group="云直播①" data-play="/play/sm.html?id=432&id2=" href=""><strong>云直播①</strong></a>
<a class="item ok me" target="myplayer" data-group="云直播④" data-play="/play/pao/?id=46364301&id2=" href=""><strong>云直播④</strong></a>
<a class="item ok me" target="myplayer" data-group="云直播④" data-play="=&id2=" href=""><strong>备用</strong></a>
<a class="item ok me" target="myplayer" data-group="云直播④" data-play="=&id2=" href=""><strong>备用</strong></a>
</div>
`;
    const channels = parseSourcePage(html, "http://play.sportsteam368.com/play/steam821720.html");
    expect(channels.map((c) => c.name)).toEqual(["云直播①", "云直播④"]);
    expect(channels.map((c) => c.pageURL)).toEqual([
      "http://play.sportsteam368.com/play/sm.html?id=432&id2=",
      "http://play.sportsteam368.com/play/pao/?id=46364301&id2=",
    ]);
  });
});
