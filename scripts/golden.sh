#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded jobs called on the signed bundle the way Gaea calls them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through indextts-inproc with the
# lane configuration, requests and seeding the worker uses. Each pair must be byte for byte the same WAV.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases, all cloning scripts/fixtures/ref-en.wav: plain English (fp16, and the int8 lane), happy at intensity 0.8, the
# emotion vector, a 4 s target with a pause, speed 1.3, Chinese and Spanish.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/indextts.gaeaplugin
REF=$ROOT/scripts/fixtures/ref-en.wav
MODELS=${CHECK_MODELS_ROOT:-/Volumes/DEV_VOL1/Models/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product indextts-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/indextts-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# IndexTTS 2.5 golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
same() { # name, gpp wav, inproc wav
  local a=$(shasum -a 256 $2 2>/dev/null | cut -c1-16) b=$(shasum -a 256 $3 2>/dev/null | cut -c1-16)
  if [[ -n $a && $a == $b ]]; then pass=$((pass+1)); say "PASS  $1: byte-identical, sha256 $a…"
  else fail=$((fail+1)); say "FAIL  $1: differs ($a… / $b…)"; fi
}
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' }

# speak <name> <lane> <seed> <params json> <text> [inproc args…]
speak() {
  local name=$1 lane=$2 seed=$3 params=$4 text=$5; shift 5
  $CHECK $B --operation audio.speak --model indextts-2.5 --lane $lane --params $params --seed $seed --text "text=$text" \
    --input "voice_ref=$REF" --models-root "$MODELS" --budget 64000000000 --timeout 900 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(outputs $OUT/$name-gpp.log | tail -1); [[ -f $file ]] && cp $file $OUT/$name-gpp.wav
  $INPROC --ref $REF --lane $lane --seed $seed --text "$text" --models-root "$MODELS" --out $OUT/$name-inproc.wav "$@" 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1); in-process $(cat $OUT/$name-inproc.json)"
  same $name $OUT/$name-gpp.wav $OUT/$name-inproc.wav
}

EN='Gaea speaks. This sentence came from a signed plugin, over its own protocol.'
speak plain fp16 42 '{"language":"en"}' "$EN" --language en
speak plain-int8 int8 42 '{"language":"en"}' "$EN" --language en
speak happy fp16 3 '{"language":"en","emotion":{"label":"happy","intensity":0.8}}' 'We won! I still can not believe it.' --language en --emotion happy --intensity 0.8
speak vector fp16 5 '{"language":"en","x-indextts.emotion_vector":[0,0.9,0,0,0.3,0,0,0]}' 'Put it back where you found it.' --language en --vector 0,0.9,0,0,0.3,0,0,0
speak fitted fp16 7 '{"language":"en","target_duration_s":4.0}' 'This line has to fit the cue. [pause 0.5s] Exactly.' --language en --target-duration 4.0
speak fast fp16 9 '{"language":"en","speed":1.3}' "$EN" --language en --speed 1.3
speak chinese fp16 11 '{"language":"zh"}' '今天天气很好，我们去公园散步吧。' --language zh
speak spanish fp16 13 '{"language":"es"}' 'Hoy hace buen tiempo, vamos a dar un paseo por el parque.' --language es

for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
