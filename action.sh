#!/bin/bash

# Helper functions
function log_debug() {
  [ "${INPUT_DEBUG}" == "true" ] && echo "DEBUG: $1"
}

function get_pr_from_api() {
  local url=$1
  local response=""
  local attempt=1
  local max_attempts=3
  local sleep_seconds=2

  while [ $attempt -le $max_attempts ]; do
    log_debug "Fetching PR from API (attempt ${attempt}/${max_attempts})...."
    
    response=$(curl -sL -w "\n%{http_code}" -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${INPUT_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url" 2>/dev/null)
    
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
      echo "WARNING: curl failed with exit code ${exit_code}" >&2
    fi

    # Split response into body and http_code
    local http_code
    http_code=$(echo "$response" | tail -n 1)
    local body
    body=$(echo "$response" | sed '$d')

    log_debug "API HTTP status: ${http_code}"
    
    if [ "${http_code}" -eq 200 ]; then
      local pr_number
      pr_number=$(echo "$body" | jq -r '.[0].number // empty' 2>/dev/null)
      if [ -n "${pr_number}" ] && [ "${pr_number}" != "null" ]; then
        echo "$body"
        return 0
      else
        log_debug "API returned 200 but no associated pull request was found (indexing lag)."
      fi
    else
      echo "WARNING: API request failed with HTTP ${http_code}. Response: ${body}" >&2
    fi

    if [ $attempt -lt $max_attempts ]; then
      log_debug "Sleeping ${sleep_seconds}s before next attempt..."
      sleep $sleep_seconds
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

function get_pr_from_api_response() {
  local response=$1
  echo "$response" | jq -r '.[0].number // empty' 2>/dev/null
}

function get_pr_from_git() {
  local commits=${1:-1}
  local squash_pattern='\(#([0-9]+)\)$'
  local merge_pattern='Merge pull request #([0-9]+)'

  # Check if we are inside a valid git repository
  local git_err
  git_err=$(git rev-parse --is-inside-work-tree 2>&1)
  if [ $? -ne 0 ]; then
    echo "WARNING: git command failed. Not in a valid git repository or directory ownership issue: ${git_err}" >&2
    return 1
  fi

  local log_output
  log_output=$(git log --pretty=format:%s -${commits} 2>&1)
  if [ $? -ne 0 ]; then
    echo "WARNING: git log failed: ${log_output}" >&2
    return 1
  fi

  echo "$log_output" | while read -r line; do
    local trimmed
    trimmed=$(echo "$line" | sed 's/[[:space:]]*$//')
    if [[ $trimmed =~ $squash_pattern ]]; then
      echo "${BASH_REMATCH[1]}"
      break
    elif [[ $trimmed =~ $merge_pattern ]]; then
      echo "${BASH_REMATCH[1]}"
      break
    fi
  done
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
    if [ -z "${pr}" ] || [ "${pr}" = "null" ]; then
      log_debug "API method failed, trying git history"
      pr=$(get_pr_from_git)
    fi
    ;;
  "release")
    echo "Event type: release"
    # Find PR from the release's commit SHA (same approach as push events)
    if [ -n "${GITHUB_SHA}" ] && [ -n "${GITHUB_REPOSITORY}" ]; then
      api_response=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls")
      pr=$(get_pr_from_api_response "$api_response")
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
