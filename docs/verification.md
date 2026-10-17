# 本机验证记录

日期：2026-10-17。环境：Apple Silicon、macOS 27.0.1、Swift 6.4。

## 实例状态、侧栏与隐私：本次最新结果

- 实测发现运行中的微信分身被显示为待打开：App Translocation 路径经 Foundation 处理后使用 `/var/folders/…`，旧代码仅接受 `/private/var/folders/…`。包名、实例标记、Bundle ID、只读卷、包及主程序 inode 均一致。现在兼容两种系统别名，继续保留全部身份验证；管理器实际显示微信分身 Running 及其 PID。
- 卡片与菜单栏共用逐实例状态，提供检查中、启动中、运行中、退出中、失败和副本缺失反馈。启动先观察实际进程，交接最多额外检查 8 秒；超时显示原因和重试，不会一直转圈。退出被拒绝时继续显示真实运行状态及原因。事件监听归 AppModel 所有，窗口关闭不取消监听。
- 使用独立的 `.local/verification/status-example` 工作区与真实 Cocoa Probe 验证：管理器启动/退出、外部启动/退出通知、临时缺失可执行文件时的失败提示、恢复后重试成功。全过程没有创建管理窗口，状态仍正常更新；验证程序不操作微信进程或账号资料。
- 新界面已实际打开，检查了微信运行状态、折叠后的图标导航、展开按钮与 Control-Command-S 快捷键。重开管理器后，折叠偏好保留，运行中的微信仍被正确识别。截图仅保存在忽略目录 `.local/verification/`。
- 32 项测试通过：26 项核心测试和 6 项管理状态测试。新增覆盖两种系统路径、exec 退出与启动交接、回调返回 PID 但实际未运行的超时、失败恢复、退出失败和窗口之外的事件更新。
- 最终 release 构建及 `codesign --verify --deep --strict` 通过，新版 `dist/DualSpace.app` 已启动。
- 隐私规则覆盖运行资料、清单、恢复包、账号数据库、日志、截图目录、安装包、环境凭据和构建产物。当前可分享文件扫描通过。另在隔离的测试仓库中确认：忽略文件已经被跟踪、正文已脱敏但暂存区仍保留敏感路径、可分享符号链接，这三类情况均被检查脚本拒绝；输出不包含匹配正文。
- 公开文档中的本机用户名路径、具体实例标识和本地证据编号已脱敏，原始记录只保留在 `.local`。项目根目录没有 Git 仓库或远端；本次未提交、推送或上传文件。检查不追溯远端和历史提交，也不读取账号数据库。

实现边界与接口依据见[状态与隐私设计](design/instance-status-privacy.md)。进程状态仍不等同于账号已登录。

## 朋友圈故障修复：本次最新结果

当前官网版 4.1.15 私有 HOME 分身与原版 4.1.13 同时运行。用户已实际验证并确认「朋友圈属于分身，操作正常」。以下旧记录中的「尚未取得独立登录窗口」描述早期沙盒实验，不能代表当前私有 HOME 分身状态。

- 根因证据：Crashpad 的 bootstrap_check_in 报 `name too long`。原厂团队前缀 + 分身 Bundle ID + 握手后缀共 129 字节，系统上限为 128 字节且包含结尾空字符。原始错误摘录在 `.local/verification/moments-root-cause.log`。
- 仅为 AppEx 重新分配 ID 时仍卡在相同 Mach 消息等待位置；设置分身 Info.plist 的 TeamIdentifier 为空后，Crashpad 和 AppEx/Helper/GPU/Renderer 均正常运行。主 Bundle ID 和账号目录未迁移。
- 旧主进程正常退出后，确认并清理了其不持有聊天数据库句柄的孤立 AppEx；没有添加自动杀进程或常驻轮询服务。
- 修复后首次观测：主程序 PID（已省略）、Crashpad PID（已省略）、AppEx PID（已省略）；持续近四分钟仍只有同一个 AppEx 主进程，辅助渲染进程随功能使用正常出现。原版 PID（已省略） 保持运行。未测量定量帧率或长期内存趋势。
- 25 项测试全部通过。新增覆盖辅助身份隔离、服务名故障样例、直接入口主程序权限、旧账号目录保留。真实修复包通过 `codesign --verify --deep --strict`。
- release 管理器已重新构建并验签。使用新版 CLI 从官网源新建 `.local/verification/moments-build/Applications/WeChat Build Check-<instance>.app`，确认原生入口、空团队前缀、独立 AppEx ID、预创建的私有 HOME 和完整签名均正确。这份构建检查副本未启动或登录；当前用户已确认的运行副本仍为原来的 WeChat Private。
- 回退包保存在 `.local/verification/before-moments/Previous.bundle`；只改辅助身份的中间包为同目录 `Namespaced.bundle`。回退时须先正常退出分身；不要覆盖资料目录。当前工作区清单未改动。

本次没有发送消息、点赞或发布朋友圈。朋友圈内容与流畅程度由用户亲测确认，长期稳定性、音视频和所有微信版本兼容性不属于已通过结果。实现与证据详见 [修复设计](design/wechat-moments.md)。

## 早期验证记录

- 微信来源：本机 `/Applications/WeChat.app`，版本 4.1.13，build 269602，带 App Store 收据。原包 entitlements 导出提示 invalid entitlements blob，原包严格验签返回 CSSMERR_TP_NOT_TRUSTED。这个结果只说明本环境中检查未通过，不能推断其原因或断言原包被修改。
- 创建了真实微信副本，独立 Bundle ID，完整代码签名检查通过。最初启动的崩溃日志明确指出本地签名动态库的团队验证失败；随后在副本签名中处理了本地库加载。
- 非沙盒版本曾出现在系统运行列表，但窗口检查未能证明独立账号登录。因此未标记微信双开成功。
- 原生独立沙盒版本在启动阶段退出，未完成独立账号验收。本次没有操作微信账号退出、扫码、发送消息或修改原版安装。
- 创建并实际启动 Cocoa Profile Probe 副本。它写出的 Foundation HOME、环境 HOME、Bundle ID 均指向其独立资料配置，重启后的 launchCount 增加，已有资料保留。
- 原生管理窗口已实际打开，并检查副本列表、已安装应用库、搜索及启动操作。它显示错误与启动观察，不将启动状态等同于账号隔离。
- 19 项核心测试通过，新增内嵌代码 bundle、真实扩展属性签名资源及未知权限阻止发布的回归覆盖。签名失败等事务测试使用注入的测试签名器；真实签名另由真实应用副本与样例验证。最新 release 构建完成并通过发布包签名检查。

## 用户提供的官网版 4.1.15

DMG 路径：`~/Downloads/WeChatMac_4.1.15.dmg`，532016523 字节。SHA-256：`ceea355d5c93419658f777fdd1010f9b19d14fab6dc552af9c208cddad7f248f`。通过 Finder 打开映像，只将应用提取到项目 `vendor/WeChat-4.1.15/WeChat.app`，没有覆盖已安装微信。版本 4.1.15，build 270135，无 App Store 收据。

主程序 SHA-256：`c74cdb70a5e261bf264e71e38a646f1f936469c1d7d31c7c490588166e892c53`。受控终端报告签名权限 blob 无效，但正常 GUI 和 REA 原生检查均能读出原有 app-sandbox、allow-jit、应用组、网络与设备权限。两条检查路径的程序摘要一致；不能据终端结果断言官网包损坏或没有权限。来源签名证据为 （本地证据编号已脱敏），留存在 `.local/verification/official-source-signature.json`；该检查不等于整包信任或公证验收。

首次创建漏签了 XPlayer 的 `vk_swiftshader_icd.json`：它通过扩展属性持有独立签名。现已将这类普通文件纳入签名叶节点，保留正文。随后 CLI 和正常 GUI 均成功创建并严格验签官网版副本。

GUI 生成的 `.local/Applications/WeChat Official-<instance>.app` 保留可读的普通来源权限，并移除原厂共享应用组。它生成了自己的容器 `~/Library/Containers/local.dualspace.instance.i<instance-id>/Data`，有独立配置及日志。没有读取聊天数据库。管理器观察到启动后退出，用户明确反馈只有原来的微信窗口。另一副本补加动态代码运行权限的实验也未取得独立窗口。

按副本 PID 与已知时间窗检查的系统记录包含 App Translocation、ad-hoc 证书链警告、服务连接错误和进程结束，尚不足以单独确立退出根因。证据：（本地证据编号已脱敏）、（本地证据编号已脱敏）。输出有截断，不声称覆盖全部日志。

来源权限无法读取时，创建与重建现会明确停止，保留旧副本和清单，避免猜测权限继续发布。官网下载包及 `/Applications/WeChat.app` 未被修改；失败副本保留用于诊断，暂不作为可用微信分身交付。

## 原生沙盒独立启动样例

通过 `DUALSPACE_PROBE_SANDBOX=1 ./scripts/build-probe.sh` 构建明确启用 App Sandbox 的来源样例，创建两个副本并分别打开。窗口及各自 state.json 显示不同的系统容器。

第二个副本打开时，系统应用清单显示 DualSpace 已退出，来源 `examples/build/ProfileProbeSandbox.app` 已临时移到 `.source-backup`；副本仍显示自己的窗口、独立 HOME 和 launchCount 1。来源随后恢复。此流程验证无需来源程序和管理器参与启动，不宣称完成了两个样例同时持续运行的验收。

第二个样例的状态位于 `~/Library/Containers/local.dualspace.instance.i<instance-id>/Data/Library/Application Support/ProfileProbe/state.json`，Foundation HOME 和环境 HOME 相同。原生沙盒由系统设置 HOME，不依赖启动器环境变量，因此状态中 profile 字段的缺省字符串不代表它使用原版资料。

## 最新性能调整

管理器不再每三秒重读清单或检查所有进程。由 NSWorkspace 的启动/退出事件及窗口重新激活事件触发刷新；未变化的数据不发布 UI 更新。图标读取离开 UI 主执行器。

日常启动只做轻量身份/文件存在性检查，不再执行整包 codesign --verify。完整验签在创建、重建及用户手动诊断时执行。移除了启动后固定两秒等待。

原生沙盒程序直接作为副本主入口；需要环境设置的副本启动器以 exec 替换自身。没有新增常驻服务或包装进程。关闭管理器后的沙盒样例验证见上。没有将窗口检查工具的等待时间当作应用冷启动耗时，正式性能数据仍未测量。

## 早期未通过的验收（后续进展见顶部）

微信两个真实账号同时在线、消息与文件隔离、通知及音视频、冷启动性能和长期稳定性尚未通过。官网包已由用户提供并实测，但仍没有取得独立登录窗口，具体兼容性原因尚未证实。

泛化到其他应用需要逐项观察，不能从 Cocoa 样例或单元测试推导“所有软件都能隔离”。完整 VM 级隔离不在当前实现中。
