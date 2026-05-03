# Defender-Inventory-Refresh — daily refresh of the Inventory capability
# (21 streams covering settings, MDI identity, metadata long-tail). Per
# directive 12: capability-named not cron-named. Shared body lives in
# Invoke-TierPollWithHeartbeat — see its comment-based help for the full
# execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'Inventory' -FunctionName 'Defender-Inventory-Refresh'
