#!/bin/zsh
# Records a transition on a simulator and cuts it into frames, for the
# check-up in CHECKLIST.md: anything that jumps shows up as two frames that
# don't follow from each other.
#
#   tools/rec.sh start NAME      record the test simulator until stopped
#                                (stays in the foreground: run it in the
#                                background; a recorder whose shell ends
#                                dies with it)
#   tools/rec.sh stop  NAME      stop, cut to 30 fps, and draw strips
#
# Output in $REC (default: /tmp/search-ios-rec/NAME): video.mp4, frames/*.png
# (full size), strip-*.png (12 frames a strip, numbered).
set -e
D=${SIM:-015CFB2F-C2F0-4931-9948-1FDDD1FA07A5}
NAME=$2
OUT=${REC:-/tmp/search-ios-rec}/$NAME
case $1 in
start)
  rm -rf "$OUT"; mkdir -p "$OUT/frames"
  exec xcrun simctl io $D recordVideo --codec=h264 --force "$OUT/video.mp4"
  ;;
stop)
  pkill -INT -f "recordVideo --codec=h264 --force $OUT/video.mp4"; sleep 1.5
  ffmpeg -loglevel error -i "$OUT/video.mp4" -vf fps=30 "$OUT/frames/%03d.png"
  ffmpeg -loglevel error -framerate 30 -i "$OUT/frames/%03d.png" \
    -vf "scale=150:-1,drawtext=text='%{frame_num}':start_number=1:x=4:y=4:fontsize=18:fontcolor=red:box=1:boxcolor=white,tile=12x1" \
    "$OUT/strip-%02d.png"
  ls "$OUT/frames" | wc -l | tr -d ' ' | xargs echo frames:
  ls "$OUT"/strip-*.png
  ;;
esac
