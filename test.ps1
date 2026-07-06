#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProjectRoot = $PSScriptRoot
$script:TestCount = 0
$script:Failures = @()

function Invoke-Test {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Body
    )

    $script:TestCount++
    try {
        & $Body
        Write-Host "PASS $Name"
    } catch {
        $script:Failures += [PSCustomObject]@{
            Name = $Name
            Error = $_
        }
        Write-Host "FAIL $Name"
        Write-Host "  $($_.Exception.Message)"
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Actual,

        [Parameter(Mandatory)]
        [AllowNull()]
        $Expected,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected: <$Expected> Actual: <$Actual>"
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-False {
    param(
        [bool]$Condition,
        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Condition) {
        throw $Message
    }
}

function Assert-Match {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Actual,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Actual -notmatch $Pattern) {
        throw "$Message Pattern: <$Pattern> Actual: <$Actual>"
    }
}

function Assert-NotMatch {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Actual,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Actual -match $Pattern) {
        throw "$Message Pattern should not match: <$Pattern>"
    }
}

function Assert-SequenceEqual {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Actual,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Expected,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw "$Message Expected count: <$($Expected.Count)> Actual count: <$($Actual.Count)>"
    }

    for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
        if ($Actual[$Index] -ne $Expected[$Index]) {
            throw "$Message Difference at index $Index. Expected: <$($Expected[$Index])> Actual: <$($Actual[$Index])>"
        }
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$ExpectedMessagePattern
    )

    $Thrown = $false
    try {
        & $ScriptBlock
    } catch {
        $Thrown = $true
        if ($ExpectedMessagePattern -and $_.Exception.Message -notmatch $ExpectedMessagePattern) {
            throw "$Message Expected error matching <$ExpectedMessagePattern>, got <$($_.Exception.Message)>"
        }
    }

    if (-not $Thrown) {
        throw $Message
    }
}

function Get-ScriptAst {
    param([Parameter(Mandatory)][string]$Path)

    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
    if ($ParseErrors.Count -ne 0) {
        throw "PowerShell parse errors in $Path"
    }

    $Ast
}

function Import-ScriptFunctionsForTest {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$FunctionName,

        [Parameter(Mandatory)]
        [string]$Prefix,

        [string]$Initializer = '',

        [string]$AdditionalScript = '',

        [string[]]$AdditionalExportName = @()
    )

    $Ast = Get-ScriptAst $Path
    $Definitions = foreach ($Name in $FunctionName) {
        $FunctionAst = $Ast.Find({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name
        }, $true)

        if (-not $FunctionAst) {
            throw "Function $Name was not found in $Path"
        }

        $FunctionAst.Extent.Text
    }

    $ExportNames = (($FunctionName + $AdditionalExportName) | ForEach-Object { "'$_'" }) -join ', '
    $ModuleText = @"
$Initializer
$($Definitions -join "`r`n`r`n")
$AdditionalScript
Export-ModuleMember -Function $ExportNames
"@

    $Module = New-Module -Name "WindowsDetailsFieldsTest$Prefix" -ScriptBlock ([scriptblock]::Create($ModuleText))
    Import-Module $Module -Prefix $Prefix -Global -Force
}

function Get-ScriptParameterNames {
    param([Parameter(Mandatory)][string]$Path)

    $Ast = Get-ScriptAst $Path
    if (-not $Ast.ParamBlock) {
        return @()
    }

    @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

function New-TestTempDirectory {
    $Path = Join-Path ([System.IO.Path]::GetTempPath()) ("WindowsDetailsFields.Tests." + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $Path
}

function Get-EncodingPreambleLength {
    param([Parameter(Mandatory)][System.Text.Encoding]$Encoding)

    @($Encoding.GetPreamble()).Length
}

function Invoke-Quietly {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)

    & $ScriptBlock 6>$null
}

function Test-IsWindows {
    if ($PSVersionTable.ContainsKey('Platform')) {
        return $PSVersionTable.Platform -eq 'Win32NT'
    }

    $true
}

function Get-Utf8FileContent {
    param([Parameter(Mandatory)][string]$Path)

    [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding -ArgumentList $true))
}

function Get-CommandValidateSetValues {
    param(
        [Parameter(Mandatory)]
        [string]$CommandName,

        [Parameter(Mandatory)]
        [string]$ParameterName
    )

    $Command = Get-Command $CommandName
    $Parameter = $Command.Parameters[$ParameterName]
    $ValidateSet = $Parameter.Attributes |
        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
        Select-Object -First 1

    if (-not $ValidateSet) {
        throw "$CommandName parameter $ParameterName does not have a ValidateSet attribute."
    }

    @($ValidateSet.ValidValues)
}

function New-TestInstallTarget {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [string]$Name = 'PowerShell'
    )

    [PSCustomObject]@{
        Name = $Name
        ModuleDir = Join-Path $Root "Modules\WindowsDetailsFields"
        Profile = Join-Path $Root 'profile.ps1'
    }
}

$ProfileBlockInitializer = @'
$ModuleName = 'WindowsDetailsFields'
$BeginMarker = '# BEGIN WindowsDetailsFields'
$EndMarker = '# END WindowsDetailsFields'
$SentinelName = '.managed-by-WindowsDetailsFields'
'@

$InstallScriptPathLiteral = (Join-Path $ProjectRoot 'install.ps1').Replace("'", "''")
$InstallInitializer = $ProfileBlockInitializer + "`r`n" + ('$InstallScriptPath = ''{0}''' -f $InstallScriptPathLiteral)

$InstallWrapperScript = @'
function Start-ModuleFileForTest {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)]$InstallTarget)

    Install-ModuleFile $InstallTarget
}

function Start-ProfileImportForTest {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)]$InstallTarget)

    Install-ProfileImport $InstallTarget
}
'@

$UninstallWrapperScript = @'
function Start-ProfileImportForTest {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)]$InstallTarget)

    Uninstall-ProfileImport $InstallTarget
}

function Start-ModuleFileForTest {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)]$InstallTarget)

    Uninstall-ModuleFile $InstallTarget
}
'@

$FakeRegistryInitializer = @'
$script:FakeRegistry = @{}

function Set-RegistryForTest {
    param([hashtable]$Registry)

    $script:FakeRegistry = $Registry
}

function New-RegistryKeyForTest {
    param([hashtable]$Values)

    $Key = [PSCustomObject]@{ Values = $Values }
    $Key | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
        param($Name)

        if ($this.Values.ContainsKey($Name)) {
            return $this.Values[$Name]
        }

        $null
    } -Force
    $Key
}

function Get-Item {
    param(
        [string]$LiteralPath,
        [object]$ErrorAction
    )

    if ($script:FakeRegistry.ContainsKey($LiteralPath)) {
        return (New-RegistryKeyForTest $script:FakeRegistry[$LiteralPath])
    }

    $null
}

function Add-Type {
    param([string]$TypeDefinition)
}
'@

Import-ScriptFunctionsForTest `
    -Path (Join-Path $ProjectRoot 'install.ps1') `
    -FunctionName @(
        'Get-RepositoryFileUrl',
        'Get-ModuleSource',
        'Get-Utf8BomEncoding',
        'Get-AnsiEncoding',
        'Get-ProfileEncoding',
        'Test-TextFileContent',
        'Backup-File',
        'Test-ExecutionPolicyError',
        'Get-InstallTargets',
        'Remove-ProfileBlock',
        'Install-ModuleFile',
        'Install-ProfileImport'
    ) `
    -Prefix 'Install' `
    -Initializer $InstallInitializer `
    -AdditionalScript $InstallWrapperScript `
    -AdditionalExportName @('Start-ModuleFileForTest', 'Start-ProfileImportForTest')

Import-ScriptFunctionsForTest `
    -Path (Join-Path $ProjectRoot 'uninstall.ps1') `
    -FunctionName @(
        'Get-Utf8BomEncoding',
        'Get-AnsiEncoding',
        'Get-ProfileEncoding',
        'Backup-File',
        'Get-ModuleBackupFiles',
        'Get-InstallTargets',
        'Remove-ProfileBlock',
        'Uninstall-ProfileImport',
        'Uninstall-ModuleFile'
    ) `
    -Prefix 'Uninstall' `
    -Initializer $ProfileBlockInitializer `
    -AdditionalScript $UninstallWrapperScript `
    -AdditionalExportName @('Start-ProfileImportForTest', 'Start-ModuleFileForTest')

Import-ScriptFunctionsForTest `
    -Path (Join-Path $ProjectRoot 'WindowsDetailsFields.psm1') `
    -FunctionName @(
        'ConvertTo-ShortRegistryPath',
        'Split-PropertyList'
    ) `
    -Prefix 'Module'

Import-ScriptFunctionsForTest `
    -Path (Join-Path $ProjectRoot 'WindowsDetailsFields.psm1') `
    -FunctionName @('Show-WindowsDetailsFields') `
    -Prefix 'Fake' `
    -Initializer $FakeRegistryInitializer `
    -AdditionalExportName @('Set-RegistryForTest')

Invoke-Test 'PowerShell files parse without errors' {
    foreach ($RelativePath in @('install.ps1', 'uninstall.ps1', 'WindowsDetailsFields.psm1', 'test.ps1')) {
        [void](Get-ScriptAst (Join-Path $ProjectRoot $RelativePath))
    }
}

Invoke-Test 'install and uninstall scripts stay self-contained' {
    $SetupPath = Join-Path $ProjectRoot 'setup.ps1'
    Assert-False (Test-Path -LiteralPath $SetupPath) 'setup.ps1 should not exist.'

    $ForbiddenParameters = @('Target', 'NoProfile', 'NoBackup', 'Force', 'Uninstall')
    foreach ($ScriptName in @('install.ps1', 'uninstall.ps1')) {
        $ScriptPath = Join-Path $ProjectRoot $ScriptName
        Assert-True (Test-Path -LiteralPath $ScriptPath) "$ScriptName should exist."

        $ParameterNames = @(Get-ScriptParameterNames $ScriptPath)
        foreach ($ParameterName in $ForbiddenParameters) {
            Assert-False ($ParameterNames -contains $ParameterName) "$ScriptName should not expose -$ParameterName."
        }

        $Content = [System.IO.File]::ReadAllText($ScriptPath)
        Assert-NotMatch $Content 'setup\.ps1' "$ScriptName should not reference setup.ps1."
        Assert-NotMatch $Content 'managed-by-WindowsDetailsFields-setup' "$ScriptName should not keep the legacy setup sentinel name."
        Assert-NotMatch $Content 'SetupUrl' "$ScriptName should not download or delegate to a setup script."
        Assert-NotMatch $Content '\$(Target|NoProfile|NoBackup|Force)\b' "$ScriptName should hard-code the former option behavior instead of branching on option variables."
        Assert-Match $Content 'PowerShell\\Modules\\\$ModuleName' "$ScriptName should target PowerShell module installation."
        Assert-Match $Content 'WindowsPowerShell\\Modules\\\$ModuleName' "$ScriptName should target Windows PowerShell module installation."
        Assert-Match $Content 'profile\.ps1' "$ScriptName should manage profile imports."
        Assert-Match $Content 'Copy-Item -LiteralPath \$Path -Destination \$BackupPath -Force' "$ScriptName should create backups before changing existing files."
    }
}

Invoke-Test 'README stays aligned with public command and root scripts' {
    $Readme = Get-Utf8FileContent (Join-Path $ProjectRoot 'README.md')

    Assert-Match $Readme 'raw\.githubusercontent\.com/xincongjun/WindowsDetailsFields/main/install\.ps1' 'README install command should point at the root install script.'
    Assert-Match $Readme 'raw\.githubusercontent\.com/xincongjun/WindowsDetailsFields/main/uninstall\.ps1' 'README uninstall command should point at the root uninstall script.'

    Remove-Module WindowsDetailsFields -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $ProjectRoot 'WindowsDetailsFields.psm1') -Force
    $Command = Get-Command Show-WindowsDetailsFields
    foreach ($ParameterName in @('Extension', 'Width', 'FieldList')) {
        Assert-True $Command.Parameters.ContainsKey($ParameterName) "README documents parameter $ParameterName, so the command should expose it."
        Assert-Match $Readme ([regex]::Escape("`-$ParameterName")) "README should document -$ParameterName."
    }

    $CommandFieldListValues = @(Get-CommandValidateSetValues 'Show-WindowsDetailsFields' 'FieldList' | Sort-Object)

    $ReadmeLines = @($Readme -split '\r?\n')
    $FieldListStart = -1
    for ($Index = 0; $Index -lt $ReadmeLines.Count; $Index++) {
        if ($ReadmeLines[$Index] -match '^\| `Auto` \|') {
            $FieldListStart = $Index
            break
        }
    }

    Assert-True ($FieldListStart -ge 0) 'README should contain a FieldList values table.'

    $FieldListEnd = $ReadmeLines.Count
    for ($Index = $FieldListStart + 1; $Index -lt $ReadmeLines.Count; $Index++) {
        if ($ReadmeLines[$Index] -match '^## ') {
            $FieldListEnd = $Index
            break
        }
    }

    $ReadmeFieldListValues = @(
        for ($Index = $FieldListStart; $Index -lt $FieldListEnd; $Index++) {
            $Match = [regex]::Match($ReadmeLines[$Index], '^\| `([^`]+)` \|')
            if ($Match.Success) { $Match.Groups[1].Value }
        }
    ) | Sort-Object

    Assert-SequenceEqual $ReadmeFieldListValues $CommandFieldListValues 'README FieldList values should match the command ValidateSet.'
}

Invoke-Test 'install profile block removal keeps surrounding user lines separated' {
    $Content = "Set-Location C:\Work`r`n# BEGIN WindowsDetailsFields`r`nImport-Module WindowsDetailsFields -ErrorAction SilentlyContinue`r`n# END WindowsDetailsFields`r`nWrite-Host Ready`r`n"
    $Expected = "Set-Location C:\Work`r`nWrite-Host Ready`r`n"

    Assert-Equal (Remove-InstallProfileBlock $Content) $Expected 'Install cleanup should preserve one newline between surrounding user lines.'
}

Invoke-Test 'uninstall profile block removal keeps surrounding user lines separated' {
    $Content = "Set-Location C:\Work`r`n# BEGIN WindowsDetailsFields`r`nImport-Module WindowsDetailsFields -ErrorAction SilentlyContinue`r`n# END WindowsDetailsFields`r`nWrite-Host Ready`r`n"
    $Expected = "Set-Location C:\Work`r`nWrite-Host Ready`r`n"

    Assert-Equal (Remove-UninstallProfileBlock $Content) $Expected 'Uninstall cleanup should preserve one newline between surrounding user lines.'
}

Invoke-Test 'profile block removal handles boundary and repeated blocks' {
    $Block = "# BEGIN WindowsDetailsFields`r`nImport-Module WindowsDetailsFields -ErrorAction SilentlyContinue`r`n# END WindowsDetailsFields`r`n"
    Assert-Equal (Remove-InstallProfileBlock $Block) '' 'A file containing only the managed block should become empty.'
    Assert-Equal (Remove-InstallProfileBlock ("first`r`n" + $Block + $Block + "last`r`n")) "first`r`nlast`r`n" 'Repeated managed blocks should be removed without deleting user lines.'
    Assert-Equal (Remove-UninstallProfileBlock "first`r`nlast`r`n") "first`r`nlast`r`n" 'Content without a managed block should be unchanged.'
}

Invoke-Test 'install helper builds repository raw file URLs' {
    Assert-Equal (Get-InstallRepositoryFileUrl 'WindowsDetailsFields.psm1') 'https://raw.githubusercontent.com/xincongjun/WindowsDetailsFields/main/WindowsDetailsFields.psm1' 'Repository URL should point at the main branch raw file.'
}

Invoke-Test 'install helper reads the local sibling module source' {
    $Expected = Get-Utf8FileContent (Join-Path $ProjectRoot 'WindowsDetailsFields.psm1')

    Assert-Equal (Get-InstallModuleSource) $Expected 'Local installation should read the sibling module file before trying the network.'
}

Invoke-Test 'install and uninstall target helpers point at both PowerShell profile families' {
    $InstallTargets = @(Get-InstallInstallTargets)
    $UninstallTargets = @(Get-UninstallInstallTargets)

    foreach ($Targets in @($InstallTargets, $UninstallTargets)) {
        Assert-Equal $Targets.Count 2 'Target helper should return PowerShell and WindowsPowerShell targets.'
        Assert-SequenceEqual @($Targets | ForEach-Object { $_.Name }) @('PowerShell', 'WindowsPowerShell') 'Target names should stay in the expected order.'
        Assert-Match $Targets[0].ModuleDir 'PowerShell\\Modules\\WindowsDetailsFields$' 'PowerShell module target should use the PowerShell profile family.'
        Assert-Match $Targets[0].Profile 'PowerShell\\profile\.ps1$' 'PowerShell profile target should point at profile.ps1.'
        Assert-Match $Targets[1].ModuleDir 'WindowsPowerShell\\Modules\\WindowsDetailsFields$' 'WindowsPowerShell module target should use the WindowsPowerShell profile family.'
        Assert-Match $Targets[1].Profile 'WindowsPowerShell\\profile\.ps1$' 'WindowsPowerShell profile target should point at profile.ps1.'
    }
}

Invoke-Test 'profile encoding detection preserves expected profile encodings' {
    $Temp = New-TestTempDirectory
    try {
        $MissingPath = Join-Path $Temp 'missing-profile.ps1'
        Assert-Equal (Get-EncodingPreambleLength (Get-InstallProfileEncoding $MissingPath)) 3 'Missing install profile should default to UTF-8 BOM.'
        Assert-Equal (Get-EncodingPreambleLength (Get-UninstallProfileEncoding $MissingPath)) 3 'Missing uninstall profile should default to UTF-8 BOM.'

        $ModernDir = Join-Path $Temp 'PowerShell'
        New-Item -ItemType Directory -Path $ModernDir -Force | Out-Null
        $ModernProfile = Join-Path $ModernDir 'profile.ps1'
        $Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
        [System.IO.File]::WriteAllBytes($ModernProfile, $Utf8NoBom.GetBytes('Write-Host modern'))
        Assert-Equal (Get-EncodingPreambleLength (Get-InstallProfileEncoding $ModernProfile)) 0 'PowerShell profile with UTF-8 no BOM should stay no BOM.'

        $WindowsPowerShellDir = Join-Path $Temp 'WindowsPowerShell'
        New-Item -ItemType Directory -Path $WindowsPowerShellDir -Force | Out-Null
        $WindowsPowerShellProfile = Join-Path $WindowsPowerShellDir 'profile.ps1'
        [System.IO.File]::WriteAllBytes($WindowsPowerShellProfile, $Utf8NoBom.GetBytes('Write-Host legacy'))
        Assert-Equal (Get-EncodingPreambleLength (Get-InstallProfileEncoding $WindowsPowerShellProfile)) 3 'WindowsPowerShell profile without BOM should be rewritten with UTF-8 BOM.'
    } finally {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'install helper compares text using the selected encoding' {
    $Temp = New-TestTempDirectory
    try {
        $Path = Join-Path $Temp 'module.psm1'
        $Encoding = Get-InstallUtf8BomEncoding
        [System.IO.File]::WriteAllText($Path, "alpha`r`n", $Encoding)

        Assert-True (Test-InstallTextFileContent $Path "alpha`r`n" $Encoding) 'Exact file content should match.'
        Assert-False (Test-InstallTextFileContent $Path "beta`r`n" $Encoding) 'Different file content should not match.'
        Assert-False (Test-InstallTextFileContent (Join-Path $Temp 'missing.psm1') "alpha`r`n" $Encoding) 'Missing file should not match.'
    } finally {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'backup helper copies existing files and ignores missing files' {
    $Temp = New-TestTempDirectory
    try {
        $Path = Join-Path $Temp 'profile.ps1'
        [System.IO.File]::WriteAllText($Path, "profile`r`n", (Get-InstallUtf8BomEncoding))

        Invoke-Quietly { Backup-InstallFile $Path }

        $Backups = @(Get-ChildItem -LiteralPath $Temp -Filter 'profile.ps1.bak.*')
        Assert-Equal $Backups.Count 1 'Backup helper should create one timestamped backup for an existing file.'
        Assert-Equal (Get-Utf8FileContent $Backups[0].FullName) "profile`r`n" 'Backup content should match the source file.'

        Invoke-Quietly { Backup-InstallFile (Join-Path $Temp 'missing.ps1') }
        $BackupsAfterMissing = @(Get-ChildItem -LiteralPath $Temp -Filter 'missing.ps1.bak.*')
        Assert-Equal $BackupsAfterMissing.Count 0 'Missing files should not create backups.'
    } finally {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'execution policy errors are recognized without hiding other errors' {
    $SecurityException = New-Object System.Management.Automation.PSSecurityException -ArgumentList 'blocked'
    $SecurityRecord = New-Object System.Management.Automation.ErrorRecord -ArgumentList $SecurityException, 'SecurityError', ([System.Management.Automation.ErrorCategory]::SecurityError), $null
    Assert-True (Test-InstallExecutionPolicyError $SecurityRecord) 'PSSecurityException should be classified as execution policy related.'

    $OtherException = New-Object System.InvalidOperationException -ArgumentList 'other'
    $OtherRecord = New-Object System.Management.Automation.ErrorRecord -ArgumentList $OtherException, 'OtherError', ([System.Management.Automation.ErrorCategory]::InvalidOperation), $null
    Assert-False (Test-InstallExecutionPolicyError $OtherRecord) 'Non-policy errors should not be classified as execution policy related.'
}

Invoke-Test 'install module file writes module sentinel backup and honors WhatIf' {
        $Temp = New-TestTempDirectory
    try {
        $WhatIfTarget = New-TestInstallTarget (Join-Path $Temp 'whatif')
        Assert-True (Invoke-Quietly { Start-InstallModuleFileForTest $WhatIfTarget -WhatIf }) 'WhatIf install should still report a successful preview.'
        Assert-False (Test-Path -LiteralPath $WhatIfTarget.ModuleDir) 'WhatIf install should not create the module directory.'

        $Target = New-TestInstallTarget (Join-Path $Temp 'real')
        Assert-True (Invoke-Quietly { Start-InstallModuleFileForTest $Target }) 'Install should report success when module files are written.'

        $ModulePath = Join-Path $Target.ModuleDir 'WindowsDetailsFields.psm1'
        $SentinelPath = Join-Path $Target.ModuleDir '.managed-by-WindowsDetailsFields'
        $ExpectedModuleContent = (Get-InstallModuleSource).Trim() + "`r`n"

        Assert-True (Test-Path -LiteralPath $ModulePath) 'Install should write the module file.'
        Assert-True (Test-Path -LiteralPath $SentinelPath) 'Install should write the sentinel file.'
        Assert-Equal (Get-Utf8FileContent $ModulePath) $ExpectedModuleContent 'Installed module content should match normalized source content.'
        Assert-Equal (Get-Utf8FileContent $SentinelPath) "Managed by install.ps1.`r`n" 'Sentinel content should identify install.ps1.'

        [System.IO.File]::WriteAllText($ModulePath, "old module`r`n", (Get-InstallUtf8BomEncoding))
        Assert-True (Invoke-Quietly { Start-InstallModuleFileForTest $Target }) 'Install should update a changed module file.'

        $Backups = @(Get-ChildItem -LiteralPath $Target.ModuleDir -Filter 'WindowsDetailsFields.psm1.bak.*')
        Assert-Equal $Backups.Count 1 'Changed module file should be backed up before replacement.'
        Assert-Equal (Get-Utf8FileContent $Backups[0].FullName) "old module`r`n" 'Module backup should contain the previous module content.'
        Assert-Equal (Get-Utf8FileContent $ModulePath) $ExpectedModuleContent 'Changed module file should be replaced with source content.'
    } finally {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'install profile import writes replaces and honors WhatIf' {
    $Temp = New-TestTempDirectory
    try {
        $WhatIfTarget = New-TestInstallTarget (Join-Path $Temp 'whatif')
        $WhatIfProfileParent = Split-Path -Parent $WhatIfTarget.Profile
        New-Item -ItemType Directory -Path $WhatIfProfileParent -Force | Out-Null
        [System.IO.File]::WriteAllText($WhatIfTarget.Profile, "Keep`r`n", (Get-InstallUtf8BomEncoding))
        Invoke-Quietly { Start-InstallProfileImportForTest $WhatIfTarget -WhatIf }
        Assert-Equal (Get-Utf8FileContent $WhatIfTarget.Profile) "Keep`r`n" 'WhatIf profile install should not change an existing profile.'

        $Target = New-TestInstallTarget (Join-Path $Temp 'real')
        $Parent = Split-Path -Parent $Target.Profile
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
        $OldBlock = "# BEGIN WindowsDetailsFields`r`nOld-Command`r`n# END WindowsDetailsFields`r`n"
        [System.IO.File]::WriteAllText($Target.Profile, "Before`r`n$OldBlock`r`nAfter`r`n", (Get-InstallUtf8BomEncoding))

        Invoke-Quietly { Start-InstallProfileImportForTest $Target }

        $Content = Get-Utf8FileContent $Target.Profile
        Assert-Match $Content 'Before' 'Install should preserve user content before the old managed block.'
        Assert-Match $Content 'After' 'Install should preserve user content after the old managed block.'
        Assert-Match $Content 'After\r?\n\r?\n# BEGIN WindowsDetailsFields' 'Install should append the current managed block after preserved user content.'
        Assert-Match $Content 'Import-Module WindowsDetailsFields -ErrorAction SilentlyContinue' 'Install should write the desired import command.'
        Assert-NotMatch $Content 'Old-Command' 'Install should replace old managed block content.'
        Assert-Equal ([regex]::Matches($Content, '# BEGIN WindowsDetailsFields').Count) 1 'Install should leave exactly one managed block.'
    } finally {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'uninstall helper finds only managed module backups' {
    $Temp = New-TestTempDirectory
    try {
        $ModuleDir = Join-Path $Temp 'WindowsDetailsFields'
        New-Item -ItemType Directory -Path $ModuleDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $ModuleDir 'WindowsDetailsFields.psm1.bak.20260102030405') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $ModuleDir 'other.psm1.bak.20260102030405') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $ModuleDir 'WindowsDetailsFields.psm1.bak.directory') -Force | Out-Null

        $Backups = @(Get-UninstallModuleBackupFiles $ModuleDir)
        Assert-Equal $Backups.Count 1 'Only matching backup files should be returned.'
        Assert-Equal $Backups[0].Name 'WindowsDetailsFields.psm1.bak.20260102030405' 'The matching module backup should be returned.'
        Assert-Equal @(Get-UninstallModuleBackupFiles (Join-Path $Temp 'missing')).Count 0 'Missing module directory should have no backups.'
    } finally {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'uninstall profile import removes managed block backs up and honors WhatIf' {
    $Temp = New-TestTempDirectory
    try {
        $Block = "# BEGIN WindowsDetailsFields`r`nImport-Module WindowsDetailsFields -ErrorAction SilentlyContinue`r`n# END WindowsDetailsFields`r`n"

        $WhatIfTarget = New-TestInstallTarget (Join-Path $Temp 'whatif')
        $WhatIfParent = Split-Path -Parent $WhatIfTarget.Profile
        New-Item -ItemType Directory -Path $WhatIfParent -Force | Out-Null
        [System.IO.File]::WriteAllText($WhatIfTarget.Profile, "Before`r`n$Block`r`nAfter`r`n", (Get-UninstallUtf8BomEncoding))
        Invoke-Quietly { Start-UninstallProfileImportForTest $WhatIfTarget -WhatIf }
        Assert-Equal (Get-Utf8FileContent $WhatIfTarget.Profile) "Before`r`n$Block`r`nAfter`r`n" 'WhatIf uninstall should not change the profile.'

        $Target = New-TestInstallTarget (Join-Path $Temp 'real')
        $Parent = Split-Path -Parent $Target.Profile
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
        [System.IO.File]::WriteAllText($Target.Profile, "Before`r`n$Block`r`nAfter`r`n", (Get-UninstallUtf8BomEncoding))

        Invoke-Quietly { Start-UninstallProfileImportForTest $Target }

        $UninstalledContent = Get-Utf8FileContent $Target.Profile
        Assert-Match $UninstalledContent 'Before' 'Uninstall should preserve user content before the managed block.'
        Assert-Match $UninstalledContent 'After' 'Uninstall should preserve user content after the managed block.'
        Assert-NotMatch $UninstalledContent '# BEGIN WindowsDetailsFields' 'Uninstall should remove the managed profile block.'
        Assert-NotMatch $UninstalledContent 'Import-Module WindowsDetailsFields' 'Uninstall should remove the managed import command.'
        $Backups = @(Get-ChildItem -LiteralPath $Parent -Filter 'profile.ps1.bak.*')
        Assert-Equal $Backups.Count 1 'Uninstall should back up a changed profile.'
        Assert-Match (Get-Utf8FileContent $Backups[0].FullName) '# BEGIN WindowsDetailsFields' 'Profile backup should contain the pre-uninstall managed block.'

        $NoBlockTarget = New-TestInstallTarget (Join-Path $Temp 'noblock')
        $NoBlockParent = Split-Path -Parent $NoBlockTarget.Profile
        New-Item -ItemType Directory -Path $NoBlockParent -Force | Out-Null
        [System.IO.File]::WriteAllText($NoBlockTarget.Profile, "UserOnly`r`n", (Get-UninstallUtf8BomEncoding))
        Invoke-Quietly { Start-UninstallProfileImportForTest $NoBlockTarget }
        Assert-Equal @(Get-ChildItem -LiteralPath $NoBlockParent -Filter 'profile.ps1.bak.*').Count 0 'Profile without a managed block should not be backed up.'
    } finally {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'uninstall module file removes only managed files and honors WhatIf' {
    $Temp = New-TestTempDirectory
    try {
        $WhatIfTarget = New-TestInstallTarget (Join-Path $Temp 'whatif')
        New-Item -ItemType Directory -Path $WhatIfTarget.ModuleDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $WhatIfTarget.ModuleDir 'WindowsDetailsFields.psm1') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $WhatIfTarget.ModuleDir '.managed-by-WindowsDetailsFields') -Force | Out-Null
        Invoke-Quietly { Start-UninstallModuleFileForTest $WhatIfTarget -WhatIf }
        Assert-True (Test-Path -LiteralPath (Join-Path $WhatIfTarget.ModuleDir 'WindowsDetailsFields.psm1')) 'WhatIf uninstall should keep the module file.'
        Assert-True (Test-Path -LiteralPath (Join-Path $WhatIfTarget.ModuleDir '.managed-by-WindowsDetailsFields')) 'WhatIf uninstall should keep the sentinel file.'

        $Target = New-TestInstallTarget (Join-Path $Temp 'with-unrelated')
        New-Item -ItemType Directory -Path $Target.ModuleDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $Target.ModuleDir 'WindowsDetailsFields.psm1') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $Target.ModuleDir '.managed-by-WindowsDetailsFields') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $Target.ModuleDir 'WindowsDetailsFields.psm1.bak.20260102030405') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $Target.ModuleDir 'keep.txt') -Force | Out-Null

        Invoke-Quietly { Start-UninstallModuleFileForTest $Target }

        Assert-False (Test-Path -LiteralPath (Join-Path $Target.ModuleDir 'WindowsDetailsFields.psm1')) 'Uninstall should remove the managed module file.'
        Assert-False (Test-Path -LiteralPath (Join-Path $Target.ModuleDir '.managed-by-WindowsDetailsFields')) 'Uninstall should remove the sentinel file.'
        Assert-False (Test-Path -LiteralPath (Join-Path $Target.ModuleDir 'WindowsDetailsFields.psm1.bak.20260102030405')) 'Uninstall should remove managed module backups.'
        Assert-True (Test-Path -LiteralPath (Join-Path $Target.ModuleDir 'keep.txt')) 'Uninstall should preserve unrelated files.'
        Assert-True (Test-Path -LiteralPath $Target.ModuleDir) 'Uninstall should keep a non-empty module directory.'

        $EmptyTarget = New-TestInstallTarget (Join-Path $Temp 'empty-after-managed-removal')
        New-Item -ItemType Directory -Path $EmptyTarget.ModuleDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $EmptyTarget.ModuleDir 'WindowsDetailsFields.psm1') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $EmptyTarget.ModuleDir '.managed-by-WindowsDetailsFields') -Force | Out-Null
        Invoke-Quietly { Start-UninstallModuleFileForTest $EmptyTarget }
        Assert-False (Test-Path -LiteralPath $EmptyTarget.ModuleDir) 'Uninstall should remove the module directory when no files remain.'
    } finally {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'module helper parses property lists and registry sources' {
    $Properties = @(Split-ModulePropertyList 'prop:*System.Title;~System.Author;;System.Comment')
    Assert-SequenceEqual $Properties @('System.Title', 'System.Author', 'System.Comment') 'Property list parsing should remove prop prefix, flags, and empty entries.'
    Assert-Equal @(Split-ModulePropertyList '   ').Count 0 'Blank property lists should return no fields.'
    Assert-Equal (ConvertTo-ModuleShortRegistryPath 'Registry::HKEY_CLASSES_ROOT\.jpg') 'HKCR\.jpg' 'Registry source should be shortened for display.'
    Assert-Equal (ConvertTo-ModuleShortRegistryPath 'Generic fallback') 'Generic fallback' 'Non-registry source should stay unchanged.'
}

Invoke-Test 'module registry lookup uses deterministic source and list priority' {
    if (-not (Test-IsWindows)) {
        Write-Host 'SKIP fake registry test requires Windows because the command guards platform support.'
        return
    }

    Set-FakeRegistryForTest @{
        'Registry::HKEY_CLASSES_ROOT\.abc' = @{ '' = 'abcfile'; PerceivedType = 'image' }
        'Registry::HKEY_CLASSES_ROOT\SystemFileAssociations\.abc' = @{ PreviewDetails = 'prop:System.Title;System.Comment' }
        'Registry::HKEY_CLASSES_ROOT\abcfile' = @{ FullDetails = 'prop:System.Author' }
        'Registry::HKEY_CLASSES_ROOT\SystemFileAssociations\image' = @{ FullDetails = 'prop:System.Subject' }
        'Registry::HKEY_CLASSES_ROOT\AllFilesystemObjects' = @{ FullDetails = 'prop:System.DateCreated' }
        'Registry::HKEY_CLASSES_ROOT\*' = @{ FullDetails = 'prop:System.DateModified' }
    }

    $AutoOutput = Show-FakeWindowsDetailsFields 'abc' -Width 1000
    Assert-Match $AutoOutput 'System.Title' 'Auto should use the first registry source with any candidate list.'
    Assert-Match $AutoOutput 'System.Comment' 'Auto should include all fields from the selected list.'
    Assert-Match $AutoOutput 'PreviewDetails' 'Auto should record the selected list type.'
    Assert-Match $AutoOutput ([regex]::Escape('HKCR\SystemFileAssociations\.abc')) 'Auto should record the selected registry source.'
    Assert-NotMatch $AutoOutput 'System.Author' 'Auto should not continue to later sources after selecting a list.'

    $FullDetailsOutput = Show-FakeWindowsDetailsFields '.abc' -FieldList FullDetails -Width 1000
    Assert-Match $FullDetailsOutput 'System.Author' 'Explicit FullDetails should skip sources that do not have FullDetails.'
    Assert-Match $FullDetailsOutput ([regex]::Escape('HKCR\abcfile')) 'Explicit FullDetails should use the ProgID source when it first has the requested list.'
    Assert-NotMatch $FullDetailsOutput 'System.Title' 'Explicit FullDetails should not use PreviewDetails from an earlier source.'
}

Invoke-Test 'module registry lookup supports perceived type wildcard and generic fallback' {
    if (-not (Test-IsWindows)) {
        Write-Host 'SKIP fake registry fallback test requires Windows because the command guards platform support.'
        return
    }

    Set-FakeRegistryForTest @{
        'Registry::HKEY_CLASSES_ROOT\.camera' = @{ PerceivedType = 'photo' }
        'Registry::HKEY_CLASSES_ROOT\SystemFileAssociations\photo' = @{ FullDetails = 'prop:System.Subject' }
        'Registry::HKEY_CLASSES_ROOT\AllFilesystemObjects' = @{ InfoTip = 'prop:System.DateCreated' }
        'Registry::HKEY_CLASSES_ROOT\*' = @{ FullDetails = 'prop:System.DateModified' }
    }

    $PerceivedOutput = Show-FakeWindowsDetailsFields '.camera' -Width 1000
    Assert-Match $PerceivedOutput 'System.Subject' 'Lookup should use perceived type when extension-specific and ProgID sources do not provide a list.'
    Assert-Match $PerceivedOutput ([regex]::Escape('HKCR\SystemFileAssociations\photo')) 'Perceived type source should be shown.'

    $WildcardOutput = Show-FakeWindowsDetailsFields '.unknown' -Width 1000
    Assert-Match $WildcardOutput 'System.DateCreated' 'Lookup should use AllFilesystemObjects before wildcard when it has a candidate list.'
    Assert-Match $WildcardOutput ([regex]::Escape('HKCR\AllFilesystemObjects')) 'AllFilesystemObjects source should be shown.'

    Set-FakeRegistryForTest @{}
    $FallbackOutput = Show-FakeWindowsDetailsFields @('one', '.two') -Width 1000
    Assert-Match $FallbackOutput 'Generic fallback' 'Lookup should use generic fallback when no registry source provides a list.'
    Assert-Match $FallbackOutput '\.one' 'Fallback output should include normalized first extension.'
    Assert-Match $FallbackOutput '\.two' 'Fallback output should include already-dotted second extension.'
    Assert-Match $FallbackOutput 'Fallback' 'Fallback output should identify the list type.'
}

Invoke-Test 'module exports only the public command' {
    Remove-Module WindowsDetailsFields -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $ProjectRoot 'WindowsDetailsFields.psm1') -Force
    $CommandNames = @(Get-Command -Module WindowsDetailsFields | Select-Object -ExpandProperty Name)

    Assert-SequenceEqual $CommandNames @('Show-WindowsDetailsFields') 'Module should export only Show-WindowsDetailsFields.'
}

Invoke-Test 'public command validates unsafe parameter values' {
    Assert-Throws { Show-WindowsDetailsFields '   ' } 'Whitespace-only extension should be rejected.'
    Assert-Throws { Show-WindowsDetailsFields '.' } 'Single-dot extension should be rejected.'
    Assert-Throws { Show-WindowsDetailsFields 'bad/name' } 'Extensions containing Windows filename-invalid characters should be rejected.'
    Assert-Throws { Show-WindowsDetailsFields '.txt' -Width 79 } 'Width below the supported range should be rejected.'
    Assert-Throws { Show-WindowsDetailsFields '.txt' -FieldList 'Bogus' } 'Unknown field list names should be rejected.'
}

Invoke-Test 'public command returns a formatted table for a valid extension on Windows' {
    if (-not (Test-IsWindows)) {
        Write-Host 'SKIP public command valid output test requires Windows.'
        return
    }

    $Extension = '.wdf-test-extension-never-registered'
    $Output = Show-WindowsDetailsFields $Extension -Width 1000

    Assert-Match $Output ([regex]::Escape($Extension)) 'Output should include the normalized extension.'
    Assert-Match $Output 'CanonicalName' 'Output should include the CanonicalName column.'
    Assert-Match $Output 'ListType' 'Output should include the ListType column.'
}

if ($script:Failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($script:Failures.Count) of $script:TestCount tests failed."
    exit 1
}

Write-Host ''
Write-Host "$script:TestCount tests passed."
