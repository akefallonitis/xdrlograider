# References

Every source cited in the codebase or docs, with context and accessed date.

## Community research (portal-API patterns)

### [nodoc — Nathan McNulty](https://nodoc.nathanmcnulty.com/)
Accessed 2026-04-22. Documents 594 undocumented portal operations across 18 Microsoft portals (Defender XDR, Intune, Purview, Entra, M365 Admin, Exchange, Teams, SharePoint, etc.). Foundation for our endpoint catalogue. Authors describe APIs as "undocumented, unsupported by Microsoft, and may change without notice".

### [XDRInternals — MSCloudInternals (Fabian Bader, Nathan McNulty)](https://github.com/MSCloudInternals/XDRInternals)
Accessed 2026-04-22. 100+ cmdlets for programmatic Defender XDR portal access. Reference implementation of the `sccauth` cookie chain, MFA handling, and passkey-assertion flow in PowerShell. Demonstrates feasibility of the undocumented-API approach. We built our `Xdr.Portal.Auth` module from scratch using publicly documented specs rather than porting this code, but architectural patterns are similar.

### [DefenderHarvester — Olaf Hartong](https://github.com/olafhartong/DefenderHarvester)
Accessed 2026-04-22. Go-based tool that historically extracted MDE telemetry from portal endpoints. README notes Microsoft has hardened the APIs it used ("essentially kills this tool for now"). The `main.go` source confirms 12 endpoint paths (machineactions, customdetections, suppressionrules, machinegroups, dataexportsettings, advanced features, alert service settings, timeline, etc.) — we verified these are still accessible as of 2026-04 with the updated auth chain. Serves as evidence that per-endpoint breakage is the operational risk, not auth chain itself.

### [FalconForce MDE Internals series — Olaf Hartong](https://medium.com/falconforce/tagged/microsoft-defender)
Accessed 2026-04-22. Multi-part deep dive into the MDE sensor (SenseIR / MsSense), ETW providers, telemetry pipeline, and TamperProtection. Especially the 0x05 post on sensitive actions telemetry informs what compliance-relevant configuration state exists in the portal but not public APIs.

### [Lifting the veil: MDE under the hood — FIRST 2022 paper](https://www.first.org/resources/papers/conf2022/MDEInternals-FIRST.pdf)
Accessed 2026-04-22. Peer-reviewed paper on MDE sensor architecture. Provides independent corroboration of the sensor/portal boundary and confirms which data lives where.

## Security research

### [Avoid Entra Conditional Access via sccauth — CloudBrothers, April 7 2026](https://cloudbrothers.info/en/avoid-entra-conditional-access-sccauth/)
Accessed 2026-04-22. Disclosed April 2026. The `sccauth` cookie from security.microsoft.com acts as an alternative token broker bypassing Conditional Access. MSRC classified moderate-severity, "does not meet Microsoft's bar for immediate servicing" — as of publication the pattern remains available. Key endpoint: `/api/Auth/getToken` can mint access tokens for Graph, ARM, Security Center API, Log Analytics, Purview, and Threat Intelligence Portal. This is the auth chain foundation for all internal-portal connectors. We treat it as a risk (see risk register in the project plan and `docs/RUNBOOK.md`).

### [RFC 6238 — TOTP: Time-Based One-Time Password Algorithm](https://datatracker.ietf.org/doc/html/rfc6238)
Specifies HMAC-SHA1 truncation for time-based codes. Used directly in `Xdr.Portal.Auth` TOTP implementation. Test vectors in Appendix B used for unit tests.

### [W3C WebAuthn Level 2](https://www.w3.org/TR/webauthn-2/)
Specifies the Web Authentication API, including the CBOR attestation / assertion formats used by FIDO2 passkeys. Our passkey signing implementation builds the client-data-JSON and performs ECDSA-P256 signing per § 7.2 "Verifying an Authentication Assertion".

### [NIST SP 800-63B — Digital Identity Guidelines, Authentication & Lifecycle Management](https://pages.nist.gov/800-63-3/sp800-63b.html)
AAL2/AAL3 authentication requirements. Informs our choice of passkey (AAL3-compatible) as the "strict tenant" option over TOTP (AAL2).

## Microsoft official — Sentinel deployment + architecture

### [Create a codeless connector for Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/create-codeless-connector)
Confirms CCF supports only four auth types (Basic, APIKey, OAuth2 authz-code/client-credentials, JWT) — none can express cookie-chain + TOTP + passkey. Justifies why we use Function App + Logs Ingestion API instead.

### [RestApiPoller data connector reference](https://learn.microsoft.com/en-us/azure/sentinel/data-connector-connection-rules-reference)
Full auth-type reference. Verified CCF cannot dynamically promote response headers to request headers, ruling it out for XSRF rotation handling.

### [Logs Ingestion API in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview)
The API our Function App uses to send data to Log Analytics via DCE + DCR. Supports batching up to 1 MB per request.

### [Data Collection Rules (DCR) overview](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview)
DCR structure, stream declarations, transform KQL, destination tables. Our `schemas/dcr-streams.json` matches this spec.

### [Data Collection Endpoints](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-endpoint-overview)
DCE ingestion URL format and auth. Our DCE is deployed via Bicep; the Function App's managed identity authenticates to it.

### [Azure Functions PowerShell best practices](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell)
Cold-start optimization, `profile.ps1` usage, module-preload pattern, managed dependencies. We follow the per-function isolation guidance: one timer function per logical unit for observability, shared in-memory state via `$global:` variables populated in `profile.ps1`.

### [Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
Pattern for CI-to-Azure authentication without stored secrets. **XdrLogRaider v1.0 does NOT use this** — CI runs only offline tests, and online tests run from your laptop with your own `Connect-AzAccount` session (no SP). Reference retained for anyone who forks and wires up their own online CI pipeline.

### [Azure-Sentinel repo / Solutions directory](https://github.com/Azure/Azure-Sentinel/tree/master/Solutions)
Reference for community-submitted solution layout. Our `deploy/solution/` folder mirrors this structure for future Content Hub submission (see `docs/SENTINEL-SOLUTION-SUBMISSION.md`).

### [Microsoft Sentinel Solution packaging tool](https://github.com/Azure/Azure-Sentinel/tree/master/Tools/Create-Azure-Sentinel-Solution)
The tool used to package Sentinel Solutions into a Content Hub-compatible ZIP. Our `package-solution.yml` workflow invokes it.

### [Microsoft Security Exposure Management (XSPM)](https://learn.microsoft.com/en-us/security-exposure-management/)
Background on XSPM attack paths, chokepoints, initiatives, security baselines — concepts used in our P3 Exposure streams.

### [Defender XDR API overview](https://learn.microsoft.com/en-us/defender-xdr/api-overview)
What IS in public APIs — explicit scope for what our connector deliberately does NOT duplicate.

## Testing tooling

### [Pester 5+](https://pester.dev/)
PowerShell test framework. Used for unit, integration, and e2e tests. 5.5+ required for advanced mocking features.

### [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
PowerShell lint. Runs in CI on every PR. Errors block merge, warnings visible but non-blocking.

### [Kusto.Language NuGet package (Microsoft.Azure.Kusto.Language)](https://www.nuget.org/packages/Microsoft.Azure.Kusto.Language/)
Official KQL parser. We use it in CI to validate all KQL files (parsers, analytic rules, hunting queries) without a live workspace.

### [ARM-TTK (Template Toolkit)](https://github.com/Azure/arm-ttk)
Official ARM template best-practices tester. Used in CI to validate `mainTemplate.json` before every release.

### [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
ARM template DSL. Our source infrastructure is Bicep; we compile to ARM JSON for the Deploy button.

## Standards + specifications

### [Contributor Covenant 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct.html)
Our [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) is based on this.

### [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
Our `CHANGELOG.md` follows this format.

### [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)
We tag releases `vMAJOR.MINOR.PATCH`.

### [Conventional Commits](https://www.conventionalcommits.org/)
Our commit messages follow `type(scope): description`.

## How to add a reference

When adding a new source to this file:

1. Cite the full title and author/org
2. Link to a stable URL (prefer permalinks over "current version")
3. Add accessed date
4. Explain **how the source is used in this project** — concretely, not abstractly
5. If the source is a specification (RFC, W3C), note which section is relied upon

## Last updated

2026-04-22 — initial M0 reference set.
