#!/usr/bin/env bash
set -euo pipefail

state=${FAKE_GH_STATE:?}
label_log=${FAKE_GH_LABEL_LOG:?}
call_log=${FAKE_GH_CALL_LOG:?}

printf '%q ' "$@" >>"$call_log"
printf '\n' >>"$call_log"

resource=${1:-}
operation=${2:-}
shift 2 || true

case "$resource:$operation" in
  label:create)
    printf '%s\n' "${1:?}" >>"$label_log"
    ;;
  issue:list)
    jq_filter=
    while (($#)); do
      case $1 in
        --jq)
          jq_filter=${2:?}
          shift 2
          ;;
        *) shift ;;
      esac
    done
    jq -r "$jq_filter" "$state"
    ;;
  issue:create)
    title=
    body_file=
    labels=
    repository=
    while (($#)); do
      case $1 in
        --title) title=${2:?}; shift 2 ;;
        --body-file) body_file=${2:?}; shift 2 ;;
        --label) labels=${2:?}; shift 2 ;;
        --repo) repository=${2:?}; shift 2 ;;
        *) shift ;;
      esac
    done
    number=$(jq 'length + 1' "$state")
    body=$(<"$body_file")
    temporary=$(mktemp)
    jq \
      --argjson number "$number" \
      --arg title "$title" \
      --arg body "$body" \
      --arg labels "$labels" \
      '. + [{
        number: $number,
        title: $title,
        body: $body,
        labels: ($labels | split(","))
      }]' "$state" >"$temporary"
    mv "$temporary" "$state"
    printf 'https://github.com/%s/issues/%s\n' "$repository" "$number"
    ;;
  issue:edit)
    number=${1:?}
    shift
    title=
    body_file=
    labels=
    while (($#)); do
      case $1 in
        --title) title=${2:?}; shift 2 ;;
        --body-file) body_file=${2:?}; shift 2 ;;
        --add-label) labels=${2:?}; shift 2 ;;
        *) shift ;;
      esac
    done
    body=$(<"$body_file")
    temporary=$(mktemp)
    jq \
      --argjson number "$number" \
      --arg title "$title" \
      --arg body "$body" \
      --arg labels "$labels" \
      'map(
        if .number == $number then
          .title = $title |
          .body = $body |
          .labels = ((.labels + ($labels | split(","))) | unique)
        else . end
      )' "$state" >"$temporary"
    mv "$temporary" "$state"
    ;;
  *)
    echo "unsupported fake gh command: $resource $operation" >&2
    exit 1
    ;;
esac
