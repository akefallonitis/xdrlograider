@{
    RootModule        = 'Xdr.Common.Parser.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd4e5f6a7-b8c9-0123-4567-890123def012'
    Author            = 'Alex Kefallonitis'
    Description       = 'XdrLogRaider parser · 3 keystones: B1 per-item fan-out · B1b empty-element gate · B3 RawJson per-item 240KB LA-safe clamp. Operator-binding per 8 production requirements.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @('ConvertTo-XdrRows','Apply-XdrProjectionMap','Test-XdrEmptyElement','Compress-XdrRawJson','Get-XdrSafeColumnName','Get-XdrEnvelopeColumns','Get-XdrCategoryToken','Get-XdrArmGuid','Get-XdrArtifactTransformKql','Get-XdrResponseItemCount')
    CmdletsToExport   = @()
}
