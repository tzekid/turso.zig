#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 UPSTREAM CLASSIFICATION WORKING_REVISION LATEST_REVISION RUN_URL EVIDENCE_JSON [PULL_REQUEST_URL]" >&2
  exit 2
}

[[ $# -ge 6 && $# -le 7 ]] || usage
upstream=$1
classification=$2
working_revision=$3
latest_revision=$4
run_url=$5
evidence_json=$6
pull_request_url=${7:-}

[[ $upstream == zig || $upstream == turso ]] || usage
[[ $classification == maintenance-required || $classification == infrastructure-failure ]] || usage
jq -e '.classification and (.reasons | type == "array")' "$evidence_json" >/dev/null

repository=${REPOSITORY:-${GITHUB_REPOSITORY:-}}
[[ -n $repository ]] || {
  echo "REPOSITORY or GITHUB_REPOSITORY is required" >&2
  exit 1
}

marker="development-target:$upstream:$classification"
run_id=${run_url##*/}
reasons=$(jq -r '.reasons[] | "- " + .' "$evidence_json")
breaking=false
if [[ $classification == maintenance-required ]] &&
  jq -e 'any(.reasons[]?; test("ABI|version family|format|compile|behavior"; "i"))' \
    "$evidence_json" >/dev/null; then
  breaking=true
fi

if [[ $classification == maintenance-required ]]; then
  title="$upstream maintenance: $working_revision"
  state=agent-queued
  if [[ -n $pull_request_url ]]; then state=agent-working; fi
else
  title="$upstream candidate verification infrastructure failure"
  state=needs-automation-repair
fi

body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
{
  printf '<!-- %s -->\n' "$marker"
  printf '<!-- development-target-working:%s:%s -->\n\n' "$upstream" "$working_revision"
  printf 'Classification: **%s**\n\n' "$classification"
  printf 'State: **%s**\n\n' "$state"
  printf -- "- Working candidate: \`%s\`\n" "$working_revision"
  printf -- "- Latest observed candidate: \`%s\`\n" "$latest_revision"
  printf -- "- Breaking compatibility signal: \`%s\`\n" "$breaking"
  if [[ -n $pull_request_url ]]; then
    printf -- '- Draft pull request: %s\n' "$pull_request_url"
  else
    printf -- '- Draft pull request: not created yet\n'
  fi
  printf '\n%s\n\n' "$reasons"
  printf 'Latest evidence: %s\n\n' "$run_url"
  if [[ -n $pull_request_url ]]; then
    printf '%s\n\n' 'The draft pull request freezes the working candidate. Newer upstream revisions update only the latest-observed field until this episode is resolved.'
  else
    printf '%s\n\n' 'The working candidate will be frozen when its draft pull request is created. Until then a newer observation may advance it.'
  fi
  printf '%s\n\n' 'Download the exact candidate and evidence while the workflow artifacts are retained:'
  printf '```sh\n'
  printf 'gh run download %q --repo %q --name development-candidate --dir candidate\n' "$run_id" "$repository"
  printf 'gh run download %q --repo %q --name %q --dir evidence\n' \
    "$run_id" "$repository" "$upstream-candidate-evidence"
  printf '```\n'
} >"$body_file"

if [[ ${DEVELOPMENT_TARGET_RENDER_ONLY:-false} == true ]]; then
  cat "$body_file"
  exit 0
fi

gh label create upstream-maintenance --repo "$repository" --color B60205 --force
gh label create "$upstream" --repo "$repository" --color 1D76DB --force
labels="upstream-maintenance,$upstream"
if [[ $classification == maintenance-required ]]; then
  gh label create agent-maintenance --repo "$repository" --color FBCA04 --force
  labels="$labels,agent-maintenance"
fi
if [[ $breaking == true ]]; then
  gh label create breaking-change --repo "$repository" --color D93F0B --force
  labels="$labels,breaking-change"
fi

issue_number=$(
  gh issue list --repo "$repository" --state open --limit 100 \
    --label upstream-maintenance --json number,body \
    --jq ".[] | select(.body | contains(\"<!-- $marker -->\")) | .number" |
    head -1
)
created=false
if [[ -n $issue_number ]]; then
  gh issue edit "$issue_number" --repo "$repository" \
    --title "$title" --body-file "$body_file" --add-label "$labels" >/dev/null
else
  issue_url=$(
    gh issue create --repo "$repository" --title "$title" \
      --body-file "$body_file" --label "$labels"
  )
  issue_number=${issue_url##*/}
  created=true
fi

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "issue_number=$issue_number"
    echo "created=$created"
    echo "breaking=$breaking"
  } >>"$GITHUB_OUTPUT"
fi

echo "Synchronized $classification tracker #$issue_number for $upstream."
