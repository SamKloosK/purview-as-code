@{
    RootModule        = 'PurviewAsCode.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '3367be14-9b96-4ce9-91ea-c37aaa482c16'
    Author            = 'Samantha Kloos-Kilkens'
    CompanyName       = 'Argus IT'
    Copyright         = '(c) 2026 Samantha Kloos-Kilkens. MIT licence.'
    Description       = 'Deploy Microsoft Purview sensitivity labels, label policies, DLP and retention from a JSON config, with a plan of every change before anything is applied.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Invoke-PurviewDeployment', 'Test-PurviewConfig', 'Get-PurviewLabelState', 'Export-PurviewConfig')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags                       = @('Purview', 'SensitivityLabels', 'DLP', 'Retention', 'Compliance')
            ProjectUri                 = 'https://github.com/SamKloosK/purview-as-code'
            LicenseUri                 = 'https://github.com/SamKloosK/purview-as-code/blob/main/LICENSE'
            ExternalModuleDependencies = @('ExchangeOnlineManagement')
        }
    }
}
