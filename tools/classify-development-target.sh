#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 UPSTREAM PROMOTED_JSON CANDIDATE_JSON [EVIDENCE_JSON]" >&2
  exit 2
}

[[ $# -ge 3 && $# -le 4 ]] || usage
upstream=$1
promoted=$2
candidate=$3
evidence=${4:-}
[[ $upstream == zig || $upstream == turso ]] || usage

for path in "$promoted" "$candidate"; do
  jq -e '.schema == 1' "$path" >/dev/null
done

if [[ $upstream == zig ]]; then
  old_revision=$(jq -er '.zig.version' "$promoted")
  new_revision=$(jq -er '.zig.version' "$candidate")
  old_family=${old_revision%%-dev.*}
  old_family=${old_family%.*}
  new_family=${new_revision%%-dev.*}
  new_family=${new_family%.*}
else
  old_revision=$(jq -er '.turso.commit' "$promoted")
  new_revision=$(jq -er '.turso.commit' "$candidate")
  old_version=$(jq -er '.turso.declared_version' "$promoted")
  new_version=$(jq -er '.turso.declared_version' "$candidate")
  old_family=$(awk -F. '{ print $1 "." $2 }' <<<"$old_version")
  new_family=$(awk -F. '{ print $1 "." $2 }' <<<"$new_version")
fi

classification=no-change
reasons=()

if [[ -n $evidence ]] && jq -e '.infrastructure == "failed"' "$evidence" >/dev/null; then
  classification=infrastructure-failure
  reasons+=("candidate verification infrastructure failed")
elif [[ -n $evidence ]] && jq -e '.stable_release_detected == true' "$evidence" >/dev/null; then
  classification=release-event
  reasons+=("a new stable upstream release was detected")
elif [[ $old_revision != "$new_revision" ]]; then
  classification=routine
  reasons+=("candidate revision differs from the promoted revision")

  if [[ $old_family != "$new_family" ]]; then
    classification=maintenance-required
    reasons+=("development version family changed from $old_family to $new_family")
  fi

  if [[ -z $evidence ]]; then
    classification=maintenance-required
    reasons+=("no verification evidence was supplied")
  else
    required_unchanged=(format abi behavior_audit features native_dependencies licenses)
    required_passed=(compile tests)
    for key in "${required_unchanged[@]}"; do
      value=$(jq -r --arg key "$key" '.[$key] // "missing"' "$evidence")
      if [[ $value != unchanged ]]; then
        classification=maintenance-required
        reasons+=("$key is $value")
      fi
    done
    for key in "${required_passed[@]}"; do
      value=$(jq -r --arg key "$key" '.[$key] // "missing"' "$evidence")
      if [[ $value != passed ]]; then
        classification=maintenance-required
        reasons+=("$key is $value")
      fi
    done
  fi
fi

if ((${#reasons[@]} == 0)); then
  reasons+=("candidate equals the promoted revision")
fi

reasons_json=$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -s .)
jq -n \
  --arg classification "$classification" \
  --arg upstream "$upstream" \
  --arg old_revision "$old_revision" \
  --arg new_revision "$new_revision" \
  --arg dedupe_key "$upstream:$new_revision" \
  --argjson reasons "$reasons_json" \
  '{
    classification: $classification,
    upstream: $upstream,
    old_revision: $old_revision,
    new_revision: $new_revision,
    dedupe_key: $dedupe_key,
    reasons: $reasons
  }'
