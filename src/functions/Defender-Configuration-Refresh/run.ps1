# Defender-Configuration-Refresh — every 6 hours, refreshes the Configuration
# capability (detection rules, RBAC, integrations). Per directive 12:
# capability-named not cron-named. Shared body lives in
# Invoke-TierPollWithHeartbeat — see its comment-based help for the full
# execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'Configuration' -FunctionName 'Defender-Configuration-Refresh'
