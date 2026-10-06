package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.JrsException
import com.leeguoo.jrkan.data.JrsListingParser
import com.leeguoo.jrkan.data.SourcePageParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Port of App/Tests/JRSListingParserTests.swift. */
class ListingParserTest {
    @Test
    fun parsesMatchAndPlayableSources() {
        val script = """
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
        """.trimIndent()

        val matches = JrsListingParser().parse(script, "https://www.jrs03.com/")

        assertEquals(1, matches.size)
        assertEquals("WNBA", matches[0].league)
        assertEquals("王牌", matches[0].homeTeam)
        assertEquals("自由人", matches[0].awayTeam)
        assertEquals("07-31 10:00", matches[0].time)
        assertEquals("https://img.example/home.png", matches[0].homeLogoUrl)
        assertTrue(matches[0].isHot)
        assertEquals(1, matches[0].sources.size)
        assertEquals("直播①", matches[0].sources[0].name)
        assertEquals("http://backup.example/1.html", matches[0].sources[0].pageUrl)
    }

    @Test
    fun preservesEverySelectableCommentarySource() {
        val script = """
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
        """.trimIndent()

        val matches = JrsListingParser().parse(script, "https://www.jrs03.com/")

        assertEquals(1, matches.size)
        assertEquals(
            listOf("主播解说①", "主播解说②", "主播解说③", "主播解说④", "中文高清 Q ⑤", "高清直播⑥"),
            matches[0].sources.map { it.name },
        )
    }

    @Test
    fun parsesSecondLevelCommentaryChannelsFromSourcePage() {
        val html = """
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
        """.trimIndent()

        val channels = SourcePageParser().parse(html, "http://play.example/play/game.html")

        assertEquals(
            listOf("主播解说①", "主播解说②", "主播解说③", "主播解说④", "中文高清 Q ⑤", "高清直播⑥"),
            channels.map { it.name },
        )
        assertEquals("http://play.example/play/kbs/?id=11022600215&id2=", channels[4].pageUrl)
    }

    @Test
    fun buildsSourceUrlsFromGetPlayUrlAnchors() {
        val homepage = """
        <script>
        window.PLAY_HOSTS = {
            line1: atob("aHR0cDovL3BsYXkuc3BvcnRzdGVhbTM2OC5jb20="),
            line2: atob("aHR0cDovL3BsYXkuamdkaGRzLmNvbQ==")
        };
        function getPlayUrl(line, id) { return window.PLAY_HOSTS[line] + "/play/steam" + id + ".html"; }
        </script>
        """.trimIndent()
        val hosts = JrsListingParser.playHosts(homepage)
        assertEquals(mapOf("line1" to "http://play.sportsteam368.com", "line2" to "http://play.jgdhds.com"), hosts)

        val script = """
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
        """.trimIndent()

        val matches = JrsListingParser().parse(script, "https://www.jrs03.com/", hosts)

        assertEquals(1, matches.size)
        assertEquals(listOf("直播①", "直播②"), matches[0].sources.map { it.name })
        assertEquals(
            listOf(
                "http://play.sportsteam368.com/play/steam821720.html",
                "http://play.jgdhds.com/play/steam821720.html",
            ),
            matches[0].sources.map { it.pageUrl },
        )
    }

    @Test
    fun skipsPlaceholderChannelAnchorsOnSourcePage() {
        val html = """
        <div class="sub_channel">
        <a class="item play ok me" target="myplayer" data-group="云直播①" data-play="/play/sm.html?id=432&id2=" href=""><strong>云直播①</strong></a>
        <a class="item ok me" target="myplayer" data-group="云直播④" data-play="/play/pao/?id=46364301&id2=" href=""><strong>云直播④</strong></a>
        <a class="item ok me" target="myplayer" data-group="云直播④" data-play="=&id2=" href=""><strong>备用</strong></a>
        <a class="item ok me" target="myplayer" data-group="云直播④" data-play="=&id2=" href=""><strong>备用</strong></a>
        </div>
        """.trimIndent()
        val channels = SourcePageParser().parse(html, "http://play.sportsteam368.com/play/steam821720.html")
        assertEquals(listOf("云直播①", "云直播④"), channels.map { it.name })
        assertEquals(
            listOf(
                "http://play.sportsteam368.com/play/sm.html?id=432&id2=",
                "http://play.sportsteam368.com/play/pao/?id=46364301&id2=",
            ),
            channels.map { it.pageUrl },
        )
    }

    // Kotlin-only checks for the regex translation.

    @Test
    fun emptyListingThrowsTheListingError() {
        try {
            JrsListingParser().parse("document.write('<p>nothing</p>');", "https://www.jrs03.com/")
            fail("expected NoMatches")
        } catch (e: JrsException) {
            assertEquals(JrsException.Kind.NoMatches, e.kind)
            assertEquals("公开页面当前没有可识别的比赛，或者页面格式已经变化。", e.message)
        }
    }

    @Test
    fun decodesEscapedQuotesAndSurvivesVeryLongWrites() {
        // A 200k-character write overflowed the JDK engine with the original
        // alternation loop; escaped quotes and slashes must still decode.
        val padding = "x".repeat(200_000)
        val script = """
        document.write('<ul class="item play" data-lid="1,1,1"><!-- $padding -->');
        document.write('<li class="lab_events"><span class="name">It\'s League</span></li>');
        document.write('<li class="lab_time">09-05 20:30</li>');
        document.write('<li class="lab_team_home"><strong class="name">A</strong><img src="https:\/\/img.example\/a.png"></li>');
        document.write('<li class="lab_team_away"><strong class="name">B</strong><img src="https://img.example/b.png"></li>');
        document.write('<a class="item ok" href="//play.example/x.html"><strong></strong></a>');
        document.write('</ul>');
        """.trimIndent()
        val match = JrsListingParser().parse(script, "https://www.jrs03.com/").single()
        assertEquals("It's League", match.league)
        assertEquals("https://img.example/a.png", match.homeLogoUrl)
        assertEquals("https://play.example/x.html", match.sources.single().pageUrl)
        assertEquals("线路 1", match.sources.single().name)
    }
}
