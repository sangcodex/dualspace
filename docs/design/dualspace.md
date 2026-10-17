# DualSpace：macOS 独立应用副本

## 目标与已获授权范围

用户要求实际实现“选择哪个应用，就给哪个应用创建独立副本”，以微信双开为首个真实验证对象。提供可双击运行的原生 macOS 软件，支持任意数量的副本、独立名称、启动、定位、更新、移除以及可观察的兼容状态。此次已经授权实现与运行验证，无需再次确认方案。

当前目录为空。本机为 macOS 27.0.1、Apple Silicon、Swift 6.4；微信为 4.1.13。现有微信的 codesign 检查返回 CSSMERR_TP_NOT_TRUSTED，导出 entitlements 提示 invalid entitlements blob，因此不能把本机安装包当作签名与沙盒权限正常的样本，更不能由 Bundle ID 推断数据必定独立。

## 调研与选型

核验日期：2026-10-17。

- Apple NSWorkspace OpenConfiguration 支持 createsNewApplicationInstance 与 allowsRunningApplicationSubstitution，使用准确应用路径启动，并阻止系统替换成已运行的原版：https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/createsnewapplicationinstance
- Apple 的应用组可以共享容器、凭据与 IPC；仅修改顶层 Bundle ID 不等于隔离所有数据：https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups
- Apple 在 macOS 15 及以上对应用组容器检查签名与授权：https://developer.apple.com/documentation/xcode/accessing-app-group-containers
- wechat-multi 展示了复制、改 ID、重新签名路线，MIT 开源，但只针对微信，其静态说明不足以证明当前安装包正常：https://github.com/ashinno/wechat-multi
- macos-app-dual-open 的脚本适合单副本实验，缺少原生交互、事务更新与多副本状态：https://github.com/walker1211/macos-app-dual-open
- Duplex 展示 Electron 的独立 user-data-dir 路线，但许可证不允许重新分发源码或构建，且不覆盖原生微信。只借鉴公开文档解释的通用机制，不复制其代码：https://github.com/bnimit/duplex

采用 SwiftPM + Foundation/AppKit + SwiftUI，无第三方运行依赖。原生应用可直接调用系统复制、签名与 Launch Services；无需引入 Electron 管理器或后台服务。

## 能力边界

工具管理的是实际 .app 副本，而不是原版快捷方式。每个副本固定 UUID、Bundle ID、应用路径、资料目录和名称。更名与更新保留身份及资料目录。原应用和原有账号数据不作为修改目标。

兼容策略分为原生沙盒、普通原生和 Electron/Chromium。原生沙盒应用直接以原可执行文件作为副本主程序，由 Launch Services 建立独立系统容器；不能以未沙盒化启动器 exec 一个需要独立沙盒的主程序。普通原生副本内置启动器并设置独立 HOME/CFFIXED_USER_HOME。Electron/Chromium 内置启动器并额外传 user-data-dir；若来源启用沙盒，启动器作为沙盒主程序，而原程序按 Apple 规定继承沙盒，profile 放在自己的容器内。原生 HOME 重定向只是策略，不能保证应用遵守。现有权限可读取时保留可用的普通沙盒权限；开发团队、共享应用组与共享钥匙串权限不能冒充原厂授权。

运行反馈修订：微信重新签名后的动态库受 hardened runtime 的团队校验影响，需要在副本签名中允许加载本地签名库。仅以私有 HOME 启动未能核实独立微信登录；微信改用明确的独立沙盒主程序。QQ 的 NSPrincipalClass 为 AtomApplication，尽管它重命名了框架且未在标准位置放置 app.asar，仍应识别为 Chromium。

官网版 4.1.15 追加验证：用户提供 DMG，提取源放在项目 vendor 目录。XPlayer 的 JSON 资源带有 com.apple.cs.CodeDirectory 等扩展属性签名，不能仅靠 Mach-O 魔数枚举签名叶节点。复制后应将这些已有独立签名的普通文件一并重新签名，再签所在 bundle；保留资源正文，不修改官网源和原安装。

同一官网包在受控终端内的 codesign 报告权限 blob 无效，而由 GUI 正常启动的管理器及 REA 原生签名检查能读出完整权限，二者核对的可执行文件 SHA-256 相同。因此“当前调用环境读取失败”不能当作“来源没有权限”。创建与重建遇到未知权限应停止，不再通过猜测缺省权限继续生成；提示使用正常 GUI 路径重试。图形流程的官网版副本已创建且有独立容器，但仍在启动阶段退出，尚未证明原因，更不能宣称独立微信账号可用。

参考：https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html 与 https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox 。原生样例已经实际写出独立的 Foundation home，且再次启动后 launchCount 增加。

应用自带的授权、固定锁路径、共享 helper、Apple 系统服务、硬编码容器及云端账号规则可能阻止多开。系统保护应用不作为支持目标。禁止宣称“100% 全应用隔离”；界面展示复制就绪、运行观察、待验证与失败原因。没有登录验证时不能标为账号双开成功。

## 模块与接口

- DualSpaceCore：应用检查、模型、异步命令执行、目录与 manifest、复制和签名事务、运行状态。
- DualSpaceLauncher：嵌入副本的小型可执行文件，读取签名内的固定配置，设置资料环境，exec 原应用可执行文件。
- DualSpace：SwiftUI 主窗口和菜单栏，应用选择/拖入、资料卡片、状态和操作。
- dualspace-cli：同一核心的可复制示例与故障诊断入口；GUI 为常用途径。

核心构造显式注入 workspace URL、launcher URL 和命令执行器。create(source:name:)、refresh(id:)、rename(id:name:)、remove(id:) 都为异步接口；mutations 由跨进程文件锁保护，防止 GUI/CLI 重入。

## 用户对运行空间与性能的进一步要求

2026-10-17 继续修订：用户明确确认初版已在两个窗口登录不同账号。保留的 WeChat Work 包使用内置启动器、私有 HOME，启动器与微信主程序签名均未启用 App Sandbox；这是可用基线，而后续强制系统沙盒改变了运行条件。现在新微信副本恢复私有 HOME 策略，不修改已可用的初版副本和资料。签名时必须在私有 HOME 模式的所有代码中移除 app-sandbox/inherit，避免父进程与 exec 目标的沙盒模式冲突。保留必要的运行时权限及本地库加载能力。

重建必须保留已有模式：旧清单 usesSandbox 缺省代表原有私有 HOME，不能重新按来源权限推导并改成系统容器；显式 usesSandbox=true 的已有副本也不自动迁移。资料路径在刷新、更名后保持不变。检查、创建说明及界面区分私有资料与系统安全沙盒；恢复兼容路线不代表获得完整安全隔离。先用官网版创建新身份、新资料目录的副本验证，再补模式保持和签名权限边界测试。

本次官网私有 HOME 副本已实际运行，lsof 显示主程序与动态库来自副本，数据库句柄位于副本私有 HOME 下的独立容器。另发现 NSWorkspace 的路径检查遗漏 App Translocation：运行包被系统放到临时只读挂载位置，与管理路径设备号不同，但 bundle inode 相同。运行匹配增加一个受限分支：系统 AppTranslocation 路径、只读卷、相同文件名、实例标记与 Bundle ID、相同 bundle 和主程序 inode，全部成立才接受临时运行位置。普通外部复制路径仍不接受，避免按名称误认原版。启动回调中的旧进程对象退出不再直接当作启动失败；先找当前实例，无法立即确认则报告已请求启动，由事件更新真实状态。通知同样检查替代进程，避免把 exec 阶段当作崩溃。

用户明确要求副本像原软件一样独立运行，管理器只是创建/维护工具，不得形成运行依赖。副本从 Finder/Dock 启动时不读取管理器清单、不检查原版、不进行整包验签；需要设置环境时，内置启动器 exec 原程序后不再常驻。新的应用文件名使用可读名称与短 ID。

移除 GUI 的三秒轮询与每次启动的全包验签；通过系统应用事件刷新状态，图标读取放到后台，只在数据变化时刷新 UI。移除固定两秒等待，由启动/退出通知观察实际状态。创建/重建保持完整签名校验，手动诊断仍可验签。最终验收包括完全退出管理器后，直接启动两个副本并验证资料互不干扰。

## 生命周期与恢复

### 微信朋友圈与辅助进程适配实验（2026-10-17）

后续结果：本次已查明 Crashpad 握手服务名长达 129 字节，超出系统 128 字节缓冲区；清空私有 HOME 分身中遗留的 TeamIdentifier 前缀后，Crashpad、AppEx 和渲染进程正常运行。另补齐了 AppEx 的独立辅助身份，并将直接主程序入口纳入正式构建。用户确认「朋友圈属于分身，操作正常」。详细实验与边界见 [朋友圈修复设计](wechat-moments.md)。下面一段保留为初始实验背景。

用户确认只有分身卡顿、朋友圈无法打开，原版正常。实际采样发现分身反复创建 WeChatAppEx，多个进程停在 Crashpad SendDataToHandle 的 mach_msg 发送步骤，尚未完成初始化；原版只有一组正常浏览器辅助进程。当前 exec 方案下主程序在 sample 中没有正确 bundle 标识，NSWorkspace 也无法稳定观察它。先验证保留 CFBundleExecutable=WeChat、由 Launch Services 直接执行原程序、以 LSEnvironment 传递固定的私有 HOME/CFFIXED_USER_HOME 等资料环境是否消除该问题。Apple 官方键文档：https://developer.apple.com/documentation/bundleresources/information-property-list/lsenvironment 。该实验保留原实例 ID、资料路径、已有签名权限与可回退旧包，不更改原版或聊天资料；只有验证有效后才纳入微信构建策略。不能通过关闭 Crashpad 或 Chromium 安全功能来掩盖阻塞。

创建在工作区 staging 中完成复制、改写、内置启动器、签名和校验，全部成功才发布，并原子写 manifest。命令失败、取消、超时均清理 staging，不将半成品列作就绪。

更新先创建并校验完整新副本，再将旧副本移到备份、置换新副本、原子更新 manifest；失败恢复旧副本。更名同样走重建事务，避免直接修改有效包。运行中的副本禁止更新、更名和删除。移除只针对工具管理的 UUID 应用目录，保留资料目录及系统容器。

manifest 无法解析时明确失败，不能当作空清单覆盖。跨进程锁、重复名称校验、路径和符号链接检查、来源变化检测均有针对性验证。外部命令使用参数数组，不经 shell 拼接。

正常运行默认使用用户 Application Support/DualSpace；本次在受控工作区以 DUALSPACE_HOME 指定 .local，所有复制、构建、日志和验证产物留在项目内。

## 实现与验收

先通过 CLI 运行真实的微信创建示例，再补必要的事务与进程边界测试；随后运行 GUI，用原生 UI 核验选择应用、创建副本、显示错误和启动路径。真实微信验收区分：副本可构建、签名通过、进程存活、独立登录界面、两个真实账号同时在线。最后一项需要用户自己的扫码登录，不代替用户操作账号。

另创建小型 Cocoa 样例应用验证独立 HOME、重启后资料保留、两个实例同时运行、固定身份更新以及 Finder 双击启动器行为。它只证明通用机制，不替代微信兼容性验证。
