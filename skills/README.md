# InnoNetwork agent skill

The canonical skill lives in [`innonetwork/`](innonetwork/SKILL.md), alongside
its library. It targets the published **6.1.0** release at
`79ff9f535a0a15ad8b52ce49cb5a4b1ea1dfec16`. It covers Core JSON APIs,
buffered encoded requests, operation ownership, auth, retry, and resource limits.

## Install a standalone skill

Copy the **complete** `skills/innonetwork` directory from a selected source
commit into one of these project-local locations. Compare an existing
installation before replacing it, and preserve the references, scripts, assets,
and MIT notice together.

| Host | Destination | Explicit invocation |
| --- | --- | --- |
| Codex | `.agents/skills/innonetwork/` | `$innonetwork` |
| Claude Code | `.claude/skills/innonetwork/` | `/innonetwork` |

Start a new session after installation. The description also allows implicit
selection for relevant InnoNetwork tasks, subject to host settings. Example:

> Use InnoNetwork 6.1.0 to implement a named user endpoint and test its request
> with the public mock transport. Check this project's resolved dependency first.

Adding the Swift package does **not** install the AI skill. The
[central plugin repository](https://github.com/InnoSquadCorp/innosquad-agent-skills)
packages exact library-owned skill snapshots for both hosts; its local pilot
is not a public marketplace release. A plugin installation namespaces invocation
as `$innosquad:innonetwork` or `/innosquad:innonetwork`.

## Maintain and validate

Change API guidance and its consumer fixture here. Central distribution records
this skill's source commit/tree separately from the supported Swift release.
An instruction update does not require a new Swift library release.

```bash
python3 skills/innonetwork/scripts/validate_consumer.py --scratch-path /tmp/innonetwork-skill-validation
```

The helper requires macOS with Swift/Xcode and Python 3, plus network access on
a cold cache. It copies the example outside the skill, verifies all six remote
pins and clean checkouts, checks the active graph including SwiftPM's optional
SwiftSyntax prebuilt selection, and runs strict-concurrency tests. Logs and
`evidence.json` remain under the selected scratch directory.

Read [validation.md](validation.md) for the tested scope and limitations. Host
installation and AI selection/generation evidence belongs in the central plugin
repository. A consumer passing locally is not proof of AI behavior or device
and real-service acceptance.
