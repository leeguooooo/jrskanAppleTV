#!/bin/bash
# 用 chatgpt-imagegen 生成界面所需的原始素材（启动画面 + 四张状态插画）。
# 状态插画要求纯黑底，由 build_assets.py 的 key_out_black() 抠成透明。
set -u
cd "$(dirname "$0")/src"
GEN=chatgpt-imagegen
gen() { # name size prompt
  local name="$1" size="$2" prompt="$3"
  if [ -s "$name.png" ]; then echo "skip $name"; return; fi
  echo "==> $name"
  $GEN "$prompt" --no-style --size "$size" -o "$name.png" --quiet --timeout 420 2>"../gen-logs/$name.log" && echo "ok $name" || echo "FAIL $name (see gen-logs/$name.log)"
}
gen launch-art 1536x1024 "Cinematic wide shot of an empty modern sports stadium at night seen from high in the stands, deep navy blue atmosphere, warm amber floodlights glowing from the far side with soft haze and lens bloom, the pitch and seats fading into darkness toward the bottom, subtle film grain, moody and premium, no people, no text, no logos, no letters."
gen empty-nomatch 1024x1024 "Minimal flat vector illustration on a pure solid black background: a wall calendar page with an empty grid and a small sports whistle hanging from it, drawn in warm amber orange and soft white line art with a gentle glow, centered, plenty of black space around, no text, no letters, no numbers."
gen empty-offline 1024x1024 "Minimal flat vector illustration on a pure solid black background: a rooftop TV antenna with a broken signal, three arc waves above it with the top arc cracked apart, drawn in warm amber orange and soft white line art with a gentle glow, centered, plenty of black space around, no text, no letters."
gen empty-nochannel 1024x1024 "Minimal flat vector illustration on a pure solid black background: a retro television set showing gentle static noise with an unplugged power cable lying in front of it, drawn in warm amber orange and soft white line art with a gentle glow, centered, plenty of black space around, no text, no letters."
gen empty-search 1024x1024 "Minimal flat vector illustration on a pure solid black background: a large magnifying glass hovering over a basketball and a football, with a small question-mark-free empty highlight inside the lens, drawn in warm amber orange and soft white line art with a gentle glow, centered, plenty of black space around, no text, no letters."
echo "ALL DONE"
