@{
    RootModule        = 'Xdr.Common.Exceptions.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a1b2c3d4-e5f6-7890-1234-567890abcdef'
    Author            = 'Alex Kefallonitis'
    CompanyName       = 'Alex Kefallonitis'
    Copyright         = '(c) 2026 Alex Kefallonitis · MIT License'
    Description       = 'XdrLogRaider · typed exception classes · each maps to distinct caller recovery (retry / DLQ / skip / fall through) · prevents silent catch swallowing.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @('New-XdrException','Get-XdrErrorClass','ConvertTo-XdrUtc','ConvertTo-XdrUtcString')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
