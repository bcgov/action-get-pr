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
  } else if (eventName === 'issues') {
    console.log('Event type: issues');
    const issueTitle = payload.issue && payload.issue.title;

    // Load ignore rules dynamically from rules.yml (dependency-free parser)
    let ignoreTitles = [];
    const rulesPath = 'rules.yml';
    if (fs.existsSync(rulesPath)) {
      try {
        const content = fs.readFileSync(rulesPath, 'utf8');
        const lines = content.split('\n');
        for (const line of lines) {
          const match = line.match(/^\s*-\s*["']?([^"'\r\n]+)["']?/);
          if (match) {
            ignoreTitles.push(match[1].trim());
          }
        }
      } catch (e) {
        logDebug(`Failed to parse rules.yml: ${e.message}`);
      }
    }

    // Default fallbacks if rules.yml is missing or empty
    if (ignoreTitles.length === 0) {
      ignoreTitles = ['Dependency Dashboard', 'ZAP Security Report'];
    }

    if (issueTitle) {
      for (const title of ignoreTitles) {
        if (issueTitle.includes(title)) {
          console.log(`Ignore rule matched for "${title}". Skipping gracefully.`);
          process.exit(0);
        }
      }
    }
    console.error('Error: Standard issues do not have pull request numbers.');
    process.exit(1);
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
      // TIER 1: Fetch associated pull requests directly from GitHub API (requires pull-requests:read)
      if (token) {
        const url = `https://api.github.com/repos/${repository}/commits/${commitSha}/pulls`;
        let attempt = 1;
        const maxAttempts = 3;
        let sleepMs = 2000;

        while (attempt <= maxAttempts) {
          logDebug(`Tier 1: Fetching PR from API (attempt ${attempt}/${maxAttempts})...`);
          let timeoutId;
          try {
            const controller = new AbortController();
            timeoutId = setTimeout(() => controller.abort(), 10000); // 10s timeout

            const res = await fetch(url, {
              headers: {
                'Accept': 'application/vnd.github+json',
                'Authorization': `Bearer ${token}`,
                'X-GitHub-Api-Version': '2022-11-28',
                'User-Agent': 'action-get-pr-node'
              },
              signal: controller.signal
            });

            logDebug(`Tier 1: API HTTP status: ${res.status}`);
            if (res.status === 200) {
              const body = await res.json();
              if (body && body[0] && body[0].number) {
                pr = String(body[0].number);
                break;
              } else {
                logDebug('Tier 1: API returned 200 but no associated pull request was found (indexing lag).');
              }
            } else if (res.status === 401 || res.status === 403) {
              logDebug(`Tier 1: API request returned HTTP ${res.status} (Restricted permissions). Soft-falling back to Tier 2...`);
              break; // Quietly break to fall back to Tier 2
            } else {
              logDebug(`Tier 1: API returned unexpected status: ${res.status}`);
              break;
            }
          } catch (err) {
            logDebug(`Tier 1: Fetch failed (attempt ${attempt}): ${err.message}`);
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
      }

      // TIER 2: Fetch commit details from GitHub API (only requires default contents:read)
      if (!pr && token) {
        logDebug('Tier 2: Attempting commit details API fallback...');
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
          
          logDebug(`Tier 2: API HTTP status: ${res.status}`);
          if (res.status === 200) {
            const commitData = await res.json();
            const msg = commitData.commit && commitData.commit.message;
            if (msg) {
              logDebug(`Tier 2: Commit message: ${msg}`);
              const firstLine = msg.split('\n')[0];
              const squashMatch = firstLine.match(/\(#(\d+)\)$/);
              const standardMatch = firstLine.match(/Merge pull request #(\d+)/i);
              const generalMatch = msg.match(/PR #(\d+)/i);

              if (squashMatch) {
                pr = squashMatch[1];
                logDebug(`Tier 2: Found PR #${pr} in squash commit message.`);
              } else if (standardMatch) {
                pr = standardMatch[1];
                logDebug(`Tier 2: Found PR #${pr} in merge commit message.`);
              } else if (generalMatch) {
                pr = generalMatch[1];
                logDebug(`Tier 2: Found PR #${pr} in commit message.`);
              }
            }
          }
        } catch (e) {
          logDebug(`Tier 2: Commit details fallback failed: ${e.message}`);
        }
      }

      // TIER 3: Offline Fallback (Local git log)
      if (!pr && fs.existsSync('.git')) {
        logDebug('Tier 3: Attempting local git history fallback...');
        try {
          const { execSync } = require('child_process');
          const commitsToSearch = eventName === 'workflow_dispatch' ? 10 : 1;
          const log = execSync(`git log --pretty=format:%s -${commitsToSearch}`, { encoding: 'utf8' });
          const lines = log.split('\n');
          for (const line of lines) {
            const trimmed = line.trim();
            const squashMatch = trimmed.match(/\(#(\d+)\)$/);
            const standardMatch = trimmed.match(/Merge pull request #(\d+)/i);
            const generalMatch = trimmed.match(/PR #(\d+)/i);

            if (squashMatch) {
              pr = squashMatch[1];
              logDebug(`Tier 3: Found PR #${pr} in local squash commit message.`);
              break;
            } else if (standardMatch) {
              pr = standardMatch[1];
              logDebug(`Tier 3: Found PR #${pr} in local merge commit message.`);
              break;
            } else if (generalMatch) {
              pr = generalMatch[1];
              logDebug(`Tier 3: Found PR #${pr} in local commit message.`);
              break;
            }
          }
        } catch (e) {
          logDebug(`Tier 3: Local git history fallback failed: ${e.message}`);
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
