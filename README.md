# Apple Music Win10 Bundle Patcher

这个项目用于修改根目录中的 Apple Music Windows 安装包，将包内清单中的 Windows.Desktop 最低版本要求从 `10.0.26100.0` 降为 `10.0.0.0`，然后使用 Windows SDK 工具重新打包并重签名。

当前实现不是简单的压缩包替换，而是走完整的 Windows 打包流程：

- Python 负责选择 bundle、收集用户输入并串联脚本
- PowerShell 负责解包、修改 manifest、重打包、签名和证书导入
- 输出包会根据兼容性要求生成 `.appxbundle`

## 功能说明

执行主脚本后，会完成以下操作：

1. 扫描项目根目录下的 `.msixbundle` 文件，并按自然顺序列出。
2. 让用户选择要处理的 bundle。
3. 调用 PowerShell 脚本解包 bundle 和内部 payload。
4. 将以下清单中的 `TargetDeviceFamily` 的 `MinVersion` 改为 `10.0.0.0`：
   - 外层 bundle manifest
   - 两个内部 payload 的 `AppxManifest.xml`
5. 使用自签名证书重新签名内部包和最终输出包。
6. 自动导出 `.pfx` 和 `.cer` 证书文件到 `certificates` 目录。
7. 自动将证书导入 Windows 证书存储。

## 目录结构

项目的关键文件如下：

- [patch_msixbundle.py](patch_msixbundle.py)：主入口，负责交互和调度。
- [script/New-CertificateAndPack.ps1](script/New-CertificateAndPack.ps1)：解包、修改、重打包、签名。
- [script/Import-GeneratedCertificate.ps1](script/Import-GeneratedCertificate.ps1)：导入生成的证书。
- `certificates/`：输出生成的 `.pfx` 和 `.cer`。
- `output/`：输出重打包后的 `.appxbundle`。
- `work/`：中间工作目录。成功时会自动删除，失败时会保留以便排查。

## 环境要求

运行前请确认以下条件满足：

- Windows 系统
- 已安装 Python 3
- 已安装 Windows SDK，并且系统中可找到以下工具：
  - `makeappx.exe`
  - `signtool.exe`
- PowerShell 可用

如果你要把证书导入到 `LocalMachine`，需要管理员权限。当前脚本会在需要时自动请求提权。

## 使用方法

在项目根目录执行：

```powershell
python .\patch_msixbundle.py
```

如果你使用项目内虚拟环境，也可以执行：

```powershell
.\.venv\Scripts\python.exe .\patch_msixbundle.py
```

运行过程中会提示以下信息：

1. 选择要处理的 `.msixbundle` 序号
2. 输入证书密码，默认是 `12345`
3. 输入证书名称，默认是 `AppleMusicWinLocalTest`
4. 是否使用时间戳
5. 如果使用时间戳，输入时间戳 URL
6. 选择证书导入范围：`CurrentUser` 或 `LocalMachine`

## 输出结果

成功后会生成以下内容：

- `output` 目录下的重打包安装包
- `certificates` 目录下的证书文件

当前 Apple Music 包处理完成后的输出文件名类似：

```text
output\AppleInc.AppleMusicWin_1.1540.23042.0_neutral_~_nzyj5cx40ttqa.appxbundle
```

注意：

- 输入是 `.msixbundle`
- 输出可能变成 `.appxbundle`

这是当前实现的预期行为。因为将最低系统版本降到较旧平台后，内部 payload 会按 `.appx` 重新构建，最终 bundle 也会相应变为 `.appxbundle`。

## 证书导入说明

导入脚本会根据你选择的范围写入证书存储：

- PFX 导入到 `My`
- CER 导入到 `Root`
- CER 导入到 `TrustedPeople`

如果选择 `LocalMachine`，对应位置分别是：

- `Cert:\LocalMachine\My`
- `Cert:\LocalMachine\Root`
- `Cert:\LocalMachine\TrustedPeople`

其中 `Cert:\LocalMachine\Root` 就是“受信任的根证书颁发机构”。

## 常见问题

### 1. 为什么不能直接改压缩包后就安装？

因为 MSIX/MSIXBundle 修改后原始签名会失效。要想得到可安装的结果，必须重新打包并重新签名。

### 2. 为什么输出不是 `.msixbundle`，而是 `.appxbundle`？

这是为了兼容较低平台版本。当前项目里把 `MinVersion` 改成 `10.0.0.0` 后，内部包会改为 `.appx` 重新打包，因此最终输出为 `.appxbundle`。

### 3. 导入 `LocalMachine` 失败怎么办？

如果当前 PowerShell 不是管理员权限，导入脚本会自动尝试提权。如果系统拦截了 UAC 提示，需要手动确认。

### 4. 失败后怎么排查？

如果流程失败，`work` 目录不会被删除。可以直接查看其中的：

- 解包后的 bundle 文件
- 解包后的 payload
- 修改后的 manifest
- 重建前的目录结构

优先检查以下几点：

- Windows SDK 是否安装完整
- `makeappx.exe` 和 `signtool.exe` 是否可用
- 证书是否成功生成到 `certificates` 目录
- 时间戳服务是否可访问

## 直接运行 PowerShell 脚本

如果你只想执行打包脚本，也可以直接运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\script\New-CertificateAndPack.ps1 -RootPath . -BundleIndex 1 -Password 12345 -CertName AppleMusicWinLocalTest -SkipTimestamp
```

只执行证书导入脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\script\Import-GeneratedCertificate.ps1 -RootPath . -Password 12345 -CertName AppleMusicWinLocalTest -Scope CurrentUser
```

## 当前默认值

- 默认证书密码：`12345`
- 默认证书名称：`AppleMusicWinLocalTest`
- 默认时间戳地址：`http://timestamp.digicert.com`

## 说明

这个项目面向当前仓库里的 Apple Music 安装包处理流程，默认假设：

- 根目录存在一个或多个 `.msixbundle`
- 每个 bundle 中包含 2 个 payload 包
- 需要将目标最低版本统一降到 `10.0.0.0`

如果后续换成其他应用包，建议先确认其内部结构是否仍满足这些假设。