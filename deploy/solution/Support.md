# XdrLogRaider — Support

## Channel

**GitHub Issues** — [github.com/akefallonitis/xdrlograider/issues](https://github.com/akefallonitis/xdrlograider/issues)

Use issue templates:
- **bug_report** — something broken or behaving unexpectedly
- **feature_request** — new stream, workbook, analytic rule, or workflow
- **new_stream_request** — specific portal endpoint you'd like XdrLogRaider
  to poll (include XDRInternals / nodoc reference + expected response shape)
- **portal_endpoint_broken** — a currently-shipped stream stops returning
  rows; include the CSV + markdown from `Audit-Endpoints-Live.ps1`

## SLA

**Community best-effort.** XdrLogRaider is maintained by a single author +
community contributors. No commercial support contract, no 24/7 pager.

Typical response times:
- P0 (connector down for all users, credential leak, security bug): 24-48h
- P1 (one stream consistently failing for all users): 1 week
- P2 (feature request, docs): best-effort; often accepted via PR

## Escalation

1. Open a GitHub issue with the appropriate template + full details
2. If you need faster response for a production incident, tag the issue
   `priority/p0` in the title AND ping me on [X/Twitter](https://x.com/akefallonitis)
3. Security-sensitive issues: email `al.kefallonitis@gmail.com` directly
   rather than file a public issue

## Known limitations (v0.1.0-beta)

| Limitation | Impact | Workaround / status |
|------------|--------|---------------------|
| 9 of 45 streams return 4xx on tenants without the relevant Microsoft feature/license (MDI, TVM add-on, MTO, etc.) | Expected behaviour — classified `tenant-feature-gated`. No rows until customer provisions the feature. | Auto-activates when customer enables feature; no code change needed. |
| 2 streams require `Defender XDR Operator` / `MCAS Administrator` roles beyond `Security Reader` + `Defender XDR Analyst` | Expected — classified `role-gated`. Rows appear only if customer elevates service account. | Documented in `docs/PERMISSIONS.md`. |
| XSPM endpoints require XSPM/Defender CSPM license | Expected — tenants without license see empty responses from XSPM queries. | License gating; nothing we can do. |
| Portal API drift risk | Unofficial APIs change without notice. v0.1.0-beta discovered 5 URLs drifted since v0.1.0-beta.1 — all fixed with evidence. | Live-capture harness (`tools/Audit-Endpoints-Live.ps1`) runs regularly; quarterly re-audit recommended. |
| DirectCookies auth not production-ready | Cookies expire in 4-24h without auto-refresh. | `Initialize-XdrLogRaiderAuth.ps1` refuses `cookies` as a production KV method. Use CredentialsTotp or Passkey for production. |
| Content Hub UI may show partial connection status during first 5 min | "IsConnected" query keys on `MDE_Heartbeat_CL` rows; heartbeat fires every 5 min. | Wait one full heartbeat cycle (up to 5 min) after deploy. |

## Contact

- **Author**: Alex Kefallonitis
- **Email**: al.kefallonitis@gmail.com
- **GitHub**: [@akefallonitis](https://github.com/akefallonitis)
- **Source**: [github.com/akefallonitis/xdrlograider](https://github.com/akefallonitis/xdrlograider)
