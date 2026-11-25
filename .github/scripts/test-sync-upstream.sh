#!/usr/bin/env bash
# Tests for sync-upstream.sh using a stub `gh` on PATH. No network access.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/sync-upstream.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh. Behaviour is driven by STUB_* env vars; calls are logged to $STUB_DIR/calls.
set -euo pipefail
echo "$*" >>"$STUB_DIR/calls"
case "$1" in
  repo)
    n=$(grep -c '^repo sync' "$STUB_DIR/calls")
    read -r -a results <<<"$STUB_SYNC_RESULTS"
    [[ "${results[n - 1]:-fail}" == ok ]] && exit 0
    echo "HTTP 500 (stub)" >&2; exit 1 ;;
  api)
    [[ "${STUB_API_FAIL:-0}" == 1 ]] && { echo "HTTP 500 (stub)" >&2; exit 1; }
    path="$2"
    case "$path" in
      */workflows/*/runs*) printf '%s\n' "${STUB_RUNS:-}" | sed '/^$/d' ;;
      */actions/runs/*/jobs) id="${path#*/actions/runs/}"; echo "${id%/jobs}0" ;;
      */check-runs/*/annotations)
        job="${path#*/check-runs/}"; job="${job%/annotations}"; run="${job%0}"
        if [[ " ${STUB_SOFT_RUNS:-} " == *" $run "* ]]; then echo upstream-sync-soft-failure; fi ;;
      *) echo "unexpected api path $path" >&2; exit 3 ;;
    esac ;;
  *) echo "unexpected gh call $*" >&2; exit 3 ;;
esac
STUB
chmod +x "$work/bin/gh"

pass=0 fail=0
# run_case NAME EXPECTED_EXIT EXPECTED_SYNC_CALLS OUTPUT_PATTERN [ENV=VAL...]
run_case() {
  local name="$1" want_rc="$2" want_calls="$3" pattern="$4"; shift 4
  local dir="$work/$name" rc=0 out calls
  mkdir -p "$dir"; : >"$dir/calls"
  out="$(env -i PATH="$work/bin:/usr/bin:/bin" HOME="$dir" STUB_DIR="$dir" \
    SYNC_REPO=o/fork SYNC_SOURCE=u/src SYNC_BRANCH=main SYNC_RETRY_DELAYS=0 \
    GITHUB_REPOSITORY=o/fork GITHUB_RUN_ID=999 \
    GITHUB_WORKFLOW_REF=o/fork/.github/workflows/sync.yml@refs/heads/main \
    STUB_SYNC_RESULTS=fail "$@" bash "$script" 2>&1)" || rc=$?
  calls=$(grep -c '^repo sync' "$dir/calls" || true)
  if [[ "$rc" == "$want_rc" && "$calls" == "$want_calls" ]] && grep -qE -- "$pattern" <<<"$out"; then
    pass=$((pass + 1)); echo "ok   $name"
  else
    fail=$((fail + 1))
    echo "FAIL $name: rc=$rc (want $want_rc) sync_calls=$calls (want $want_calls)"
    while IFS= read -r line; do echo "     | $line"; done <<<"$out"
  fi
}

run_case first-try-ok         0 1 '^$'                       STUB_SYNC_RESULTS=ok
run_case retry-then-ok        0 2 'attempt 1/3 failed'       STUB_SYNC_RESULTS="fail ok"
run_case third-try-ok         0 3 'attempt 2/3 failed'       STUB_SYNC_RESULTS="fail fail ok"
run_case single-failure-soft  0 3 '::warning title=upstream-sync-soft-failure::.*1 of 3' \
  STUB_RUNS="101 success"
run_case second-failure-soft  0 3 '2 of 3' \
  STUB_RUNS=$'101 success\n100 success' STUB_SOFT_RUNS=101
run_case third-failure-alerts 1 3 '::error::.*3 consecutive' \
  STUB_RUNS=$'101 success\n100 success' STUB_SOFT_RUNS="101 100"
run_case after-hard-failure   1 3 '::error::.*3 consecutive' \
  STUB_RUNS=$'101 failure\n100 success' STUB_SOFT_RUNS=100
run_case streak-broken        0 3 '2 of 3' \
  STUB_RUNS=$'101 success\n100 success\n99 success' STUB_SOFT_RUNS="101 99"
run_case cancelled-breaks     0 3 '1 of 3' \
  STUB_RUNS=$'101 cancelled\n100 failure'
run_case skips-current-run    0 3 '2 of 3' \
  STUB_RUNS=$'999 failure\n101 failure\n100 success'
run_case api-down-soft        0 3 'Could not read previous runs.*' STUB_API_FAIL=1
run_case threshold-one        1 3 '::error::.*1 consecutive' SYNC_FAILURE_THRESHOLD=1
run_case custom-attempts      0 5 'attempt 4/5 failed'       SYNC_ATTEMPTS=5
run_case bad-threshold        2 0 'positive integers'        SYNC_FAILURE_THRESHOLD=0
run_case missing-repo         1 0 'SYNC_REPO is required'    SYNC_REPO=

total=$((pass + fail))
echo "$pass passed, $fail failed, 0 skipped ($total total)"
((total > 0)) || { echo "no tests ran" >&2; exit 1; }
((fail == 0))
