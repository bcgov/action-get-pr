#!/bin/bash

# Helper functions
function log_debug() {
  [ "${INPUT_DEBUG}" == "true" ] && echo "DEBUG: $1"
}

function get_pr_from_api() {
  local url=$1
  curl -sL -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url" 2>/dev/null
}

function get_pr_from_api_response() {
  local response=$1
  echo "$response" | jq -r '.[0].number // empty' 2>/dev/null
}

function get_pr_from_git() {
  local commits=${1:-1}
  git log --pretty=format:%s -${commits} 2>/dev/null | grep -o '#[0-9]\+' | grep -o '[0-9]\+' | head -1
}

# Process variables and inputs
pr=""
case "${GITHUB_EVENT_NAME}" in
  "")
    echo "Event type: local run (no GitHub event)"
    pr=$(get_pr_from_git)
    ;;
  "pull_request")
    echo "Event type: pull request"
    pr=${GITHUB_EVENT_NUMBER}
    ;;
  "merge_group")
    echo "Event type: merge queue"
    [ -n "${MERGE_GROUP_HEAD_REF}" ] && \
      pr=$(echo ${MERGE_GROUP_HEAD_REF} | grep -Eo "queue/main/pr-[0-9]+" | cut -d '-' -f2)
    ;;
  "push"|"release"|"workflow_dispatch")
    echo "Event type: ${GITHUB_EVENT_NAME}"
    # Use GITHUB_SHA for workflow_dispatch/release, GITHUB_EVENT_AFTER for push
    local commit_sha="${GITHUB_SHA}"
    [ "${GITHUB_EVENT_NAME}" = "push" ] && commit_sha="${GITHUB_EVENT_AFTER}"
    
    if [ -n "${GITHUB_REPOSITORY}" ] && [ -n "${commit_sha}" ]; then
      api_response=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${commit_sha}/pulls")
      pr=$(get_pr_from_api_response "$api_response")
    fi
    if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
      echo "No PR number found for commit ${commit_sha}. All commits on default branch should come from PRs."
      exit 1
    fi
    ;;
  *)
    echo "Event type: unknown or unexpected"
    exit 1
    ;;
esac

# Debug output
log_debug "Event: ${GITHUB_EVENT_NAME}"
log_debug "SHA: ${GITHUB_SHA}"
log_debug "Found PR: ${pr}"

# Validate PR number
[[ ! "${pr}" =~ ^[0-9]+$ ]] && {
  echo "PR number format incorrect: ${pr}"
  exit 1
}

# Output PR number
echo "Summary ---"
echo -e "\tPR: ${pr}"

# Only write to GITHUB_OUTPUT when running as a GitHub Action
[ -n "${INPUT_TOKEN}" ] && echo "pr=${pr}" >> $GITHUB_OUTPUT
