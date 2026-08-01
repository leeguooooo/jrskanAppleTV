import XCTest
@testable import JRKANTV

final class JRSListingParserTests: XCTestCase {
    func testParsesMatchAndPlayableSources() throws {
        let script = #"""
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
        """#

        let matches = try JRSListingParser().parse(
            script: script,
            relativeTo: URL(string: "https://www.jrs03.com/")!
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].league, "WNBA")
        XCTAssertEqual(matches[0].homeTeam, "王牌")
        XCTAssertEqual(matches[0].awayTeam, "自由人")
        XCTAssertEqual(matches[0].time, "07-31 10:00")
        XCTAssertTrue(matches[0].isHot)
        XCTAssertEqual(matches[0].sources.count, 1)
        XCTAssertEqual(matches[0].sources[0].name, "直播①")
        XCTAssertEqual(
            matches[0].sources[0].pageURL.absoluteString,
            "http://backup.example/1.html"
        )
    }

    func testPreservesEverySelectableCommentarySource() throws {
        let script = #"""
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
        """#

        let matches = try JRSListingParser().parse(
            script: script,
            relativeTo: URL(string: "https://www.jrs03.com/")!
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(
            matches[0].sources.map(\.name),
            ["主播解说①", "主播解说②", "主播解说③", "主播解说④", "中文高清 Q ⑤", "高清直播⑥"]
        )
        XCTAssertEqual(matches[0].sources.count, 6)
    }
}
