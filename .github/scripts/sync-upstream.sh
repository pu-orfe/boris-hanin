#!/usr/bin/env bash
# Sync this fork's branch with its upstream, tolerating transient GitHub errors.
#
# 1. Try `gh repo sync` up to SYNC_ATTEMPTS times, sleeping between attempts.
# 2. If every attempt fails, count how many runs in a row have failed (this one
#    plus the previous completed runs of the same workflow that either failed or
#    carry the soft-failure annotation written below).
# 3. Below SYNC_FAILURE_THRESHOLD: emit a warning annotation and exit 0, so a
#    one-off GitHub outage does not send a failure notification.
#    At or above the threshold: exit 1 so GitHub notifies.
#
# Required env: GH_TOKEN, SYNC_REPO, SYNC_SOURCE, SYNC_BRANCH
# In Actions also: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_WORKFLOW_REF
# Optional env:
#   SYNC_ATTEMPTS          total sync attempts per run          (default 3)
#   SYNC_RETRY_DELAYS      space-separated sleep seconds        (default "15 45")
#   SYNC_FAILURE_THRESHOLD consecutive failed runs before exit 1 (default 3)
set -euo pipefail

: "${SYNC_REPO:?SYNC_REPO is required}"
: "${SYNC_SOURCE:?SYNC_SOURCE is required}"
: "${SYNC_BRANCH:?SYNC_BRANCH is required}"
attempts="${SYNC_ATTEMPTS:-3}"
threshold="${SYNC_FAILURE_THRESHOLD:-3}"
read -r -a delays <<<"${SYNC_RETRY_DELAYS:-15 45}"
((${#delays[@]} > 0)) || delays=(15)

for v in "$attempts" "$threshold"; do
  if ! [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::SYNC_ATTEMPTS and SYNC_FAILURE_THRESHOLD must be positive integers" >&2
    exit 2
  fi
done

readonly SOFT_FAIL_MARKER="upstream-sync-soft-failure"

for ((i = 1; i <= attempts; i++)); do
  if gh repo sync "$SYNC_REPO" --source "$SYNC_SOURCE" --branch "$SYNC_BRANCH"; then
    exit 0
  fi
  if ((i < attempts)); then
    delay="${delays[i - 1]:-${delays[${#delays[@]} - 1]}}"
    echo "Sync attempt $i/$attempts failed; retrying in ${delay}s." >&2
    sleep "$delay"
  fi
done
echo "Sync failed after $attempts attempts." >&2

# Count earlier consecutive failed runs (hard failures or soft-failure annotations).
# Prints the count; returns non-zero if the GitHub API could not be read.
previous_failures() {
  local repo="${GITHUB_REPOSITORY:?}" workflow_file runs id conclusion jobs count=0
  workflow_file="${GITHUB_WORKFLOW_REF:?}"
  workflow_file="${workflow_file%@*}"
  workflow_file="${workflow_file##*/}"
  runs="$(gh api "repos/$repo/actions/workflows/$workflow_file/runs?branch=$SYNC_BRANCH&status=completed&per_page=$threshold" \
    --jq '.workflow_runs[] | "\(.id) \(.conclusion)"')" || return 1
  while read -r id conclusion; do
    [[ -z "$id" || "$id" == "${GITHUB_RUN_ID:-}" ]] && continue
    if [[ "$conclusion" == "failure" ]]; then
      count=$((count + 1))
      continue
    fi
    [[ "$conclusion" == "success" ]] || break
    jobs="$(gh api "repos/$repo/actions/runs/$id/jobs" --jq '.jobs[].id')" || return 1
    local job soft=0
    for job in $jobs; do
      local ann
      ann="$(gh api "repos/$repo/check-runs/$job/annotations" \
        --jq ".[] | select((.title // \"\") == \"$SOFT_FAIL_MARKER\") | .title")" || return 1
      if [[ -n "$ann" ]]; then
        soft=1
        break
      fi
    done
    ((soft)) || break
    count=$((count + 1))
  done <<<"$runs"
  echo "$count"
}

if prev="$(previous_failures)"; then
  streak=$((prev + 1))
else
  echo "::warning::Could not read previous runs; treating this as the first failure." >&2
  streak=1
fi

if ((streak >= threshold)); then
  echo "::error::Upstream sync has failed in $streak consecutive runs."
  exit 1
fi
echo "::warning title=$SOFT_FAIL_MARKER::Upstream sync failed ($streak of $threshold consecutive failures before alerting)."
exit 0
