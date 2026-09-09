# auditor_repo_scanner

Bot-contract checklist runner for the auditor pack (design:
`bot-army-starter/vagrant-test/AUDITOR_PACK_DESIGN.md`). First of the
original 6 auditor bots to be implemented — the rest are still template
scaffolds.

## Subjects

- `auditor.repo.scan` — request/reply. Payload: `{"repo": "<path-or-name>"}`.
  Bare names resolve against `AUDITOR_REPO_ROOT` (default `/repos`).
  Optional `catalog_path` adds a catalog-entry check. Replies with the full
  results map: checks, summary, verdict (`healthy|degraded|failing`), score.
- `auditor.repo.ping` — liveness probe.

## Receipts (conformance-bot pattern)

- Every completed scan publishes an sre audit receipt on
  `sre.audit.repo_scanner` (event `sre.repo.scan.completed`) — regardless of
  verdict.
- Verdict `failing` (required checks failed) additionally publishes an sre
  incident envelope on `events.sre.log.incident`.

## Checks

Required (fail): `config/prod.exs`, committed `mix.lock`, release block with
`<name>_bot`, Makefile with `test:` + `publish-release:`, semver version,
git repo with origin. Warnings: git hooks, README, `runtime.exs`, real tests,
clean tree, no committed artifacts, no runtime `Mix.` calls, catalog entry.

## Triggering

From inside the staging VM:

    nats -s nats://localhost:55622 request auditor.repo.scan '{"repo":"bot_army_sre"}'

or via the stage script:

    bash scripts/05-stage-env.sh scan bot_army_sre
