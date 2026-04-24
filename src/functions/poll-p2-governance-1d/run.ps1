# poll-p2-governance-1d — daily poll of all Tier 2 governance/RBAC streams.
# Canonical body is the shared Invoke-TierPollWithHeartbeat helper — see its
# comment-based help for the full execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'P2' -FunctionName 'poll-p2-governance-1d'
