# poll-p5-identity-1d — daily poll of all Tier 5 identity/MDI streams.
# Canonical body is the shared Invoke-TierPollWithHeartbeat helper — see its
# comment-based help for the full execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'P5' -FunctionName 'poll-p5-identity-1d'
