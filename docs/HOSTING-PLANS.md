# Hosting plans — operator decision aid

> Iter 13.15 introduces the `hostingPlan` deploy parameter as a 3-tier enum.
> This document is the operator decision aid: how to choose, what each tier
> costs, what each tier secures, and how to migrate between them.

## TL;DR — pick one

| Profile | Choose | Why |
|---|---|---|
| Lab / dev / proof-of-concept / cost-constrained | `consumption-y1` (DEFAULT) | Free tier on Azure Functions; ~$0–10/month for typical workload. Documented residual shared-key risk on the content share (see [SECURITY-NOTES.md](SECURITY-NOTES.md)) |
| Production / business-critical | `flex-fc1` | ~$10–30/month. Full Managed Identity (no shared keys anywhere). Closed privilege-escalation chain. **Recommended default for production deploys.** |
| Regulated / compliance / financial / healthcare / government | `premium-ep1` | ~$140–300/month. Full MI + always-warm (no cold start) + private-endpoint capable. Required for environments under CIS / SOC2 / PCI / HIPAA / FedRAMP frameworks |

Switch via the `hostingPlan` ARM template parameter. Re-deploys are idempotent and preserve all `connectorCheckpoints` data.

---

## Side-by-side comparison

| Property | `consumption-y1` | `flex-fc1` | `premium-ep1` |
|---|---|---|---|
| Azure Functions plan | Linux Consumption Y1 | Flex Consumption FC1 | Elastic Premium EP1 |
| Monthly cost (typical workload) | $0–10 | $10–30 | $140–300 |
| Cold start | ~3–8 s on first poll after idle | ~1–3 s | None (always-warm) |
| Memory ceiling | 1.5 GB | 4 GB (default; up to 16 GB) | 3.5 GB (EP1; up to 14 GB on EP3) |
| `AzureWebJobsStorage` Managed Identity | ✅ MI (`__accountName` form) | ✅ MI | ✅ MI |
| `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` Managed Identity | ❌ Shared key (Microsoft platform limit on Y1 Linux) | ✅ MI | ✅ MI |
| `allowSharedKeyAccess: false` on Storage | ❌ Cannot set (content share needs key) | ✅ Can set | ✅ Can set |
| Private endpoint support | Partial (some services) | Full | Full |
| Always-on | No | No (default `AlwaysReady=0`) | Yes |
| First deploy region availability | All Azure regions | Most Azure regions (FC1 GA) | All Azure regions |
| Marketplace v1.2 default | (operator opt-in) | **DEFAULT** | (operator opt-up) |

---

## Threat model: why hostingPlan matters for security

The `hostingPlan` choice gates a documented privilege-escalation chain.

### The chain (active when `hostingPlan = consumption-y1`)

```
Attacker compromises any identity with Microsoft.Web/sites/config/list/action
  ↓ (FA Contributor role — much lower bar than Storage Owner / RG Owner)
Reads the WEBSITE_CONTENTAZUREFILECONNECTIONSTRING app setting from Azure Portal
  ↓ (this app setting contains the Storage Account Key on Y1)
Extracts the Storage Account Key (shared-key form)
  ↓ (the key bypasses ALL Azure RBAC on the storage account)
Writes attacker code to the Files share that hosts the Function App runtime
  ↓ (next FA cold start mounts the Files share and loads attacker code)
Function host loads attacker PowerShell, executing as SAMI
  ↓
SAMI has Key Vault Secrets User role → reads `mde-portal-auth` secret
  ↓
Attacker has UPN + password + TOTP shared secret for the MDE service account
  ↓
Full Microsoft Defender XDR tenant compromise
```

This is **CWE-269 privilege escalation, severity HIGH**. The CIS Microsoft Azure Foundations Benchmark control 4.4 ("Storage account shared-key access disabled") exists precisely to break this chain.

### Why we ship Y1 as the default anyway

1. **Adoption parity**: every Microsoft-published Sentinel connector ships Y1 + shared key by default (M365 Defender, MISP, GitHub Audit Logs, etc.). Operators expect Y1 as the entry point.
2. **Cost parity**: Y1 is free for typical workloads. Forcing FC1 by default would add $10–30/month with no operator opt-in.
3. **Documented choice**: this document + the `hostingPlan` parameter description make the trade-off **visible**. Operators who care can opt up; operators who don't aren't surprised by an unexpected bill.
4. **Mitigations available**: operators on Y1 can mitigate by tightly scoping FA Contributor RBAC. The escalation chain only fires if an attacker already has FA Contributor.
5. **v1.2 Marketplace default flip**: when xdrlograider goes to Microsoft Marketplace, the default flips to `flex-fc1` (Marketplace baseline = no shared keys).

### `flex-fc1` and `premium-ep1` close the chain

Both tiers use Managed Identity for **both** `AzureWebJobsStorage` AND `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`. The Storage Account Key is no longer in any app setting. `allowSharedKeyAccess: false` is set on the storage account — even if an attacker somehow got the key from Azure ARM (`Microsoft.Storage/storageAccounts/listKeys/action`), the data plane would reject it. The chain terminates at step 2.

---

## SAMI role matrix per tier

The Function App's System-Assigned Managed Identity gets these roles, scoped to specific resources:

| Role | Scope | `consumption-y1` | `flex-fc1` | `premium-ep1` |
|---|---|---|---|---|
| Key Vault Secrets User | KV | ✓ | ✓ | ✓ |
| Storage Table Data Contributor | Storage | ✓ | ✓ | ✓ |
| Monitoring Metrics Publisher | DCR | ✓ | ✓ | ✓ |
| Storage Blob Data Owner | Storage | ✓ | ✓ | ✓ |
| Storage Queue Data Contributor | Storage | ✓ | ✓ | ✓ |
| Storage File Data SMB Share Contributor | Storage | — (Y1 uses shared key for files; this role would be unused) | ✓ | ✓ |

All scoped to specific resource IDs. **Zero subscription-level or resource-group-level grants.** Locked by `tests/arm/LeastPrivilege.Tests.ps1`.

---

## How to migrate between hosting plans

Re-deploy the ARM template with the new `hostingPlan` value.

```powershell
# Move from consumption-y1 → flex-fc1
$params = @{
    hostingPlan = 'flex-fc1'
    # ... all other parameters preserved
}
New-AzResourceGroupDeployment -ResourceGroupName 'xdrlograider' `
    -TemplateFile './deploy/compiled/mainTemplate.json' `
    -TemplateParameterObject $params
```

**What changes**: serverfarm SKU, env-var forms (MI vs shared key), SAMI roles (one new role added: Storage File SMB Share Contributor), `allowSharedKeyAccess` flips false.

**What's preserved**: `connectorCheckpoints` table state (gate flag + 45 stream timestamps), Key Vault secrets, all Sentinel content, App Insights history, DCE/DCR.

**Downtime**: the Function App restarts during plan migration (~30 s). Polling resumes on next timer fire.

---

## Comparison to Microsoft's own connectors

| Connector | Plan choice exposed? | Network choice exposed? | Auth choice exposed? |
|---|---|---|---|
| Microsoft 365 Defender (MS) | ❌ Y1 only | ❌ Public only | ❌ App-reg only |
| MISP solution (MS template) | ❌ Y1 only | ❌ Public only | ❌ Key only |
| GitHub Audit Logs (MS) | ❌ Y1 only | ❌ Public only | ❌ PAT only |
| Defender for IoT (MS) | ❌ EP1 hardcoded | ✅ Private capable | ❌ Single |
| **xdrlograider (this)** | ✅ **3-tier choice** | ✅ **Operator opt-in** | ✅ **TOTP or Passkey** |

This level of operator agency is genuinely novel for the Sentinel connector ecosystem. Operators in $5/month dev labs and operators in regulated finance/healthcare/government both get a sensible deployment path with informed defaults and documented trade-offs.

---

## See also

- [SECURITY-NOTES.md](SECURITY-NOTES.md) — full threat model + per-plan residual risk
- [UNATTENDED-AUTH.md](UNATTENDED-AUTH.md) — how the auth chain works for both `credentials_totp` and `passkey`
- The `hostingPlan` parameter description in `deploy/main.bicep` — inline summary
