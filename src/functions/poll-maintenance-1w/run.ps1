# poll-maintenance-1w — weekly poll of the Maintenance tier (rare-change
# long-tail surfaces, principally MDE_DataExportSettings_CL). Shared body
# lives in Invoke-TierPollWithHeartbeat — see its comment-based help for the
# full execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'maintenance' -FunctionName 'poll-maintenance-1w'
