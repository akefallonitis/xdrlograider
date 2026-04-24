# poll-p6-audit-10m — 10-minute poll of all Tier 6 audit/AIR streams.
# ActionCenter is filterable (incremental fetch via checkpoint; see manifest).
# Canonical body is the shared Invoke-TierPollWithHeartbeat helper — see its
# comment-based help for the full execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'P6' -FunctionName 'poll-p6-audit-10m'
