# Terms of Use · XdrLogRaider v0.1.0

**Effective**: 2026-06-01
**Maintainer**: Alex Kefallonitis · al.kefallonitis@gmail.com

## Acceptance

By installing or using XdrLogRaider, you accept these Terms. If you do not accept, do not install or use the software.

## License

XdrLogRaider is licensed under the MIT License (see `LICENSE` file at the repository root). You may use, modify, and distribute the software per MIT terms.

## Permitted use

XdrLogRaider is provided for use as a Microsoft Sentinel data connector to access Microsoft Defender XDR portal endpoints from within your own Microsoft Entra tenant.

You may use this connector:
- In production Azure environments under your control
- In MSSP scenarios (multi-tenant management) provided per-tenant deployment is honored
- For commercial, government, education, and non-profit purposes (per MIT License)

## Prohibited use

You shall NOT:
- Use XdrLogRaider to access tenant data you are not authorized to access
- Modify the connector to bypass Microsoft Defender XDR portal rate limits, robots.txt, or terms of service
- Use the connector for security research that violates the Microsoft Online Services Acceptable Use Policy
- Distribute modified versions of the connector under the original name (consistent with MIT trademark norms)

## Compliance

You are responsible for ensuring your use of XdrLogRaider complies with:
- Microsoft Online Services Terms (https://www.microsoft.com/licensing/terms)
- Microsoft Defender XDR portal terms (implicit per your Entra license agreement)
- Your tenant's data handling policies
- All applicable laws and regulations in your jurisdiction

## Microsoft trademarks

This connector references "Microsoft Defender XDR", "Microsoft Sentinel", "Microsoft Entra ID" — these are trademarks of Microsoft Corporation. XdrLogRaider is NOT a Microsoft product and is NOT endorsed by Microsoft.

## No warranty

XdrLogRaider is provided "AS IS" without warranty of any kind (per MIT License). The maintainer makes no guarantee that:
- The connector will work with all Entra tenants
- Microsoft Defender XDR portal endpoint shapes will remain compatible
- The connector is fit for any particular purpose

## Limitation of liability

To the maximum extent permitted by law, the maintainer is not liable for:
- Data loss from connector failures
- Lost productivity due to ingestion gaps
- Costs incurred from Azure resource consumption while the connector runs
- Indirect, incidental, or consequential damages

## Supported scope

XdrLogRaider provides:
- **Defender portal**: portal-internal telemetry polling · dynamic per-operation dispatch gated by tenant capability + cadence · operations onboarded incrementally from the Defender catalog
- **Additional Microsoft security portals** (Entra · Intune · Purview · SecurityCopilot): authentication supported

Endpoints NEVER polled (operator policy):
- Advanced Hunting (`/api/advancedhunting/*`) — reverse-included would compete with Microsoft Sentinel native AH
- Alerts & Incidents (`/api/security/incidents/*`) — duplicates Microsoft Sentinel native
- Live Response (`/api/devices/*/live-response`) — write-side · intentionally excluded

## Service account credentials

You must provide a tenant service account with appropriate Defender XDR portal access permissions. The connector does NOT create accounts on your behalf. Service account credentials are stored in your Key Vault.

The maintainer does NOT have access to your service account credentials at any time.

## Reporting issues

Bug reports: https://github.com/akefallonitis/xdrlograider/issues
Security issues: https://github.com/akefallonitis/xdrlograider/security/advisories/new (private disclosure)

## Modifications to terms

The maintainer reserves the right to modify these Terms in future versions of XdrLogRaider. Continued use of newer versions constitutes acceptance of revised Terms. Existing v0.1.0 installations retain the Terms in effect at install time.

## Contact

General: al.kefallonitis@gmail.com

## Governing law

These Terms are governed by the laws of the maintainer's jurisdiction (Greece). Any dispute shall be resolved through good-faith dialogue first; failing that, courts of the maintainer's jurisdiction have non-exclusive jurisdiction.
