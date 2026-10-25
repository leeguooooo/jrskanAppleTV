# Bundled fonts

All fonts are licensed under the SIL Open Font License 1.1 (full text in `OFL.txt`).

| File | Source | Copyright |
|---|---|---|
| `VT323-Regular.ttf` | google/fonts `ofl/vt323` | Copyright 2011 The VT323 Project Authors |
| `ChakraPetch-SemiBold.ttf`, `ChakraPetch-Bold.ttf` | google/fonts `ofl/chakrapetch` | Copyright 2018 The Chakra Petch Project Authors |
| `LeeguooHeading-Black.ttf` | Subset of Noto Serif SC (google/fonts `ofl/notoserifsc`), weight 900, renamed so it never shadows a full Noto Serif SC install | Copyright 2012 Google Inc. |

`LeeguooHeading-Black.ttf` contains only the characters of fixed section headings:

```
今日比赛正在进行稍后开始未开赛已结束其他最近观看热门关注收藏历史篮球羽毛球足球搜索录像设置我的账号本场数据球员球队分节线路赛况对比技术统计概况全部得分换手动自动直播看0123456789leeguosprtLEEGUOSPRT
```

Characters outside it fall back to the system font. Rebuild it with
`fonttools varLib.instancer NotoSerifSC[wght].ttf wght=900` followed by `pyftsubset --text=…` (then rename it in the `name` table) when a heading needs a new character.
