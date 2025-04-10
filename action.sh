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
if [ ${GITHUB_EVENT_NAME} == 'pull_request' ]
then
  echo "Event type: pull request"
  pr=${GITHUB_EVENT_NUMBER}
elif [ ${GITHUB_EVENT_NAME} == 'merge_group' ]
then
  echo "Event type: merge queue"
  pr=$(echo ${MERGE_GROUP_HEAD_REF} | grep -Eo "queue/main/pr-[0-9]+" | cut -d '-' -f2)
elif [ ${GITHUB_EVENT_NAME} == 'push' ]
then
  echo "Event type: push"
  api_response=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_EVENT_AFTER}/pulls")
  pr=$(echo "$api_response" | jq .[0].number)

  if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
    log_debug "API method failed, trying git history"
    pr=$(get_pr_from_git)
  fi
elif [ ${GITHUB_EVENT_NAME} == 'release' ]
then
  echo "Event type: release"
  # Try API first
  api_response=$(get_pr_from_api "https://api.github.com/search/issues?q=repo:${GITHUB_REPOSITORY}+is:pr+is:merged+sort:updated-desc")
  pr=$(echo "$api_response" | jq .items[0].number)

  # Fallback to git history if API fails
  if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
    log_debug "API method failed, trying git history"
    pr=$(get_pr_from_git)
  fi

  # Final fallback message
  if [ -z "${pr}" ]
  then
    echo "No PR number found through API or git history"
    pr=""
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
echo "pr=${pr}" >> $GITHUB_OUTPUT
