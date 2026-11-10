@{
    # Write-Host is deliberate: the plan is console output for a person, the objects go to -PassThru.
    ExcludeRules = @('PSAvoidUsingWriteHost')
}
