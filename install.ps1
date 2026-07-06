#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.ContainsKey('Platform') -and $PSVersionTable.Platform -ne 'Win32NT') {
    throw 'WindowsDetailsFields 只能在 Windows 上安装和运行。'
}

$ModuleName = 'WindowsDetailsFields'
$BeginMarker = '# BEGIN WindowsDetailsFields'
$EndMarker = '# END WindowsDetailsFields'
$SentinelName = '.managed-by-WindowsDetailsFields'
$InstallScriptPath = $MyInvocation.MyCommand.Path

function Get-RepositoryFileUrl($FileName) {
    "https://raw.githubusercontent.com/xincongjun/WindowsDetailsFields/main/$FileName"
}

function Get-ModuleSource {
    if ($InstallScriptPath) {
        $LocalModulePath = Join-Path (Split-Path -Parent $InstallScriptPath) "$ModuleName.psm1"
        if (Test-Path -LiteralPath $LocalModulePath) {
            return [System.IO.File]::ReadAllText($LocalModulePath, [System.Text.UTF8Encoding]::new($true))
        }
    }

    $ModuleUrl = Get-RepositoryFileUrl "$ModuleName.psm1"
    return (Invoke-RestMethod -Uri $ModuleUrl)
}

function Get-Utf8BomEncoding {
    New-Object System.Text.UTF8Encoding -ArgumentList $true
}

function Get-AnsiEncoding {
    try {
        $ProviderType = [System.Type]::GetType('System.Text.CodePagesEncodingProvider, System.Text.Encoding.CodePages', $false)
        if (-not $ProviderType) { $ProviderType = [System.Type]::GetType('System.Text.CodePagesEncodingProvider', $false) }
        if ($ProviderType) {
            $Instance = $ProviderType.GetProperty('Instance').GetValue($null, $null)
            [System.Text.Encoding]::RegisterProvider($Instance)
        }
    } catch {}

    [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
}

function Get-ProfileEncoding($Path) {
    $Utf8Bom = Get-Utf8BomEncoding
    if (-not (Test-Path -LiteralPath $Path)) { return $Utf8Bom }

    $Bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($Bytes.Length -eq 0) { return $Utf8Bom }

    if ($Bytes.Length -ge 4) {
        if ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0x00 -and $Bytes[3] -eq 0x00) {
            return [System.Text.Encoding]::UTF32
        }
        if ($Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) {
            return (New-Object System.Text.UTF32Encoding -ArgumentList $true, $true)
        }
    }

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return $Utf8Bom }

    if ($Bytes.Length -ge 2) {
        if ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode }
        if ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode }
    }

    $Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    try {
        [void]$Utf8NoBom.GetString($Bytes)
        if ($Path -match '\\WindowsPowerShell\\') { return $Utf8Bom }
        return $Utf8NoBom
    } catch {
        return Get-AnsiEncoding
    }
}

function Test-TextFileContent($Path, $Content, $Encoding) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    try {
        return ([System.IO.File]::ReadAllText($Path, $Encoding) -eq $Content)
    } catch {
        return $false
    }
}

function Backup-File($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $BackupPath = '{0}.bak.{1}' -f $Path, (Get-Date -Format 'yyyyMMddHHmmss')
    Copy-Item -LiteralPath $Path -Destination $BackupPath -Force
    Write-Host "已备份：$BackupPath"
}

function Test-ExecutionPolicyError($ErrorRecord) {
    if (-not $ErrorRecord) { return $false }

    if ($ErrorRecord.Exception -is [System.Management.Automation.PSSecurityException]) {
        return $true
    }

    $ErrorRecord.FullyQualifiedErrorId -like 'UnauthorizedAccess,*ImportModuleCommand'
}

function Write-ExecutionPolicyHelp($ModulePath) {
    $PolicyText = $null
    try {
        $PolicyText = Get-ExecutionPolicy
    } catch {}

    $PolicySuffix = if ($PolicyText) { "当前有效策略：$PolicyText。" } else { '' }
    Write-Warning "模块已安装，但当前 PowerShell 执行策略阻止加载脚本模块：$ModulePath。$PolicySuffix"
    Write-Host '请先为当前用户调整 PowerShell 执行策略，然后重新打开 PowerShell：'
    Write-Host '  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned'
    Write-Host '如果设置执行策略后不想重新打开窗口，也可以在当前窗口手动加载模块：'
    Write-Host "  Import-Module $ModuleName"

    try {
        $PolicyList = Get-ExecutionPolicy -List
        $MachinePolicy = ($PolicyList | Where-Object Scope -eq 'MachinePolicy').ExecutionPolicy
        $UserPolicy = ($PolicyList | Where-Object Scope -eq 'UserPolicy').ExecutionPolicy
        if (($MachinePolicy -and $MachinePolicy -ne 'Undefined') -or ($UserPolicy -and $UserPolicy -ne 'Undefined')) {
            Write-Warning '检测到执行策略可能由组策略管理。如果上面的命令无效，请联系系统管理员调整 PowerShell 执行策略。'
        }
    } catch {}
}

function Get-InstallTargets {
    $Documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($Documents)) {
        throw '无法找到当前用户的 Documents 目录。'
    }

    @(
        [PSCustomObject]@{
            Name = 'PowerShell'
            ModuleDir = Join-Path $Documents "PowerShell\Modules\$ModuleName"
            Profile = Join-Path $Documents 'PowerShell\profile.ps1'
        }
        [PSCustomObject]@{
            Name = 'WindowsPowerShell'
            ModuleDir = Join-Path $Documents "WindowsPowerShell\Modules\$ModuleName"
            Profile = Join-Path $Documents 'WindowsPowerShell\profile.ps1'
        }
    )
}

function Remove-ProfileBlock($Content) {
    $Begin = [regex]::Escape($BeginMarker)
    $End = [regex]::Escape($EndMarker)
    [regex]::Replace($Content, "(?ms)^[^\S\r\n]*$Begin\r?\n.*?^[^\S\r\n]*$End\r?\n?", '')
}

function Install-ModuleFile($InstallTarget) {
    $ModuleDir = $InstallTarget.ModuleDir
    $ModulePath = Join-Path $ModuleDir "$ModuleName.psm1"
    $SentinelPath = Join-Path $ModuleDir $SentinelName
    $Encoding = Get-Utf8BomEncoding
    $ModuleContent = (Get-ModuleSource).Trim() + "`r`n"
    $SentinelContent = "Managed by install.ps1.`r`n"

    $ModuleExists = Test-Path -LiteralPath $ModulePath
    $ModuleChanged = -not (Test-TextFileContent $ModulePath $ModuleContent $Encoding)
    $SentinelChanged = -not (Test-TextFileContent $SentinelPath $SentinelContent $Encoding)
    if (-not $ModuleChanged -and -not $SentinelChanged) {
        Write-Host "模块已是最新：$ModulePath"
        return $true
    }

    if ($PSCmdlet.ShouldProcess($ModuleDir, 'Install module files')) {
        New-Item -ItemType Directory -Path $ModuleDir -Force | Out-Null

        if ($ModuleChanged) {
            Backup-File $ModulePath
            [System.IO.File]::WriteAllText($ModulePath, $ModuleContent, $Encoding)
        }

        if ($SentinelChanged) {
            [System.IO.File]::WriteAllText($SentinelPath, $SentinelContent, $Encoding)
        }

        Write-Host "已安装模块：$ModulePath"
        $ModuleExists = $true
    }

    if ($WhatIfPreference) { return $true }
    $ModuleExists -or (Test-Path -LiteralPath $ModulePath)
}

function Install-ProfileImport($InstallTarget) {
    $Profile = $InstallTarget.Profile
    $Encoding = Get-ProfileEncoding $Profile
    $Content = if (Test-Path -LiteralPath $Profile) {
        [System.IO.File]::ReadAllText($Profile, $Encoding)
    } else {
        ''
    }

    $ContentWithoutBlock = Remove-ProfileBlock $Content
    $ImportBlock = @"
$BeginMarker
Import-Module $ModuleName -ErrorAction SilentlyContinue
$EndMarker
"@
    $DesiredContent = if ([string]::IsNullOrWhiteSpace($ContentWithoutBlock)) {
        $ImportBlock.Trim() + "`r`n"
    } else {
        $ContentWithoutBlock.TrimEnd() + "`r`n`r`n" + $ImportBlock.Trim() + "`r`n"
    }

    if ($DesiredContent -eq $Content) {
        Write-Host "profile 已是最新：$Profile"
        return
    }

    if ($PSCmdlet.ShouldProcess($Profile, 'Update profile import')) {
        $Parent = Split-Path -Parent $Profile
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
        Backup-File $Profile
        [System.IO.File]::WriteAllText($Profile, $DesiredContent, $Encoding)
        Write-Host "已更新 profile：$Profile"
    }
}

$InstalledTargets = foreach ($InstallTarget in Get-InstallTargets) {
    if (Install-ModuleFile $InstallTarget) {
        Install-ProfileImport $InstallTarget
        $InstallTarget
    }
}

$CurrentTargetName = if ($PSVersionTable.ContainsKey('PSEdition') -and $PSVersionTable.PSEdition -eq 'Core') {
    'PowerShell'
} else {
    'WindowsPowerShell'
}

$CurrentTarget = $InstalledTargets | Where-Object { $_.Name -eq $CurrentTargetName } | Select-Object -First 1
$CurrentModulePath = if ($CurrentTarget) { Join-Path $CurrentTarget.ModuleDir "$ModuleName.psm1" } else { $null }
$CurrentModuleImported = $false
$CurrentModuleBlockedByPolicy = $false
if ($CurrentModulePath -and (Test-Path -LiteralPath $CurrentModulePath)) {
    try {
        Import-Module $CurrentModulePath -Force -ErrorAction Stop
        $CurrentModuleImported = $true
    } catch {
        if (Test-ExecutionPolicyError $_) {
            $CurrentModuleBlockedByPolicy = $true
            Write-ExecutionPolicyHelp $CurrentModulePath
        } else {
            throw
        }
    }
}

if ($WhatIfPreference) {
    Write-Host '预览完成，未写入任何文件。'
} elseif ($CurrentModuleBlockedByPolicy) {
    Write-Host '安装完成。调整执行策略并重新打开 PowerShell 后可以运行：Show-WindowsDetailsFields .jpg'
} elseif ($CurrentModuleImported) {
    Write-Host '安装完成。现在可以运行：Show-WindowsDetailsFields .jpg'
} else {
    Write-Host '安装完成。重新打开 PowerShell 后可以运行：Show-WindowsDetailsFields .jpg'
}
