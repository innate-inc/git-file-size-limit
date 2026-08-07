#!/usr/bin/env bash
# Fail (or warn) when a file changed in a pull request exceeds a size limit.
#
# Exemptions use real gitignore syntax via `git check-ignore`, not an
# approximation: globs, '/'-anchoring, directory-only ('/') and negation
# ('!') all behave exactly as they would in a .gitignore. `--no-index` is
# required — without it, git refuses to flag already-tracked files as
# ignored (matching real gitignore semantics for `git status`), which
# would silently defeat the exemption file since every changed file here
# is already tracked.
set -euo pipefail

MAX_SIZE="${MAX_SIZE:-100KB}"
IGNORE_FILE="${IGNORE_FILE:-.sizelimitignore}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-}"
FAIL_ON_VIOLATION="${FAIL_ON_VIOLATION:-true}"

# --- resolve the commit range -----------------------------------------
if [ -z "$HEAD_SHA" ]; then
  HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)
  if [ -z "$HEAD_SHA" ]; then
    echo "::error::Unable to determine HEAD SHA. Pass head_sha explicitly outside of pull_request events."
    exit 1
  fi
fi

if [ -z "$BASE_SHA" ]; then
  BASE_SHA=$(git rev-parse "HEAD~1" 2>/dev/null || true)
  if [ -z "$BASE_SHA" ]; then
    BASE_SHA="$HEAD_SHA"
    echo "::notice::No base commit available; comparing HEAD against itself (no changed files will be found)."
  fi
fi

check_and_fetch_commit() {
  local sha="$1" label="$2"
  if git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    return 0
  fi
  if ! git fetch --depth=1 origin "$sha" >/dev/null 2>&1; then
    echo "::error::Could not fetch ${label} commit '${sha}' from origin. Ensure actions/checkout uses fetch-depth: 0, or that this SHA is reachable."
    exit 1
  fi
}
check_and_fetch_commit "$BASE_SHA" "base"
check_and_fetch_commit "$HEAD_SHA" "head"

# --- parse the size limit ----------------------------------------------
parse_size() {
  local raw upper num unit
  raw=$(echo "$1" | tr -d '[:space:]')
  if [[ "$raw" =~ ^([0-9]+(\.[0-9]+)?)([A-Za-z]*)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit=$(echo "${BASH_REMATCH[3]}" | tr '[:upper:]' '[:lower:]')
  else
    echo "::error::Invalid max_size value '$1'. Expected a number, optionally suffixed with B/KB/MB/GB (e.g. '100KB')." >&2
    exit 1
  fi
  case "$unit" in
    ""|b)   awk -v n="$num" 'BEGIN { printf "%d", n }' ;;
    kb|kib) awk -v n="$num" 'BEGIN { printf "%d", n * 1024 }' ;;
    mb|mib) awk -v n="$num" 'BEGIN { printf "%d", n * 1024 * 1024 }' ;;
    gb|gib) awk -v n="$num" 'BEGIN { printf "%d", n * 1024 * 1024 * 1024 }' ;;
    *)
      echo "::error::Unknown size unit '$unit' in max_size '$1'. Use B, KB, MB, or GB." >&2
      exit 1
      ;;
  esac
}
MAX_BYTES=$(parse_size "$MAX_SIZE")

human_size() {
  local size=$1
  if [ "$size" -lt 1024 ]; then
    echo "${size}B"
  elif [ "$size" -lt 1048576 ]; then
    awk -v s="$size" 'BEGIN { printf "%.1fKB", s / 1024 }'
  elif [ "$size" -lt 1073741824 ]; then
    awk -v s="$size" 'BEGIN { printf "%.1fMB", s / 1048576 }'
  else
    awk -v s="$size" 'BEGIN { printf "%.1fGB", s / 1073741824 }'
  fi
}
MAX_SIZE_HUMAN=$(human_size "$MAX_BYTES")

# --- gather changed files -----------------------------------------------
# Three-dot range: diffs HEAD against the merge-base with BASE, matching
# what GitHub's PR "Files changed" tab shows. --diff-filter=d excludes
# deletions, which can't newly violate a size limit.
echo "Checking changes in ${BASE_SHA}...${HEAD_SHA} against ${MAX_SIZE_HUMAN}"
mapfile -t CHANGED_FILES < <(git diff --name-only --diff-filter=d "${BASE_SHA}...${HEAD_SHA}")

is_ignored() {
  local file="$1"
  [ -f "$IGNORE_FILE" ] || return 1
  git -c core.excludesFile="$IGNORE_FILE" check-ignore --no-index --quiet -- "$file"
}

VIOLATIONS=()
for file in "${CHANGED_FILES[@]:-}"; do
  [ -z "$file" ] && continue
  [ -f "$file" ] || continue # deleted between diff and checkout, or a submodule gitlink

  if is_ignored "$file"; then
    echo "  - exempt (matches ${IGNORE_FILE}): $file"
    continue
  fi

  size=$(wc -c < "$file")
  if [ "$size" -gt "$MAX_BYTES" ]; then
    human=$(human_size "$size")
    echo "::error file=${file}::${file} is ${human}, exceeding the ${MAX_SIZE_HUMAN} limit"
    VIOLATIONS+=("- \`${file}\` — **${human}** (limit ${MAX_SIZE_HUMAN})")
  else
    echo "  - ok: $file ($(human_size "$size"))"
  fi
done

# --- outputs --------------------------------------------------------------
COUNT=${#VIOLATIONS[@]}
if [ "$COUNT" -gt 0 ]; then
  STATUS="fail"
else
  STATUS="pass"
fi

{
  echo "status=${STATUS}"
  echo "violations_count=${COUNT}"
  echo "violations<<GFSL_EOF"
  if [ "$COUNT" -gt 0 ]; then
    printf '%s\n' "${VIOLATIONS[@]}"
  fi
  echo "GFSL_EOF"
} >> "$GITHUB_OUTPUT"

if [ "$COUNT" -eq 0 ]; then
  echo "--- OK: no changed file exceeds ${MAX_SIZE_HUMAN} ---"
  exit 0
fi

echo ""
echo "--- ${COUNT} file(s) exceed ${MAX_SIZE_HUMAN} ---"
echo "If a file is intentionally large, exempt it by adding a pattern to ${IGNORE_FILE} (gitignore syntax) in the same PR."

if [ "$FAIL_ON_VIOLATION" = "true" ]; then
  exit 1
fi
echo "fail_on_violation is false; not failing the build."
exit 0
