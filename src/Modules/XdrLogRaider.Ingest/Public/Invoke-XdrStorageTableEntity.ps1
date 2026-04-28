function Invoke-XdrStorageTableEntity {
    <#
    .SYNOPSIS
        Unified Storage Table entity helper for the XdrLogRaider connector.

    .DESCRIPTION
        Iter 13.15: single canonical helper for all Storage Table entity ops
        (gate flag + 45 stream checkpoints). Replaces 4 scattered call sites that
        previously mixed AzTable cmdlets and ad-hoc Invoke-RestMethod blocks.

        Why this helper exists:
        - AzTable 2.1.0 + Microsoft.Azure.Cosmos.Table SDK does NOT reliably honor
          MI auth from New-AzStorageContext -UseConnectedAccount (root cause of
          iter-13.13 production breakage).
        - Ad-hoc Invoke-RestMethod calls in iter-13.14 used `If-Match: *` which
          converts PUT from Insert-Or-Replace to Update Entity (404 if row absent),
          breaking first-run gate flag write (root cause of iter-13.14).

        Definitive Azure Tables REST contract (validated live with HttpClient
        against the production storage account on 2026-04-28):

          GET    https://<sa>.table.core.windows.net/<tbl>(PartitionKey='<pk>',RowKey='<rk>')
                 -> 200 + entity JSON | 404 (treated as null)
          PUT    (same URI) WITHOUT If-Match
                 -> Insert-Or-Replace (creates if missing; replaces if exists)  ← upsert
          PUT    (same URI) WITH If-Match: *
                 -> Update Entity (404 if row missing)  ← NOT what we want
          DELETE (same URI) WITH If-Match: *
                 -> 204 (unconditional delete)

        Implementation uses System.Net.Http.HttpClient (cached as
        $script:XdrTableHttpClient for socket-pool efficiency) so headers are not
        mangled by PowerShell's Invoke-RestMethod parameter binding. Token
        acquisition uses Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/'
        which honors MI auth natively.

    .PARAMETER StorageAccountName
        Name of the storage account hosting the table.

    .PARAMETER TableName
        Name of the table.

    .PARAMETER PartitionKey
        Entity partition key.

    .PARAMETER RowKey
        Entity row key.

    .PARAMETER Operation
        One of:
          'Get'    — read single entity (returns parsed pscustomobject or $null on 404)
          'Upsert' — Insert-Or-Replace (PUT WITHOUT If-Match)
          'Delete' — unconditional delete (DELETE WITH If-Match: '*')

    .PARAMETER Entity
        Hashtable of properties for Upsert. PartitionKey + RowKey are auto-injected
        if absent. Required for Upsert; ignored for Get/Delete.

    .OUTPUTS
        [pscustomobject] for Get on 200 / [null] for Get on 404 / [null] for Upsert+Delete success.

    .EXAMPLE
        Invoke-XdrStorageTableEntity -StorageAccountName 'sa' -TableName 'tbl' `
            -PartitionKey 'auth-selftest' -RowKey 'latest' -Operation Upsert `
            -Entity @{ Success = $true; Stage = 'complete' }

    .EXAMPLE
        $row = Invoke-XdrStorageTableEntity -StorageAccountName 'sa' -TableName 'tbl' `
            -PartitionKey 'p1' -RowKey 'latest' -Operation Get
        if ($null -eq $row) { Write-Verbose 'no checkpoint yet' }

    .NOTES
        Forward-compat: this is the ONLY function that touches the Storage Table
        REST API. Future migration to Az.Data.Tables / Cosmos DB Tables / durable
        function bindings is a one-file refactor.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StorageAccountName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TableName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PartitionKey,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RowKey,

        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Upsert', 'Delete')]
        [string] $Operation,

        [hashtable] $Entity = $null
    )

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

    # Acquire MI token (storage data plane). Get-AzAccessToken honors MI auth
    # natively via IDENTITY_ENDPOINT/IDENTITY_HEADER on Azure Functions.
    $tokenObj = Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/'
    $token = if ($tokenObj.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
    } else {
        [string]$tokenObj.Token
    }

    # Cached HttpClient for socket-pool efficiency. Reused across invocations
    # within the same Function worker process.
    if ($null -eq $script:XdrTableHttpClient) {
        $script:XdrTableHttpClient = [System.Net.Http.HttpClient]::new()
    }
    $client = $script:XdrTableHttpClient

    # URI built with literal single-quotes (NOT URL-encoded). Azure Tables REST
    # accepts the canonical (PartitionKey='<pk>',RowKey='<rk>') form directly.
    $uri = "https://$StorageAccountName.table.core.windows.net/$TableName(PartitionKey='$PartitionKey',RowKey='$RowKey')"

    $httpMethod = switch ($Operation) {
        'Get'    { [System.Net.Http.HttpMethod]::Get }
        'Upsert' { [System.Net.Http.HttpMethod]::Put }       # PUT without If-Match = Insert-Or-Replace
        'Delete' { [System.Net.Http.HttpMethod]::Delete }
    }

    $req = [System.Net.Http.HttpRequestMessage]::new($httpMethod, $uri)
    $null = $req.Headers.TryAddWithoutValidation('Authorization', "Bearer $token")
    $null = $req.Headers.TryAddWithoutValidation('x-ms-version', '2020-12-06')
    $null = $req.Headers.TryAddWithoutValidation('x-ms-date', [datetime]::UtcNow.ToString('R'))
    $null = $req.Headers.TryAddWithoutValidation('Accept', 'application/json;odata=nometadata')

    if ($Operation -eq 'Delete') {
        # If-Match: '*' = unconditional delete. Required by REST contract.
        $null = $req.Headers.TryAddWithoutValidation('If-Match', '*')
    }

    if ($Operation -eq 'Upsert') {
        if ($null -eq $Entity) {
            throw "Invoke-XdrStorageTableEntity: -Entity is required when -Operation is 'Upsert'."
        }
        # Auto-inject keys into body so PUT-Insert-Or-Replace has full entity.
        if (-not $Entity.ContainsKey('PartitionKey')) { $Entity['PartitionKey'] = $PartitionKey }
        if (-not $Entity.ContainsKey('RowKey'))       { $Entity['RowKey']       = $RowKey }
        $bodyJson = ($Entity | ConvertTo-Json -Compress -Depth 5)
        $req.Content = [System.Net.Http.StringContent]::new(
            $bodyJson, [System.Text.Encoding]::UTF8, 'application/json')
        # CRITICAL: NO If-Match header on Upsert. With If-Match: '*' the PUT
        # becomes Update Entity which 404s if the row doesn't exist yet.
    }

    $resp = $client.SendAsync($req).GetAwaiter().GetResult()

    try {
        # Get 404 means "row doesn't exist yet" — caller decides semantics.
        if ($Operation -eq 'Get' -and $resp.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
            return $null
        }

        if (-not $resp.IsSuccessStatusCode) {
            $errBody = ''
            try { $errBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch {}
            throw ("Storage Table {0} {1}/{2}/{3}/{4} failed: HTTP {5} ({6}) -- {7}" -f `
                $Operation, $StorageAccountName, $TableName, $PartitionKey, $RowKey,
                [int]$resp.StatusCode, $resp.ReasonPhrase, $errBody)
        }

        if ($Operation -eq 'Get') {
            $bodyText = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ([string]::IsNullOrWhiteSpace($bodyText)) { return $null }
            return ($bodyText | ConvertFrom-Json)
        }

        return $null
    } finally {
        $resp.Dispose()
        $req.Dispose()
    }
}
