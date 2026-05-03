# Defender-ActionCenter-Refresh — every 10 minutes, refreshes the Action Center
# capability (MDE_ActionCenter_CL + MDE_MachineActions_CL). Per directive 12
# in .claude/plans/immutable-splashing-waffle.md, function name describes the
# CAPABILITY (Action Center) not the CADENCE (10m). Shared body lives in
# Invoke-TierPollWithHeartbeat — see its comment-based help for the full
# execution shape (auth gate, credential fetch, portal sign-in, tier poll,
# heartbeat, fatal-error handling, forward-scalable -Portal).
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'ActionCenter' -FunctionName 'Defender-ActionCenter-Refresh'
