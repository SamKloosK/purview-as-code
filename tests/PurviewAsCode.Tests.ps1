BeforeAll {
    . (Join-Path $PSScriptRoot 'Mocks.ps1')
    Import-Module (Join-Path $PSScriptRoot '../PurviewAsCode/PurviewAsCode.psd1') -Force

    $script:root = Split-Path $PSScriptRoot -Parent

    # Writes a modified copy of an example to a temp file and returns the path.
    function New-TestConfig {
        param([string]$Example = 'baseline.json', [scriptblock]$Change)
        $config = Get-Content (Join-Path $script:root "examples/$Example") -Raw | ConvertFrom-Json -AsHashtable
        if ($Change) { & $Change $config }
        $path = Join-Path ([IO.Path]::GetTempPath()) "pac-$([guid]::NewGuid()).json"
        $config | ConvertTo-Json -Depth 20 | Set-Content $path
        $path
    }

    function Invoke-Deploy {
        param([string]$Path, [switch]$WhatIf, [switch]$AllowRemoval)
        Invoke-PurviewDeployment -ConfigFile $Path -UseExistingSession -SkipTenantCheck -PassThru -WhatIf:$WhatIf -AllowRemoval:$AllowRemoval -Confirm:$false 6>$null
    }

    function Find-Item { param($Plan, $Area, $Name, $Action) @($Plan | Where-Object { $_.Area -eq $Area -and $_.Name -eq $Name -and (-not $Action -or $_.Action -eq $Action) }) }
}

Describe 'Examples' {
    It '<_> passes validation' -ForEach 'baseline.json', 'nl-smb.json' {
        Test-PurviewConfig -ConfigFile (Join-Path $script:root "examples/$_") 6>$null | Should -BeTrue
    }
}

Describe 'Plan and apply against an empty tenant' -ForEach 'baseline.json', 'nl-smb.json' {
    BeforeEach { Reset-MockTenant; $script:cfg = Join-Path $script:root "examples/$_" }

    It 'makes no changes with -WhatIf' {
        $plan = Invoke-Deploy $script:cfg -WhatIf
        $global:MockWrites | Should -HaveCount 0
        @($plan | Where-Object Action -eq 'Create').Count | Should -BeGreaterThan 0
    }

    It 'creates everything on the first run and changes nothing on the second' {
        $first = Invoke-Deploy $script:cfg
        @($first | Where-Object Status -eq 'Failed') | Should -HaveCount 0
        $global:MockWrites.Clear()

        $second = Invoke-Deploy $script:cfg
        $global:MockWrites | Should -HaveCount 0
        @($second | Where-Object Action -in 'Create', 'Update') | Should -HaveCount 0
    }

    It 'never sends settings to a label group' {
        $null = Invoke-Deploy $script:cfg
        $config = Get-Content $script:cfg -Raw | ConvertFrom-Json -AsHashtable
        foreach ($group in $config.SensitivityLabels | Where-Object IsLabelGroup) {
            $global:MockWrites | Should -Not -Contain "Set-Label $($group.Name)"
        }
    }
}

Describe 'Changes to an existing tenant' {
    BeforeEach {
        Reset-MockTenant
        $null = Invoke-Deploy (Join-Path $script:root 'examples/baseline.json')
        $global:MockWrites.Clear()
    }

    It 'updates a changed tooltip and header colour on that label only' {
        $path = New-TestConfig -Change {
            param($c)
            $label = $c.SensitivityLabels | Where-Object Name -eq 'Internal'
            $label.Tooltip = 'Changed tooltip'
            $label.ContentMarking.Header.FontColor = '#123456'
        }
        $plan = Invoke-Deploy $path
        $item = Find-Item $plan 'Sensitivity label' 'Internal' 'Update'
        $item | Should -HaveCount 1
        ($item.Details -join "`n") | Should -Match 'Tooltip'
        ($item.Details -join "`n") | Should -Match 'FontColor'
        $global:MockWrites | Should -HaveCount 1
        $global:MockWrites | Should -Contain 'Set-Label Internal'
    }

    It 'adds a DLP location with AddXxxLocation, which is what Set-DlpCompliancePolicy accepts' {
        $path = New-TestConfig -Change {
            param($c)
            $c.DlpPolicies[0].ExchangeLocation = @('All', 'finance@contoso.com')
        }
        $plan = Invoke-Deploy $path
        @($plan | Where-Object Status -eq 'Failed') | Should -HaveCount 0
        (Find-Item $plan 'DLP policy' 'DLP-FinancialData' 'Update') | Should -HaveCount 1
    }

    It 'leaves a location that is not in the config alone unless -AllowRemoval is used' {
        $path = New-TestConfig -Change { param($c) $c.DlpPolicies[0].TeamsLocation = @('Nobody') }
        $plan = Invoke-Deploy $path
        (Find-Item $plan 'DLP policy' 'DLP-FinancialData' 'Drift') | Should -HaveCount 1
        $policy = Get-DlpCompliancePolicy -Identity 'DLP-FinancialData'
        $policy.TeamsLocation.Name | Should -Contain 'All'

        $null = Invoke-Deploy $path -AllowRemoval
        (Get-DlpCompliancePolicy -Identity 'DLP-FinancialData').TeamsLocation.Name | Should -Not -Contain 'All'
    }

    It 'treats BlockAccess false as a setting' {
        $path = New-TestConfig -Change { param($c) $c.DlpPolicies[0].Rules[0].BlockAccess = $false }
        $plan = Invoke-Deploy $path
        $item = Find-Item $plan 'DLP rule' 'DLP-FinancialData-HighVolume' 'Update'
        ($item.Details -join "`n") | Should -Match 'BlockAccess: True -> False'
    }

    It 'reports a marking that is on in the tenant but removed from the config, and leaves it' {
        $path = New-TestConfig -Change { param($c) ($c.SensitivityLabels | Where-Object Name -eq 'Internal').ContentMarking.Remove('Footer') }
        $plan = Invoke-Deploy $path
        $drift = Find-Item $plan 'Sensitivity label' 'Internal' 'Drift'
        ($drift.Details -join "`n") | Should -Match 'Footer is on in the tenant'
        $global:MockWrites | Should -HaveCount 0
    }

    It 'resolves defaultlabelid from a label name to its GUID' {
        $policy = Get-LabelPolicy -Identity 'Default-Label-Policy'
        $guid = "$((Get-Label -Identity 'Internal').Guid)"
        $policy.Settings | Should -Contain "[defaultlabelid, $guid]"
    }

    It 'collects failures, keeps going, and throws at the end' {
        $path = New-TestConfig -Change { param($c) ($c.SensitivityLabels | Where-Object Name -eq 'Public').Tooltip = 'x' }
        $global:MockFail = @('Set-Label')
        { Invoke-Deploy $path } | Should -Throw '*failed*'
    }
}

Describe 'Retention' {
    BeforeEach { Reset-MockTenant }

    It 'creates a retention rule on a later run when it failed the first time' {
        $cfg = Join-Path $script:root 'examples/baseline.json'
        $global:MockFail = @('New-RetentionComplianceRule')
        { Invoke-Deploy $cfg } | Should -Throw
        $global:MockFail = @()
        $global:MockWrites.Clear()

        $plan = Invoke-Deploy $cfg
        (Find-Item $plan 'Retention rule' 'Retention-Email-7Years-Rule' 'Create') | Should -HaveCount 1
        $global:MockWrites | Should -Contain 'New-RetentionComplianceRule Retention-Email-7Years-Rule'
    }

    It 'reports a changed retention action as drift instead of trying to change it' {
        $null = Invoke-Deploy (Join-Path $script:root 'examples/baseline.json')
        $path = New-TestConfig -Change { param($c) $c.RetentionLabels[0].RetentionAction = 'Keep' }
        $plan = Invoke-Deploy $path
        (Find-Item $plan 'Retention label' 'Retain-7Years' 'Drift') | Should -HaveCount 1
    }
}

Describe 'Safety checks' {
    BeforeEach { Reset-MockTenant }

    It 'stops when the session belongs to another tenant' {
        $path = New-TestConfig -Change { param($c) $c.TenantId = '99999999-9999-9999-9999-999999999999' }
        { Invoke-PurviewDeployment -ConfigFile $path -UseExistingSession -WhatIf 6>$null } | Should -Throw '*Nothing was changed*'
        $global:MockWrites | Should -HaveCount 0
    }

    It 'refuses a config with a label group in a label policy' {
        $path = New-TestConfig -Change { param($c) $c.LabelPolicies[0].Labels += 'Confidential' }
        { Invoke-Deploy $path } | Should -Throw '*error*'
        $global:MockWrites | Should -HaveCount 0
    }

    It 'refuses placeholders left in from the examples' {
        $path = New-TestConfig -Change { param($c) $c.LabelPolicies[0].Settings.defaultlabelid = 'REPLACE-WITH-GUID' }
        Test-PurviewConfig -ConfigFile $path 6>$null | Should -BeFalse
    }

    It 'refuses UserDefined encryption for files and email without DoNotForward or EncryptOnly' {
        $path = New-TestConfig -Change {
            param($c)
            $label = $c.SensitivityLabels.SubLabels | Where-Object { $_.Encryption.ProtectionType -eq 'UserDefined' } | Select-Object -First 1
            $label.Encryption.Remove('DoNotForward')
        }
        Test-PurviewConfig -ConfigFile $path 6>$null | Should -BeFalse
    }

    It 'refuses a sublabel published without its parent label (classic scheme)' {
        $path = New-TestConfig -Example 'nl-smb.json' -Change {
            param($c)
            $parent = $c.SensitivityLabels | Where-Object { $_.SubLabels } | Select-Object -First 1
            $c.LabelPolicies[0].Labels = @($c.LabelPolicies[0].Labels | Where-Object { $_ -ne $parent.Name })
        }
        Test-PurviewConfig -ConfigFile $path 6>$null | Should -BeFalse
    }
}
