# DualSpace

[English](README.md)

为 macOS 应用创建可独立运行的副本和资料配置。创建后，直接从 Finder 或 Dock 启动副本 `.app`，管理器可以完全退出；副本运行不依赖管理器、代理或后台服务。

## 使用

双击 `dist/DualSpace.app`。还没有构建时，双击 `Launch.command`，或者运行：

```sh
./scripts/build.sh
```

在 **App library** 选择应用，或者把 `.app` 拖入窗口，命名并创建副本。在副本操作菜单选择 **Show Copy in Finder**，将它拖到 Dock，以后就按普通软件使用。每个副本都有固定的独立身份和区别图标。

实例卡片与菜单栏会显示检查中、启动中、运行中、退出中、启动失败或副本缺失。运行时显示 PID，失败时显示原因及重试按钮。从 Finder 启动也会同步状态，关闭管理窗口后仍有效。进程运行状态不代表账号已经登录。

点击页面标题旁的侧栏图标，或按 **Control-Command-S**，即可折叠或展开左侧栏。折叠后仍能通过图标导航，软件会记住这一选择。

完整复制与签名只在创建、重建时执行。日常启动不扫描整包签名。平时通过系统应用事件更新状态，仅在启动交接、等待 macOS 登记进程时进行有界检查。

## 独立空间如何运行

- 原生沙盒应用保持原有主程序入口，由 macOS 为独立应用身份建立系统容器。
- 微信私有 HOME 副本保留原生入口，通过 Launch Services 传入独立资料环境；AppEx 辅助程序使用独立身份，清空遗留的原厂团队名前缀，避免 Crashpad 通信服务名超过系统长度限制。
- 其他原生应用设置独立 HOME。内置的小启动器通过 `exec` 将自身替换成副本主程序，不保留常驻包装进程。
- Chromium / Electron 应用额外设置独立 `--user-data-dir`；来源启用沙盒时，资料放在自己的系统容器内。

副本自带程序文件与必要启动器，启动时不查询原版和管理器。重建更新需要原版应用。重建和更名保留副本身份及资料路径；移除副本会保留资料，并将应用包放进工作区 `Retired` 文件夹，便于恢复。

独立进程、独立资料目录和系统安全沙盒是不同的层级。普通原生应用的 HOME 重定向只是资料分离策略，不能保证它没有硬编码路径、共享服务或额外账号规则。App Store 收据、原厂授权与网页登录回调也可能影响兼容性。界面分别显示启动观察与尚未核实的账号隔离状态，**不宣称任意应用百分之百兼容**。

## 当前验证

核心测试覆盖签名失败保留旧副本、固定身份更新、并发操作、路径边界、取消和不依赖原版的启动前检查。实际 Cocoa 样例会记录 Foundation HOME 和持久化启动计数；这个结果证明通用机制，不代替每个目标应用的验证。

官网微信 4.1.15 私有 HOME 副本现已与本机原版 4.1.13 同时运行。此次发现 Crashpad 服务名超出 macOS 的 128 字节缓冲区，导致 AppEx 初始化阻塞，且 AppEx 辅助程序仍沿用原版身份。两处已修复，保留原有账号资料目录；用户已确认「朋友圈属于分身，操作正常」。详见[验证记录](docs/verification.md)和[修复设计](docs/design/wechat-moments.md)。长期稳定性及其他微信版本尚未验证。

沙盒样例已验证：管理器关闭、原样例安装包临时移开后，仍能直接启动副本。32 项测试通过，包含微信隔离、系统转移路径识别、启动交接与超时、失败恢复及不依赖窗口的状态更新。真实 Cocoa 样例也通过启动、退出、外部事件、失败与重试检查。来源签名权限无法读取时，创建与重建会停止并保留现有状态；可从受控终端之外正常打开的图形界面重试。

## 本地隐私

`.gitignore` 排除本地工作区、资料、实例清单、恢复副本、数据库、日志、截图目录、应用包、安装包、凭据及构建产物。公开验证记录已脱敏本机路径和实例标识；原始诊断与截图放在 `.local/` 下。

分享源码前运行 `./scripts/check-privacy.sh`（需要 Git 和 ripgrep）。它检查忽略规则、可分享文件及存在的 Git 暂存内容，也能指出已经被跟踪的忽略文件。检查只报告文件名，不打印敏感匹配正文，不上传数据。范围是当前文件和暂存内容中的已知模式，不包括远端及历史提交。开发构建产物分享前需单独检查；使用 `DUALSPACE_STANDARD_STORAGE=1` 可避免把本地工作区路径写入应用配置。

## 开发

需要 macOS 13 以上及 Xcode Command Line Tools。构建当前机器架构的二进制；本次环境为 Apple Silicon、macOS 27.0.1。

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/build-probe.sh
DUALSPACE_PROBE_SANDBOX=1 ./scripts/build-probe.sh
./scripts/cli.sh inspect '/Applications/Google Chrome.app'
./scripts/cli.sh create '/Applications/Google Chrome.app' 'Chrome Work'
./scripts/cli.sh list
```

`scripts/cli.sh` 使用最近构建的 CLI；修改源码后先重新构建。`DUALSPACE_HOME` 可以覆盖储存目录。本地构建默认把副本及资料放在项目 `.local` 内，并在应用中写入这个开发工作区的位置。需要使用正常的 Application Support 储存时：

```sh
DUALSPACE_STANDARD_STORAGE=1 ./scripts/build.sh
```

本地应用为 ad-hoc 签名，未经公证，不修改系统安全设置。构建缓存与暂存文件保留在项目内。`--disable-sandbox` 仅用于避免嵌套 SwiftPM 构建沙盒，既不改变 macOS 安全设置，也不改变目标应用的运行时沙盒。

[设计文档](docs/design/dualspace.md)记录了兼容策略与原始参考来源。
