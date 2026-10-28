# 平台对齐记录

更新：2026-10-28。Android 目标为手机版；视觉参考 iPhone 端，保留 Android 原生导航、权限、画中画与文件分享方式。网页版（`web/`，sports.leeguoo.com）窄屏参考 iPhone、宽屏参考 iPad/Mac 的列表 + 详情布局。

| 范围 | Android / Apple 共同规则 |
| --- | --- |
| 比赛入口 | 直接播放；手动选线默认收起，关闭播放器后不自动重开 |
| 线路策略 | 中文 Q、中文 M、其他中文、其他高清、其他入口、主播；历史仅对同类排序 |
| 播放恢复 | 校验 HLS、首帧/进度监测、有限重连、轮换未失败线路，不循环重试已失败线路 |
| 腾讯匹配 | 支持 kbs、vxt、txf；比赛 ID、两队名称和开赛时间核对一致后才加载 NBA/CBA 数据 |
| 多源补位 | 腾讯优先；缺少的整张统计表依次由咪咕、ESPN 补齐，标明每张表的来源；不混合单元格、不覆盖腾讯比分；每轮重新检查优先源 |
| 第三方匹配 | CBA 先按明确的简称/冠名映射比较球队（如上海/上海久事、福建/福建晋江文旅），保留北京/北控、浙江/广厦的区别；腾讯、咪咕共用映射。咪咕按 NBA/CBA 公开赛程的比赛 ID、联赛、双方球队、开赛时间唯一匹配；ESPN 按 NBA 球队别名和时区换算后的赛程匹配，摘要再次核对 ID/球队/时间 |
| 评论弹幕 | 腾讯有未显示的新评论时优先腾讯，否则尝试咪咕最新评论；ESPN 仅提供统计。只读，独立开关；10 秒轮询，ID 去重，120 秒过期，三轨、每 2.5 秒一条，队列最多 20 条 |
| 比赛数据 | 概况/技术统计两页，分节得分、双边球队比较、两队球员表，姓名列固定；缺值显示 —，零仍为零 |
| 数据刷新 | 打开统计面板立即获取，可手动刷新；请求中禁用刷新按钮并保留已有数据，正常请求下每 10 秒自动获取一次，慢请求不堆积；底部时间标记为获取时间 |
| 生命周期 | 后台、画中画不轮询评论；评论/统计超时不改播放状态、线路评分或录像任务 |
| 其他能力 | 保留赛程、比分、搜索、收藏/历史、账号、远程配置、水印、后台录像及导出 |

## 网页版

网页版同样遵守上表所有规则（同一套线路分级、换线与重连阈值、腾讯/咪咕/ESPN 匹配与补位、评论节流与过期）。业务逻辑在 `web/src/core`（赛程、事件源、线路排序、播放恢复）和 `web/src/sports`（比赛数据与评论），抓取在 `web/worker`：

- 赛程、事件源、线路页、播放器脚本都由 Cloudflare Worker 在服务端抓取；站点播放器脚本跑在 Worker 内的 QuickJS 沙箱里（对应 Apple 的 JSContext、Android 的 Rhino），浏览器只拿到校验过的 m3u8，视频直接从线路 CDN 播放，只用浏览器原生 HLS。
- 必须登录 leeguoo 账号；Worker 只接受自己签过名的线路地址和 `web/worker/sports.ts` 里固定的数据接口白名单，不是通用代理。
- 不向第三方暴露网站：所有上游抓取经 `web/relay` 出口中转（腾讯云 VM）发出，没有 `Cf-Worker` 头和我们的 Origin/Referer；视频在 sandbox iframe 里用原生 HLS 播放，线路 CDN 的请求不带 Origin、Referer、Cookie。
- 关注、观看记录、线路表现记在浏览器 localStorage。

网页版差异：没有录像与导出；只支持有原生 HLS 的浏览器（Chrome、Edge、Safari、安卓 Chrome；Firefox 会提示换浏览器），因为 hls.js 的请求必然带 Origin；不支持 AirPlay；画中画用视频自带控件里的按钮；浏览器拒绝带声音自动播放时显示「点击播放」，此时算暂停，不触发换线；全屏走播放器自己的全屏按钮（整块画面，水印与弹幕都在）；iPhone Safari 只能让 video 元素本身全屏、浏览器画中画窗口也只有视频，这两种情况下看不到水印和弹幕。

平台差异：AirPlay 为 Apple 原生能力，Android 未宣称支持 AirPlay；Android 使用原生画中画和 MediaStore，Apple 使用 AVKit 与照片/文件接口。Android 手机包不等同于 Android TV 遥控器版本。

## 回归入口

- 共用样例：`contracts/tencent-sports.json` 和 `contracts/multi-sports.json`。
- 网页：`cd web && npm test`（`test/sports*.test.ts` 读同一份契约样例，`test/core-*.test.ts` 对应 Swift 的列表、赛程、解析、播放测试）。
- Apple：`TencentSportsTests.testSharedAndroidAppleContract`、`MultiSportsTests`，另有线路回退、过期评论和比赛匹配测试。
- Android：`TencentSportsTest`、`MultiSportsTest`、`ExperienceTest`；真实站点检查用 `-PjrkanLive=1`，与确定性测试分开。
- 调试包可通过 `jrkan_qa=overview|players|play` 和 `qa_mid` 打开公开腾讯数据。只有 debug 构建接受这些入口；测试视频/测试弹幕有明确标记，不计为真实赛事或真机验收。
- 正式包必须核对包名、versionCode、签名证书、SHA-256，并用旧版正式 APK 执行覆盖安装验证。

签名 APK、CI 通过、模拟器验证与真机验证分别记录。无已授权安卓真机时明确保留该验收缺口；不得把模拟器结果写成真机通过。内部 APK 继续挂草稿 Release，未经明确要求不公开发布。

多源统计不会合成综合评分。咪咕当前显示真实命中率等原始指标；ESPN 球员姓名保留来源文字。评论只使用 120 秒内的消息，过滤置顶、推广、空内容及错场 ID；读不到新评论时不回放旧评论充数。

咪咕评论同时兼容网页及 APP 格式。APP 评论的 `contentId=100` 不是比赛 ID；以同时一致的 `mId` 和 `objectId` 核对比赛，并验证评论类型。上海/福建样例同时覆盖两种格式及错场、置顶、重复、过期消息。
