# 现场远程接入工具包 — 安全加固原型

> **状态（2026-10-27）：现场链路只读回归通过；01/02 已加入变更日志、签名校验、凭据传递加固和 03 撤销机制；UAC 提权+同意+执行已在 Server 2019 Desktop 上自动化验证通过；已按现场复盘加固 TLS 握手重置与 MSI 安装判定。仍不是已完成全场景安全验收的稳定版。**
> 底层借用 Tailscale，目标是现场和本机各运行一次。现场初始化默认暂停；不得在生产跳板机反复试跑初始化或修改转发来验证工具。
> 分发配置是空模板，不含实际口令、auth key、项目地址或测试结果。

## 当前已验证

- Windows PowerShell 5.1；控制台编码、中文启动脚本 UTF-8 BOM。
- 2026-10-20 现场只读回归：四条既有规则均为 `unchanged`，四个入口 TCP OPEN，Web HTTP 200；未修改现场配置或重启服务。
- 2026-10-20 隔离 VM（Windows Server 2022 Standard Evaluation，Desktop Experience）全新安装：内置 MSI 离线安装、首次 auth key 入网、WinRM、`zcode_ops` 管理员账号、`access-result.txt` / `config.json` 回填均通过；本机经 Tailscale 到客机 5985/WinRM 闭环验证通过。
- 2026-10-21 安全加固与撤销：
  - 01 改为 `New-LocalUser` 建账号（口令不再进入 native 命令行）、auth key 优先走 `TS_AUTHKEY`、SYSTEM 降级任务改用随机任务名 + ACL 受限随机目录并清理、安装包 Authenticode 校验、`Enable-PSRemoting` 新建的宽规则自动禁用、变更写入 journal、失败自动回滚。
  - 02 为新建的 portproxy/防火墙写入 connect journal，防火墙规则带 `ZCodeRemoteAccess:<runid>` 描述标记；本机 TrustedHosts 和档案也写入本地 journal。
  - 新增 [03-undo.ps1](03-undo.ps1)：按 journal 只删除/恢复归属明确且当前状态未变的资源，默认先 DryRun 再确认。
  - 2026-10-21 在已装好的 Server 2022 客机上实测：01（`-SkipTailscale`、新建 `zcode_ops2`）→ 03 DryRun → 03 实际撤销；账号、新防火墙规则、`LocalAccountTokenFilterPolicy`、`access-result.txt` 全部按预期创建/撤销/恢复，原有账号、WinRM 监听和配置未被误删，journal 状态 `Undone`。
- 2026-10-21 干净 Server 2022 Standard Core VM 完整安装 + 全量撤销（通过）：
  - 全新无人值守安装后，01 完成 Tailscale MSI 安装、auth key 入网（IPN/GUI 阻塞 CLI 时先停止 IPN，仍阻塞则用 `--authkey` 兜底）、WinRM、`zcode_ops`、access-result；journal 状态 `Applied`。
  - 03 以 `-RemoveTailscale -UnjoinTailscale` 撤销：节点 logout、Tailscale MSI 卸载、账号/注册表/防火墙规则/access-result/临时目录全部回退；原有 WinRM 监听和预存规则保留；journal 状态 `Undone`；20/20 检查通过。
  - 注意：该评估镜像默认已启用 WinRM（监听器和两条宽规则），因此“禁用 Enable-PSRemoting 新建宽规则”的分支未在本轮实测；预先存在的宽规则按策略只告警、不擅自收紧。
- 2026-10-21 干净 Server 2019 Standard Core VM 完整安装 + 全量撤销（通过）：
  - Windows Server 2019 Standard Evaluation（17763）Core，1.5GB/2vCPU；同一套 01/03 流程。
  - 01：Tailscale MSI 安装、停 IPN + `--authkey` 入网（100.115.79.17）、WinRM、`zcode_ops`、access-result；03：logout、MSI 卸载、账号/注册表/规则/文件回退，原有 WinRM 监听/规则保留；20/20 检查通过，VM 关机。
  - 结论：`New-LocalUser`、`Get-LocalGroupMember -SID`、`Set-NetFirewallRule`、Tailscale MSI、journal/undo 在 Server 2019（17763）上均正常。
- 2026-10-22 干净 Server 2019 **Desktop Experience** VM 完整安装 + 全量撤销（通过）：
  - Windows Server 2019 Standard Evaluation（17763）Desktop Experience，3GB/2vCPU，镜像索引 2，主机名 `ZCODE-KIT-2019D`。
  - 01：Tailscale MSI 安装、停 IPN + `--authkey` 入网（100.89.103.13）、WinRM、`zcode_ops`、access-result（工具目录+桌面）；03：logout、MSI 卸载、账号/规则/注册表/文件回退，原有 WinRM 监听/规则保留；**22/22 检查通过**（含 DesktopExperience、DesktopPresentFinal），VM 关机。
  - 结论：生产同版 OS/Desktop 路径已验证；评估镜像仍可能与客户定制镜像不同，现场实际镜像/真实 UAC 仍需单独确认。
- 2026-10-22 02 connect journal + Scope Local 实测（通过）：
  - 以旧跳板 VM 为跳板，02 创建 4 条映射（13306/18080/13389 + 28081→127.0.0.1:5985），写 8 条 connect journal 变更和本机 TrustedHosts/profile journal；28081 TCP 实测 OPEN。
  - 03 Site 删除 4 条 portproxy + 4 条防火墙规则（按 netsh 规则的 DisplayName 查找、按真实 Rule Name 删除），原有 `ZCode-WinRM-Tailscale` 保留；03 Local 恢复 TrustedHosts、删除 profile；Site/Local journal 均 `Undone`，12/12 检查通过。
  - 本轮测试使用 `-Target 172.21.64.1 -NoVerify`（该目标仅 3306 开放）；28081 的 TCP 已实测，Web/MySQL/RDP 的端到端验证仍需真实目标。
- 离线测试：26 项转发 + 10 项菜单/参数/失败传播 + 35 项状态/撤销 + 12 项 01（Join-Tailnet 重试 + 安装判定），共 83 项通过。测试不执行真实安装或访问生产。
- 2026-10-23 UAC/安全基线自动化验证（在保留的 2019 Desktop 机 `zcode-kit-2019d` 上，无人工点击）：
  - **完整闭环通过**：`Msvm_Keyboard` 注入 `Win+R` → `uac-launch.cmd`（`Start-Process -Verb RunAs`），PowerShell Direct 检测到 `consent.exe`（证明真实弹出 UAC 同意框），`Alt+Y` 批准后 01 以管理员运行并**成功入网**（`100.67.69.46`，`[ ok ] tailnet joined.`），随后 03 全量撤销（logout、MSI 卸载、账号/规则/注册表/access-result 回退）；`01Exit=0`、`03Exit=0`、journal `Undone`、Tailscale 已卸载、`zcode_ops` 已删。
  - 首轮 Tailscale 在 `TS_AUTHKEY` 路径回退到交互登录（后台确认旧 key 实为可复用且有效，非过期/消耗），01 正确回滚；换新 key、停 IPN 后用**显式 `--authkey` 兜底**才通过。说明 env-key 路径可能静默转交互、`--authkey` 更可靠。**已加固**：01 现在把 `To authenticate, visit:` 也纳入兜底重试条件，env-key 静默转交互时会自动改走 `--authkey`（离线测试覆盖）。测试壳已改为读取 `uac-01.exit`（01 真实退出码）。
  - 关键排障：`Set-VM -EnhancedSessionTransportType HvSocket` 是**开启**增强会话（会弹「显示配置」对话框挡住合成键盘），`VMBus` 才是基本会话；此前写反导致自动化卡住。
  - 测试后清理：删 `uac_admin`、关闭自动登录、config.json 复位为空模板、删测试产物与桌面快捷方式、删本地 authkey/凭据文件、VM 关机；UAC 注册表回到基线。证据见 `lab\helper49.log`、`lab\uac2-01.log`、`lab\uac2-03.log`、`lab\status-52/53.json`。
- 2026-10-27 按现场复盘加固：
  - **控制面 TLS 握手被重置**（`BackendState=NeedsLogin` + `fetch control key`/`wsarecv`，但 curl 同地址返回 200）：01 自动给 Tailscale 服务设 `GODEBUG=tlsmlkem=0`、重启服务并重试；变更写 `registry.tailscale-env` journal，03 精确回退。
  - **MSI 安装判定**：不再只看退出码（部分机器返回空）；以安装产品/服务存在 + MSI 日志 `MainEngineThread is returning 0` 判定（`Test-ZcTailscaleInstall`）。
  - 无内置安装包时改用 `curl.exe --retry` 下载 + 大小/签名校验；join 失败输出 `BackendState/Health`。
  - **真机回归未做**（无可复用 VM/ISO）。

**未验证：**
- 客户现场实际的 Windows Server 2019 定制镜像（评估版 Desktop/Core 均已通过）、完整现场安全基线、重启恢复；评估版上的真实 UAC 双击完整闭环已通过。
- `Enable-PSRemoting` 新建宽规则的禁用分支未在“WinRM 默认关闭”的宿主上实测；评估镜像默认已启用 WinRM，预先存在的宽规则只告警不收紧。
- 02 的完整目标验证（本次 `-NoVerify`，仅 28081 TCP 实测；Web/MySQL/RDP 需要真实目标服务）；多项目并发、MySQL 登录与业务查询。
- Tailscale GUI/IPN 持有时 CLI 会阻塞：01 会停 IPN 后重试，仍阻塞时使用 `--authkey` 兜底；该兜底会让本地管理员在短命进程命令行看到 auth key。完整干净测试中正是靠该兜底入网。
- 02 在“规则已创建、后续验证失败”时不会自动回滚远程规则；journal 已记录，需运行 `03-undo.ps1 -Scope Site`。本次测试中已用 03 清理。
- TCP OPEN 只证明入口连接成功，不代表后端应用健康。

回归全过程（含一次写坏生产转发并恢复的事故）记录在项目内部回归文档中，未随本仓库分发。

## 入口

- `start.cmd`：菜单 `[1] 现场初始化 / [2] 本机连接`。
- `config.json`：运行前填入实际信息，视为密码文件保管。
- `01-jump-setup.ps1`：现场引擎，默认拒绝执行。只有隔离测试机可显式使用 `-AllowExperimentalSiteSetup`。新增 `-SkipSignatureCheck`、`-AllowExistingAccountUpdate`、`-AllowBroadWinRM`、`-NoRollbackOnFailure` 等显式开关；加 `-UseOnlineInstaller`（或 config `useOnlineInstaller: true`）改为在线下载官方安装包，不再使用内置 MSI（安装时需能访问 `pkgs.tailscale.com`）。
- `02-connect-site.ps1`：本机引擎；相同转发不写入；冲突直接失败；新建规则写入 connect journal；不再自动重启 IP Helper。
- `zc-state.ps1`：共享变更日志/撤销库；01/02/03 必须与它放在同一目录。
- `03-undo.ps1`：按 journal 撤销；支持 `-List / -DryRun / -RunId / -Latest / -All / -Scope Site|Local|All`。
- `tools/tailscale-setup-1.104.1-amd64.msi`：约 36.9MB，x64 离线安装载体；安装前校验 Authenticode 签名。
- `tests/`：只运行模拟测试，不要把它当作生产部署脚本。

## 推荐：已有现场只读检查

先填写配置中的 `opsUser / opsPassword / siteName / jumpHost / targetServer`。为避免连接错服务器，建议明确填写 `targetServer`，不要凭端口开放情况推断业务角色。

```powershell
.\run.ps1 -Mode 2 -VerifyOnly
```

或直接运行引擎（省略密码参数时交互输入）：

```powershell
.\02-connect-site.ps1 -JumpHost <跳板机TailscaleIP> -Target <主服务器IPv4> -VerifyOnly
```

`-VerifyOnly` 不安装软件、不改服务/TrustedHosts、不自动发现或扫描候选、不改转发/防火墙、不写接入档案。任一必需规则缺失、监听未启用、TCP 或 HTTP 验证失败，最终返回非零，不显示成功。

## 普通本机模式的安全行为

```powershell
.\run.ps1 -Mode 2
```

- 如果规则完全一致：仅验证，显示 `unchanged`，不删除重建、不刷新防火墙。
- 如果缺少规则：先完整预检、再创建；检查命令退出码并回读。失败只回滚本次新增对象，不碰既有规则。
- 如果同端口已有其他目标/监听地址/服务：拒绝执行，不自动接管。
- `-Force` 与 `-EnsureOnBoot` 已禁用；不再建立高权限开机任务或重启服务。
- `-NoVerify` 明确显示 `UNVERIFIED`，不等于验证通过。
- 自动候选识别仅是辅助；多个候选需要人工确认。无头运行必须填写 `targetServer`，不能隐藏等待输入。

## 变更日志与撤销

每次 01/02 运行都会写一份 journal，不含 auth key 或密码：

| 范围 | 位置 | 内容 |
|---|---|---|
| 现场（01/02） | `C:\ProgramData\ZCodeRemoteAccess\runs\<runid>.json` | 账号、注册表、WinRM、防火墙、portproxy、文件、Tailscale |
| 本机（02） | `%LOCALAPPDATA%\ZCodeRemoteAccess\runs\<runid>.json` | TrustedHosts、生成的 profile |

撤销命令：

```powershell
# 列出所有运行记录（在跳板机上执行）
.\03-undo.ps1 -List -Scope Site

# 只出计划，不改动
.\03-undo.ps1 -RunId <runid> -Scope Site -DryRun

# 确认后执行（Site 必须在跳板机上运行）
.\03-undo.ps1 -RunId <runid> -Scope Site -Force

# 本机 TrustedHosts/profile 撤销
.\03-undo.ps1 -Scope Local -Latest -DryRun

# 显式吊销 Tailscale 节点 / 卸载由本工具安装的 Tailscale
.\03-undo.ps1 -RunId <runid> -Scope Site -UnjoinTailscale -RemoveTailscale -Force
```

安全规则：

- 只删除 journal 记录、且当前值仍与 journal 完全一致的资源；被改过的规则/账号会报错并跳过。
- 防火墙规则必须带有本 run 的 `ZCodeRemoteAccess:<runid>` 描述标记。
- portproxy 必须监听地址、端口、目标全部匹配。
- 账号删除必须 SID 匹配；已有账号被改密码时无法恢复旧密码，会在撤销报告中要求人工处理。
- `config.json` 是用户可编辑文件，不自动回滚；`access-result.txt` 有备份时恢复备份。
- 默认保留 Tailscale 安装和节点；卸载/登出必须显式加 `-RemoveTailscale` / `-UnjoinTailscale`，且 auth key 仍需在 Tailscale 管理后台吊销。
- `-Scope Site` 必须在跳板机上运行；本机运行会因 journal 主机名不匹配而拒绝。

## 配置示意（不要直接复制示意值上生产）

```json
{
  "authKey": "",
  "opsUser": "zcode_ops",
  "opsPassword": "",
  "siteName": "",
  "jumpHost": "",
  "targetServer": "",
  "dbPort": 13306,
  "webPort": 18080,
  "rdpPort": 13389,
  "extraForwards": [],
  "advertiseRoutes": [],
  "useOnlineInstaller": false,
  "profilePath": ""
}
```

- `jumpHost` 是跳板机的 Tailscale IPv4；若为空，可读取从现场带回的 `access-result.txt`。
- `targetServer` 是现场实际主服务器 IPv4；与跳板机地址不是同一概念。
- `dbPort/webPort/rdpPort` 是跳板机入口端口，目标端口暂固定为 3306/80/3389。
- `extraForwards` 是字符串数组，例如 `["23389:10.4.76.200:3389", "33389:10.4.76.30:3389"]`。
- `profilePath` 为空时生成工具目录下的项目档案；只读模式不生成文件。
- `authKey/advertiseRoutes` 仅用于现场实验模式。已有节点连接不需要重新输入 auth key。
- `useOnlineInstaller: true`（或运行 `run.ps1 -Mode 1 -OnlineInstaller`）改为在线下载 Tailscale 官方安装包（带签名校验），不再用内置 MSI；适用于想用最新版或分发时不想带 37MB 安装包的场景。安装时需能访问 `pkgs.tailscale.com`。

## 安全加固现状与剩余项

已加固：

1. SYSTEM 降级任务：随机任务名、随机脚本/密钥/输出文件，位于 `%ProgramData%\ZCodeRemoteAccess\runs\<runid>\`，ACL 仅 SYSTEM/Administrators，任务结束删除；auth key 优先通过 `TS_AUTHKEY` 进程环境传入。GUI/IPN 阻塞 CLI 时先停 IPN 重试；仍阻塞时用 `--authkey` 兜底（会短暂出现在本地进程命令行，输出中会告警）；SYSTEM 任务为最后手段，带超时和进程/文件清理。
2. 账号创建：`New-LocalUser` + SecureString，不再把口令交给 `net user` 命令行；`LocalAccountTokenFilterPolicy` 修改写入 journal，可精确恢复。
3. 安装包：Tailscale MSI/安装器先校验 Authenticode（发行者 Tailscale Inc.），可再指定 `-ExpectedInstallerSha256`。
4. WinRM：`Enable-PSRemoting` 新建的宽规则会被标记并禁用；本工具自己的规则限源 `100.64.0.0/10`。**预先存在**的宽规则不擅自修改，只告警。
5. 变更日志与撤销：01/02 所有新建资源写入 journal；03 只撤销归属明确且状态未变的资源；01 失败时自动回滚本次已应用资源。
6. 02 新建防火墙规则唯一命名并带 run 标记；本机 TrustedHosts 仅在当前值与 journal 预期一致时恢复。

剩余风险：

1. 预先存在的宽 WinRM 规则仍可能保留；现场若不允许，需要甲方单独审批后手工收紧。
2. 已有账号被 `-AllowExistingAccountUpdate` 改密后，旧密码无法恢复；默认拒绝改已有账号。
3. `config.json` 不自动回滚；本机安装的 Tailscale 不自动卸载；Tailscale 节点和 auth key 需管理后台手工吊销。
4. 客户现场实际定制镜像的“加固后完整 01 + 03”复验仍未做（评估版 2019 Desktop/Core 已通过）。
5. 安全基线（磁盘加密、日志审计、最小权限、凭据轮换、节点审批）仍需按现场制度补齐。

## 离线测试

```powershell
.\tests\Forwarding.Tests.ps1
.\tests\Launcher.Tests.ps1
.\tests\State.Tests.ps1
.\tests\JoinRetry.Tests.ps1
```

四组共 83 项，均不连接现场、不执行真实安装。`State.Tests.ps1` 覆盖 journal 往返、归属判断、变更资源拒绝删除、只删本 run 防火墙、DryRun 零写入、02 connect journal 写入、netsh 规则 DisplayName 回退、`registry.tailscale-env` 回退和源码安全约束；`JoinRetry.Tests.ps1` 覆盖 Join-Tailnet 的交互回退/`--authkey`/TLS-reset 兜底与 MSI 安装结果判定。

## 关于“零操作”

一键是目标，不是无条件保证：双方需要管理员授权、现场允许出网、Tailscale 节点已被授权、服务可达。离线安装包只解决安装文件下载，不会让没有网络的设备入网。Tailscale 打洞成功可直连，失败时可能中继；不能保证所有现场相同延迟或一定 P2P。
