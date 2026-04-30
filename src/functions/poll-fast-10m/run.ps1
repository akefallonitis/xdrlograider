# poll-fast-10m — every 10 minutes, polls the Action Center event tier
# (MDE_ActionCenter_CL + MDE_MachineActions_CL). Shared body lives in
# Invoke-TierPollWithHeartbeat — see its comment-based help for the full
# execution shape (auth gate, credential fetch, portal sign-in, tier poll,
# heartbeat, fatal-error handling, forward-scalable -Portal).
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'fast' -FunctionName 'poll-fast-10m'
