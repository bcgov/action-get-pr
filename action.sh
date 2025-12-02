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
    if [ -n "${MERGE_GROUP_HEAD_REF}" ]; then
      # MERGE_GROUP_HEAD_REF format: queue/<branch>/pr-<number>
      # Anchor to start, match any branch name, capture PR number only
      pr=$(echo "${MERGE_GROUP_HEAD_REF}" | sed -n 's|^queue/[^/]*/pr-\([0-9]\+\).*|\1|p')
    fi
    ;;
  "push")
    echo "Event type: push"
    if [ -n "${GITHUB_EVENT_AFTER}" ] && [ -n "${GITHUB_REPOSITORY}" ]; then
      api_response=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_EVENT_AFTER}/pulls")
      pr=$(get_pr_from_api_response "$api_response")
    fi
    ;;
  "release")
    echo "Event type: release"
    if [ -n "${GITHUB_REPOSITORY}" ]; then
      api_response=$(get_pr_from_api "https://api.github.com/search/issues?q=repo:${GITHUB_REPOSITORY}+is:pr+is:merged")
      # Sort by merged_at timestamp (most recent first) to ensure we get the latest merge
      pr=$(echo "$api_response" | jq -r '.items | sort_by(.pull_request.merged_at) | reverse | .[0].number // empty' 2>/dev/null)
    fi
    if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
      log_debug "API method failed, trying git history"
      pr=$(get_pr_from_git)
    fi
    if [ -z "${pr}" ]; then
      echo "No PR number found through API or git history"
      exit 1
    fi
    ;;
  "workflow_dispatch")
    echo "Event type: workflow_dispatch"
    pr=$(get_pr_from_git)
    if [ -z "${pr}" ] && [ -n "${GITHUB_REPOSITORY}" ] && [ -n "${GITHUB_SHA}" ]; then
      log_debug "Commit message method failed, trying API"
      api_response=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls")
      pr=$(get_pr_from_api_response "$api_response")
    fi
    if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
      log_debug "API method failed, searching recent commit history"
      pr=$(get_pr_from_git 10)
    fi
    if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
      echo "No PR number found in commit message, API, or recent git history"
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
