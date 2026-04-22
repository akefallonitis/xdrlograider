# Hunting queries

10 analyst-facing hunting queries ship with XdrLogRaider.

| Query | Purpose |
|---|---|
| `ConfigChangesByUpn` | Who changed what config, joined with AuditLogs |
| `AfterHoursDrift` | Config changes outside business hours |
| `SilentBypassIndicators` | Composite: suppression adds + ASR downgrades + PUA off on same day |
| `AsrRuleStateTransitions` | Every ASR rule mode transition, 30-day view |
| `LrSessionsWithoutJustification` | Live Response sessions with no matching investigation |
| `ExclusionAdditionsPastQuarter` | AV exclusions added in past 90 days |
| `RbacEscalationEvents` | Role assignments to accounts with no prior admin history |
| `XspmChokepointDeltas` | Newly-identified XSPM chokepoints |
| `MdiServiceAccountDrift` | MDI service account classification changes |
| `CustomDetectionContentAudit` | Full current text of all custom detection rules (governance review) |

## Format

Sentinel-Solutions-compatible YAML:

```yaml
id: <GUID>
name: <display name>
description: <description>
requiredDataConnectors:
  - connectorId: XdrLogRaiderInternal
    dataTypes:
      - MDE_Heartbeat_CL
tactics: [ Discovery, ... ]
relevantTechniques: [ T1595, ... ]
query: | <KQL>
```

## Adding a new hunting query

1. Create `sentinel/hunting-queries/<Name>.yaml`
2. Fresh GUID for `id`
3. Add to `deploy/solution/manifest.json` under `HuntingQueries`
4. Validate with `pwsh ./tests/Run-Tests.ps1 -Category validate`
