# Azure Functions PowerShell — module dependency manifest.
#
# THIS FILE IS DELIBERATELY EMPTY (iter 13).
#
# Linux Consumption "Legion" runtime (Microsoft's current compute platform for
# Y1 PowerShell function apps) does NOT support Managed Dependencies. Every
# function load throws: "Failed to install function app dependencies. Error:
# 'Managed Dependencies is not supported in Linux Consumption on Legion.'"
#
# Microsoft's official guidance (https://aka.ms/functions-powershell-include-modules):
#   "Including modules in app content ... Compatibility: Works on Flex
#    Consumption and is recommended for other Linux SKUs."
#
# Therefore: Az.Accounts, Az.KeyVault, Az.Storage are BUNDLED INSIDE the
# function-app.zip under Modules/<ModuleName>/<Version>/ via Save-Module
# during release packaging (see .github/workflows/release.yml).
#
# Tests/unit/FunctionAppZip.BundledModules.Tests.ps1 locks the invariant:
# requirements.psd1 must remain empty + Modules/Az.* must be present in zip.
#
# Same approach carries forward to Flex Consumption (v0.2.0 migration target)
# — Flex also requires bundled modules; Managed Dependencies isn't supported
# on Flex either.
#
# To add a new module:
#   1. Add it to the Save-Module list in .github/workflows/release.yml
#   2. Update tests/unit/FunctionAppZip.BundledModules.Tests.ps1
#   3. Bump the size budget in release.yml if it pushes past 150 MB
#
# DO NOT add module references here. The Pester gate fails the PR.

@{
}
