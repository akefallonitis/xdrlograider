# poll-config-6h — every 6 hours, polls the Configuration / detection-rule
# tier. Shared body lives in Invoke-TierPollWithHeartbeat — see its
# comment-based help for the full execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'config' -FunctionName 'poll-config-6h'
