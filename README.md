# WindowsDetailsFields

查看某种文件类型在 Windows 文件资源管理器中会显示哪些详细信息字段，并把 `System.Photo.DateTaken` 这类字段名显示为“拍摄日期”等更容易理解的名称。

## 环境

- Windows PowerShell 5.1 或 PowerShell 7+

## 安装

```powershell
irm https://raw.githubusercontent.com/xincongjun/WindowsDetailsFields/main/install.ps1 | iex
```

如果安装后提示“在此系统上禁止运行脚本”，请先为当前用户调整 PowerShell 执行策略，然后重新打开 PowerShell：

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

如果只是当前窗口还没有加载命令，可以重新打开 PowerShell，或手动运行：

```powershell
Import-Module WindowsDetailsFields
```

如果执行策略由公司、学校或安全软件通过组策略管理，上面的设置可能无效，需要联系管理员调整。

## 示例

```powershell
Show-WindowsDetailsFields .jpg
Show-WindowsDetailsFields .jpg,.png
Show-WindowsDetailsFields .jpg -Width 500
Show-WindowsDetailsFields .jpg -FieldList PreviewDetails
```

| 列名 | 说明 |
| --- | --- |
| `Extension` | 查询的扩展名。 |
| `Order` | 字段在该详情列表中的顺序。 |
| `Kind` | `Field` 表示字段，`Group` 表示资源管理器详情分组。 |
| `DisplayName` | Windows 本地化显示名称，查不到时回退为字段规范名。 |
| `CanonicalName` | Windows 属性系统规范名，例如 `System.Photo.DateTaken`。 |
| `ListType` | 命中的详情列表类型，例如 `FullDetails` 或 `PreviewDetails`。 |
| `Source` | 命中的注册表来源或通用回退，便于判断字段来自扩展名、ProgID、PerceivedType、通用配置还是脚本内置默认列表。 |

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Extension` | 必填 | 要查询的扩展名。可以写 `.jpg`，也可以写 `jpg`；多个扩展名用逗号分隔，例如 `.jpg,.png`。 |
| `-Width` | `300` | 控制表格输出宽度，范围是 `80` 到 `1000`。字段名或来源路径显示不完整时可以调大。 |
| `-FieldList` | `Auto` | 指定要读取的字段列表。默认 `Auto` 会自动选择最合适的一组；一般不用手动设置。 |

`-FieldList` 可选值：

| 值 | 说明 |
| --- | --- |
| `Auto` | 先按注册表来源优先级查找，再在每个来源里按 `FullDetails`、`PreviewDetails`、`DetailsPane`、`InfoTip` 的顺序查找，找到第一组可用字段就返回。 |
| `FullDetails` | 文件属性“详细信息”里较完整的字段列表，通常也是默认结果。 |
| `PreviewDetails` | 预览相关字段，数量通常比 `FullDetails` 少。 |
| `DetailsPane` | 详情窗格字段。 |
| `InfoTip` | 鼠标悬停信息提示字段。 |

## 卸载

```powershell
irm https://raw.githubusercontent.com/xincongjun/WindowsDetailsFields/main/uninstall.ps1 | iex
```

## 注意

- 查询结果来自当前系统，不同 Windows 版本、语言和已安装软件可能会显示不同字段。
