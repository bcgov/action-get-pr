const fs = require('fs');

async function main() {
  const debug = process.env.INPUT_DEBUG === 'true';
  const token = process.env.INPUT_GITHUB_TOKEN || process.env.GITHUB_TOKEN;
  const eventName = process.env.TEST_EVENT_NAME || process.env.GITHUB_EVENT_NAME;
  const repository = process.env.TEST_REPOSITORY || process.env.GITHUB_REPOSITORY;
  const sha = process.env.TEST_SHA || process.env.GITHUB_SHA;

  function logDebug(msg) {
    if (debug) console.log(`DEBUG: ${msg}`);
  }

  logDebug(`Event: ${eventName}`);

  // Load and parse event payload JSON natively if present
  let payload = {};
  const eventPath = process.env.TEST_EVENT_PATH || process.env.GITHUB_EVENT_PATH;
  if (eventPath && fs.existsSync(eventPath)) {
    try {
      payload = JSON.parse(fs.readFileSync(eventPath, 'utf8'));
      logDebug(`Loaded event payload file successfully.`);
    } catch (e) {
      console.error(`Error: Failed to parse event payload JSON from '${eventPath}': ${e.message}`);
      process.exit(1);
    }
  }

  let pr = '';

  if (eventName === 'pull_request') {
    console.log('Event type: pull request');
    // Extract pull request number from payload
    if (payload.pull_request && payload.pull_request.number) {
      pr = String(payload.pull_request.number);
    } else if (payload.number) {
      pr = String(payload.number);
    } else if (process.env.GITHUB_EVENT_NUMBER) {
      pr = process.env.GITHUB_EVENT_NUMBER;
    }
  } else if (eventName === 'merge_group') {
    console.log('Event type: merge queue');
    // Sourced natively from event payload
    let mergeGroupHeadRef = '';
    if (payload.merge_group && payload.merge_group.head_ref) {
      mergeGroupHeadRef = payload.merge_group.head_ref;
    } else if (process.env.MERGE_GROUP_HEAD_REF) {
      mergeGroupHeadRef = process.env.MERGE_GROUP_HEAD_REF;
    }

    if (mergeGroupHeadRef) {
      // Format: queue/<branch>/pr-<number>
      const match = mergeGroupHeadRef.match(/^queue\/[^\/]+\/pr-(\d+)/);
      if (match) pr = match[1];
    }
  } else if (eventName === 'push' || eventName === 'release' || eventName === 'workflow_dispatch') {
    console.log(`Event type: ${eventName}`);
    
    // Resolve commit SHA (will look up via REST API, falling back to message parsing)
    let commitSha = sha || '';
    if (eventName === 'push') {
      commitSha = process.env.TEST_EVENT_AFTER || payload.after || process.env.GITHUB_EVENT_AFTER || sha || '';
    }

    if (commitSha && repository) {
      if (!token) {
        console.error('Error: github_token input or GITHUB_TOKEN environment variable is required to fetch PR from API.');
        process.exit(1);
      }

      const url = `https://api.github.com/repos/${repository}/commits/${commitSha}/pulls`;
      let attempt = 1;
      const maxAttempts = 3;
      let sleepMs = 2000;

      while (attempt <= maxAttempts) {
        logDebug(`Fetching PR from API (attempt ${attempt}/${maxAttempts})...`);
        let timeoutId;
        try {
          const controller = new AbortController();
          timeoutId = setTimeout(() => controller.abort(), 10000); // 10s timeout

          // Execute fetch with custom headers and signal abort
          const res = await fetch(url, {
            headers: {
              'Accept': 'application/vnd.github+json',
              'Authorization': `Bearer ${token}`,
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'action-get-pr-node'
            },
            signal: controller.signal
          });

          logDebug(`API HTTP status: ${res.status}`);
          if (res.status === 200) {
            const body = await res.json();
            if (body && body[0] && body[0].number) {
              pr = String(body[0].number);
              break;
            } else {
              logDebug('API returned 200 but no associated pull request was found (indexing lag).');
            }
          } else if (res.status === 401 || res.status === 403) {
            console.error(`Error: API request failed with HTTP ${res.status} (Authentication/Permissions issue). Please verify inputs.github_token is configured with correct permissions.`);
            process.exit(1);
          } else if (res.status === 404) {
            console.error(`Error: API request failed with HTTP 404 (Not Found). Please verify GITHUB_REPOSITORY and GITHUB_SHA / GITHUB_EVENT_AFTER are correct.`);
            process.exit(1);
          } else {
            const bodyText = await res.text();
            console.error(`WARNING: API request failed with HTTP ${res.status}. Response: ${bodyText}`);
          }
        } catch (err) {
          console.error(`WARNING: Fetch failed (network issue or timeout): ${err.message}`);
        } finally {
          if (timeoutId) clearTimeout(timeoutId);
        }

        if (attempt < maxAttempts) {
          logDebug(`Sleeping ${sleepMs}ms before next attempt...`);
          await new Promise(resolve => setTimeout(resolve, sleepMs));
          sleepMs *= 2; // Exponential backoff
        }
        attempt++;
      }

      // API fallback: If direct pulls association is empty (e.g. indexing lag or direct release tags),
      // fetch commit details and parse the commit message for squash or standard merges.
      if (!pr) {
        logDebug('PR not found via direct pulls association. Attempting commit message parsing fallback...');
        try {
          const commitUrl = `https://api.github.com/repos/${repository}/commits/${commitSha}`;
          const res = await fetch(commitUrl, {
            headers: {
              'Accept': 'application/vnd.github+json',
              'Authorization': `Bearer ${token}`,
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'action-get-pr-node'
            }
          });
          if (res.status === 200) {
            const commitData = await res.json();
            const msg = commitData.commit && commitData.commit.message;
            if (msg) {
              logDebug(`Commit message: ${msg}`);
              const firstLine = msg.split('\n')[0];
              const squashMatch = firstLine.match(/\(#(\d+)\)$/);
              const standardMatch = firstLine.match(/Merge pull request #(\d+)/i);
              const generalMatch = msg.match(/PR #(\d+)/i);

              if (squashMatch) {
                pr = squashMatch[1];
                logDebug(`Found PR #${pr} in squash commit message.`);
              } else if (standardMatch) {
                pr = standardMatch[1];
                logDebug(`Found PR #${pr} in merge commit message.`);
              } else if (generalMatch) {
                pr = generalMatch[1];
                logDebug(`Found PR #${pr} in full commit message.`);
              }
            }
          }
        } catch (e) {
          logDebug(`Commit message fallback failed: ${e.message}`);
        }
      }
    }
  } else {
    console.error(`Event type: unknown or unexpected event '${eventName}'`);
    process.exit(1);
  }

  // Validate PR
  if (!/^\d+$/.test(pr)) {
    console.error('Error: No valid PR number could be resolved for this event.');
    process.exit(1);
  }

  console.log('Summary ---');
  console.log(`\tPR: ${pr}`);

  // Output to GITHUB_OUTPUT
  const outputPath = process.env.GITHUB_OUTPUT;
  if (outputPath) {
    fs.appendFileSync(outputPath, `pr=${pr}\n`);
  }
}

main().catch(err => {
  console.error(`Fatal error: ${err.message}`);
  process.exit(1);
});
