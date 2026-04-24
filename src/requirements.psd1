# Azure Functions PowerShell managed dependencies.
# Installed automatically on cold start via host.json managedDependency:enabled=true.
# Pin to major version to get security updates without surprise breaking changes.
#
# v0.1.0-beta: Az.Monitor removed — audit confirmed zero runtime references
# across src/ (Get-AzDiagnostic*, New-AzDiagnostic*, *-AzMetric, *-AzAlert*,
# *-AzActionGroup — all grep-clean). Kept it in v1.x as a defensive import
# but it was never used; dropping saves ~40 MB of cold-start module download
# per worker, which is paid on every new Consumption-plan instance scale-out.

@{
    'Az.Accounts'     = '3.*'
    'Az.KeyVault'     = '6.*'
    'Az.Storage'      = '7.*'
}
