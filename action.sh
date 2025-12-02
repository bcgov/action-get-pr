#!/bin/bash

# Helper functions
function log_debug() {
  if [ "${INPUT_DEBUG}" == "true" ]; then
    echo "DEBUG: $1"
  fi
}

function get_pr_from_api() {
  local response
  response=$(curl -sL -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$1")

  if [ $? -ne 0 ]; then
    echo "API request failed" >&2
    return 1
  fi

  echo "$response"
}

function get_pr_from_git() {
  git log -1 --pretty=format:%s | grep -o '#[0-9]\+' | grep -o '[0-9]\+'
}

# Process variables and inputs
if [ -z "${GITHUB_EVENT_NAME}" ]; then
  echo "Event type: local run (no GitHub event)"
  pr=$(get_pr_from_git)
elif [ "${GITHUB_EVENT_NAME}" == 'pull_request' ]
then
  echo "Event type: pull request"
  pr=${GITHUB_EVENT_NUMBER}
elif [ "${GITHUB_EVENT_NAME}" == 'merge_group' ]
then
  echo "Event type: merge queue"
  if [ -n "${MERGE_GROUP_HEAD_REF}" ]; then
  pr=$(echo ${MERGE_GROUP_HEAD_REF} | grep -Eo "queue/main/pr-[0-9]+" | cut -d '-' -f2)
  fi
elif [ "${GITHUB_EVENT_NAME}" == 'push' ]
then
  echo "Event type: push"
  if [ -n "${GITHUB_EVENT_AFTER}" ] && [ -n "${GITHUB_REPOSITORY}" ]; then
    api_response=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_EVENT_AFTER}/pulls")
    pr=$(echo "$api_response" | jq .[0].number)
  fi
elif [ "${GITHUB_EVENT_NAME}" == 'release' ]
then
  echo "Event type: release"
  # Try API first if we have the repository info
  if [ -n "${GITHUB_REPOSITORY}" ]; then
    api_response=$(get_pr_from_api "https://api.github.com/search/issues?q=repo:${GITHUB_REPOSITORY}+is:pr+is:merged+sort:updated-desc")
  fi
  # Fallback to git history if API fails
  if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
    log_debug "API method failed, trying git history"
    pr=$(get_pr_from_git)
  fi

  # Final fallback message
  if [ -z "${pr}" ]
  then
    echo "No PR number found through API or git history"
    exit 1
  fi
elif [ "${GITHUB_EVENT_NAME}" == 'workflow_dispatch' ]
then
  echo "Event type: workflow_dispatch"
  # First try to get PR from current commit message
  pr=$(get_pr_from_git)
  
  # If that fails, try API to get PRs associated with current commit
  if [ -z "${pr}" ] && [ -n "${GITHUB_REPOSITORY}" ] && [ -n "${GITHUB_SHA}" ]; then
    log_debug "Commit message method failed, trying API"
    api_response=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls")
    pr=$(echo "$api_response" | jq -r '.[0].number // empty')
  fi
  
  # If still no PR, search recent commit history (last 10 commits)
  if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
    log_debug "API method failed, searching recent commit history"
    pr=$(git log --pretty=format:%s -10 | grep -o '#[0-9]\+' | grep -o '[0-9]\+' | head -1)
  fi
  
  # Final validation
  if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
    echo "No PR number found in commit message, API, or recent git history"
    exit 1
  fi
else
  echo "Event type: unknown or unexpected"
  exit 1
fi

# Debug output
log_debug "Event: ${GITHUB_EVENT_NAME}"
log_debug "SHA: ${GITHUB_SHA}"
log_debug "Found PR: ${pr}"

# Validate PR number
if [[ ! "${pr}" =~ ^[0-9]+$ ]]; then
  echo "PR number format incorrect: ${pr}"
  exit 1
fi

# Output PR number
echo "Summary ---"
echo -e "\tPR: ${pr}"

# Only write to GITHUB_OUTPUT when running as a GitHub Action
if [ -n "${INPUT_TOKEN}" ]; then
  echo "pr=${pr}" >> $GITHUB_OUTPUT
fi
