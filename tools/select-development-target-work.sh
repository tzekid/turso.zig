#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 UPSTREAM CLASSIFICATION REVISION ISSUES_JSON PULL_REQUESTS_JSON" >&2
  exit 2
}

[[ $# -eq 5 ]] || usage
upstream=$1
classification=$2
revision=$3
issues_json=$4
pull_requests_json=$5

[[ $upstream == zig || $upstream == turso ]] || usage
[[ $classification == routine || $classification == maintenance-required ||
  $classification == infrastructure-failure ]] || usage
jq -e 'type == "array"' "$issues_json" >/dev/null
jq -e 'type == "array"' "$pull_requests_json" >/dev/null

if [[ $upstream == zig ]]; then
  [[ $revision =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+\+[0-9a-f]+$ ]] || usage
else
  [[ $revision =~ ^[0-9a-f]{40}$ ]] || usage
fi

extract_working_revision() {
  local body=$1
  sed -n "s|^<!-- development-target-working:$upstream:\([^ ]*\) -->$|\1|p" <<<"$body" |
    head -1
}

working_revision=
source=current
issue_number=
pull_request_number=
pull_request_url=
pull_request_branch=

pull_request=$(
  jq -c --arg marker "<!-- development-target-working:$upstream:" \
    '[.[] | select((.body // "") | contains($marker))][0] // empty' \
    "$pull_requests_json"
)
if [[ -n $pull_request ]]; then
  pull_request_body=$(jq -r '.body // ""' <<<"$pull_request")
  working_revision=$(extract_working_revision "$pull_request_body")
  pull_request_number=$(jq -r '.number' <<<"$pull_request")
  pull_request_url=$(jq -r '.url // ""' <<<"$pull_request")
  pull_request_branch=$(jq -r '.headRefName // ""' <<<"$pull_request")
  source=pull-request
fi

issue=$(
  jq -c --arg marker "<!-- development-target:$upstream:$classification -->" \
    '[.[] | select((.body // "") | contains($marker))][0] // empty' \
    "$issues_json"
)
if [[ -n $issue ]]; then
  issue_number=$(jq -r '.number' <<<"$issue")
  if [[ -z $working_revision ]]; then
    source=issue
  fi
fi

if [[ -z $working_revision ]]; then
  working_revision=$revision
fi

if [[ $upstream == zig ]]; then
  [[ $working_revision =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+\+[0-9a-f]+$ ]] || {
    echo "invalid frozen Zig revision: $working_revision" >&2
    exit 1
  }
else
  [[ $working_revision =~ ^[0-9a-f]{40}$ ]] || {
    echo "invalid frozen Turso revision: $working_revision" >&2
    exit 1
  }
fi

jq -n \
  --arg working_revision "$working_revision" \
  --arg source "$source" \
  --arg issue_number "$issue_number" \
  --arg pull_request_number "$pull_request_number" \
  --arg pull_request_url "$pull_request_url" \
  --arg pull_request_branch "$pull_request_branch" \
  '{
    working_revision: $working_revision,
    source: $source,
    issue_number: (if $issue_number == "" then null else ($issue_number | tonumber) end),
    pull_request_number: (if $pull_request_number == "" then null else ($pull_request_number | tonumber) end),
    pull_request_url: (if $pull_request_url == "" then null else $pull_request_url end),
    pull_request_branch: (if $pull_request_branch == "" then null else $pull_request_branch end)
  }'
