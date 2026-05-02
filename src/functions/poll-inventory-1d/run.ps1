# poll-inventory-1d — daily poll of the Inventory tier (21 streams covering
# settings, MDI identity, and metadata long-tail). Shared body lives in
# Invoke-TierPollWithHeartbeat — see its comment-based help for the full
# execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'inventory' -FunctionName 'poll-inventory-1d'
