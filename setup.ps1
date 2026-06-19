#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Uninstall,
    [switch]$NoProfile,
    [switch]$NoBackup,
    [switch]$Force,
    [ValidateSet('Both', 'PowerShell', 'WindowsPowerShell')]
    [string]$Target = 'Both'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.ContainsKey('Platform') -and $PSVersionTable.Platform -ne 'Win32NT') {
    throw 'WindowsDetailsFields 只能在 Windows 上安装和运行。'
}

$ModuleName = 'WindowsDetailsFields'
$BeginMarker = '# BEGIN WindowsDetailsFields'
$EndMarker = '# END WindowsDetailsFields'
$SentinelName = '.managed-by-WindowsDetailsFields-setup'

$ModuleSource = @'
Set-StrictMode -Version 2.0

function Show-WindowsDetailsFields {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) { throw 'Extension 不能为空或纯空白。' }
            if ($_.Trim() -eq '.') { throw 'Extension 不能只有一个点。' }
            if ($_ -match '[\\/:*?"<>|]') { throw 'Extension 不能包含 Windows 文件名非法字符：\ / : * ? " < > |' }
            $true
        })]
        [string[]]$Extension,

        [ValidateRange(80, 1000)]
        [int]$Width = 300,

        [ValidateSet('Auto', 'FullDetails', 'PreviewDetails', 'DetailsPane', 'InfoTip')]
        [string]$FieldList = 'Auto'
    )

    if ($PSVersionTable.ContainsKey('Platform') -and $PSVersionTable.Platform -ne 'Win32NT') {
        throw 'Show-WindowsDetailsFields 只能在 Windows 上运行。'
    }

    $cs = @"
using System;
using System.Runtime.InteropServices;

namespace WindowsDetailsFieldsNative
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("6f79d558-3e96-4549-a1d1-7d75d2288814")]
    public interface IPropertyDescription
    {
        void GetPropertyKey(out PropertyKey propertyKey);
        void GetCanonicalName(out IntPtr canonicalName);
        ushort GetPropertyType();
        void GetDisplayName(out IntPtr displayName);
    }

    public static class PropertyDescription
    {
        [DllImport("propsys.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void PSGetPropertyDescriptionByName(
            string canonicalName,
            ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyDescription description);

        public static string GetDisplayName(string canonicalName)
        {
            Guid iid = new Guid("6f79d558-3e96-4549-a1d1-7d75d2288814");
            IPropertyDescription description;
            PSGetPropertyDescriptionByName(canonicalName, ref iid, out description);

            IntPtr displayName;
            description.GetDisplayName(out displayName);
            string value = Marshal.PtrToStringUni(displayName);
            Marshal.FreeCoTaskMem(displayName);
            return value;
        }
    }
}
"@

    if (-not ([System.Management.Automation.PSTypeName]'WindowsDetailsFieldsNative.PropertyDescription').Type) {
        Add-Type -TypeDefinition $cs
    }

    $Alias = @{
        'System.DisplayName'   = 'System.ItemNameDisplay'
        'System.CanonicalType' = 'System.ItemTypeText'
        'System.DisplayFolder' = 'System.ItemFolderPathDisplay'
        'System.Attributes'    = 'System.FileAttributes'
        'System.File.Owner'    = 'System.FileOwner'
    }

    $Fallback = @{
        'System.PropGroup.Description' = '说明'; 'System.PropGroup.FileSystem' = '文件系统'
        'System.DisplayName' = '名称'; 'System.ItemNameDisplay' = '名称'
        'System.CanonicalType' = '类型'; 'System.ItemType' = '类型'; 'System.ItemTypeText' = '类型'
        'System.DisplayFolder' = '文件位置'; 'System.ItemFolderPathDisplay' = '文件夹路径'
        'System.DateCreated' = '创建日期'; 'System.DateModified' = '修改日期'; 'System.Size' = '大小'
        'System.Attributes' = '属性'; 'System.FileAttributes' = '属性'
        'System.File.Owner' = '所有者'; 'System.FileOwner' = '所有者'; 'System.ComputerName' = '计算机'
        'System.Title' = '标题'; 'System.Subject' = '主题'; 'System.Author' = '作者'
        'System.Keywords' = '标记'; 'System.Comment' = '备注'; 'System.AcquisitionID' = '采集 ID'
        'System.GPS.AltitudeRef' = '海拔参考'; 'System.GPS.Date' = 'GPS 日期'
        'System.GPS.DestBearing' = '目标方位'; 'System.GPS.DestDistance' = '目标距离'
        'System.GPS.DestLatitude' = '目标纬度'; 'System.GPS.DestLongitude' = '目标经度'
        'System.GPS.DOP' = 'GPS 精度因子'; 'System.GPS.ImgDirection' = '图像方向'
        'System.GPS.ImgDirectionRef' = '图像方向参考'; 'System.GPS.LatitudeRef' = '纬度方向参考'
        'System.GPS.LongitudeRef' = '经度方向参考'; 'System.GPS.MapDatum' = '地图基准'
        'System.GPS.Speed' = 'GPS 速度'; 'System.GPS.Track' = 'GPS 航向'
        'System.History.DateChanged' = '更改日期'; 'System.History.VisitCount' = '访问次数'
    }

    function Get-RegistryValue($Path, $Name) {
        $Key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($Key) { $Key.GetValue($Name) }
    }

    function ConvertTo-ShortRegistryPath($Path) {
        $Prefix = 'Registry::HKEY_CLASSES_ROOT\'
        if ($Path -and $Path.StartsWith($Prefix)) {
            return 'HKCR\' + $Path.Substring($Prefix.Length)
        }
        $Path
    }

    function Split-PropertyList($Text) {
        if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

        ($Text -replace '^prop:', '') -split ';' |
            ForEach-Object { ($_ -replace '^[*~]+', '').Trim() } |
            Where-Object { $_ }
    }

    function Get-PropertyDisplayName($Name) {
        if ($Name.StartsWith('@')) { return $Name }
        if ($Fallback.ContainsKey($Name)) { return $Fallback[$Name] }

        $Lookup = if ($Alias.ContainsKey($Name)) { $Alias[$Name] } else { $Name }
        try {
            $DisplayName = [WindowsDetailsFieldsNative.PropertyDescription]::GetDisplayName($Lookup)
            if ($DisplayName -and $DisplayName -ne $Lookup -and $DisplayName -notlike 'System.*') {
                return $DisplayName
            }
        } catch {}

        if ($Fallback.ContainsKey($Lookup)) { return $Fallback[$Lookup] }
        $Name
    }

    $Generic = 'prop:System.PropGroup.Description;System.Title;System.Subject;System.Author;System.Keywords;System.Comment;System.PropGroup.FileSystem;System.ItemNameDisplay;System.ItemType;System.ItemFolderPathDisplay;System.DateCreated;System.DateModified;System.Size;System.FileAttributes;System.FileOwner;System.ComputerName'
    $CandidateValueNames = if ($FieldList -eq 'Auto') {
        'FullDetails', 'PreviewDetails', 'DetailsPane', 'InfoTip'
    } else {
        @($FieldList)
    }

    $Rows = foreach ($Ext in $Extension) {
        $Ext = $Ext.Trim()
        if (-not $Ext.StartsWith('.')) { $Ext = ".$Ext" }

        $ExtPath = "Registry::HKEY_CLASSES_ROOT\$Ext"
        $ProgId = Get-RegistryValue $ExtPath ''
        $PerceivedType = Get-RegistryValue $ExtPath 'PerceivedType'

        $Paths = @("Registry::HKEY_CLASSES_ROOT\SystemFileAssociations\$Ext")
        if ($ProgId) { $Paths += "Registry::HKEY_CLASSES_ROOT\$ProgId" }
        if ($PerceivedType) { $Paths += "Registry::HKEY_CLASSES_ROOT\SystemFileAssociations\$PerceivedType" }
        $Paths += 'Registry::HKEY_CLASSES_ROOT\AllFilesystemObjects', 'Registry::HKEY_CLASSES_ROOT\*'

        $List = $null
        $Source = $null
        $ListType = $null

        foreach ($Path in $Paths) {
            $Key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            if (-not $Key) { continue }

            foreach ($Name in $CandidateValueNames) {
                $Value = $Key.GetValue($Name)
                if ($Value) {
                    $List = $Value
                    $Source = ConvertTo-ShortRegistryPath $Path
                    $ListType = $Name
                    break
                }
            }

            if ($List) { break }
        }

        if (-not $List) {
            $List = $Generic
            $Source = 'Generic fallback'
            $ListType = 'Fallback'
        }

        $Order = 0
        foreach ($Name in Split-PropertyList $List) {
            if ($Name.StartsWith('@')) { continue }

            $Order++
            [PSCustomObject]@{
                Extension = $Ext
                Order = $Order
                Kind = if ($Name -like 'System.PropGroup.*') { 'Group' } else { 'Field' }
                DisplayName = Get-PropertyDisplayName $Name
                CanonicalName = $Name
                ListType = $ListType
                Source = $Source
            }
        }
    }

    $Rows | Format-Table Extension, Order, Kind, DisplayName, CanonicalName, ListType, Source -AutoSize |
        Out-String -Width $Width
}

Export-ModuleMember -Function Show-WindowsDetailsFields
'@

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
    if ($NoBackup -or -not (Test-Path -LiteralPath $Path)) { return }

    $BackupPath = '{0}.bak.{1}' -f $Path, (Get-Date -Format 'yyyyMMddHHmmss')
    Copy-Item -LiteralPath $Path -Destination $BackupPath -Force
    Write-Host "已备份：$BackupPath"
}

function Get-InstallTargets {
    $Documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($Documents)) {
        throw '无法找到当前用户的 Documents 目录。'
    }

    $Items = @()

    if ($Target -eq 'Both' -or $Target -eq 'PowerShell') {
        $Items += [PSCustomObject]@{
            Name = 'PowerShell'
            ModuleDir = Join-Path $Documents "PowerShell\Modules\$ModuleName"
            Profile = Join-Path $Documents 'PowerShell\profile.ps1'
        }
    }

    if ($Target -eq 'Both' -or $Target -eq 'WindowsPowerShell') {
        $Items += [PSCustomObject]@{
            Name = 'WindowsPowerShell'
            ModuleDir = Join-Path $Documents "WindowsPowerShell\Modules\$ModuleName"
            Profile = Join-Path $Documents 'WindowsPowerShell\profile.ps1'
        }
    }

    $Items
}

function Remove-ProfileBlock($Content) {
    $Begin = [regex]::Escape($BeginMarker)
    $End = [regex]::Escape($EndMarker)
    $Content = [regex]::Replace($Content, "(?s)\r?\n?$Begin.*?$End\r?\n?", '')
    $Content = [regex]::Replace($Content, "(?m)^\s*Import-Module\s+$ModuleName\s+-ErrorAction\s+SilentlyContinue\s*$", '')
    $Content = [regex]::Replace($Content, "(?m)^\s*#\s*$ModuleName\s*$", '')
    $Content
}

function Install-ModuleFile($InstallTarget) {
    $ModuleDir = $InstallTarget.ModuleDir
    $ModulePath = Join-Path $ModuleDir "$ModuleName.psm1"
    $SentinelPath = Join-Path $ModuleDir $SentinelName
    $Encoding = Get-Utf8BomEncoding
    $ModuleContent = $ModuleSource.Trim() + "`r`n"
    $SentinelContent = "Managed by setup.ps1.`r`n"

    $ModuleDirExists = Test-Path -LiteralPath $ModuleDir
    $SentinelExists = Test-Path -LiteralPath $SentinelPath
    $ModuleExists = Test-Path -LiteralPath $ModulePath

    if ($ModuleDirExists -and -not $SentinelExists -and -not $Force) {
        Write-Warning "检测到同名模块目录，已跳过：$ModuleDir。确认要覆盖时请加 -Force。"
        return $false
    }

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
    if ($NoProfile) { return }

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

function Uninstall-ProfileImport($InstallTarget) {
    if ($NoProfile) { return }

    $Profile = $InstallTarget.Profile
    if (-not (Test-Path -LiteralPath $Profile)) { return }

    $Encoding = Get-ProfileEncoding $Profile
    $Content = [System.IO.File]::ReadAllText($Profile, $Encoding)
    $NewContent = Remove-ProfileBlock $Content

    if ($NewContent -eq $Content) { return }

    if ($PSCmdlet.ShouldProcess($Profile, 'Remove profile import')) {
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
    $SentinelPath = Join-Path $ModuleDir $SentinelName

    if (-not (Test-Path -LiteralPath $ModuleDir)) { return }

    $SentinelExists = Test-Path -LiteralPath $SentinelPath
    if (-not $SentinelExists -and -not $Force) {
        Write-Warning "模块目录不像是本 setup 脚本创建的，已保留：$ModuleDir。确认要删除本模块文件时请加 -Force。"
        return
    }

    $ManagedPaths = @($ModulePath, $SentinelPath)
    $ExistingManagedPaths = @($ManagedPaths | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $ExistingManagedPaths) { return }

    if ($PSCmdlet.ShouldProcess($ModuleDir, 'Remove setup-managed module files')) {
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
$InstallTargets = Get-InstallTargets

if ($Uninstall) {
    foreach ($InstallTarget in $InstallTargets) {
        Uninstall-ProfileImport $InstallTarget
        Uninstall-ModuleFile $InstallTarget
    }

    Remove-Module $ModuleName -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\Show-WindowsDetailsFields -ErrorAction SilentlyContinue
    Remove-Item Alias:\Get-WindowsDetailsFields -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-WindowsDetailsFields -ErrorAction SilentlyContinue
    Write-Host '卸载完成。重新打开 PowerShell 后会完全生效。'
    return
}

$InstalledTargets = foreach ($InstallTarget in $InstallTargets) {
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
if ($CurrentModulePath -and (Test-Path -LiteralPath $CurrentModulePath)) {
    Import-Module $CurrentModulePath -Force
}

if ($WhatIfPreference) {
    Write-Host '预览完成，未写入任何文件。'
} else {
    Write-Host '安装完成。现在可以运行：Show-WindowsDetailsFields .jpg'
}
