# 现场远程接入工具包

本工具用 Tailscale + WinRM 连接另一台 Windows 电脑，也可以经该电脑转发访问内网服务器。双击 `start.cmd` 使用图形界面，不需要手工编辑配置。

**当前状态：2026-11-10 本地优化版。** 已补齐直连模式并修复本轮评审发现的撤销、凭据保存和 GUI 反馈问题。离线验证覆盖真实 GUI 控件及模拟引擎；客户现场真实安装、重启恢复和业务访问仍需单独验收。现场初始化仍是实验功能，仅在隔离测试机使用。

## 两种连接方式

| 方式 | 适用场景 | 必填地址 | 实际验证 |
|---|---|---|---|
| 直连另一台电脑 | A 直接管理电脑 B | B 的 Tailscale IP | 实际执行一条 WinRM 远程命令 |
| 经跳板机访问内网服务器 | A → 跳板机 B → 内网服务器 C | B 的 Tailscale IP、C 的内网 IP | 转发规则、入口 TCP 和 Web 响应 |

直连模式不会扫描内网、创建端口转发或修改对端防火墙。它不负责开启 Windows 远程桌面；只有 B 原本已开启 RDP 时，才能用 B 的 Tailscale IP 连接远程桌面。

## 首次连接两台测试电脑

1. 将工具包解压到 B，双击 `start.cmd`，接受管理员提权。
2. 在“通用”填写运维账号（默认 `zcode_ops`）、自行设置的强口令和现场名。
3. 在“对端初始化”填写所属 Tailscale 网络生成的 auth key。默认使用内置离线 MSI；需要在线下载时再勾选。
4. 点击“开始初始化”。成功后，B 的 Tailscale IP 会回填到界面，并写入 `access-result.txt`。GUI 会清除本地保存的 auth key；后台 key 的吊销仍需在 Tailscale 管理后台操作。
5. 在 A 安装并登录同一 Tailscale 网络。将工具包解压到 A，双击 `start.cmd`。
6. 选择“直连另一台电脑”，填 B 的 Tailscale IP，以及刚才在 B 设置的运维账号和口令。目标服务器和转发端口无需填写。
7. 首次点击“连接 / 配置”，准备 A 的 WinRM 客户端及 TrustedHosts，并验证真实远程命令。以后可用“只读检查”复核现有连接。

管理员口令属于 B 的运维账号，不是 Tailscale 登录密码。A 和 B 都必须在同一 tailnet，且现场允许访问控制面。离线安装包只解决安装文件下载，不会让断网的设备入网。

## 已接入的电脑或现场

不重复运行初始化。填写现有对端地址、运维账号和口令：

- A 已配置过：先用“只读检查”。
- A 第一次接入：使用“连接 / 配置”，该操作会准备本机客户端和信任配置。
- 访问 B 背后的 C：选择转发模式，明确填写 C 的实际内网 IP，不按端口开放情况猜测业务主机。

转发模式的默认入口为 MySQL 13306 → 3306、Web 18080 → 80、RDP 13389 → 3389。当前 GUI 按三种服务一起验证；不应把无 MySQL/Web 服务的普通电脑当作服务器目标。额外转发格式为 `23389:10.0.0.20:3389`，每行一条。

完全相同的转发显示 `unchanged`，不删除重建，不重启 IP Helper。已有端口冲突时拒绝接管。`TCP OPEN` 只说明入口可建立连接，不证明数据库登录、业务查询或真实 RDP 会话成功。

## 凭据如何保存

- `config.json` 只保存地址、端口、模式和随机凭据引用；`opsPassword`、`authKey` 字段保持为空。
- 凭据使用 Windows 当前用户 DPAPI 加密，存放在 `%LOCALAPPDATA%\ZCodeRemoteAccess\credentials\`。目录权限仅授予当前用户和 SYSTEM。
- 凭据绑定当前配置路径。换电脑、Windows 账号或复制到另一个工具目录后，在 GUI 重新填写，不能把复制的配置当作已有授权。
- 保存配置时，新加密记录先落盘，再原子更新公开配置；旧的同配置加密记录随后清理。
- 旧版明文配置仍能读取，会输出迁移提示；在 GUI 点击“保存配置”即可迁移。不要把填过的旧配置直接发给其他人。
- 密码和 auth key 不作为 GUI 子进程命令行参数传递。01 的 Tailscale `--authkey` 兜底仍可能让本机管理员短暂看到入网密钥，运行输出会告知。
- 需要清除本机保存的口令时，清空对应输入框并保存。删除工具目录不会自动删除用户凭据存储，也不会吊销后台节点或 key。

## 撤销

GUI 先点击“预览撤销”，查看日志里的运行记录和资源，再点击“执行撤销”。更改范围、现场名、卸载选项，或执行其他任务后，必须重新预览。

| 范围 | 在哪里运行 | 内容 |
|---|---|---|
| Local | A | 本机 TrustedHosts、接入档案 |
| Site | B | B 上归本工具所有的账号、规则、转发和设置 |
| All | 当前电脑 | 当前电脑上的两个范围，不代表远程同时撤销 A 和 B |

填写现场名时只选择该现场的记录；留空时预览当前主机该范围全部待处理记录。默认按新到旧处理全部未完成记录，避免重跑产生的空记录遮住旧资源。`-Latest` 是主动缩小范围的选项，不代表全量清理。

- 只撤销 journal 明确记录且当前状态仍匹配的资源。不同主机、SID、marker、内容或备份 hash 不符时拒绝。
- 档案与接入结果覆盖前保存原始字节；撤销恢复旧文件。用户修改过的内容不会静默覆盖。
- 多次运行的档案、TrustedHosts、注册表按逆序恢复；预览使用同样的状态投影。
- 默认保留 Tailscale 安装和节点。后续可针对原记录补做注销、卸载，保留的可选项不会被“已撤销”状态永久跳过。
- 注销失败时不继续卸载，防止丢失后续清理入口。失败恢复所需的备份目录会保留。
- 旧版日志缺少完整备份证据时，工具保持保守；无法证明可恢复的原文件不会凭推测重建。

命令行示例（参数中的地址、现场名需填写自己的值）：

```powershell
# 已有连接的直连只读检查
.\run.ps1 -Mode 2 -ConnectionMode Direct -VerifyOnly

# 直连首次准备本机
.\run.ps1 -Mode 2 -ConnectionMode Direct

# 服务器转发；配置中必须有 targetServer
.\run.ps1 -Mode 2 -ConnectionMode Forward -VerifyOnly

# 在 B 列出、预览指定现场的撤销
.\03-undo.ps1 -List -Scope Site -SiteName example
.\03-undo.ps1 -Scope Site -SiteName example -DryRun

# 审核预览后执行；同时注销、卸载需显式给出两个选项
.\03-undo.ps1 -Scope Site -SiteName example -UnjoinTailscale -RemoveTailscale -Force

# 指定原记录补做可选清理
.\03-undo.ps1 -Scope Site -RunId <runid> -UnjoinTailscale -RemoveTailscale -DryRun
```

Site 撤销必须在 B 本机执行，不能在 A 用相同名字冒充 B 的日志。

## GUI 执行反馈

窗口会明确显示成功、失败退出码或“无法确认结果”。任务执行时禁用配置和其他操作，防止改写运行中使用的配置；执行未结束时阻止关闭窗口。子进程使用有超时约束的测试入口验证，真实远端网络仍可能需要等待底层服务超时。

日志临时文件位于当前用户私有目录，任务结束读取后删除。GUI 日志框中的输出供当前操作排查，不会进入分发包。普通用户从包含空格的目录启动时，提权路径经过统一引用处理。

初始化只有取得 IPv4、且本次确实产生了新的接入结果才成功，旧的 `access-result.txt` 不能证明本次成功。

## 文件与开发检查

运行时必须保留 `01-jump-setup.ps1`、`02-connect-site.ps1`、`03-undo.ps1`、`run.ps1`、`gui.ps1`、`zc-state.ps1`、`zc-config.ps1`、`zc-process.ps1` 及入口脚本。

`tests/` 全部使用合成数据、临时目录或 stub。GUI 检查创建真实控件并调用真实按钮事件，但替换引擎、确认框和错误框；不执行客户初始化或真实撤销。测试日志、故障注入输出和真实现场资料均不随 ZIP 分发。

```powershell
# 在仓库目录运行全部离线检查
Get-ChildItem .\tests\*.Tests.ps1 | ForEach-Object { & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $_.FullName; if ($LASTEXITCODE -ne 0) { throw $_.Name } }

# 生成经过模板净化的分发包
.\Build-Package.ps1
```

本轮验证详情见 [验证记录](docs/validation-2026-11-10.md)。当前测试不能替代客户定制 Windows 镜像的真实 UAC、首次安全基线、重启恢复、多现场并发、数据库登录与业务验收。预先存在的宽 WinRM 防火墙规则仍只告警，不能声称整机仅允许 Tailscale 访问。

## 历史验证基线

2026-10 的历史记录包含 Server 2022 Core、Server 2019 Core/Desktop 的隔离安装与全量撤销，以及评估版 Desktop 的真实 UAC 提权闭环。它们证明对应历史版本与镜像的结果；本次优化版的真实现场验收单列，不借用历史结果冒充已验收。
