<!-- Badges -->
[![Issues](https://img.shields.io/github/issues/bcgov/action-get-pr)](/../../issues)
[![Pull Requests](https://img.shields.io/github/issues-pr/bcgov/action-get-pr)](/../../pulls)
[![MIT License](https://img.shields.io/github/license/bcgov/action-get-pr.svg)](/LICENSE)
[![Lifecycle](https://img.shields.io/badge/Lifecycle-Experimental-339999)](https://github.com/bcgov/repomountie/blob/master/doc/lifecycle-badges.md)

# Get PR Number - Merges and Queues

PR numbers are easy to come by in PRs, but passing those same numbers to merge queues and PR-backed merges can get tricky. This action makes that convenient in the following cases:
* PR merge queues
* Merged PR workflows
* PRs themselves (just for consistency)
* Release events (finds the most recently merged PR)

# Usage

The build will return a PR number as output.
