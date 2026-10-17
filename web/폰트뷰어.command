#!/bin/zsh
# 폰트뷰어 — 더블클릭하면 설치된 폰트 미리보기가 브라우저로 열린다.
# 폰트 폴더를 인자로 주면(또는 폰트뷰어.app 에 폴더를 드롭하면) 설치 안 한 폰트도 미리본다.
DIR="${0:A:h}"
for p in /usr/local/bin/python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
  [ -x "$p" ] && PY="$p" && break
done
if [ -z "$PY" ]; then echo "python3 를 찾지 못했습니다."; exit 1; fi
exec "$PY" "$DIR/fontviewer.py" "$@"
