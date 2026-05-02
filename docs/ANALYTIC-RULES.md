# Analytic rules

15 scheduled analytic rules ship with XdrLogRaider. All ship as **Suggested** (disabled by default) — enable selectively after reviewing.

| Rule file | Severity | Description |
|---|---|---|
| `AsrRuleDowngrade.yaml` | High | ASR rule moved from Block to Audit/Off |
| `LrUnsignedScriptsOn.yaml` | High | Live Response unsigned-scripts enabled |
| `DataExportNewDestination.yaml` | Medium | New data export destination added |
| `PuaDisabled.yaml` | High | PUA protection disabled |
| `TamperProtectionOff.yaml` | High | Tamper Protection disabled |
| `TenantAllowListNewEntry.yaml` | Medium | New URL/IP/hash/sender added to allow-list |
| `SuppressionRuleBroadened.yaml` | Medium | Suppression rule scope widened |
| `RbacRoleToUnusualAccount.yaml` | High | RBAC role to unusual account |
| `XspmNewAttackPath.yaml` | Medium | New XSPM attack path discovered |
| `XspmPathToCriticalAsset.yaml` | High | Attack path terminates at critical asset |
| `MdiDcSensorDown.yaml` | High | MDI DC sensor stopped reporting |
| `AlertTuningBroadened.yaml` | Medium | Alert tuning rule scope widened |
| `StreamingApiNewTarget.yaml` | Medium | New streaming API target configured |
| `ConnectedAppNewRegistration.yaml` | Low | New 3rd-party app connected |
| `PortalConfigAfterHours.yaml` | Low | Config change outside business hours |

## Format

Sentinel-Solutions-compatible YAML:

```yaml
id: <GUID>
name: <rule name>
description: <description>
severity: Informational | Low | Medium | High
requiredDataConnectors:
  - connectorId: XdrLogRaiderInternal
    dataTypes:
      - MDE_Heartbeat_CL
queryFrequency: 15m
queryPeriod: 2h
triggerOperator: gt
triggerThreshold: 0
tactics: [ DefenseEvasion, ... ]
relevantTechniques: [ T1562.001, ... ]
query: | <KQL>
entityMappings: []
eventGroupingSettings:
  aggregationKind: SingleAlert
suppressionEnabled: false
suppressionDuration: PT5H
```

## Tuning

Each rule is a starting point. Tune before enabling in production:

1. **Scope**: add `| where` clauses for known-benign sources (change-management tool service accounts, scheduled maintenance windows)
2. **Threshold**: adjust `triggerThreshold` / `queryFrequency` for your alert volume tolerance
3. **Severity**: downgrade if the rule generates too many alerts in your tenant
4. **Entity mappings**: populate `entityMappings` to enrich alerts with AccountUpn, MachineName, etc.

## Enabling

1. Sentinel → Analytics → Rule templates
2. Filter by `XdrLogRaider`
3. Review the rule in detail
4. Click **Create rule** to enable (with your tuning)

## Adding a new rule

1. Create `sentinel/analytic-rules/<Name>.yaml`
2. Use a fresh GUID for `id` (`[guid]::NewGuid()`)
3. Follow the schema above
4. Validate: `pwsh ./tests/Run-Tests.ps1 -Category validate`
5. Add to `deploy/solution/manifest.json` under `AnalyticalRules`
