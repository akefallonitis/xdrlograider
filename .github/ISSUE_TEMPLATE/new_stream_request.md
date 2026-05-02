---
name: New telemetry stream request
about: Propose a new MDE_*_CL stream to add to the connector
title: '[STREAM] '
labels: 'new-stream'
assignees: ''
---

## Stream proposal

- **Proposed table name**: <!-- e.g., MDE_SomeNewThing_CL -->
- **Proposed cadence tier**: <!-- P0-P7, see docs/STREAMS.md for tier definitions -->
- **Proposed poll cadence**: <!-- 5m / 10m / 30m / 1h / 1d / on-demand -->

## Why this stream

### What compliance / detection value does it provide?

<!-- What question does this stream answer that current streams can't? -->

### Why isn't it in public APIs?

<!-- Confirm: Graph Security / Defender XDR / MDE public APIs / Exposure Mgmt Graph / Vuln Mgmt API do NOT cover this data. Link to MS docs showing the gap. -->

## Endpoint details

- **Portal URL**: <!-- e.g., https://security.microsoft.com/apiproxy/... -->
- **HTTP method**: <!-- GET / POST -->
- **Request body** (if POST, redacted):
  ```json
  ```

### Sample response (redacted)

```json
```

## Proposed schema

| Column | Type | Description |
|--------|------|-------------|
| TimeGenerated | datetime | Poll timestamp |
| ... | ... | ... |

## Drift relevance

- [ ] Configuration — useful for drift detection
- [ ] Inventory — useful for point-in-time posture
- [ ] Event stream — useful for audit
- [ ] Threat intelligence — useful for hunting

## Related streams

<!-- Any existing MDE_*_CL streams that overlap or complement this one? -->

## Implementation offer

- [ ] I will submit a PR implementing this
- [ ] I'd like someone else to implement it

## Checklist

- [ ] I read [CONTRIBUTING.md#adding-a-new-telemetry-stream](../CONTRIBUTING.md#adding-a-new-telemetry-stream)
- [ ] I confirmed this endpoint works in my test tenant
- [ ] I verified no public API covers this data
- [ ] I redacted tenant-specific data from all samples
