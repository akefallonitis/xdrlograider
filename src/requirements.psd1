# Az modules pinned to the v0.0.x compatibility baseline. Managed dependencies
# disabled in host.json; the build pipeline (release.yml) bundles these into
# the function-app.zip Modules/ directory at packaging time. Pinning here
# documents the contract; the actual import happens via Import-Module in
# profile.ps1.
@{
    'Az.Accounts' = '5.4.0'
    'Az.KeyVault' = '6.4.3'
}
