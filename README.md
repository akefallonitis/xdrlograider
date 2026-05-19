# XdrLogRaider

[![release](https://github.com/akefallonitis/xdrlograider/actions/workflows/release.yml/badge.svg)](https://github.com/akefallonitis/xdrlograider/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/akefallonitis/xdrlograider?include_prereleases)](https://github.com/akefallonitis/xdrlograider/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Microsoft Sentinel data connector for Defender XDR portal-internal telemetry (`/apiproxy/`).

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fgithub.com%2Fakefallonitis%2Fxdrlograider%2Freleases%2Flatest%2Fdownload%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fgithub.com%2Fakefallonitis%2Fxdrlograider%2Freleases%2Flatest%2Fdownload%2FcreateUiDefinition.json)

<!-- ITER11 HIGH6 · Button URL switched from main-branch raw to releases/latest/download.
     Operators get the LATEST RELEASED ARM template, not unreleased main-branch HEAD.
     Each release uploads cosign-signed mainTemplate.json + createUiDefinition.json as assets. -->


**Status**: v0.1.0 · Defender ACTIVE (519 endpoints · 19 per-sub-area DCRs) · TOTP + Passkey · 4 portals warm-up-scaffolded for v0.3.0 active polling · Sentinel content roadmap'd for v0.2.0+. Artefacts cosign-signed (keyless OIDC) · SBOM (SPDX) ships with every release.

## What this does

Harvests the `security.microsoft.com/apiproxy/*` surface (Action Center · Attack Simulator · Endpoint Devices · Exposure Management · Identity · Multi-Tenant · Secure Score · Threat Analytics · Vulnerability Management · etc.) that Microsoft does not publicly document. Ingests typed rows into Log Analytics tables `Defender_<SubArea>_CL` with operator-queryable `ProjectedData` primary surface + `RawJson` companion. Heartbeat row in `XdrConnectorHealth_CL` powers the Sentinel data-connector card (4 KQL connectivity criteria).

Tables surface in **both** the legacy Azure portal Sentinel UI **and** the new unified Microsoft Defender XDR portal (Sentinel-in-Defender · July 2025+) · same KQL works in both. Azure portal Sentinel retires **March 31, 2027** per Microsoft's unified security operations roadmap — your queries will continue to work.

## What this is NOT (binding disclaimers)

- ❌ **NOT a Microsoft-supported product**. The `/apiproxy/` surface is portal-internal · **no Microsoft SLA** · breaking changes possible without notice. Operator owns the risk.
- ❌ **NOT a replacement for Microsoft Defender XDR public APIs** (Advanced Hunting · Incidents · Streaming) · use those for what they officially cover. This connector targets the ~65% telemetry gap.
- ❌ **NOT a Graph-API connector** (uses cookie + bearer portal flows · NOT Graph data plane).
- ❌ **NOT a bypass tool** — uses operator-authorised service-account credentials; Conditional Access applies normally.
- ❌ **NOT a read/write tool** — connector is strict-read-only · POST/PATCH/DELETE endpoints classified `ProbeMode='Excluded'` at runtime (never called). 86 read-only POST telemetry endpoints catalogued for v0.2.0 with explicit BodyTemplate.

## Prerequisites

- Azure subscription with a Sentinel-enabled Log Analytics workspace
- Service account in your Entra tenant (dedicated · MFA via TOTP or Passkey)
- Role assignments on the SA: **Security Reader** + **Microsoft Defender Analyst** (read-only)
- **Conditional Access exemption** from interactive-MFA / device-compliance for the SA (unattended TOTP/Passkey IS the MFA factor · audit this exemption quarterly per your security policy)
- Deploying identity: **Contributor + User Access Administrator** on the connector resource group (OR Contributor only · run `tools/Grant-Post-Deploy-Rbac.ps1` post-deploy)

## Roadmap context (Azure platform updates to be aware of)

- **Y1 Linux Consumption** retires Sept 30, 2028 · v0.1.0 ships on Y1 (default) · v0.2.0 will add Flex Consumption (`FC1`) parameter option
- **Azure portal Sentinel UI** retires Mar 31, 2027 · use **Sentinel-in-Defender XDR portal** going forward · same KQL · same DCRs · same tables

## Quick start (5 steps)

1. Click **Deploy to Azure** above
2. Fill the Marketplace blade: project prefix · select Sentinel workspace · SA UPN + password + TOTP seed (or Passkey PEM)
3. (Optional) Change Function App plan SKU (default: Y1 Consumption) or release tag (default: `latest` · pin to `v0.1.0` for reproducibility)
4. Click **Create** · ARM provisions in ~3 min · FA cold-start ~2 min (identity-based storage adds 30-60s) · first heartbeat row ~5-10 min
5. Verify: `pwsh tools/Verify-Deploy.ps1 -ResourceGroup <rg>` (7 control-plane checks) + `pwsh tools/Smoke-E2E.ps1 -ResourceGroup <rg>` (AC-1..AC-10)

## Verifying release integrity

Every release artefact is cosign-signed (keyless OIDC) and listed in `SHA256SUMS.txt` (itself signed). The verifier chain:

```bash
# 1. Verify the SHA256SUMS file is authentic (cosign-signed)
cosign verify-blob \
  --certificate SHA256SUMS.txt.pem \
  --signature SHA256SUMS.txt.sig \
  --certificate-identity-regexp '^https://github\.com/akefallonitis/xdrlograider/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  SHA256SUMS.txt

# 2. Verify every artefact matches its checksum
sha256sum -c SHA256SUMS.txt
```

SBOM (SPDX format) at `sbom.spdx.json`. Solution V3 marketplace zip at `XdrLogRaider-1.0.0.zip`.

## Reporting issues

[Open an issue](https://github.com/akefallonitis/xdrlograider/issues) with `Smoke-E2E.ps1` output + App Insights logs + redacted response samples.

## License

MIT — see [LICENSE](LICENSE).
