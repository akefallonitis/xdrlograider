# XdrLogRaider

Microsoft Sentinel data connector for **Microsoft Defender XDR portal-internal telemetry** — the `security.microsoft.com` apiproxy surface Microsoft does not publish a public Graph or MDE API for. 493 read endpoints across 18 nodoc sub-areas → 19 DCRs → 18 `Defender_<Sub>_CL` workspace tables + 1 `XdrConnectorHealth_CL` operational table.

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FcreateUiDefinition.json)

Pre-built signed artifacts on the [Releases](https://github.com/akefallonitis/xdrlograider/releases) page (cosign keyless OIDC).

## Verify

```powershell
pwsh ./tools/Verify-Deploy.ps1 -ResourceGroup <rg>
```

14-phase markdown report at `tests/results/verify-deploy-<utc>.md`. ConnectorHeartbeat lands the card on **Connected** within 10 minutes of first fire.
