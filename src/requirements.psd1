# XdrLogRaider · PSGallery module dependencies
#
# ITER#15 NOTE (2026-06-03): intentionally EMPTY. The connector has ZERO Az PowerShell
# dependency at runtime — Key Vault secrets, the DCE ingest token (monitor.azure.com), and
# the Storage token (storage.azure.com) are all acquired via the Function App managed-identity
# REST endpoint ($env:IDENTITY_ENDPOINT) directly. No managedDependency restore, no bundled Az
# modules. (iter#14 had bundled Az.Accounts + Az.KeyVault, but on the Legion Linux Consumption
# worker Az.KeyVault 6.5.0 could not bind its Az.KeyVault.private assembly against the
# independently-pinned Az.Accounts 5.5.0 — cascade-failing the load of every Xdr.* module.)
#
# This file's existence is required by the PowerShell Functions runtime baseline; it stays empty.

@{
}
