# poll-p0-compliance-1h — hourly poll of all Tier 0 security-configuration streams.
# Fires at :15 past every hour. Canonical body is the shared
# Invoke-TierPollWithHeartbeat helper; see its comment-based help for the full
# execution shape (auth gate, credential fetch, portal sign-in, tier poll,
# heartbeat, fatal-error handling, forward-scalable -Portal).
param($Timer)
Invoke-TierPollWithHeartbeat -Tier 'P0' -FunctionName 'poll-p0-compliance-1h'
