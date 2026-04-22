# Azure Functions PowerShell managed dependencies.
# Installed automatically on cold start via host.json managedDependency:enabled=true.
# Pin to major version to get security updates without surprise breaking changes.

@{
    'Az.Accounts'     = '3.*'
    'Az.KeyVault'     = '6.*'
    'Az.Storage'      = '7.*'
    'Az.Monitor'      = '5.*'
}
