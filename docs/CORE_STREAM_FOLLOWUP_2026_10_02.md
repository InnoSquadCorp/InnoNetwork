# Core follow-up for Stream development

Originally developed on PR #132, this narrow upload fix was extracted onto
main at `2afe0a65fa1d255ebb02527b411614a2fb39c811` on 2026-10-05.
PR #132 and its encoded-request changes are not included. Stream consumers
must record the exact tested commit in their own lock after this branch rewrite.
This record does not authorize a Core release.

## Upload terminal ordering

The PR's remote TSAN run `36756997166` failed the upload retry completion
assertions. A terminal event can reach its observer before `UploadManager`
returns from publishing it. The observer starts another attempt on the same
logical task, then the old publisher removes runtime state by logical ID,
accidentally retiring the replacement attempt.

A package-only publication hook holds this boundary. The original algorithm
reproduces both network-failure and HTTP-503 variants: a second upload starts
while retirement is held, and the new completion is lost. Cancelling the
prospective retry also arrives too late. The same production file exists in
the inspected main baseline, so this is not attributed to Stream integration.
The retained before log includes the two bounded time-limit failures; those
are failing reproductions, never counted as validation passes.

The correction reserves one retry owner per logical task and waits for the
previous terminal transition. Cleanup precedes final event publication; the
transition closes after publication settles. Cancelling a waiting retry removes
only its waiter and creates no URLSession task. Network/status failures, normal
completion and cancellation share the same terminal transition ordering.

The regression covers both failure forms, retry success, waiting cancellation
and duplicate retry rejection. Existing upload/restoration/retention tests are
the normal controls. No public signature, dependency, workflow or performance
threshold changes are included.

## Validation and handoff

Historical validation below was performed on the original stacked commit
`91b4b417ca134d0f837f8e000846cd0478e7d439`, not on the rebased main candidate.
The original local evidence was retained in `.build/stream-followup/`:

- `swift test --no-parallel`: 2,040 registered tests, 2,036 ordinary passes and
  four explicitly skipped opt-in live tests (`core-final-tests.log`).
- `swift test --sanitize thread --no-parallel --filter Upload`: 53 upload tests
  and 39 Core upload-path tests passed (`core-final-upload-tsan.log`). This is
  focused TSAN coverage, not a new full-suite TSAN run.
- Formatting (552 files), document/API contracts (1,764 declarations) and
  strict Periphery completed successfully.
- The four-case regression is included in both normal and focused TSAN runs;
  `upload-terminal-before.log` retains the failing original-ordering control.

## Main extraction validation

The upload manager and existing upload test support at the original parent
`7957642bca41773bae12a5e201ed063d3e4ca08c` are byte-identical to the main
extraction base. Only this commit's runtime and regression-test delta is applied.
The changelog is reconciled into main's Unreleased section without importing
PR #132's entries. Workflow, dependency, and public API inventory files remain
unchanged from main.

The Linux VM can run formatting and repository contract checks; Apple-only
runtime tests and sanitizer validation are owned by this candidate's exact-head
GitHub CI. Historical local results above do not replace those checks.
