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
    log_debug "Fetching PR from API (attempt ${attempt}/${max_attempts})..."
    
    # Connection timeout 5s, total time 10s
    response=$(curl -sL -w "\n%{http_code}" \
      --connect-timeout 5 \
      --max-time 10 \
      -H "Accept: application/vnd.github+json" \
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
        echo "${pr_number}"
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
      # Exponential backoff
      sleep_seconds=$((sleep_seconds * 2))
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

# Process variables and inputs
pr=""
case "${GITHUB_EVENT_NAME}" in
  "pull_request")
    echo "Event type: pull request"
    pr=${GITHUB_EVENT_NUMBER}
    ;;
  "merge_group")
    echo "Event type: merge queue"
    if [ -n "${MERGE_GROUP_HEAD_REF}" ]; then
      pr=$(echo "${MERGE_GROUP_HEAD_REF}" | sed -n 's|^queue/[^/]*/pr-\([0-9]\+\).*|\1|p')
    fi
    ;;
  "push")
    echo "Event type: push"
    if [ -n "${GITHUB_EVENT_AFTER}" ] && [ -n "${GITHUB_REPOSITORY}" ]; then
      pr=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_EVENT_AFTER}/pulls")
    fi
    ;;
  "release"|"workflow_dispatch")
    echo "Event type: ${GITHUB_EVENT_NAME}"
    if [ -n "${GITHUB_SHA}" ] && [ -n "${GITHUB_REPOSITORY}" ]; then
      pr=$(get_pr_from_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls")
    fi
    ;;
  *)
    echo "Event type: unknown or unexpected event '${GITHUB_EVENT_NAME}'"
    exit 1
    ;;
esac

# Validate PR number
[[ ! "${pr}" =~ ^[0-9]+$ ]] && {
  echo "Error: No valid PR number could be resolved for this event."
  exit 1
}

# Output PR number
echo "Summary ---"
echo -e "\tPR: ${pr}"

[ -n "${INPUT_TOKEN}" ] && echo "pr=${pr}" >> $GITHUB_OUTPUT
