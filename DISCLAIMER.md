# Disclaimer

This tool is provided as-is for authorized security professionals and system administrators with proper authorization to manage Microsoft Defender XDR and Sentinel environments in tenants they own.

## Usage Requirements

- You must have proper authorization to ingest telemetry from the target tenant
- Use only within environments where you have explicit permission to access Defender XDR portal data
- The authors are not responsible for any misuse of this tool
- This is unofficial research — undocumented Microsoft APIs may change without notice

## Authentication Patterns

The authentication patterns used in this project (sccauth cookie chain, TOTP code generation, FIDO2 passkey signing) are based on publicly documented specifications:

- [RFC 6238](https://datatracker.ietf.org/doc/html/rfc6238) — TOTP
- [W3C WebAuthn](https://www.w3.org/TR/webauthn-2/) — FIDO2 passkey
- [CloudBrothers — sccauth CA-bypass finding, April 2026](https://cloudbrothers.info/en/avoid-entra-conditional-access-sccauth/) — disclosed to MSRC, classified moderate-severity, not-immediate-servicing as of publication

The sccauth cookie pattern accesses publicly researched, undocumented Microsoft portal APIs. Microsoft may harden these endpoints at any time. This tool is designed to fail gracefully per-stream when that happens, with community-reported breakage via the `portal_endpoint_broken` issue template.

## Credits

**Author**: Alex Kefallonitis

**Referenced community research**:
- [nodoc — Nathan McNulty](https://nodoc.nathanmcnulty.com/)
- [XDRInternals — Fabian Bader & Nathan McNulty (MSCloudInternals)](https://github.com/MSCloudInternals/XDRInternals)
- [DefenderHarvester — Olaf Hartong](https://github.com/olafhartong/DefenderHarvester)
- [MDE Internals series — Olaf Hartong / FalconForce](https://medium.com/falconforce/tagged/microsoft-defender)

These references informed the research. All code in this repo is original work.

*Last updated: 2026-04-22*
