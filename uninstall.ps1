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
$LegacySentinelName = '.managed-by-WindowsDetailsFields'

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

function Backup-File($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $BackupPath = '{0}.bak.{1}' -f $Path, (Get-Date -Format 'yyyyMMddHHmmss')
    Copy-Item -LiteralPath $Path -Destination $BackupPath -Force
    Write-Host "已备份：$BackupPath"
}

function Get-ModuleBackupFiles($ModuleDir) {
    if (-not (Test-Path -LiteralPath $ModuleDir)) { return @() }

    Get-ChildItem -LiteralPath $ModuleDir -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and $_.Name -like "$ModuleName.psm1.bak.*" }
}

function Test-UninstallShouldProcess($ShouldProcessTarget, $Action) {
    $PSCmdletValue = $null
    try {
        $PSCmdletValue = Get-Variable -Name PSCmdlet -ValueOnly -ErrorAction Stop
    } catch {}

    if ($PSCmdletValue) {
        return $PSCmdletValue.ShouldProcess($ShouldProcessTarget, $Action)
    }

    $WhatIfValue = $false
    try {
        $WhatIfValue = Get-Variable -Name WhatIfPreference -ValueOnly -ErrorAction Stop
    } catch {}

    if ($WhatIfValue) {
        Write-Host ('What if: Performing the operation "{0}" on target "{1}".' -f $Action, $ShouldProcessTarget)
        return $false
    }

    return $true
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

function Uninstall-ProfileImport($InstallTarget) {
    $Profile = $InstallTarget.Profile
    if (-not (Test-Path -LiteralPath $Profile)) { return }

    $Encoding = Get-ProfileEncoding $Profile
    $Content = [System.IO.File]::ReadAllText($Profile, $Encoding)
    $NewContent = Remove-ProfileBlock $Content

    if ($NewContent -eq $Content) { return }

    if (Test-UninstallShouldProcess $Profile 'Remove profile import') {
        $OutputContent = if ([string]::IsNullOrWhiteSpace($NewContent)) {
            ''
        } else {
            $NewContent.TrimEnd() + "`r`n"
        }

        Backup-File $Profile
        [System.IO.File]::WriteAllText($Profile, $OutputContent, $Encoding)
        Write-Host "已清理 profile：$Profile"
    }
}

function Uninstall-ModuleFile($InstallTarget) {
    $ModuleDir = $InstallTarget.ModuleDir
    $ModulePath = Join-Path $ModuleDir "$ModuleName.psm1"
    $LegacySentinelPath = Join-Path $ModuleDir $LegacySentinelName

    if (-not (Test-Path -LiteralPath $ModuleDir)) { return }

    $ModuleBackupPaths = @(Get-ModuleBackupFiles $ModuleDir | ForEach-Object { $_.FullName })
    $ManagedPaths = @($ModulePath, $LegacySentinelPath) + $ModuleBackupPaths
    $ExistingManagedPaths = @($ManagedPaths | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $ExistingManagedPaths) { return }

    if (Test-UninstallShouldProcess $ModuleDir 'Remove managed module files') {
        foreach ($Path in $ExistingManagedPaths) {
            Remove-Item -LiteralPath $Path -Force
        }

        $RemainingItems = @(Get-ChildItem -LiteralPath $ModuleDir -Force -ErrorAction SilentlyContinue)
        if ($RemainingItems.Count -eq 0) {
            Remove-Item -LiteralPath $ModuleDir -Force
            Write-Host "已删除模块目录：$ModuleDir"
        } else {
            Write-Host "已删除本脚本管理的模块文件：$ModuleDir"
        }
    }
}

foreach ($InstallTarget in Get-InstallTargets) {
    Uninstall-ProfileImport $InstallTarget
    Uninstall-ModuleFile $InstallTarget
}

Remove-Module $ModuleName -Force -ErrorAction SilentlyContinue
Remove-Item Function:\Show-WindowsDetailsFields -ErrorAction SilentlyContinue
if ($WhatIfPreference) {
    Write-Host '预览完成，未写入任何文件。'
} else {
    Write-Host '卸载完成。'
}
