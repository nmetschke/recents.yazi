#!/usr/bin/env bash
set -euo pipefail
# set -x trace

# export LC_ALL=C

SESSION="yazi-test"

WORK_DIR=$(mktemp -d)

if [[ ! "$WORK_DIR" || ! -d "$WORK_DIR" ]]; then
    echo "Could not create tmpdir $WORK_DIR"
    exit 1
fi
function cleanup {
    tmux kill-session -t "$SESSION"
    echo "Deleting temp working directory $WORK_DIR"
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

export YAZI_RECENTLY_USED="$WORK_DIR/recently-used.xbel"
export YAZI_LOG=debug
export YAZI_ID=42
YAZI_LOG_FILE="$HOME/.local/state/yazi/yazi.log"

function now() {
    date -u +"%Y-%m-%dT%H:%M:%S.%NZ"
}

function recently_used() {
    sed -r -e 's/"[0-9TZ:.-]{4,}"/"DATE"/g' -e 's/tmp\.[a-zA-Z0-9]+/tmp.XXXX/' <"$YAZI_RECENTLY_USED"
}
function recently_used_timestamps() {
    grep -oP "\d+-\d+-\d+T\d+:\d+:\d+\.?\d*Z" <"$YAZI_RECENTLY_USED"
}

function cmp_timestamps() {
    local n=$1 a=$2 b=$3 x y d
    while IFS= read -r x && IFS= read -r y <&3; do
        d=$(bc <<<"sqrt(($(date -d "$x" '+%s.%N') - $(date -d "$y" '+%s.%N'))^2)")
        if (($(echo "$d > $n" | bc -l))); then
            echo "time diff too large for $x and $y: $d > $n"
            diff <(echo "$a") <(echo "$b")
            exit 1
        fi
    done <<<"$a" 3<<<"$b"
}

function cmp_recently_used() {
    if ! diff <(echo "$2") <(recently_used); then
        echo "$1 failed"
        exit 1
    fi
}

function yazi_grep() {
    CAP="$(tmux capture-pane -J -p)"
    if ! grep -q $1 <<<"$CAP"; then
        echo "capture does not contain $1"
        cat "$YAZI_LOG_FILE"
        printf "%s" "$CAP"
        exit 1
    fi
}

echo "Workdir is $WORK_DIR"

echo "Starting yazi"
tmux new-session -d -s "$SESSION" "yazi --client-id=$YAZI_ID $WORK_DIR"

echo "Creating test file"
echo foo >"$WORK_DIR/foo.txt"

# wait for yazi to start
while ! ya exec hover &>/dev/null; do
    sleep 0.1
done
sleep 0.5
yazi_grep "foo.txt"

# run unit tests
echo "Running unit tests"
ya emit-to $YAZI_ID plugin recents unit_tests
sleep 0.2
if ! grep -q "all tests passed" "$YAZI_LOG_FILE"; then
    echo "unit tests didn't complete"
    cat "$YAZI_LOG_FILE"
    ya emit-to $YAZI_ID tasks:show
    sleep 0.1
    tmux capture-pane -J -p
    tmux send-keys Enter
    sleep 5
    tmux capture-pane -J -p
    exit 1
fi

echo "Add to recents"
ya emit-to $YAZI_ID plugin recents modify
while ! [ -e $YAZI_RECENTLY_USED ]; do
    sleep 0.1
done
read -r -d '' EXPECTED_RECENTLY_USED <<'EOF' || true
<?xml version="1.0" encoding="UTF-8"?>
<xbel xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks" xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info" version="1.0">
  <bookmark href="file:///tmp/tmp.XXXX/foo.txt" added="DATE" modified="DATE" visited="DATE">
    <info>
      <metadata owner="http://freedesktop.org">
        <mime:mime-type type="text/plain"/>
        <bookmark:applications>
          <bookmark:application name="Yazi" exec="'yazi %f'" modified="DATE" count="1"/>
        </bookmark:applications>
      </metadata>
    </info>
  </bookmark>
</xbel>
EOF
cmp_recently_used "Add to recents" "$EXPECTED_RECENTLY_USED"
NOW_ADD=$(now)
cmp_timestamps 1 "$(recently_used_timestamps)" "$(printf "$NOW_ADD\n$NOW_ADD\n$NOW_ADD\n$NOW_ADD\n")"

echo "Open recents"
ya emit-to $YAZI_ID plugin recents
sleep 0.1
yazi_grep "foo.txt"

echo "Modify recents"
ya emit-to $YAZI_ID plugin recents modify
cmp_recently_used "Modify recents" "$EXPECTED_RECENTLY_USED"
NOW_MOD=$(now)
sleep 0.1
cmp_timestamps 1 "$(recently_used_timestamps)" "$(printf "$NOW_ADD\n$NOW_MOD\n$NOW_MOD\n$NOW_MOD\n")"

echo "Remove from recents"
ya exec remove --permanently --force >/dev/null
sleep 0.1
read -r -d '' EXPECTED_RECENTLY_USED <<'EOF' || true
<?xml version="1.0" encoding="UTF-8"?>
<xbel xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks" xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info" version="1.0"/>
EOF
cmp_recently_used "Remove from recents" "$EXPECTED_RECENTLY_USED"

echo bar >"$WORK_DIR/bar.txt"
sleep 0.1
ya exec back >/dev/null
sleep 0.1

echo "Add all to recents"
ya exec toggle_all --state=on >/dev/null
sleep 0.1
ya emit-to $YAZI_ID plugin recents modify
sleep 0.3
yazi_grep "foo.txt"
yazi_grep "bar.txt"
read -r -d '' EXPECTED_RECENTLY_USED <<'EOF' || true
<?xml version="1.0" encoding="UTF-8"?>
<xbel xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks" xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info" version="1.0">
  <bookmark href="file:///tmp/tmp.XXXX/bar.txt" added="DATE" modified="DATE" visited="DATE">
    <info>
      <metadata owner="http://freedesktop.org">
        <mime:mime-type type="text/plain"/>
        <bookmark:applications>
          <bookmark:application name="Yazi" exec="'yazi %f'" modified="DATE" count="1"/>
        </bookmark:applications>
      </metadata>
    </info>
  </bookmark>
  <bookmark href="file:///tmp/tmp.XXXX/foo.txt" added="DATE" modified="DATE" visited="DATE">
    <info>
      <metadata owner="http://freedesktop.org">
        <mime:mime-type type="text/plain"/>
        <bookmark:applications>
          <bookmark:application name="Yazi" exec="'yazi %f'" modified="DATE" count="1"/>
        </bookmark:applications>
      </metadata>
    </info>
  </bookmark>
  <bookmark href="file:///tmp/tmp.XXXX/recently-used.xbel" added="DATE" modified="DATE" visited="DATE">
    <info>
      <metadata owner="http://freedesktop.org">
        <mime:mime-type type="text/xml"/>
        <bookmark:applications>
          <bookmark:application name="Yazi" exec="'yazi %f'" modified="DATE" count="1"/>
        </bookmark:applications>
      </metadata>
    </info>
  </bookmark>
</xbel>
EOF
cmp_recently_used "Add all recents" "$EXPECTED_RECENTLY_USED"
sleep 0.1

rm "$WORK_DIR/bar.txt"
sleep 0.1

echo "Open recents with deleted"
ya emit-to $YAZI_ID plugin recents
sleep 0.1

if grep "error" "$YAZI_LOG_FILE"; then
    echo "found err in log"
    exit 1
fi
