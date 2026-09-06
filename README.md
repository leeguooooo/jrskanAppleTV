# JRKAN Apple TV

面向实体 Apple TV 的原生 tvOS 赛事观看应用，另有共用业务层的 iPhone / iPad / Mac 版。

tvOS 17+ · iOS 17+ · macOS 14+（Mac Catalyst）· SwiftUI · AVFoundation · XcodeGen

---

## 界面

赛事列表。按「正在进行 / 即将开始 / 已结束」分组，进行中显示 LIVE 与已进行分钟数，开赛时间换算成本机时区；分类 chip 带场次，右侧是搜索、刷新、设置。

![赛事列表](assets/store/ui/list-web.png)

比赛详情。对阵 hero 带比赛状态与「关注」按钮；线路读取期间显示骨架屏，读取完成后焦点直接落在上次看过的线路（首次为第一条）。

![比赛详情](assets/store/ui/detail-web.png)

设置。自动换线、自动刷新两个开关，关注与观看记录清除，以及内容来源、隐私、遥控器说明。

![设置](assets/store/ui/settings-web.png)

iPhone 版。同一套数据与播放逻辑，界面按触屏重排：分组列表、分类 chip、下拉刷新、搜索补全；详情页关注与线路；全屏播放带关闭与线路菜单，支持画中画与 AirPlay。播放时自动转横屏，关闭后转回。

<p>
  <img src="assets/store/ui/ios-list-web.png" width="300" alt="iPhone 赛事列表">
  <img src="assets/store/ui/ios-detail-web.png" width="300" alt="iPhone 比赛详情">
</p>

iPad 与 Mac 共用一套宽屏布局：左侧分类、中间赛程、右侧比赛详情。Mac 版走 Mac Catalyst，就是这套 iPad 界面加原生窗口与菜单栏，不是另写一遍。窗口变窄（iPhone、iPad 分屏、窄 Mac 窗口）自动切回紧凑堆栈。

Top Shelf 横幅（2320×720），应用在主屏聚焦时显示。

![Top Shelf 横幅](assets/store/ui/topshelf-web.png)

应用图标（1280×768，三层视差合成预览）。沿用 leeguoo.com 的红蓝手绘风格，`lg` 标记中融入播放符号。

![应用图标](assets/store/ui/icon-web.png)

> 截图取自 Apple TV 4K 模拟器实拍。播放页是全屏 `AVPlayerViewController`，带原生传输栏、LIVE 指示与 Info 面板；因画面内嵌第三方推广，此处不附播放截图。

---

## 能力

| 能力 | 实现 |
| --- | --- |
| 比赛列表 | 读取目标站点公开首页与动态列表脚本，并接入站点同源的实时赛事事件源；线路地址按首页 `PLAY_HOSTS` 表还原 |
| 状态与排序 | 使用网页同源赛事状态，进行中且有线路的排最前；开赛时间只用于未开赛倒计时，不推断完赛 |
| 浏览 | 分类 chip（全部 / 关注 / 热门 / 篮球 / 足球），搜索带联赛名一键补全 |
| 关注 | 在详情页关注球队，列表出现「关注」分类与标记；只存本机 |
| 线路 | 第 1 步选比赛，第 2 步选具体频道；记住每场上次用的线路并默认聚焦 |
| 自动换线 | 线路页面、播放列表不可用或 20 秒未出现画面时尝试下一条，不重复尝试已失败线路；可在设置里关闭 |
| 播放 | 支持嵌套页面、转跳、相对地址及加密播放器链路；先检查播放列表，再交给 AVPlayer 全屏播放；传输栏内可切换线路 |
| 刷新 | 列表每 5 分钟自动刷新、回到前台检查过期；刷新失败保留上次数据并提示 |
| 比分 | 与状态取自同一份事件数据；未开赛、缺值或异常值保留 VS，只显示真实比分（含 0-0 与终场比分） |
| 播放水印 | 播放画面右下角半透明 `leeguoo.com`，按安全区内缩摆放，不挡系统播放控件 |
| 赛事状态 | 取站点同源的实时事件源（半场、加时、点球、延期、完赛），比赛分钟按事件里的比赛用时算，不用墙钟推断；成功取到快照时，快照里已消失的比赛与网页一样移出列表。事件源取不到或数据过期时，保留静态赛程与线路入口，既不猜 LIVE 也不猜完赛 |
| 平台 | tvOS / iOS 两个目标共用 `App/Sources/Shared`，iOS 目标同时产出 iPhone、iPad 与 Mac Catalyst 三种形态；启动画面、空态插画、隐私清单齐备，最终验收设备为实体 Apple TV、iPhone 与 Mac |

## 构建与测试

```bash
xcodegen generate

xcodebuild -project JRKANApple.xcodeproj -scheme JRKANTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K' test

xcodebuild -project JRKANApple.xcodeproj -scheme JRKANiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

xcodebuild -project JRKANApple.xcodeproj -scheme JRKANTV \
  -sdk appletvos -configuration Release build CODE_SIGNING_ALLOWED=NO
```

Debug 包支持启动参数直达页面，模拟器核对界面时不必模拟遥控器或点击：

```bash
xcrun simctl launch <udid> com.leeguoo.jrskan.tv -route play:live   # 最新开赛且有线路的比赛，直接播放
xcrun simctl launch <udid> com.leeguoo.jrskan.tv -route detail:0    # 当前分类第 1 场的详情
```

品牌资源与界面插画由脚本合成，**不要手改 `App/Resources/Assets.xcassets`**，下次运行会被整个覆盖：

```bash
python3 assets/brand/build_assets.py
```

原始素材由 imagegen 生成，保存在 `assets/brand/src/`。标记和状态插画使用原生透明背景，打包脚本保留其透明度，不再用黑底抠图；iOS 与 Mac Catalyst 使用独立方形图标。

## TestFlight

```bash
Scripts/testflight.sh tvos            # 归档 → 用 ASC API 密钥云端签名 → 上传
Scripts/testflight.sh ios             # iPhone / iPad 版
Scripts/testflight.sh mac             # Mac Catalyst 版（必须签名归档，见脚本注释）
Scripts/testflight.sh all 202609051   # 三端一起，指定构建号（缺省为 UTC 时间戳）
```

前提：`~/.appstoreconnect/private_keys/AuthKey_<ID>.p8`（Admin / App Manager 角色），App Store Connect 里已有 Bundle ID 为 `com.leeguoo.jrskan.tv` 的 App 记录（App ID 6808947990，名称 JRKAN，SKU `JRKANTV-2026`，tvOS 与 iOS 两个平台挂同一条记录）。查构建处理状态：

```bash
python3 Scripts/asc_api.py GET "/v1/builds?filter[app]=6808947990&sort=-uploadedDate&limit=3"
```

**到期自动续传**：TestFlight 构建 90 天过期。`.github/workflows/testflight-renew.yml` 每周一 02:00 UTC 跑 `Scripts/renew-if-expiring.sh`，查 ASC 两端最新构建的到期日，剩余不足 14 天才重新归档上传，其余时候直接退出；也可在 Actions 页手动触发（`force` 选 `all` / `ios` / `tvos` 立即上传）。runner 上不需要证书，签名靠仓库 Secrets 里的 CI 专用 Admin 密钥（`ASC_KEY_P8` / `ASC_KEY_ID` / `ASC_ISSUER_ID`；云端签名只有 Admin 角色能用，App Manager 不行），用完即删。

站点改字段是最容易让状态整体失真的事，`JRKANLiveContract` scheme 里的实站契约测试专门断言事件源的字段与取值，站点一改跑它就能立刻定位：

```bash
xcodebuild -project JRKANApple.xcodeproj -scheme JRKANLiveContract \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K' test
```

> 模拟器测试和成功上传都不等于真机验收。完成标准是：在指定实体 Apple TV 上装上 TestFlight 构建，用遥控器打开应用、加载比赛列表、进入赛事并确认至少一条公开线路开始播放。

## 目录

| 路径 | 内容 |
| --- | --- |
| `App/Sources/Shared/` | 两端共用：模型、网络、解析、`MatchListModel`、`MatchPlaybackModel`（线路与播放状态）、`Preferences`、`DesignSystem` |
| `App/Sources/TV/` | tvOS 界面与 `AVPlayerViewController` 模态播放 |
| `App/Sources/iOS/` | iPhone / iPad / Mac 界面：`RootScreen` 按尺寸类在紧凑与分栏之间分流，`Touch*` 是三种形态共用的组件 |
| `App/Resources/` | tvOS 与 iOS 两套资源目录、启动画面 storyboard、隐私清单 |
| `assets/brand/` | 图标与插画原始素材、生成脚本、合成脚本 |
| `assets/store/` | 商店截图（3840×2160）与 README 用的缩略版 |
| `Scripts/` | TestFlight 上传脚本、导出配置、ASC API 最小客户端 |
| `docs/app-store-submission.html` | 上架准备：ASC 全部字段、隐私标签、审核信息模板与阻断项 |

## 边界

应用只读取公开页面，不托管或重分发视频，不绕过登录、DRM、付费墙或地域限制。线路由第三方维护，可能随时失效。

当前为兼容第三方 HTTP 页面启用了宽松网络策略（`NSAllowsArbitraryLoads`）。正式发布前应由自有 HTTPS 后端完成解析，并收紧 App Transport Security。

> **产品决定（2026-09-05）：只做 TestFlight 内部测试，永不提交 App Store。** 原因是当前播放链路输出的第三方流内嵌境外博彩推广，且转播的是持权赛事信号，这是开发者账号封停级别的组合。取证与曾经评估过的合规路线保留在 [`docs/app-store-submission.html`](docs/app-store-submission.html)，仅作记录。
>
> 内部测试的运行规则：只加团队成员进「内部测试」组，不建外部测试组、不开公开链接（外部分发会触发 Beta 审核，标准与提审相同）；TestFlight 构建 90 天过期，到期前跑一次 `Scripts/testflight.sh` 重新上传即可。
