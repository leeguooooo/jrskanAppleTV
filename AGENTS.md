# leeguoo sports (formerly JRKAN) cross-platform work

The product is called **leeguoo sports**. JRKAN survives only in identifiers (bundle id `com.leeguoo.jrskan.tv`, Android package `com.leeguoo.jrkan`, Xcode targets/schemes, `JRKAN_*` CI variables, KV key `jrkan`, account tenant/client ids, recording folders); never rename those as part of branding.

- The supported family is iPhone/iPad, Apple TV, Mac Catalyst and Android. A business or provider-contract fix must check both `App/Sources/Shared` and `android/app/src/main/java/com/leeguoo/jrkan/{data,state}`. State explicitly when a platform-specific feature differs.
- Use `contracts/tencent-sports.json` and `contracts/multi-sports.json` for shared channel-priority, provider-entry, statistics and comment samples. Both `App/Tests/TencentSportsTests.swift` and Android `TencentSportsTest` must consume it. Add a provider's new entry to both implementations and this fixture.
- Match ID, both teams and kickoff must agree before attaching third-party data. Missing data is not zero. Comments/statistics run independently of video, never change channel performance, and stop polling when the screen is no longer resumed.
- Main match selection plays automatically. Keep Q, M, other Chinese, other HD, other entrances, then host commentary tiers; history may only reorder peers. Manual channel selection starts collapsed.
- Check Android and Apple UI parity for player controls, comments, match overview, player tables, error states and return-from-player behavior. Keep screenshots as private QA evidence when video embeds third-party promotion.
- Code, tests, signed package, distribution availability and physical-device acceptance are separate. Verify each applicable stage; do not call a source/CI pass device acceptance.
- Android is internal testing only. Preserve the existing release signing key. Attach APK and SHA-256 to a **draft** GitHub Release; do not publish publicly unless explicitly requested. A missing production key must fail formal release builds.

- Sports content priority is Tencent, Migu, then ESPN (statistics only). Recheck preferred sources every poll. Fill missing whole tables, label their sources, preserve scoreboard provenance and team orientation, and never synthesize ratings or replay old comments to fill an empty stream.

- Compare explicit CBA sponsor aliases through the same canonical team map for Tencent and Migu on both platforms. Extend `contracts/multi-sports.json` when names change; never strip arbitrary city prefixes or merge Beijing/Beikong and Zhejiang/Guangsha.

- Migu web comments bind `contentId/objectId` to the match; app comments use `contentId=100`, `commentType=5`, `contentType=40` and bind both `mId/objectId` to it. Test both shapes and reject conflicting IDs; never accept the shared contentId alone.
