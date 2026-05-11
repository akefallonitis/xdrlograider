# v0.2.0 Microsoft Sentinel Solution Gallery PR Submission Checklist

> **Goal**: submit XdrLogRaider as a formal Microsoft Sentinel Solution Gallery entry under `Solutions/XdrLogRaider/` in [Azure/Azure-Sentinel](https://github.com/Azure/Azure-Sentinel).
>
> **Status**: prepared post-v0.2.0 multi-portal expansion stable. Single multi-portal solution package (Defender + Entra + Purview + Intune + Power Platform + M365 Admin + SharePoint + Teams + Security Copilot).
>
> **Outcome**: formal Content Hub linkage; Sentinel UI shows Workbooks count + Analytics rules templates count + Hunting queries count + Data connectors (replaces current "Workbooks: --" / "Rules: 0" widget gap on community-deployed solutions).

## Pre-submission requirements

### Repo structure

```
Azure-Sentinel/
└── Solutions/
    └── XdrLogRaider/
        ├── Data/
        │   ├── Solution_XdrLogRaider.json   # mainTemplate.json
        │   └── createUiDefinition.json
        ├── Workbooks/
        │   └── *.json (8+ files; per portal)
        ├── Analytic Rules/
        │   └── *.yaml (21+ files; per portal)
        ├── Hunting Queries/
        │   └── *.yaml (12+ files; per portal)
        ├── Parsers/
        │   └── *.kql (4+ files)
        ├── Data Connectors/
        │   └── XdrLogRaider_DataConnector.json
        ├── Package/
        │   ├── createUiDefinition.json
        │   ├── mainTemplate.json
        │   └── ContentPackages.csv (auto-generated)
        ├── ReleaseNotes.md
        ├── README.md
        └── SolutionMetadata.json
```

### SolutionMetadata.json template

```json
{
  "publisherId": "akefallonitis",
  "offerId": "xdrlograider",
  "firstPublishDate": "2026-MM-DD",
  "providers": ["Microsoft Sentinel"],
  "categories": {
    "domains": ["Security - Threat Protection"],
    "verticals": []
  },
  "support": {
    "tier": "Community",
    "name": "XdrLogRaider Community",
    "link": "https://github.com/akefallonitis/xdrlograider/issues"
  }
}
```

## Content checklist (per Solution Gallery PR template)

### Documentation
- ☐ `ReleaseNotes.md` — per-version changelog (v0.1.0 GA + v0.1.0.x patches + v0.2.0 multi-portal expansion)
- ☐ `README.md` — operator-facing overview + Deploy-to-Azure button + prerequisites + scope + license
- ☐ Solution-level `Description.md` (top-level summary)
- ☐ Solution-level `Support.md` (community support model)

### Templates
- ☐ `Data/Solution_XdrLogRaider.json` — full mainTemplate.json (cosign-signed; ARM-TTK PASS)
- ☐ `Data/createUiDefinition.json` — wizard UI (cosign-signed; ARM-TTK PASS)
- ☐ All ARM expressions use `[parameters('...')]` not hardcoded values
- ☐ `[concat()]` used correctly; no string-concat anti-patterns
- ☐ All resources use `apiVersion` from latest stable

### Sentinel content
- ☐ All workbooks valid JSON; passes `tools/Validate-WorkbookSchema.ps1`
- ☐ All analytic rules valid YAML; ship `enabled: false` per Sentinel best practice; `entityMappings` populated from canonical entity cols (Architecture J)
- ☐ All hunting queries valid YAML; runtime-verified against fixtures
- ☐ All parsers valid KQL; deployed as workspace functions

### CI/CD validation
- ☐ ARM-TTK: 0 errors (run `tools/Run-ArmTtk.ps1`)
- ☐ Solution-validation workflow GREEN (`.github/workflows/validate-solution.yml`)
- ☐ Content-pack-build workflow GREEN — produces `xdrlograider-solution-X.Y.Z.zip`
- ☐ Cosign-signed release artifacts × 6 (function-app.zip + mainTemplate + createUiDefinition + sentinelContent + solution.zip + SBOM)

### Cosign verification examples (in README.md)

```bash
# Install cosign
brew install cosign  # macOS
# OR download from https://github.com/sigstore/cosign/releases

# Verify each release artifact (Sigstore keyless, GitHub Actions OIDC)
cosign verify-blob \
  --certificate-identity-regexp "^https://github.com/akefallonitis/xdrlograider/.github/workflows/release.yml" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --bundle function-app.zip.bundle \
  function-app.zip

# Repeat for: mainTemplate.json / createUiDefinition.json / sentinelContent.json /
#             xdrlograider-solution-0.2.0.zip / xdrlograider-sbom-0.2.0.spdx.json
```

## PR submission steps

### 1. Fork [Azure/Azure-Sentinel](https://github.com/Azure/Azure-Sentinel)

```bash
gh repo fork Azure/Azure-Sentinel --clone --remote
cd Azure-Sentinel
git checkout -b solutions/xdrlograider-v0.2.0
```

### 2. Copy XdrLogRaider artifacts

```bash
mkdir -p Solutions/XdrLogRaider/{Data,Workbooks,"Analytic Rules","Hunting Queries",Parsers,"Data Connectors",Package}
# Copy from xdrlograider repo:
cp ../xdrlograider/deploy/compiled/mainTemplate.json Solutions/XdrLogRaider/Data/Solution_XdrLogRaider.json
cp ../xdrlograider/deploy/compiled/createUiDefinition.json Solutions/XdrLogRaider/Data/
cp ../xdrlograider/sentinel/workbooks/*.json Solutions/XdrLogRaider/Workbooks/
cp ../xdrlograider/sentinel/analytic-rules/*.yaml Solutions/XdrLogRaider/"Analytic Rules"/
cp ../xdrlograider/sentinel/hunting-queries/*.yaml Solutions/XdrLogRaider/"Hunting Queries"/
cp ../xdrlograider/sentinel/parsers/*.kql Solutions/XdrLogRaider/Parsers/
cp ../xdrlograider/deploy/solution/Data\ Connectors/XdrLogRaider_DataConnector.json Solutions/XdrLogRaider/"Data Connectors"/
```

### 3. Run Microsoft Sentinel solution build script

```bash
# Per Microsoft Solution Gallery contributor docs
.scripts/buildSolution.ps1 -SolutionName XdrLogRaider
# Generates Package/ contents + ContentPackages.csv
```

### 4. Run validation

```bash
# ARM-TTK
.scripts/runArmTtk.sh Solutions/XdrLogRaider

# Solution package validation
.scripts/validateSolutionPackage.ps1 -SolutionPath Solutions/XdrLogRaider
```

### 5. Create PR

```bash
git add Solutions/XdrLogRaider/
git commit -m "Add XdrLogRaider v0.2.0 multi-portal solution

- 9 portals: Defender + Entra + Purview + Intune + Power Platform + M365 Admin + SharePoint + Teams + Security Copilot
- ~120 (Defender expansion) + 519 (Entra) + 238 (Purview) + 50+ (Intune) + 488 (Power Platform) + 504 (M365 Admin) + 35+98 (SharePoint+Teams) + 32 (Security Copilot) = ~2,084 portal endpoints across 10+ functional categories
- 4-function Durable orchestration topology (Connector-Heartbeat / Xdr-Refresh / Xdr-PollOrchestrator / Xdr-PollStream)
- Multi-tenant FA scoping (per-tenant secret namespace + per-tenant XdrTierState)
- Cosign-signed release artifacts (Sigstore keyless via GitHub Actions OIDC)
- Architecture J Schema Unification (canonical Sentinel Entity Type cols for cross-portal correlation)

Repo: https://github.com/akefallonitis/xdrlograider
License: MIT"

gh pr create --title "Add XdrLogRaider v0.2.0 multi-portal solution" \
  --body-file .github/PR-TEMPLATE-XdrLogRaider.md
```

### 6. Microsoft review cycle

- Microsoft Sentinel team reviews ARM-TTK + content quality + branding compliance
- Iterate on review feedback
- Microsoft team merges + publishes to Sentinel UI Content Hub

## Post-publish verification

- [ ] XdrLogRaider visible in Sentinel UI → Content Hub → search
- [ ] Workbooks count > 0 (was -- pre-publish)
- [ ] Analytic rules templates count > 0 (was 0 pre-publish)
- [ ] Hunting queries count > 0
- [ ] Data connectors visible (with sample queries auto-derived from manifest)
- [ ] Operator clicks Install → solution deploys cleanly

## Update cadence

- Each new v0.2.0.x patch: amend PR + Microsoft re-reviews
- Major versions (v0.3.0+): NEW PR per Solutions Gallery convention

## References

- [Azure/Azure-Sentinel contributor docs](https://github.com/Azure/Azure-Sentinel/blob/master/.github/SOLUTION_CONTRIBUTING.md)
- [Microsoft Sentinel Solution Gallery overview](https://learn.microsoft.com/en-us/azure/sentinel/sentinel-solutions-catalog)
- [ARM-TTK rules](https://github.com/Azure/arm-ttk)
- [Sigstore cosign keyless verification](https://docs.sigstore.dev/cosign/verifying)
- XdrLogRaider release.yml: [`.github/workflows/release.yml`](../.github/workflows/release.yml) (cosign signing + SBOM generation)
