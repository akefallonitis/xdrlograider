# poll-exposure-1h — hourly poll of the Exposure Management (XSPM) tier.
# Shared body lives in Invoke-TierPollWithHeartbeat — see its comment-based
# help for the full execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'exposure' -FunctionName 'poll-exposure-1h'
