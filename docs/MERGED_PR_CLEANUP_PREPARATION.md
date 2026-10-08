# Merged-PR cleanup: executable preparation

`.github/workflows/merged-pr-cleanup.yml` and `merged_pr_cleanup.py` are proposed in this draft PR. The trusted default-branch handler applies cleanup by default after integration. Publishing this draft does not manually cancel an existing run.

The trusted `pull_request_target: closed` workflow requires a merged PR in this exact repository. It checks out the immutable trusted workflow SHA, never PR code, and loads only the reviewed executor, selector and allowlist. Unset/empty `INNO_MERGED_PR_CLEANUP` or `enabled` selects the cleanup job with `actions: write`. `disabled` or unknown values select the separate read-only inspection job with `actions: read`. The workflow normalizes its write intent and explicitly passes `--apply`; the executor CLI itself remains read-only without that flag. Both have `pull-requests: read` and `contents: read`, with no code-writing permission.

The executor verifies repository identity, default-branch workflow context and checkout SHA. It freshly fetches the merged PR and complete bounded paginated run inventory before writes. It selects only unfinished `pull_request` runs in the PR lifetime, with a sole native association to this repository and PR and an exact matching association/run head. Previous heads of this same PR are included. Missing associations or ambiguous identity fail closed. A rerun explicitly started after merge is preserved when its attempt/start-time evidence establishes that fact.

Main push, merge_group, manual/workflow_run events, release/publication/docs-publish, protected stateful workflows, other PRs, completed runs, and same-SHA other events remain excluded. The repository-specific `ci-cleanup-workflows.json` is an exact trusted allowlist.

Immediately before each cancellation the executor re-fetches the PR and run/attempt. Changed or completed candidates are skipped. A 409 is reconciled against fresh completed status; 403 is not retried. HTTP redirects are forbidden and response sizes are bounded. The only write endpoint is the selected run's `/cancel` endpoint.

GitHub's cancel API is run-ID based, not attempt-conditional. A rerun can begin between the final GET and POST; the API provides no atomic exclusion. Thus protection against simultaneous reruns is best-effort, not an absolute guarantee. This limit is exercised by mocked race tests and must be accepted during rollout review.

Hosted validation must exercise this trusted handler/allowlist, the explicit disabled read-only path, and a disposable non-release PR with real native API associations. Local mocked pagination, provenance, attempts, fork, forbidden-event, permission and race tests are not hosted cancellation evidence. No token is persisted in the prepared artifacts.

Run inventory is scoped to each allowlisted workflow and the authoritative PR head branch, within the PR creation-to-merge interval. This retains earlier heads on that branch while avoiding unrelated repository-wide run counts. Every returned run still needs its native exact PR/repository association and a fresh pre-cancel recheck; branch-name equality alone never authorizes cancellation. A capped or changing scoped inventory fails before any write.
