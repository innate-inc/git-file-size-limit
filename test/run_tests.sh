#!/usr/bin/env bash
# Exercises check_file_size.sh against a scratch git repo covering:
# violations, exact + glob exemptions, edits, deletions, the pass path,
# fail_on_violation=false, and size-unit parsing. Run from the repo root:
#   test/run_tests.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/check_file_size.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok - $desc"
    PASS=$((PASS + 1))
  else
    echo "  NOT OK - $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

cd "$WORKDIR"
git init -q -b main
git config user.email test@example.com
git config user.name test

echo "small" > small.py
python3 -c "open('existing_big.bin','wb').write(b'\0'*300000)"
git add -A && git commit -q -m base

git checkout -q -b pr
python3 -c "open('new_big.bin','wb').write(b'\0'*200000)"      # violation
python3 -c "open('uv.lock','wb').write(b'x'*300000)"           # exempt (exact)
mkdir -p sub
python3 -c "open('sub/demo.ipynb','wb').write(b'z'*250000)"    # exempt (glob)
printf 'uv.lock\nsub/*.ipynb\n' > .sizelimitignore
echo "more" >> small.py                                        # small edit, passes
git rm -q existing_big.bin                                     # deletion, never flagged
git add -A && git commit -q -m "pr changes"

BASE_SHA=$(git rev-parse main)
HEAD_SHA=$(git rev-parse pr)

echo "== violation + exemptions =="
OUT_FILE="$WORKDIR/out1"
: > "$OUT_FILE"
set +e
MAX_SIZE=100KB BASE_SHA="$BASE_SHA" HEAD_SHA="$HEAD_SHA" GITHUB_OUTPUT="$OUT_FILE" bash "$SCRIPT" > "$WORKDIR/stdout1" 2>&1
rc=$?
set -e
assert_eq "exits 1 on violation" "1" "$rc"
assert_eq "flags new_big.bin" "1" "$(grep -c 'new_big.bin' "$WORKDIR/stdout1")"
assert_eq "exempts uv.lock" "1" "$(grep -c 'exempt.*uv.lock' "$WORKDIR/stdout1")"
assert_eq "exempts sub/demo.ipynb via glob" "1" "$(grep -c 'exempt.*sub/demo.ipynb' "$WORKDIR/stdout1")"
assert_eq "does not mention deleted existing_big.bin" "0" "$(grep -c 'existing_big.bin' "$WORKDIR/stdout1")"
assert_eq "violations_count output is 1" "violations_count=1" "$(grep '^violations_count=' "$OUT_FILE")"
assert_eq "status output is fail" "status=fail" "$(grep '^status=' "$OUT_FILE")"

echo "== clean pass under a looser limit =="
set +e
MAX_SIZE=1MB BASE_SHA="$BASE_SHA" HEAD_SHA="$HEAD_SHA" GITHUB_OUTPUT=/dev/null bash "$SCRIPT" > /dev/null 2>&1
rc=$?
set -e
assert_eq "exits 0 when nothing exceeds the limit" "0" "$rc"

echo "== fail_on_violation=false =="
set +e
MAX_SIZE=100KB FAIL_ON_VIOLATION=false BASE_SHA="$BASE_SHA" HEAD_SHA="$HEAD_SHA" GITHUB_OUTPUT=/dev/null bash "$SCRIPT" > /dev/null 2>&1
rc=$?
set -e
assert_eq "exits 0 despite a violation when fail_on_violation=false" "0" "$rc"

echo "== size unit parsing =="
for pair in "500000:488.3KB" "0.5MB:512.0KB" "1GB:1.0GB"; do
  val="${pair%%:*}"; want="${pair##*:}"
  full_out=$(MAX_SIZE="$val" BASE_SHA="$BASE_SHA" HEAD_SHA="$HEAD_SHA" GITHUB_OUTPUT=/dev/null bash "$SCRIPT" 2>&1)
  got=$(printf '%s\n' "$full_out" | head -n 1 | grep -o '[0-9.]*[A-Z]*B$')
  assert_eq "max_size '$val' parses to $want" "$want" "$got"
done

set +e
MAX_SIZE=5XB BASE_SHA="$BASE_SHA" HEAD_SHA="$HEAD_SHA" GITHUB_OUTPUT=/dev/null bash "$SCRIPT" > "$WORKDIR/badunit" 2>&1
rc=$?
set -e
assert_eq "rejects an unknown size unit" "1" "$rc"
assert_eq "reports the bad unit" "1" "$(grep -c 'Unknown size unit' "$WORKDIR/badunit")"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
