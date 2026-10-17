# 微信朋友圈串到原版与辅助进程阻塞

## 现状与证据（2026-10-17）

用户要求尝试修复分身点击朋友圈打开原版朋友圈、随后卡顿的问题，包含实现和本机验证授权。

当前运行的 `WeChat Private Fixed-<instance>.app` 为官网 4.1.15，已有独立 Bundle ID、私有 HOME、直接主程序入口和 LSEnvironment。原版 4.1.13 同时运行。主程序传给 WeChatAppEx 的 `--wechat-files-path`、`--wmpf_root_dir` 和 `--bundle-id` 已指向分身。仅继续修改 HOME 不能解释或解决剩余问题。

`BundleBuilder.rewriteNestedIdentities` 只改写主 ID 的同前缀标识，实际遗漏 `com.tencent.flue.WeChatAppEx`、`com.tencent.flue.helper*`、`com.tencent.flue.WeApp`，以及不同大小写前缀的 DebugHelper。REA `inspect_signature` 证据 （本地证据编号已脱敏） 确认分身 AppEx 签名身份仍为原版 ID。

本次 sample：分身 AppEx PID（已省略） 只有主线程和工作线程，主线程持续等待 Mach 消息；同一分身存在多份同状态 AppEx，没有正常 Helper 树。采样文件在 `.local/verification/appex-current-sample.txt`。旧记录将此位置识别为 Crashpad 初始化，但本次最近符号不完整，不能仅凭 Mach 等待断言共享 ID 是全部根因。

## 修复策略与边界

先在工作区内构造实验包，保留原包以便回退，不改原版安装、不迁移或删除账号资料。分别验证：

1. 对微信 AppEx 及所属 Helper、WeApp、DebugHelper 的已知 ID 作实例内映射；保持 framework 的资源身份，避免盲目改写所有腾讯库。检查签名标识与 Info.plist 一致。
2. 将已实验使用的直接主程序入口和私有 LSEnvironment 纳入构建流程，保存原实例 ID 与资料路径，保持 Finder/Dock 独立启动。
3. 若辅助进程仍阻塞，继续沿真实调用栈、崩溃处理服务和内部通信追踪，不把改名或单元测试当作朋友圈修复成功。

不增加常驻管理进程、轮询器或自动杀进程服务；不关闭 Crashpad、浏览器安全功能或系统安全设置。实验不发送消息、点赞或发布朋友圈。

## 选型与依据

复用 Swift/Foundation/AppKit、现有事务构建及系统 codesign，不需要第三方运行依赖。公开 wechat-multi 等项目主要处理顶层 Bundle ID 和重签名，没有给出当前版本 AppEx/朋友圈隔离验证，不能直接视作解决方案。

参考：Apple `LSEnvironment` 文档 https://developer.apple.com/documentation/bundleresources/information-property-list/lsenvironment；Crashpad Mach 服务及父子握手文档 https://chromium.googlesource.com/crashpad/crashpad/+/HEAD/handler/crashpad_handler.md 。上游资料解释系统接口，不证明微信的具体运行行为。

## 文件与验收

预计修改 BundleBuilder、实例启动策略及必要回归测试；通过真实样例验证后再固化实现。构建与验签全部成功后才置换已停止的分身，失败保留旧包。正常退出分身时不退出原版，不强杀持有数据库的主进程。

验收区分：构建/签名通过、独立辅助身份、正常辅助进程树、朋友圈归属分身、重复打开无异常堆积。最后两项必须实际观察或由用户验证；不能从静态配置推导已经成功。

## 根因更新

仅改辅助 ID 后 AppEx 仍停在同一初始化位置。2026-10-17 19:20:06（机器日志时区）新分身的 crashpad_handler PID（已省略） 明确报告 `bootstrap_check_in ...: name too long`。服务名由原厂 TeamIdentifier、分身 Bundle ID、`crashpad.child_port_handshake`、PID、线程 ID 和随机串拼接，本次为 129 字节；macOS SDK `servers/bootstrap_defs.h` 定义 `BOOTSTRAP_MAX_NAME_LEN = 128`，包含结尾空字符。Crashpad 上游 bootstrap.cc 对长度 >= 128 直接拒绝注册。

原包遗留的 Info.plist `TeamIdentifier = 5A4RE8SF68.` 并非本地 ad-hoc 签名的真实团队身份。下一实验将此配置设为空字符串，保留主 Bundle ID 和数据容器路径，缩短通信前缀 11 字节。需要确认主进程传给辅助进程的 bundle-id 同步改变、Crashpad 服务正常存活、AppEx 进入正常渲染流程。未来实例可使用更短且持久化的身份，但本次优先保住既有账号和目录，不直接改主 Bundle ID 触发隐式数据迁移。

上游验证：https://chromium.googlesource.com/crashpad/crashpad/+/6a9e2e6003096a33e4006290e570bbd3da59e5c6/util/mach/bootstrap.cc 。日志保存在 `.local/verification/moments-system.log`，只用于诊断，不包含聊天数据库正文。

## 实施结果

清空团队前缀后，分身主程序 PID（已省略）、Crashpad PID（已省略）、AppEx PID（已省略） 及其 GPU、Renderer、WeApp 辅助进程正常运行。主程序传给 AppEx 的 `--bundle-id` 与独立主 Bundle ID 相同，资料参数保持原路径。原版主程序 PID（已省略） 继续运行。

用户实际打开朋友圈后回复「朋友圈属于分身，操作正常」。这证明本机当前账号与版本组合通过本次功能验收；没有将捕获为黑色的 UI 截图当作内容验证，也不声称长期稳定性已验证。单独改辅助 ID 的实验没有解决初始化阻塞，因此服务名长度是本次卡顿的已证实原因；原版朋友圈错误路由的内部调用链未完整追踪，不能把两个修复的因果贡献混为一谈。

最终实现保持现有 UUID、Bundle ID、app 文件名与资料路径。私有 HOME 微信使用直接入口；其他需要启动器的程序仍使用 exec。直接入口保留主程序的 JIT 等签名权限，不误套用启动器的最小权限。补齐 AppEx、Helper、WeApp、DebugHelper 的已知身份映射，保留框架资源身份。

25 项测试通过，覆盖旧配置刷新后保留账号目录、独立子应用身份、原包不变、129 字节故障样例降至 118 字节、主程序权限和既有事务行为。未来微信实现变化或远超本次样例的 PID/线程编号组合仍需重新验证；本次未为此迁移既有 Bundle ID。
