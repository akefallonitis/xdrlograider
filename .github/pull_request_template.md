## Why

<!-- The motivation: what problem does this solve, what feature does this add, or what bug does this fix? Link to issues. -->

## What

<!-- Concise list of changes. One bullet per logical change. File:line references welcome. -->

-
-
-

## Testing

<!-- How was this verified? Specifically:
  * Offline tests run (`pwsh tools/Pre-Commit-Check.ps1` or equivalent)
  * Live tests / Az probes (read-only OK; cite KQL output)
  * Manual operator path walk-through
-->

-

## Breaking changes

<!-- YES / NO. If yes, describe operator-visible impact + upgrade steps. -->

NO.

## Linked issues

<!-- Closes #N / Refs #N / Part of #N -->

---

### Reviewer checklist

- [ ] All required CI status checks pass (gitleaks, PSScriptAnalyzer, Unit tests (ubuntu-latest), Static validate, Summary)
- [ ] Pester coverage gate hasn't regressed below 75% threshold
- [ ] Sentinel content recompile gate passes (no drift between sentinel/* sources and deploy/compiled/sentinelContent.json)
- [ ] If this touches `deploy/compiled/mainTemplate.json`: ARM what-if shows expected diff only
- [ ] If this changes operator surface: README / CHANGELOG / RUNBOOK / TROUBLESHOOTING updated
- [ ] No AI/Claude/Anthropic attribution in commits or files
- [ ] CODEOWNERS approval obtained
