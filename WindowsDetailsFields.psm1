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
