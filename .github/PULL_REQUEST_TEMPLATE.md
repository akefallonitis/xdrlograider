<!--
Thanks for contributing! Please fill every section so reviewers can merge confidently.
-->

## Summary

<!-- What does this PR do? One or two sentences. -->

## Type

- [ ] `feat` — new feature or stream
- [ ] `fix` — bug fix
- [ ] `docs` — documentation only
- [ ] `test` — adding or updating tests
- [ ] `chore` — maintenance, tooling, CI

## Changes

<!-- Bullet list of concrete changes. Include file paths. -->

-
-
-

## Testing

- [ ] `./tests/Run-Tests.ps1 -Category unit` passes locally
- [ ] `./tests/Run-Tests.ps1 -Category validate` passes locally
- [ ] New code has unit tests covering positive + negative paths
- [ ] `./tests/Run-Tests.ps1 -Category integration` passes (if applicable, live test tenant used)
- [ ] End-to-end deploy test passes (if infrastructure changed)

## Checklist

- [ ] I read [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] Commit messages follow conventional-commit style (`feat:`, `fix:`, etc.)
- [ ] PSScriptAnalyzer passes (no new warnings/errors introduced)
- [ ] Inline comment-based help added for new public functions
- [ ] Corresponding `docs/*.md` page updated
- [ ] `CHANGELOG.md` updated under `[Unreleased]`
- [ ] If adding a new stream: followed the [Adding a new telemetry stream](../CONTRIBUTING.md#adding-a-new-telemetry-stream) checklist
- [ ] If changing auth: tested both auth methods (passkey + credentials+TOTP)
- [ ] No secrets, tokens, or tenant-specific data in this PR
- [ ] No references to unrelated projects introduced

## Related issues

<!-- Closes #123, relates to #456 -->

## Screenshots (if UI changes)

<!-- Workbook renderings, analytic rule previews, etc. -->

## Notes for reviewers

<!-- Anything reviewers should focus on? Known trade-offs? -->
