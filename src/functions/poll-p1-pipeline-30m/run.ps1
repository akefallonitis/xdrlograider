# poll-p1-pipeline-30m — 30-min poll of all Tier 1 integration/pipeline streams.
# Canonical body is the shared Invoke-TierPollWithHeartbeat helper — see its
# comment-based help for the full execution shape.
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'P1' -FunctionName 'poll-p1-pipeline-30m'
