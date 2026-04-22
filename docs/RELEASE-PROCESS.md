# Release process

How v1.x releases are cut.

## Pre-release checklist

- [ ] All offline tests pass (`unit`, `validate`) on ubuntu + windows + macos via CI
- [ ] Integration tests pass on test tenant (manual workflow-dispatch)
- [ ] CHANGELOG.md `[Unreleased]` section populated
- [ ] Documentation up-to-date (no TODO markers)
- [ ] Bicep source matches compiled `deploy/compiled/mainTemplate.json`
- [ ] No new portal endpoints reported as broken in recent 30 days

## Cut release

1. Update `CHANGELOG.md`: rename `[Unreleased]` → `[X.Y.Z]` with date
2. Commit: `git commit -m "chore: prepare vX.Y.Z"`
3. Tag: `git tag vX.Y.Z && git push origin vX.Y.Z`
4. `.github/workflows/release.yml` fires automatically:
   - Re-runs gate tests
   - Compiles Bicep to ARM JSON
   - Builds `function-app.zip`
   - Creates GitHub Release with attached assets
   - Updates Deploy-to-Azure URL in README to pin to the tag

## Post-release

1. Verify Release page shows all three assets: `function-app.zip`, `mainTemplate.json`, `createUiDefinition.json`
2. Test Deploy-to-Azure button on a clean subscription
3. Run post-deploy helper + verify self-test passes
4. Update Discussions with release notes + feedback request

## Hotfixes

For urgent security fixes:

1. Branch off the latest tag: `git checkout -b hotfix/vX.Y.Z+1 vX.Y.Z`
2. Fix + commit
3. Merge back to `main` via PR
4. Tag `vX.Y.Z+1` from `main`
5. CI releases the patch

## Versioning policy

Semver. Specifically:

- **Major (X.0.0)**: breaking changes (schema, auth, deployment topology)
- **Minor (X.Y.0)**: new streams, new workbooks, new auth paths (backwards-compatible)
- **Patch (X.Y.Z)**: bug fixes, security patches, docs
