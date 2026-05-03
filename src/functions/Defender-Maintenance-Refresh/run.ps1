# Defender-Maintenance-Refresh — weekly refresh of the Maintenance capability
# (rare-change long-tail surfaces, principally MDE_DataExportSettings_CL).
# Per directive 12: capability-named not cron-named. Shared body lives in
# Invoke-TierPollWithHeartbeat — see its comment-based help for the full
# execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'Maintenance' -FunctionName 'Defender-Maintenance-Refresh'
