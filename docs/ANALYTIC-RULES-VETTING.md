# Analytic rules — vetting and tuning guide

> **Audience**: SOC operators planning to enable the analytic rules shipped with this connector. Each rule below has a short narrative covering what it detects, expected false-positive characteristics, environment-specific tuning recommendations, and operator decisions ("when to enable, when to leave disabled").
>
> **TL;DR**: 14 scheduled rules ship disabled. Vet each one against your tenant before enabling. Leave a rule disabled when its required telemetry is empty, when your tenant has well-established change-management noise that would dwarf real signal, or when an equivalent hunting query gives you better visibility.

This document complements [ANALYTIC-RULES.md](ANALYTIC-RULES.md), which is the catalog overview (rule-name + severity table + format), and [HUNTING-QUERIES.md](HUNTING-QUERIES.md) (analyst-driven hunts that don't fire alerts). Use this document for vetting and turn-on decisions.

---

## Overview

Fourteen Sentinel scheduled analytic rules are bundled with the connector. They surface drift on the tenant-configuration data this connector ingests — for example, "tamper protection just turned off", "a new data-export destination just appeared", "a new RBAC role assignment to an unusual account". Most rules drive off the per-tier drift parsers under [`sentinel/parsers/`](../sentinel/parsers/), so they only fire when one of the connector's polls actually observed a change.

Per Sentinel-Solutions best practice all rules ship as **Suggested** templates with `enabled: false`. Operators must:

1. Review the rule narrative below.
2. Confirm the required streams are ingesting and non-empty.
3. Decide whether to enable as-is, tune severity / threshold, or leave disabled.
4. Track the per-rule status in your tenant's runbook.

---

## Why rules ship disabled

Three reasons:

1. **False-positive minimization**. Many rules trigger on legitimate operator actions (a real change-management ticket adding a data-export destination). Without environment-specific tuning, the rule generates noise that drowns out real signal.
2. **Telemetry dependency**. Several rules depend on tenant-feature-gated streams (MDI, TVM, MTO, MCAS). When the underlying feature is not provisioned, the rule's required stream is empty and the rule never fires — but it would consume rule-count budget if enabled.
3. **Local change-management context**. Whether a rule is high-signal depends on how your SOC operates. A tenant where one approved admin makes occasional config changes is very different from a tenant where a CI/CD pipeline rotates RBAC nightly. Rules should be enabled with a per-tenant filter set.

Operators tune the rule, then create a real Sentinel rule from the template. The shipped template stays untouched as a reference.

---

## Per-rule narrative

Each section below covers one rule. The rule files live at [`sentinel/analytic-rules/`](../sentinel/analytic-rules/) (this is the source of truth) and are mirrored into the deployment package under `deploy/solution-staging/XdrLogRaider/Analytic Rules/`.

### MDE alert tuning broadened

- **File**: `AlertTuningBroadened.yaml`
- **Display name**: `MDE alert tuning broadened`
- **Severity**: Medium
- **MITRE**: T1562.006 (Indicator Blocking — Impair Defenses)
- **Required streams**: `MDE_AlertTuning_CL`
- **What it detects**: an existing alert-tuning rule had its `conditions` or `scope` field modified — i.e., the rule now matches more alerts than before. This is the silent way to broaden suppression: instead of adding a new suppression rule, the operator widens an existing one.
- **False-positive likelihood**: Medium. Legitimate tuning expansions occur as the SOC iterates on noisy alert sources. Volume depends on how active the tenant's tuning-rule editing is.
- **Tuning recommendation**: enable in audit mode for 30 days. If false-positive rate is below 5/week and edits are concentrated in a known set of operators, downgrade severity to Low. If your tenant has a strict change-management policy on tuning rules, severity High is defensible.
- **Operator decision**:
  - *Enable* if your SOC treats tuning-rule edits as audited events, especially for compliance-sensitive tenants.
  - *Leave disabled* if your operators iterate on tuning rules dozens of times per week — the noise will dwarf real signal.

### MDE connected app new registration

- **File**: `ConnectedAppNewRegistration.yaml`
- **Display name**: `MDE connected app new registration`
- **Severity**: Low
- **MITRE**: T1098 (Account Manipulation — Persistence)
- **Required streams**: `MDE_ConnectedApps_CL`
- **What it detects**: a new third-party app was connected to the Defender API surface. This is how an attacker with admin credentials persists API access independent of the human accounts.
- **False-positive likelihood**: Medium. New SIEM/XDR integrations, partner connectors, in-house automation onboarding all add new connected apps.
- **Tuning recommendation**: pair with a workspace allow-list of known apps; only fire when the new app's `Name` is not in that list. The rule itself is permissive (any new addition triggers); operators should add a `where Name !in (allowlist)` filter post-template.
- **Operator decision**:
  - *Enable* in tenants with stable third-party-app inventory; an unexpected app addition is a strong signal.
  - *Leave disabled* if you onboard apps frequently and have no tenant inventory of expected apps.

### MDE new data export destination

- **File**: `DataExportNewDestination.yaml`
- **Display name**: `MDE new data export destination`
- **Severity**: Medium
- **MITRE**: T1537 (Transfer Data to Cloud Account — Exfiltration)
- **Required streams**: `MDE_DataExportSettings_CL`
- **What it detects**: a new streaming-API destination (Event Hub, Storage Account, Log Analytics workspace) was added to MDE telemetry export. Potential exfiltration channel for tenant-wide telemetry.
- **False-positive likelihood**: Low to Medium. New destinations are added during legitimate SIEM migrations or multi-region rollouts, but not nightly.
- **Tuning recommendation**: severity Medium ships defensible. If your tenant adds destinations through a change-management workflow with ticket attribution, downgrade to Low and add a join against your CMDB. If destinations are rare in your tenant, escalate severity to High after a 30-day soak.
- **Operator decision**:
  - *Enable* in production tenants where an unexpected destination addition is a real exfiltration risk.
  - *Leave disabled* during active migration projects (the noise will dwarf signal).

### MDE Live Response unsigned scripts enabled

- **File**: `LrUnsignedScriptsOn.yaml`
- **Display name**: `MDE Live Response unsigned scripts enabled`
- **Severity**: High
- **MITRE**: T1562.001 (Disable or Modify Tools), T1059 (Command and Scripting Interpreter)
- **Required streams**: `MDE_LiveResponseConfig_CL`
- **What it detects**: the tenant-wide policy that requires Live Response scripts to be code-signed was switched to allow unsigned scripts. With unsigned scripts allowed, an operator with Live Response permission can run arbitrary code on managed endpoints.
- **False-positive likelihood**: Low. This is rarely a legitimate change in production tenants.
- **Tuning recommendation**: severity High is correct. No tuning recommended unless your tenant has a documented unsigned-LR workflow (in which case suppress the specific operator UPN).
- **Operator decision**:
  - *Enable* in every production tenant. This is one of the highest-signal rules in the bundle.
  - *Leave disabled* only during temporary unsigned-LR projects, with a planned re-enable date.

### MDE MDI DC sensor down

- **File**: `MdiDcSensorDown.yaml`
- **Display name**: `MDE MDI DC sensor down`
- **Severity**: High
- **MITRE**: T1562 (Impair Defenses)
- **Required streams**: `MDE_DCCoverage_CL` (tenant-gated — requires Defender for Identity)
- **What it detects**: a Defender for Identity domain controller sensor stopped reporting (`hasSensor` flipped from true to false). This is an identity-detection blind spot.
- **False-positive likelihood**: Low. Sensors going offline is a real signal; planned maintenance produces transient flips that the lookback window absorbs.
- **Tuning recommendation**: severity High is correct. If your DC fleet is large enough that planned reboots cause noise, lengthen the parser lookback or add a `where Domain in (production_domains)` filter.
- **Operator decision**:
  - *Enable* in tenants with MDI provisioned and active DCs. If the required stream is empty (no MDI), the rule never fires but consumes rule-count budget — leave disabled until MDI is rolled out.
  - *Leave disabled* if MDI is not licensed.

### MDE portal config change outside business hours

- **File**: `PortalConfigAfterHours.yaml`
- **Display name**: `MDE portal config change outside business hours`
- **Severity**: Low
- **MITRE**: T1562 (Impair Defenses)
- **Required streams**: `MDE_Drift_Inventory`, `MDE_Drift_Configuration`, `MDE_Drift_Configuration` (any change in any P0/P1/P2 stream)
- **What it detects**: a configuration change occurred outside 09:00-17:00 local time (workspace `TimeGenerated` is UTC, so adjust the `HourOfDay` window for your operating hours).
- **False-positive likelihood**: High. Cross-region operators, on-call rotations, automation, and after-hours incident response all trigger this. Useful as a hunting baseline; not as a high-signal rule.
- **Tuning recommendation**: configure the `HourOfDay` filter for your tenant's operating hours and time zone before enabling. Pair with a join against expected-after-hours-account list to suppress on-call automation.
- **Operator decision**:
  - *Enable* only after configuring the window for your tenant; otherwise the rule will be very noisy.
  - *Leave disabled* and use the equivalent hunting query [`AfterHoursDrift`](HUNTING-QUERIES.md) instead — hunting queries don't fire alerts but can be reviewed periodically.

### MDE PUA protection disabled

- **File**: `PuaDisabled.yaml`
- **Display name**: `MDE PUA protection disabled`
- **Severity**: High
- **MITRE**: T1562.001 (Disable or Modify Tools)
- **Required streams**: `MDE_PUAConfig_CL`
- **What it detects**: tenant-wide Potentially-Unwanted-Application protection was disabled. Attackers commonly drop tools that PUA detection catches (remote-admin software, hacking utilities).
- **False-positive likelihood**: Low. Disabling tenant-wide PUA is unusual in production tenants.
- **Tuning recommendation**: severity High is correct. No tuning recommended.
- **Operator decision**:
  - *Enable* in every production tenant where PUA is enabled today.
  - *Leave disabled* only in tenants where PUA is intentionally off (rare; usually a misconfiguration).

### MDE RBAC role to unusual account

- **File**: `RbacRoleToUnusualAccount.yaml`
- **Display name**: `MDE RBAC role to unusual account`
- **Severity**: High
- **MITRE**: T1078 (Valid Accounts — Privilege Escalation)
- **Required streams**: `MDE_UnifiedRbacRoles_CL`
- **What it detects**: a Defender unified-RBAC role assignment was added in the past day. The rule fires on the principal-identity fields specifically (not on every nested role attribute), so it alerts on "who got a new role" rather than role-definition tweaks. The query uses an exact-match filter (`FieldName == "principalId"` or `FieldName == "principalName"`) — substring matches on `principalId` would fire on benign role re-evaluations.
- **False-positive likelihood**: Medium. Legitimate role assignments occur during onboarding, role-based-access reviews, and emergency operator escalations.
- **Tuning recommendation**: pair with an allow-list of known admin accounts. The rule's description includes a suggested operator response: verify the principal resolves to a sanctioned admin, cross-reference with `SigninLogs`, suppress the principal for 30 days if benign.
- **Operator decision**:
  - *Enable* in production tenants with stable admin rosters; new role assignments are auditable events.
  - *Leave disabled* if your tenant has a CI/CD pipeline that rotates role assignments — the noise will dwarf signal.

### MDE streaming API new target

- **File**: `StreamingApiNewTarget.yaml`
- **Display name**: `MDE streaming API new target`
- **Severity**: Medium
- **MITRE**: T1537 (Transfer Data to Cloud Account)
- **Required streams**: `MDE_StreamingApiConfig_CL` (deprecated; use `MDE_DataExportSettings_CL` for active monitoring)
- **What it detects**: a new Event Hub or Storage target was configured for Defender telemetry streaming, via the legacy `streamingApiConfiguration` endpoint.
- **Important note**: the underlying stream `MDE_StreamingApiConfig_CL` is **deprecated**. Microsoft has signaled the underlying endpoint may be retired in favor of newer Defender XDR streaming-data feeds. The rule will continue to work as long as the endpoint is reachable; we surface 403/404 in the heartbeat. When Microsoft confirms retirement, remove this rule and rely on `MDE new data export destination` (the `MDE_DataExportSettings_CL`-driven equivalent above).
- **False-positive likelihood**: Low.
- **Tuning recommendation**: prefer the `MDE new data export destination` rule. Keep this rule disabled unless you have legacy streaming-API config that hasn't migrated to data-export-settings.
- **Operator decision**:
  - *Leave disabled* in modern tenants. Use `MDE new data export destination` instead.

### MDE suppression rule broadened

- **File**: `SuppressionRuleBroadened.yaml`
- **Display name**: `MDE suppression rule broadened`
- **Severity**: Medium
- **MITRE**: T1562.006 (Indicator Blocking)
- **Required streams**: `MDE_SuppressionRules_CL`
- **What it detects**: an existing alert-suppression rule had its `scope`, `conditions`, or `machineGroup` field modified. Like the alert-tuning rule above, this is the way to silently widen suppression without adding a new rule.
- **False-positive likelihood**: Medium. Legitimate scope expansions occur as the SOC iterates on tuned-out alerts.
- **Tuning recommendation**: as for alert tuning — enable in audit mode for 30 days, downgrade to Low if FP rate is below 5/week. If your tenant has a strict review process for suppression-rule edits, severity High is defensible.
- **Operator decision**:
  - *Enable* in tenants with audit requirements on suppression-rule edits.
  - *Leave disabled* if suppression-rule iteration is frequent and untracked.

### MDE Tamper Protection disabled

- **File**: `TamperProtectionOff.yaml`
- **Display name**: `MDE Tamper Protection disabled`
- **Severity**: High
- **MITRE**: T1562.001 (Disable or Modify Tools)
- **Required streams**: `MDE_AdvancedFeatures_CL`
- **What it detects**: Defender Tamper Protection was disabled. With Tamper Protection off, malicious tools can directly modify Defender settings, kill the Defender service, exclude paths from scanning, etc.
- **False-positive likelihood**: Very low. Disabling Tamper Protection is rarely legitimate.
- **Tuning recommendation**: severity High is correct. No tuning recommended.
- **Operator decision**:
  - *Enable* in every production tenant. Highest-signal rule in the bundle.
  - *Leave disabled* only during scheduled tenant operations explicitly requiring Tamper Protection off, with a planned re-enable date.

### MDE tenant allow-list new entry

- **File**: `TenantAllowListNewEntry.yaml`
- **Display name**: `MDE tenant allow-list new entry`
- **Severity**: Medium
- **MITRE**: T1562 (Impair Defenses)
- **Required streams**: `MDE_TenantAllowBlock_CL` (tenant-gated — Tenant Allow/Block List feature)
- **What it detects**: a new URL, IP, file hash, or sender was added to the Defender tenant allow-list. Allow-listing bypasses ordinary block actions; an attacker with admin access uses this to ensure their C2 is unblocked tenant-wide.
- **False-positive likelihood**: Medium. Legitimate URL allow-listing for partner integrations and false-positive remediation generates volume.
- **Tuning recommendation**: pair with a join against your tenant's expected-allow-list source-of-truth. Severity High is defensible if your tenant treats allow-list additions as audited events.
- **Operator decision**:
  - *Enable* in tenants with a documented allow-list governance process.
  - *Leave disabled* if allow-list edits are frequent and untracked. Consider the equivalent hunting query as a periodic review pattern instead.

### MDE XSPM new attack path discovered

- **File**: `XspmNewAttackPath.yaml`
- **Display name**: `MDE XSPM new attack path discovered`
- **Severity**: Medium
- **MITRE**: T1595 (Active Scanning — Discovery)
- **Required streams**: `MDE_XspmAttackPaths_CL` (tenant-gated — Defender Exposure Management licensed)
- **What it detects**: a new attack path was identified in Defender Exposure Management (XSPM). Attack paths are multi-hop chains from an entry point to a critical asset; new paths typically appear because of a new asset misconfiguration or a critical-asset rule change.
- **False-positive likelihood**: Low. XSPM paths are deterministic graph computations.
- **Tuning recommendation**: severity Medium ships defensible. Escalate to High if your tenant is XSPM-mature and treats new paths as remediation candidates.
- **Operator decision**:
  - *Enable* in tenants with XSPM provisioned and remediation workflows.
  - *Leave disabled* if XSPM isn't licensed (the underlying stream stays empty).

### MDE XSPM path to critical asset

- **File**: `XspmPathToCriticalAsset.yaml`
- **Display name**: `MDE XSPM path to critical asset`
- **Severity**: High
- **MITRE**: T1595 (Active Scanning), T1570 (Lateral Tool Transfer)
- **Required streams**: `MDE_XspmAttackPaths_CL` (tenant-gated)
- **What it detects**: an attack path terminates at an asset tagged Critical. This is the high-priority subset of new-attack-path findings. Immediate remediation candidate.
- **False-positive likelihood**: Very low. By construction, the path is real (XSPM only emits computed paths) and the target is critical (operator-tagged).
- **Tuning recommendation**: severity High is correct. The query targets `targetCriticality == "Critical"` directly and only looks at the past hour, so volume is bounded.
- **Operator decision**:
  - *Enable* in every tenant with XSPM provisioned. Highest-priority XSPM rule.
  - *Leave disabled* if XSPM isn't licensed.

---

## Rule-tuning workflow

A typical workflow for moving a rule from "shipped disabled" to "enabled in production":

1. **Pre-vetting (Day 0)**: confirm the required stream exists and has rows in your workspace. Use:
   ```kql
   <RequiredStream>_CL | where TimeGenerated > ago(24h) | summarize Rows = count()
   ```
   If `Rows == 0`, the stream is empty (tenant-gated feature not provisioned, or recent ingest issue). Investigate before enabling the rule.
2. **Audit-mode soak (Day 0 to Day 30)**: create the rule from the template with `enabled: true` and `severity: Informational`. Track fire rate and review every alert. Capture which alerts are FPs and what the FP cause was (known operator, scheduled change, automation).
3. **Tune (Day 30)**: based on the soak data, add one or more of:
   - `where Operator !in ('known-admin1@example.com','svc-xdrlr@example.com')` — exclude trusted accounts.
   - `where TimeGenerated > ago(...)` adjustments to align with your time zone.
   - Joins against a tenant-specific allow-list source.
4. **Promote (Day 30+)**: once FP rate is acceptable, set the real severity (Low / Medium / High based on the per-rule recommendation above) and notify the on-call team that the rule is active.
5. **Quarterly review**: revisit each enabled rule once per quarter. Adjust severity, scope, and filters as the tenant evolves.

### Tracking rule status

Track the per-rule status in your runbook. A simple status set:

| Status | Meaning |
|---|---|
| `disabled` | Rule template is not enabled; no Sentinel rule has been created from it. |
| `tuning` | Rule is enabled but in audit/tuning mode (severity Informational, soaking). |
| `enabled` | Rule is enabled at its tuned severity, integrated with on-call. |
| `excluded` | Rule was evaluated and intentionally left disabled (e.g. tenant has no MDI). |

Keep the rationale for `excluded` decisions in the runbook so future operators understand why the rule isn't active.

### Handling false positives

When a rule fires on a known benign event:

1. **Capture the row**: copy the alert's row into your FP log with timestamp, principal, and reason.
2. **Patch the query**: add a `where` filter for the specific principal/condition. Prefer specific filters (`where Operator != 'svc-xdrlr@example.com'`) over broad ones (`where ActionType != 'X'`).
3. **Re-deploy**: update the Sentinel rule. The shipped template stays untouched; your tenant's rule diverges from it intentionally.
4. **Soak again**: monitor for two weeks to confirm the patch did not regress signal.

### When to escalate to a hunting query instead

Some signals are too noisy for a real-time alerting rule but valuable for periodic review. A hunting query (see [HUNTING-QUERIES.md](HUNTING-QUERIES.md)) is the right pattern when:

- Volume is high (dozens of fires per day).
- Each fire requires human judgment to triage.
- Real-time detection is not necessary (a daily or weekly review is acceptable).

Examples in the bundle:

- `AfterHoursDrift` (the hunting-query equivalent of `MDE portal config change outside business hours`).
- `XspmChokepointDeltas` (XSPM chokepoint changes — expensive to alert on, valuable to review).

If a shipped rule is generating more noise than your SOC can absorb, replicate its logic as a hunting query, leave the rule disabled, and review the hunt on a cadence that matches your team's bandwidth.

---

## Cross-references

- [ANALYTIC-RULES.md](ANALYTIC-RULES.md) — rule catalog overview and YAML format reference.
- [STREAMS.md](STREAMS.md) — per-stream availability and polling cadence (so you can confirm a rule's required stream is live before enabling).
- [SCHEMA-CATALOG.md](SCHEMA-CATALOG.md) — typed columns each rule consumes.
- [DRIFT.md](DRIFT.md) — the drift parsers that most rules drive off.
- [HUNTING-QUERIES.md](HUNTING-QUERIES.md) — analyst-driven hunts that don't fire alerts.
- [RUNBOOK.md](RUNBOOK.md) — daily ops, including periodic rule review.
- [`sentinel/analytic-rules/`](../sentinel/analytic-rules/) — source of truth for the rule YAML files.
