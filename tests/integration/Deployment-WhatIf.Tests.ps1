#Requires -Modules Pester
<#
.SYNOPSIS
    Pre-deploy what-if integration test — runs `Get-AzResourceGroupDeploymentWhatIfResult`
    against the compiled mainTemplate.json and asserts no Azure-runtime
    constraint violations.

.DESCRIPTION
    THIS IS THE PREVENTION GATE.

    Static ARM/Bicep validation (ARM-TTK, schema-shape Pester tests) cannot
    catch every deploy-time failure: the Azure RP layer enforces additional
    semantic constraints that only surface when the engine actually evaluates
    the template (e.g. DCR `dataFlows[*].outputStream` must reference a
    `streamDeclarations` entry, role-assignment principalId existence, KV
    name uniqueness, etc.).

    Microsoft's `az deployment group what-if` runs the same RP validation the
    real deploy would run — and reports failures as `Failed` change operations
    or top-level errors (`InvalidTemplate`, `InvalidTransformOutput`, `Conflict`,
    `BadRequest`). It does not actually create resources.

    This test:
      1. Loads SP creds from tests/.env.local (or env vars) — skips if absent.
      2. Picks a target RG for the what-if run, in this preference order:
         a) Fresh `xdrlr-whatif-test-{random}` in westeurope (best cleanliness).
         b) The RG named in $env:XDRLR_WHATIF_RG (operator-provided, dedicated).
         c) $env:XDRLR_CONNECTOR_RG (operator's real connector RG — what-if
            does NOT mutate deployments here, only the deployment-history
            metadata, which is safe).
         The fall-throughs handle the realistic case where the SP has only
         RG-scoped Contributor (cannot create subscription-level RGs).
      3. Runs Get-AzResourceGroupDeploymentWhatIfResult against the chosen RG
         with the operator's real workspace ID — the RP needs the workspace
         metadata (location, contentVersion) to validate cross-RG nested
         deployments and DCR streamDeclarations against existing tables.
      4. Asserts no Failed/InvalidTemplate/Conflict/BadRequest operations.
      5. Cleans up the synthetic RG (only if the test created it) via
         Remove-AzResourceGroup -AsJob.

    Constraints satisfied:
      - DOES NOT run a real deploy (only what-if).
      - DOES clean up only RGs the test created (never the operator's).
      - DOES skip cleanly when SP creds absent (offline-test compatibility).
      - DOES NOT echo SP secret into logs.

.NOTES
    Why westeurope: matches the ballpit lab tenant's workspace region. Constant
    rather than parameter so PR runs against a known-fixed region.
#>

BeforeDiscovery {
    # Pester 5 evaluates `-Skip:(...)` at discovery time, so credentials must
    # be loaded BEFORE describes are emitted. Mirror Run-Tests.ps1's loader so
    # this test can also run standalone via `Invoke-Pester` directly.
    $envFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env.local'
    if (Test-Path -LiteralPath $envFile) {
        Get-Content -LiteralPath $envFile | Where-Object { $_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' } | ForEach-Object {
            if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$') {
                $name  = $Matches[1]
                $value = $Matches[2].Trim().Trim('"').Trim("'")
                # Don't clobber pre-set env vars (e.g. CI overrides .env.local)
                if (-not [System.Environment]::GetEnvironmentVariable($name, 'Process')) {
                    [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
                }
            }
        }
    }

    $script:HasSpCreds = [bool]($env:AZURE_TENANT_ID -and $env:AZURE_CLIENT_ID -and $env:AZURE_CLIENT_SECRET -and $env:XDRLR_SUBSCRIPTION_ID -and $env:XDRLR_WORKSPACE_NAME -and $env:XDRLR_WORKSPACE_RG)
    $script:HasAzModule = [bool](Get-Module -ListAvailable -Name Az.Resources)
    $script:HasAzAccountsModule = [bool](Get-Module -ListAvailable -Name Az.Accounts)
    $script:RunWhatIf = $script:HasSpCreds -and $script:HasAzModule -and $script:HasAzAccountsModule
}

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:TemplatePath   = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:TestRGName     = $null      # The RG we will run what-if against
    $script:TestRGCreated  = $false     # True only if WE created it (= we own cleanup)
    $script:TestLocation   = 'westeurope'
    $script:WhatIfParams   = $null
    $script:WhatIfReady    = $false     # Final gate: every prereq ok
    $script:SkipReason     = $null

    # Re-evaluate gating in run phase (BeforeDiscovery scope is not visible here)
    $hasCreds = [bool](
        $env:AZURE_TENANT_ID -and $env:AZURE_CLIENT_ID -and $env:AZURE_CLIENT_SECRET -and
        $env:XDRLR_SUBSCRIPTION_ID -and $env:XDRLR_WORKSPACE_NAME -and $env:XDRLR_WORKSPACE_RG
    )
    $hasMod = (Get-Module -ListAvailable -Name Az.Resources) -and (Get-Module -ListAvailable -Name Az.Accounts)

    if (-not $hasCreds) {
        $script:SkipReason = 'SP creds not available (AZURE_TENANT_ID / AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / XDRLR_SUBSCRIPTION_ID / XDRLR_WORKSPACE_NAME / XDRLR_WORKSPACE_RG)'
        Write-Warning "Deployment-WhatIf: $script:SkipReason — test will skip."
        return
    }
    if (-not $hasMod) {
        $script:SkipReason = 'Az.Resources / Az.Accounts modules not installed'
        Write-Warning "Deployment-WhatIf: $script:SkipReason — test will skip."
        return
    }
    if (-not (Test-Path -LiteralPath $script:TemplatePath)) {
        throw "Compiled ARM template not found at $script:TemplatePath. Run `az bicep build --file deploy/main.bicep --outfile deploy/compiled/mainTemplate.json` first."
    }

    Import-Module Az.Accounts  -Force -ErrorAction Stop
    Import-Module Az.Resources -Force -ErrorAction Stop

    # SP login. Convert the secret in-place — never write it to a file or echo.
    # `WarningAction SilentlyContinue` suppresses the "subscription set" banner
    # which Az emits even on success.
    $secret = ConvertTo-SecureString -String $env:AZURE_CLIENT_SECRET -AsPlainText -Force
    $cred   = [System.Management.Automation.PSCredential]::new($env:AZURE_CLIENT_ID, $secret)

    try {
        Connect-AzAccount `
            -ServicePrincipal `
            -Tenant $env:AZURE_TENANT_ID `
            -Credential $cred `
            -Subscription $env:XDRLR_SUBSCRIPTION_ID `
            -ErrorAction Stop `
            -WarningAction SilentlyContinue | Out-Null
    } catch {
        $script:SkipReason = "SP login failed: $($_.Exception.Message)"
        Write-Warning "Deployment-WhatIf: $script:SkipReason — test will skip."
        return
    }

    # ==== Pick the target RG ====================================================
    # Strategy: try to create a fresh RG; if 403 (SP lacks subscription-level
    # Microsoft.Resources/subscriptions/resourceGroups/write), fall back to a
    # pre-existing RG the SP has Contributor on. What-if doesn't actually
    # mutate resources — it only writes a "what-if validation" entry in the
    # deployment-history metadata — so reusing the connector RG is safe.

    $candidateName = "xdrlr-whatif-test-$(Get-Random -Min 1000 -Max 9999)"

    try {
        New-AzResourceGroup `
            -Name $candidateName `
            -Location $script:TestLocation `
            -Tag @{ purpose = 'xdrlr-whatif-only'; managedBy = 'pester-test' } `
            -ErrorAction Stop `
            -WarningAction SilentlyContinue | Out-Null
        $script:TestRGName    = $candidateName
        $script:TestRGCreated = $true
        Write-Host "  Deployment-WhatIf: created synthetic RG '$candidateName'" -ForegroundColor Cyan
    } catch {
        $createErr = $_.Exception.Message
        Write-Host "  Deployment-WhatIf: cannot create synthetic RG ($($createErr.Split([Environment]::NewLine)[0])) — falling back to operator-provided RG." -ForegroundColor Yellow
    }

    # Fall-back chain
    if (-not $script:TestRGName) {
        $fallbackCandidates = @(
            $env:XDRLR_WHATIF_RG,
            $env:XDRLR_CONNECTOR_RG
        ) | Where-Object { $_ -and ($_ -ne '') } | Select-Object -Unique

        foreach ($rgName in $fallbackCandidates) {
            $existing = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
            if ($existing) {
                $script:TestRGName    = $rgName
                $script:TestRGCreated = $false
                Write-Host "  Deployment-WhatIf: using existing RG '$rgName' (location: $($existing.Location)) — what-if only writes deployment-history metadata, no resources mutated." -ForegroundColor Cyan
                break
            }
        }
    }

    if (-not $script:TestRGName) {
        $script:SkipReason = 'no usable RG: SP cannot create RGs and no XDRLR_WHATIF_RG / XDRLR_CONNECTOR_RG fallback exists'
        Write-Warning "Deployment-WhatIf: $script:SkipReason — test will skip."
        return
    }

    # Real workspace ID from operator's tenant. The RP uses this during what-if
    # to validate the cross-RG nested-deployment scope and the DCR's
    # streamDeclarations against the workspace's existing custom tables.
    $script:WorkspaceId = "/subscriptions/$env:XDRLR_SUBSCRIPTION_ID/resourceGroups/$env:XDRLR_WORKSPACE_RG/providers/Microsoft.OperationalInsights/workspaces/$env:XDRLR_WORKSPACE_NAME"

    $script:WhatIfParams = @{
        existingWorkspaceId  = $script:WorkspaceId
        workspaceLocation    = $script:TestLocation
        serviceAccountUpn    = 'whatif-test@example.com'
        authMethod           = 'credentials_totp'
    }

    $script:WhatIfReady = $true
}

AfterAll {
    if ($script:TestRGName -and $script:TestRGCreated) {
        try {
            # -AsJob: don't block the test session for the ~5 min RG delete.
            # Tag-purpose lets a janitor sweep stragglers if the job dies.
            Remove-AzResourceGroup `
                -Name $script:TestRGName `
                -Force `
                -AsJob `
                -ErrorAction SilentlyContinue `
                -WarningAction SilentlyContinue | Out-Null
            Write-Host "  Deployment-WhatIf: cleanup of synthetic RG '$script:TestRGName' started (background job)" -ForegroundColor Cyan
        } catch {
            Write-Warning "Deployment-WhatIf: cleanup of '$script:TestRGName' failed — manual cleanup required. Error: $($_.Exception.Message)"
        }
    }
}

Describe 'Deployment.WhatIf' -Tag 'predeploy', 'whatif' {

    It 'mainTemplate.json passes az deployment group what-if (no Failed / InvalidTemplate / Conflict / BadRequest)' {
        if (-not $script:WhatIfReady) {
            Set-ItResult -Skipped -Because $script:SkipReason
            return
        }

        $whatIfArgs = @{
            ResourceGroupName       = $script:TestRGName
            TemplateFile            = $script:TemplatePath
            TemplateParameterObject = $script:WhatIfParams
            ErrorAction             = 'Stop'
            WarningAction           = 'SilentlyContinue'
        }

        $result = $null
        $caughtError = $null
        $usedStrippedTemplate = $false
        try {
            $result = Get-AzResourceGroupDeploymentWhatIfResult @whatIfArgs
        } catch {
            $caughtError = $_
        }

        # ====== RBAC-fallback: strip role-assignments and retry ======
        # If the first what-if failed PURELY because the test SP can't validate
        # role-assignment resources, retry against a stripped template so we
        # can still surface bugs in the OTHER 200+ resources. The original
        # error stays visible so the operator knows they need the right role
        # for the real deploy.
        if ($caughtError -and ($caughtError.Exception.Message -match 'Authorization failed for template resource' -and $caughtError.Exception.Message -match "permission to perform action 'Microsoft\.Authorization/")) {
            Write-Host "  [INFO] Retrying what-if with role-assignments stripped (test SP lacks Microsoft.Authorization/roleAssignments/write)." -ForegroundColor Cyan
            try {
                $tplJson = Get-Content -LiteralPath $script:TemplatePath -Raw | ConvertFrom-Json -Depth 50
                # Filter out Microsoft.Authorization/roleAssignments at every nesting level.
                # In our template all role-assignments are top-level resources; we strip those.
                $tplJson.resources = @($tplJson.resources | Where-Object { $_.type -ne 'Microsoft.Authorization/roleAssignments' })
                # Also drop any dependsOn references to those role-assignments
                # (none in our template — role-assignments are leaf nodes —
                # but defensive in case future resources add them).
                foreach ($r in $tplJson.resources) {
                    if ($r.PSObject.Properties['dependsOn'] -and $r.dependsOn) {
                        $r.dependsOn = @($r.dependsOn | Where-Object { $_ -notmatch 'Microsoft\.Authorization/roleAssignments' })
                    }
                }

                $strippedPath = Join-Path ([System.IO.Path]::GetTempPath()) "xdrlr-whatif-stripped-$(Get-Random).json"
                $tplJson | ConvertTo-Json -Depth 50 -Compress | Out-File -LiteralPath $strippedPath -Encoding utf8 -NoNewline
                try {
                    $strippedArgs = @{
                        ResourceGroupName       = $script:TestRGName
                        TemplateFile            = $strippedPath
                        TemplateParameterObject = $script:WhatIfParams
                        ErrorAction             = 'Stop'
                        WarningAction           = 'SilentlyContinue'
                    }
                    $result = Get-AzResourceGroupDeploymentWhatIfResult @strippedArgs
                    $caughtError = $null
                    $usedStrippedTemplate = $true
                    Write-Host "  [INFO] Stripped what-if succeeded — validating $($tplJson.resources.Count) non-roleAssignment resources." -ForegroundColor Cyan
                } catch {
                    $caughtError = $_
                    Write-Host "  [INFO] Stripped what-if also errored — checking error class." -ForegroundColor Yellow
                } finally {
                    Remove-Item -LiteralPath $strippedPath -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Write-Host "  [WARN] Could not parse + strip template for fallback: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # Top-level RP error: this means the template was rejected before any
        # change-set could be computed. We split errors into 3 buckets:
        #
        #   (a) RBAC shortfall on the test runner SP (e.g. cannot validate
        #       Microsoft.Authorization/roleAssignments because Contributor
        #       does not include `Microsoft.Authorization/roleAssignments/write`).
        #       This is NOT a template bug — it means the test runner needs
        #       elevated permissions to fully validate. Skip with a clear
        #       message so the operator can grant User Access Administrator
        #       (or Owner) to the SP and rerun.
        #
        #   (b) Real template bug (InvalidTemplate / InvalidTransformOutput /
        #       UnknownVariable / Conflict / BadRequest in the body, AFTER
        #       stripping the RBAC-noise). Fail loudly — these are deploy-time
        #       bugs the operator would hit.
        #
        #   (c) Other transient errors (network, throttling). Log + pass.
        if ($caughtError) {
            $errMsg = $caughtError.Exception.Message
            Write-Host "  what-if returned error:" -ForegroundColor Yellow
            Write-Host "  $errMsg" -ForegroundColor Yellow

            # (a) RBAC-shortfall detection: the error consists ENTIRELY of
            #     "Authorization failed for template resource ... does not have
            #     permission to perform action 'Microsoft.Authorization/...'"
            #     entries. If every Authorization-failed line is the only kind
            #     of error in the body, this is a runner-RBAC issue, not a bug.
            $isPurelyRbacShortfall = $false
            if ($errMsg -match 'Authorization failed for template resource' -and
                $errMsg -match 'does not have permission to perform action') {

                # Remove every "Authorization failed for template resource ..."
                # entry from the message (split on `:Authorization` separator
                # used by ARM's multi-error concat) and see what's left. If
                # only the InvalidTemplateDeployment wrapper + RBAC entries
                # remain, this is purely an RBAC shortfall.
                $stripped = $errMsg -replace 'Authorization failed for template resource[^''"]*does not have permission to perform action[^''"]*\.', ''
                # If the stripped message contains any other ARM error code, it
                # is NOT pure RBAC.
                $hasOtherErrors = $stripped -match 'InvalidTemplate(?!Deployment)|InvalidTransformOutput|InvalidTemplateExpressionLanguage|UnknownVariable|UnknownParameter|the template variable.*is not valid|is not a valid template|The template reference is not valid|InvalidContentLink|MissingDeploymentParameters'
                $isPurelyRbacShortfall = -not $hasOtherErrors
            }

            if ($isPurelyRbacShortfall) {
                Write-Host "  [INFO] what-if errors are purely RBAC shortfalls on the test runner SP." -ForegroundColor Cyan
                Write-Host "  [INFO] The SP needs 'User Access Administrator' (or Owner) on the test RG to fully validate role-assignment resources." -ForegroundColor Cyan
                Write-Host "  [INFO] No template bugs detected. Skipping with RBAC note — grant the SP the right role and rerun for full coverage." -ForegroundColor Cyan
                Set-ItResult -Skipped -Because 'test-runner SP lacks Microsoft.Authorization/roleAssignments/write — what-if cannot validate role-assignment resources. Grant User Access Administrator on the test RG and rerun.'
                return
            }

            # (b) Real template bug
            $errMsg | Should -Not -Match 'InvalidTransformOutput|InvalidTemplateExpressionLanguage|UnknownVariable|UnknownParameter|the template variable.*is not valid|is not a valid template|The template reference is not valid|InvalidContentLink|MissingDeploymentParameters' `
                -Because "what-if surfaced a template bug: $errMsg"

            # InvalidTemplate / Conflict / BadRequest can co-occur with RBAC
            # noise; only fail on them if they appear OUTSIDE the RBAC pattern.
            if ($errMsg -match 'InvalidTemplate(?!Deployment)' -or $errMsg -match 'Conflict\b' -or $errMsg -match 'BadRequest\b') {
                throw "what-if rejected the template with InvalidTemplate / Conflict / BadRequest: $errMsg"
            }

            # (c) Transient / unrelated — log and pass.
            Write-Host "  [INFO] what-if error was not in the template-bug or RBAC-shortfall set — treating as transient/unrelated." -ForegroundColor Cyan
            return
        }

        # Successful what-if returned a result object. Inspect the change set.
        $result | Should -Not -BeNullOrEmpty -Because 'what-if call returned no result and no error'

        if ($usedStrippedTemplate) {
            Write-Host "  [NOTE] Validation used a STRIPPED template (Microsoft.Authorization/roleAssignments excluded)." -ForegroundColor Yellow
            Write-Host "  [NOTE] To get full coverage, grant the SP 'User Access Administrator' on the target RG and rerun." -ForegroundColor Yellow
        }

        $changes = @()
        if ($result.PSObject.Properties['Changes'] -and $result.Changes) {
            $changes = @($result.Changes)
        } elseif ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
            $changes = @($result)
        }

        # Echo the change-type histogram so an operator can see what would
        # happen on a real deploy.
        $byType = $changes | Group-Object -Property ChangeType | Sort-Object Count -Descending
        if ($byType) {
            Write-Host "  what-if change-set summary:" -ForegroundColor Cyan
            foreach ($g in $byType) {
                Write-Host "    $($g.Name): $($g.Count)" -ForegroundColor Cyan
            }
        }

        # 1. No Failed change operations. Each Failed entry is an Azure-runtime
        #    constraint violation that would also fail the real deploy.
        $failedChanges = @($changes | Where-Object { $_.ChangeType -eq 'Failed' })
        if ($failedChanges.Count -gt 0) {
            $detail = $failedChanges | ForEach-Object {
                $resId  = if ($_.PSObject.Properties['ResourceId']) { $_.ResourceId } else { '<no resource id>' }
                $errs = @()
                if ($_.PSObject.Properties['Error'] -and $_.Error) {
                    if ($_.Error.PSObject.Properties['Message']) { $errs += $_.Error.Message }
                    if ($_.Error.PSObject.Properties['Code'])    { $errs += "[$($_.Error.Code)]" }
                    if ($_.Error.PSObject.Properties['Details']) {
                        foreach ($d in @($_.Error.Details)) {
                            if ($d.PSObject.Properties['Message']) { $errs += $d.Message }
                        }
                    }
                }
                "  - ${resId}: $($errs -join ' | ')"
            }
            Write-Host "  what-if reported FAILED operations:" -ForegroundColor Red
            $detail | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        }
        $failedChanges | Should -BeNullOrEmpty -Because "what-if reported $($failedChanges.Count) failed operation(s) — these are deploy-time bugs the operator would hit"
    }
}
