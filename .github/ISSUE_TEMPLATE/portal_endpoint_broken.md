---
name: Portal endpoint broken
about: Report that a Defender XDR portal endpoint no longer works (Microsoft hardened it)
title: '[ENDPOINT-BROKEN] '
labels: 'endpoint-broken, priority-high'
assignees: ''
---

## Endpoint affected

- **Stream name**: <!-- e.g., MDE_DataExportSettings_CL -->
- **Endpoint path**: <!-- e.g., /api/dataexportsettings -->
- **File in this repo**: <!-- e.g., src/Modules/XdrLogRaider.Client/Endpoints/Get-DataExportSettings.ps1 -->

## Break timeline

- **Last known working date**: <!-- YYYY-MM-DD, based on `MDE_Heartbeat_CL` or manual verification -->
- **First observed failure date**: <!-- YYYY-MM-DD -->
- **Currently broken**: <!-- Yes / Intermittent -->

## Error details

### HTTP response

- **Status code**: <!-- 404 / 403 / 401 / 500 / etc. -->
- **Response body** (redacted):
  ```json
  ```

### App Insights trace

<details>
<summary>Relevant exception / request log</summary>

```
```

</details>

## Observed Microsoft communication

<!--
Any of:
- MSRC advisory
- Defender XDR release notes
- Official Microsoft documentation update
- Tenant admin notification
-->

## Suggested workaround

<!-- Is there an alternative endpoint? Graph API equivalent (even if less detailed)? Nothing available yet? -->

## Impact

- [ ] Single stream broken, rest healthy
- [ ] Multiple streams affected
- [ ] Auth chain itself broken (sccauth acquisition fails)
- [ ] Entire connector non-functional

## Checklist

- [ ] I searched existing issues for the same endpoint
- [ ] I verified the break is not caused by my tenant's Conditional Access changes
- [ ] I redacted tenant IDs / UPNs / other tenant-specific data
