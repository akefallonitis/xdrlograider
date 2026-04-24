# poll-p3-exposure-1h — hourly poll of all Tier 3 exposure/XSPM streams.
# Canonical body is the shared Invoke-TierPollWithHeartbeat helper — see its
# comment-based help for the full execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'P3' -FunctionName 'poll-p3-exposure-1h'
