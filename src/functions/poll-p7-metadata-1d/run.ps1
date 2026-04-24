# poll-p7-metadata-1d — daily poll of all Tier 7 metadata streams.
# Canonical body is the shared Invoke-TierPollWithHeartbeat helper — see its
# comment-based help for the full execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'P7' -FunctionName 'poll-p7-metadata-1d'
