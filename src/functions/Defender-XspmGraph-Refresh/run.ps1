# Defender-XspmGraph-Refresh — hourly refresh of the XSPM exposure-graph
# capability. Per directive 12: capability-named not cron-named. Shared body
# lives in Invoke-TierPollWithHeartbeat — see its comment-based help for the
# full execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'XspmGraph' -FunctionName 'Defender-XspmGraph-Refresh'
