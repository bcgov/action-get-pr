const fs = require('fs');

async function main() {
  const debug = process.env.INPUT_DEBUG === 'true';
  const token = process.env.INPUT_GITHUB_TOKEN || process.env.GITHUB_TOKEN;
  const eventName = process.env.GITHUB_EVENT_NAME;
  const repository = process.env.GITHUB_REPOSITORY;
  const eventAfter = process.env.GITHUB_EVENT_AFTER;
  const sha = process.env.GITHUB_SHA;
  const eventNumber = process.env.GITHUB_EVENT_NUMBER;
  const mergeGroupHeadRef = process.env.MERGE_GROUP_HEAD_REF;

  function logDebug(msg) {
    if (debug) console.log(`DEBUG: ${msg}`);
  }

  logDebug(`Event: ${eventName}`);

  let pr = '';

  if (eventName === 'pull_request') {
    console.log('Event type: pull request');
    pr = eventNumber;
  } else if (eventName === 'merge_group') {
    console.log('Event type: merge queue');
    if (mergeGroupHeadRef) {
      // Format: queue/<branch>/pr-<number>
      const match = mergeGroupHeadRef.match(/^queue\/[^\/]+\/pr-(\d+)/);
      if (match) pr = match[1];
    }
  } else if (eventName === 'push' || eventName === 'release' || eventName === 'workflow_dispatch') {
    console.log(`Event type: ${eventName}`);
    const commitSha = eventName === 'push' ? eventAfter : sha;
    
    if (commitSha && repository) {
      const url = `https://api.github.com/repos/${repository}/commits/${commitSha}/pulls`;
      let attempt = 1;
      const maxAttempts = 3;
      let sleepMs = 2000;

      while (attempt <= maxAttempts) {
        logDebug(`Fetching PR from API (attempt ${attempt}/${maxAttempts})...`);
        try {
          const controller = new AbortController();
          const timeoutId = setTimeout(() => controller.abort(), 10000); // 10s timeout

          const res = await fetch(url, {
            headers: {
              'Accept': 'application/vnd.github+json',
              'Authorization': `Bearer ${token}`,
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'action-get-pr-node'
            },
            signal: controller.signal
          });
          clearTimeout(timeoutId);

          logDebug(`API HTTP status: ${res.status}`);
          if (res.status === 200) {
            const body = await res.json();
            if (body && body[0] && body[0].number) {
              pr = String(body[0].number);
              break;
            } else {
              logDebug('API returned 200 but no associated pull request was found (indexing lag).');
            }
          } else {
            const bodyText = await res.text();
            console.error(`WARNING: API request failed with HTTP ${res.status}. Response: ${bodyText}`);
          }
        } catch (err) {
          console.error(`WARNING: Fetch failed (network issue or timeout): ${err.message}`);
        }

        if (attempt < maxAttempts) {
          logDebug(`Sleeping ${sleepMs}ms before next attempt...`);
          await new Promise(resolve => setTimeout(resolve, sleepMs));
          sleepMs *= 2; // Exponential backoff
        }
        attempt++;
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
  if (outputPath && token) {
    fs.appendFileSync(outputPath, `pr=${pr}\n`);
  }
}

main().catch(err => {
  console.error(`Fatal error: ${err.message}`);
  process.exit(1);
});
