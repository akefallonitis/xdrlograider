# Upgrading XdrLogRaider

## From v0.1.0-beta.1 → v0.1.0-beta

**Non-breaking for data; breaking for two XSPM streams due to upstream API drift.**

### What changes on the deployed side

| Component | Change | Impact |
|-----------|--------|--------|
| Function App code | 9 timer bodies consolidate into a shared `Invoke-TierPollWithHeartbeat` helper; internal only, same wire behaviour | None for operators |
| `host.json` | Sampling now retains Exception traces; namespaced `XdrLogRaider` log level | App Insights shows more fatal-error detail |
| `requirements.psd1` | `Az.Monitor` removed (unused) | ~40 MB faster cold start |
| DCE ingestion | Gzip-compressed POST bodies with `Content-Encoding: gzip`; 413 split-and-retry | 5-10× less bandwidth; large bursts no longer fail |
| Portal session | Proactive TTL refresh at 3h30m | No impact (defensive) |
| 429 handling | Honours `Retry-After`, jitters, retries up to 3× | Silent data loss prevented |
| Heartbeat | New `Rate429Count` + `GzipBytes` fields inside `Notes` JSON (not first-class columns) | Query via `extend n = parse_json(Notes)` |
| Sentinel content | 14 analytic rules now ship with `enabled: false`; 9 hunting queries gained metadata | Customer must manually enable analytic rules after review |
| Data Connector card | Lists all 47 tables (was 3) | Content Hub submission unblocked |
| Custom tables | Explicit `plan: 'Analytics'` | No-op for LA workspaces on the default plan |

### What changes in the manifest

- **2 streams regressed** to `tenant-gated` due to upstream Defender XDR portal API drift: `MDE_XspmChokePoints_CL` + `MDE_XspmTopTargets_CL`. These returned 200 in v0.1.0-beta.1 but now return 400 with the committed bodies. They remain in the manifest so the tables keep existing — they just produce zero rows until a future release ships a corrected body.
- **Iter-13.8 path-research audit (2026-04-27)**: `MDE_CustomCollection_CL` path corrected `/apiproxy/mtp/mdeCustomCollection/model` → `/rules` per XDRInternals canonical source; `MDE_StreamingApiConfig_CL` marked `Availability='deprecated'` (canonical XDRInternals path collides with `MDE_DataExportSettings_CL` — will be cleanly removed in v0.2.0); `role-gated` category retired (Microsoft Learn confirms Security Admin auto-grants Full Access in MCAS + MDE settings).
- Everything else (36 live, 8 feature-gated, 1 deprecated) classified by live capture on 2026-04-27 against a full-access admin account post iter-13.8.

### Upgrade sequence

1. `git pull` (or re-clone) to pick up the new release.
2. Tag the new release as your deploy target:
   - Deploy-to-Azure button URL now pins `v0.1.0-beta`.
   - If you use your own `functionAppZipVersion`, bump it to `v0.1.0-beta`.
3. **Redeploy via ARM** — `mainTemplate.json` is backward-compatible. Existing custom tables retain all data.
4. **No Key Vault changes required.** `Initialize-XdrLogRaiderAuth.ps1` secret-name schema is unchanged.
5. **No role reassignments required.** SAMI roles are unchanged (KV Secrets User, Storage Table Data Contributor, Monitoring Metrics Publisher).
6. **Heartbeat queries**: if your workbooks / alerts reference `Rate429Count` or `GzipBytes`, parse them from the Notes JSON:
   ```kql
   MDE_Heartbeat_CL
   | extend n = parse_json(Notes)
   | extend Rate429Count = toint(n.rate429Count), GzipBytes = tolong(n.gzipBytes)
   ```
7. **If you had XSPM workbooks / rules** that depended on `MDE_XspmChokePoints_CL` or `MDE_XspmTopTargets_CL` — they will still exist but receive no new rows. Plan a workaround or wait for a future release with corrected bodies.

### Post-upgrade verification

Run the preflight gate to confirm end-to-end readiness:

```powershell
pwsh ./tools/Preflight-Deployment.ps1
```

Expected: **PRE-DEPLOY READY: YES**. Then after deploy, check heartbeat:

```kql
MDE_Heartbeat_CL
| where TimeGenerated > ago(30m)
| extend n = parse_json(Notes)
| project TimeGenerated, FunctionName, Tier, StreamsSucceeded, StreamsAttempted,
          Rate429Count = toint(n.rate429Count), GzipBytes = tolong(n.gzipBytes)
| order by TimeGenerated desc
```

Expected: `Rate429Count = 0` in steady state; `GzipBytes` populated (non-zero).

## From v1.0.x → v0.1.0-beta

See also the v0.1.0-beta.1 CHANGELOG entry for the prior cleanup pass (52 → 45 streams; `Deferred` flag → `Availability` classification; 2 write endpoints removed). Everything in that entry applies; then continue through this document for the v0.1.0-beta delta.
