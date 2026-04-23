# Changelog

All notable changes to this project will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Docs + manifest updated to reflect 52 streams across 7 tiers (was "55 / 8 tiers" — the dropped P4 tier residue). Rebuilds `sentinelContent.json` deterministically.
- CI matrix reduced to Ubuntu-only (production parity). Windows + macOS runners removed; can be added back via workflow_dispatch if a platform-specific regression ever surfaces.

## [1.0.0] — TBD

First production release.

### Features
- **52 portal-only telemetry streams** across 7 compliance tiers (P0 config · P1 pipeline · P2 governance · P3 exposure · P5 identity · P6 audit · P7 metadata).
- **Two unattended auto-refreshing authentication methods**: Credentials+TOTP (RFC 6238) and Software Passkey (WebAuthn ECDSA-P256). DirectCookies mode available for test/lab use.
- **Manifest-driven client module**: single `endpoints.manifest.psd1` catalogues every stream; one `Invoke-MDEEndpoint` dispatcher; one `Invoke-MDETierPoll` per-tier loop. No per-endpoint wrappers.
- **9 Azure Functions** (all timer-triggered): heartbeat, auth-self-test, and 7 per-tier pollers.
- **Sentinel content auto-deployed** via nested ARM: 6 KQL drift parsers, 6 workbooks, 15 analytic rules, 10 hunting queries (37 resources total).
- **One-click Deploy-to-Azure** via `mainTemplate.json` + `createUiDefinition.json`. Bicep sources included for custom forks.
- **Content Hub solution package** produced by `tools/Build-SentinelSolution.ps1`.

### Scope
- Read-only: every manifest entry is an HTTP GET. No action-triggering endpoints.
- Research basis: XDRInternals, DefenderHarvester (nodoc), CloudBrothers April-2026 sccauth disclosure.

### Verification
- 296 offline Pester tests · 100% public-function coverage across 3 modules.
- 0 PSScriptAnalyzer errors.
- 3-OS local test run; CI runs Ubuntu-only for cost + speed (production parity).

[Unreleased]: https://github.com/akefallonitis/xdrlograider/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/akefallonitis/xdrlograider/releases/tag/v1.0.0
