# 2026-11-18 两机真机直连验收记录

代码为分支 `codex/remote-access-kit-reliability` 的 `bf1912e`，分发包为 2026-11-10 12:22 重建的 `remote-access-kit.zip`（31.0MB，SHA256 `02c0d8cf4c1bbb3e66e14c4138e9cde59467c2a8edbfffc54c8ff25b270fd563`）。全程由用户在两台机器上通过 GUI 操作，日志由用户回贴；本记录不含口令与 auth key 明文。

## 环境

| 角色 | 机器 | 系统 | 说明 |
|---|---|---|---|
| A（本机） | 已在 tailnet 的主力机 | Windows | Tailscale CLI 可用，账号已隐去 |
| B（对端） | 全新 Win10 笔记本（机器名已隐去） | Windows 10 22H2（10.0.19045.5965） | 全新机器，此前未入网；工具位于本地工具目录 |

auth key 于当日经管理后台生成：Reusable、1 天有效期、非 Ephemeral、无 Tags。

## 结果

| 验收项 | 结果 | 关键证据 |
|---|---|---|
| B 端 GUI 初始化 | ✅ | Run `site-20261118T153109Z-e89947fd`，exit=0 |
| A 端 只读检查（首次） | ✅ 按设计失败 | VerifyOnly 不改 TrustedHosts，非域机器无法认证，exit=1 |
| A 端 连接/配置 | ✅ | Run `connect-20261118T154111Z-3d5a96fe`，exit=0 |
| B 重启恢复 | ✅ | 重启后 A 端只读检查 `VERIFY ONLY PASS`，exit=0 |

B 端初始化细节：

- 内置 MSI（tailscale 1.104.1）静默安装成功。
- 入网时环境变量方式被拒（IPC 被占），引擎停止 IPN/GUI 后改用 `--authkey` 重试成功——JoinRetry 加固在现场首次真实触发并生效。
- WinRM 以 Tailscale 范围规则启用；`zcode_ops` 入管理员组，`LocalAccountTokenFilterPolicy=1`。
- 结果写入 `access-result.txt`，`config.json` 回填 `jumpHost=<B-IP>`。现场名含中文，全程无异常。

A 端连接细节：

- TrustedHosts 追加 `<B-IP>`（保留既有条目，共 5 项）。
- WinRM 认证成功，远程命令 `hostname` 在 B 上验证通过；直连模式未做发现、转发或远端防火墙变更。
- 档案写入 `site-profile-site.md`。
- 隧道为 P2P 直连（未走中继），ping 约 377ms。

重启恢复细节：

- B 真实重启后 Tailscale 服务自启；A 端只读检查中默认认证方式报网络类告警后由 Negotiate 兜底成功，未修改任何本机配置、未写入档案。

## 验收后的后台设置

- `<B-节点名>` 节点密钥过期已禁用（详情页核实 `Expiry disabled`）。
- MagicDNS：`<节点名>.<tailnet>.ts.net`。
- B 作为长期在用节点保留，撤销流程本次不执行。

## 未覆盖

- 撤销回归（预览/执行、卸载 Tailscale、补做卸载路径）：用户选择保留 B 在用，按意图跳过，后续可在一次性机器上补测。
- RDP（工具不负责开启）、转发模式真实链路、MySQL/Web 业务访问、`Copy-Item -ToSession` 文件传输：本轮未执行。
- 真实 UAC 提权弹窗已由用户手动放行（两台各一次），宽 WinRM 规则告警策略未变化。

## 结论

`bf1912e` 的 GUI 全流程（对端初始化 → 首次只读拒绝 → 连接/配置 → 重启恢复）在 Win10 22H2 + 主力机真实环境验收通过；离线 142 项检查之外的“真机两机端到端”缺口自此补上直连部分。合并 `master` 前仅剩撤销回归未测（可选门槛）。
