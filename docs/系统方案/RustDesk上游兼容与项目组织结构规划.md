# RustDesk 上游兼容与项目组织结构规划

> 文档状态：项目组织基线  
> 版本：1.0  
> 日期：2026-08-10  
> 上位文档：`docs/系统方案/NexusFlow统一系统方案.md`

## 1. 文档目的

本文档定义 NexusFlow 在集成 RustDesk、Cloud/frp-rs 和 Authi 后的代码组织、Git 仓库、Cargo 模块、客户端生命周期和上游同步策略。

目标是在不改变 RustDesk 原生设备 ID、运行架构和构建入口的前提下，将 Tunnel 与 Authi 能力集成到 RustDesk 客户端，同时保持持续吸收 RustDesk 官方版本的能力。

本文档重点回答：

1. NexusFlow 客户端代码应放在哪里；
2. 新模块应挂载到哪个 RustDesk 原生进程；
3. RustDesk 上游文件允许修改到什么程度；
4. Git 仓库和 Git submodule 应如何划分；
5. Cloud 与 frp-rs 合并后如何作为独立组件发布；
6. RustDesk 官方更新如何同步、验证和发布；
7. 如何避免形成无法继续升级的长期重度 fork。

## 2. 已确认约束

### 2.1 RustDesk 原生兼容

- RustDesk 原生设备 ID 生成、存储和对外行为保持不变。
- RustDesk GUI、Service、`--server`、无人值守、UAC、登录界面和移动端服务生命周期保持原生一致。
- RustDesk 原生构建入口和平台构建方式保持不变。
- RustDesk Remote Desktop 协议、Rendezvous、Relay 和原生 IPC 不因 Tunnel/Authi 集成而破坏兼容。
- RustDesk 官方上游必须可以长期同步。

### 2.2 客户端融合

- Cloud 与 frp-rs 合并为一个 Tunnel Service。
- 用户端不运行独立 Cloud、frpc 或 Tunnel daemon。
- Tunnel 与 Authi Client 以内嵌 Rust 模块运行在 RustDesk 原生进程体系内。
- 第三方 AI Agent 仍是受控外部进程，由 Authi Agent Supervisor 启动和管理。
- Tunnel、Authi 和 RustDesk 共用 RustDesk 原生公开 ID，以及后台统一 `device_uid`。

### 2.3 后端组织

- 后端不要求单进程，目标是统一控制平面下的分布式服务。
- RustDesk Server Pro 可以获得完整授权。
- RustDesk Server Pro、Tunnel Relay、Presence Gateway、Authi Orchestrator 可以独立部署和扩容。
- 所有服务共用统一账户、设备、权限、套餐、审计和管理后台。

## 3. 当前仓库事实

截至本文档日期，当前目录具有以下特征：

- 根目录 `NexusFlow` 本身不是 Git 仓库；
- `rustdesk/rustdesk` 是独立 Git 仓库，`origin` 指向 RustDesk 官方仓库；
- `rustdesk/rustdesk-server` 是独立 Git 仓库；
- `rustdesk/rustdesk-server-pro` 是独立 Git 仓库；
- `cloud` 是独立 Git 仓库；
- `authi` 是独立 Git 仓库；
- `frp-rs` 当前目录未发现 Git 元数据；
- RustDesk Client 和 RustDesk Server 都使用 `libs/hbb_common` Git submodule；
- 当前根目录的 `docs`、集成版本和跨项目依赖关系没有统一 Git 提交进行追踪。

RustDesk Client 当前 Cargo workspace 入口：

- `rustdesk/rustdesk/Cargo.toml`
- `rustdesk/rustdesk/libs/hbb_common`
- `rustdesk/rustdesk/libs/scrap`
- `rustdesk/rustdesk/libs/enigo`
- `rustdesk/rustdesk/libs/clipboard`
- `rustdesk/rustdesk/libs/virtual_display`
- `rustdesk/rustdesk/libs/portable`
- `rustdesk/rustdesk/libs/remote_printer`

当前 RustDesk Git submodule：

```text
libs/hbb_common -> https://github.com/rustdesk/hbb_common
```

## 4. 总体组织原则

### 4.1 上游代码和产品代码分离

RustDesk 原生代码继续按照上游结构维护。NexusFlow 产品逻辑集中在明确的新目录中，不分散进入 `client.rs`、`server/connection.rs`、`core_main.rs`、平台文件和 Flutter 大型既有文件。

### 4.2 原生修改只做适配

对 RustDesk 原生文件的修改只允许承担：

- 模块声明；
- Cargo feature/依赖声明；
- 生命周期启动和停止挂载；
- 少量 FFI/IPC 入口；
- UI 导航和状态展示入口；
- 产品品牌和构建配置。

所有业务状态机、网络协议、控制平面客户端、Tunnel、Agent 管理和商业策略必须位于 NexusFlow 自有模块。

### 4.3 保持 RustDesk 双构建模式

RustDesk fork 应同时支持：

```text
不启用 nexus feature：尽可能接近 RustDesk 上游行为
启用 nexus feature：构建 NexusFlow 商业客户端
```

这样可以在每次上游同步后快速区分：

- 上游自身构建问题；
- NexusFlow 适配层问题；
- Tunnel/Authi 功能问题。

### 4.4 模块边界先稳定，仓库后拆分

不要为每个小模块创建独立 crate 或 Git 仓库。只有同时满足以下条件之一时才拆分：

- 需要独立版本和独立发布；
- 有独立服务端部署；
- 有不同许可证或授权边界；
- 被多个产品独立复用；
- 需要独立团队和发布节奏。

## 5. 客户端总体模块结构

### 5.1 三层结构

```text
RustDesk 原生层
├── 原生设备 ID
├── GUI / Service / --server 生命周期
├── Remote Desktop 协议
├── Rendezvous / Relay
├── 平台权限与无人值守
└── Flutter / IPC / FFI

NexusFlow 适配层
├── src/nexus.rs
├── RustDesk 生命周期挂载
├── RustDesk ID 和配置读取
├── Nexus IPC
├── Flutter FFI 薄接口
└── 状态与事件转换

NexusFlow 功能层
└── libs/nexus_client
    ├── runtime
    ├── identity
    ├── control
    ├── tunnel
    ├── agent
    ├── ipc
    └── status
```

### 5.2 推荐目录

```text
nexus-rustdesk/
├── src/
│   ├── 原生 RustDesk 源码
│   └── nexus.rs
├── libs/
│   ├── 原生 RustDesk libraries
│   └── nexus_client/
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs
│           ├── runtime.rs
│           ├── identity.rs
│           ├── control.rs
│           ├── tunnel.rs
│           ├── agent.rs
│           ├── ipc.rs
│           └── status.rs
├── flutter/
│   └── lib/
│       └── nexus/
│           ├── models/
│           ├── pages/
│           ├── services/
│           └── widgets/
├── Cargo.toml
└── Cargo.lock
```

### 5.3 `src/nexus.rs`

`src/nexus.rs` 是 RustDesk 原生层和 NexusFlow 功能层之间的唯一 Rust 适配入口，职责限制为：

- 组装 `NexusRuntime` 启动参数；
- 从 RustDesk 获取原生 ID；
- 获取平台、版本、安装状态和配置目录；
- 启动/停止 `nexus_client`；
- 将 RustDesk 生命周期事件转发给 `nexus_client`；
- 将 `nexus_client` 状态提供给 RustDesk FFI/IPC。

禁止在 `src/nexus.rs` 中实现：

- FRP 协议；
- UDP Presence 编解码；
- Authi HTTP/Socket.IO 业务；
- Agent 进程详细管理；
- 账户或商业逻辑；
- 服务路由和访问策略。

### 5.4 `libs/nexus_client`

初期只建立一个 crate，内部模块职责如下。

#### `runtime.rs`

- 管理 NexusFlow 客户端总体生命周期；
- 持有取消令牌；
- 启动 Presence、Control、Tunnel 和 Agent 子模块；
- 管理配置重载和有序退出；
- 汇总客户端健康状态。

#### `identity.rs`

- 接收 RustDesk 原生 ID，不自行生成替代 ID；
- 管理后台 `device_uid`；
- 管理设备公私钥和设备凭据；
- 管理绑定状态和凭据轮换；
- 对外提供统一设备身份快照。

#### `control.rs`

- 访问统一控制平面；
- 注册设备和刷新 Token；
- 拉取 Desired State；
- 上报能力、版本和配置应用结果；
- 接收 Authi 任务和控制命令。

#### `tunnel.rs`

- 管理 Cloud UDP Presence；
- 管理 Tunnel 状态机；
- 调用合并后的 `nexus-tunnel-client`；
- 按需启动、重载和停止 frp-rs runtime；
- 汇总 Tunnel 会话和流量状态。

#### `agent.rs`

- 管理 Authi Agent 会话；
- 校验可执行文件和启动参数；
- 启动第三方 AI Agent 子进程；
- 接管 stdin、stdout、stderr 和退出码；
- 执行取消、超时和故障隔离；
- 不把第三方 Agent 代码链接进 RustDesk。

#### `ipc.rs`

- 提供 `_nexus` 本地 IPC；
- 连接 GUI 进程和 RustDesk `--server` 进程；
- 使用独立版本化消息模型；
- 不修改 RustDesk Remote Desktop 网络协议；
- 尽量不修改 `hbb_common::Data`。

#### `status.rs`

- 定义 UI 所需的稳定状态 DTO；
- 汇总设备、Presence、Tunnel、Agent 和控制平面状态；
- 不向 Flutter 暴露 frp-rs 或 Authi 内部类型。

### 5.5 Flutter 组织

新的 Flutter 页面统一放在 `flutter/lib/nexus`，避免继续向已有大型 `flutter_ffi.rs` 和通用页面堆积业务逻辑。

Flutter 侧只负责：

- 开关和配置输入；
- 状态展示；
- 调用 Nexus IPC/FFI；
- 展示错误和诊断；
- 跳转统一后台或帮助文档。

Flutter 不负责：

- 持有设备长期凭据；
- 直接启动 frp-rs；
- 直接管理第三方 Agent；
- 自行决定套餐权限；
- 实现 Tunnel 路由策略。

## 6. 客户端生命周期挂载

### 6.1 运行进程选择

Presence、Tunnel 和 Authi Client 应运行在 RustDesk 原生 `--server` 主机进程中。

不建议运行在 GUI 进程，原因：

- GUI 可以退出，而无人值守服务需要继续在线；
- GUI 进程在多窗口和移动端生命周期中不稳定；
- 用户关闭窗口不应终止 Tunnel 和 Agent 控制能力。

不建议直接运行在各平台 `start_os_service()` 循环，原因：

- Windows、Linux、macOS 实现差异很大；
- Linux Service 还负责登录界面和用户会话进程监督；
- Windows Service 可能运行在 SYSTEM 身份；
- Authi Agent 通常需要用户上下文；
- 修改多个平台 Service 文件会显著增加上游冲突。

### 6.2 推荐启动顺序

```text
RustDesk --server 启动
  -> RustDesk 全局初始化
  -> RustDesk IPC 初始化
  -> NexusRuntime.start()
       -> 读取 rustdesk_id
       -> 加载 device_uid 和设备凭据
       -> 启动 Cloud Presence
       -> 连接统一控制平面
       -> 拉取 Desired State
       -> 初始化 Tunnel Runtime
       -> 初始化 Authi Client
  -> RustDesk RendezvousMediator.start_all()
```

### 6.3 推荐退出顺序

```text
RustDesk --server 退出
  -> NexusRuntime 停止接收新任务
  -> Tunnel 进入 Draining
  -> 结束或取消 Agent 会话
  -> 关闭 frp-rs runtime
  -> 停止 Presence
  -> 保存最后有效配置和状态
  -> RustDesk 原生清理
```

### 6.4 移动端

移动端继续使用 RustDesk 原生 service/foreground service 生命周期。`nexus_client` 根据平台能力启用子集：

```text
Desktop：Remote + Tunnel + Agent
Android：Remote + Tunnel；Agent 按产品需求启用
iOS：Remote；Tunnel 和 Agent 按平台限制评估
```

平台不支持的功能通过 Cargo feature 和能力上报禁用，不在运行时伪装为可用。

## 7. RustDesk 原生修改边界

### 7.1 允许修改清单

| 文件/区域 | 允许修改 | 目的 |
|---|---|---|
| `Cargo.toml` | feature、依赖、workspace member | 接入 `nexus_client` |
| `src/lib.rs` | 一个 `mod nexus` | 暴露适配入口 |
| `src/server.rs` | 启动/停止薄调用 | 挂载 `NexusRuntime` |
| `src/flutter_ffi.rs` | 少量命令和状态接口 | Flutter 访问 `_nexus` IPC |
| Flutter 导航/设置 | 少量页面入口 | 展示 NexusFlow 功能 |
| 品牌与构建配置 | 必要改动 | 商业客户端发布 |

### 7.2 尽量不修改清单

- `src/client.rs`
- `src/server/connection.rs`
- `src/rendezvous_mediator.rs`
- `src/core_main.rs`
- `src/platform/windows.rs`
- `src/platform/linux.rs`
- `src/platform/macos.rs`
- `libs/hbb_common`
- RustDesk 原生协议定义

如果确实需要修改这些文件，应先证明不能通过 `src/nexus.rs`、独立 IPC、已有配置接口或事件挂载实现。

### 7.3 `hbb_common` 策略

RustDesk Client 和 Server 当前都依赖同一个 `hbb_common` submodule。修改它会同时扩大客户端和服务端升级面。

原则：

1. 首选不修改 `hbb_common`；
2. NexusFlow 配置使用独立 `NexusConfig`；
3. Nexus IPC 使用独立 DTO；
4. Nexus 网络协议放在 `nexus-tunnel`；
5. 只有必须改变 RustDesk Client/Server 共享协议时才建立授权 fork；
6. 如果 fork，Client 和 Server 必须固定到同一个 hbb_common commit。

## 8. Plugin Framework 决策

RustDesk 已有 `plugin_framework`，但 NexusFlow 核心能力不应依赖当前动态插件体系。

原因：

- Plugin Framework 是可选 feature；
- 当前主要受 Flutter/Desktop 编译条件控制；
- 动态库 ABI 增加跨平台兼容成本；
- 移动端覆盖不足；
- Tunnel Presence 是商业客户端基础能力，不应被用户卸载；
- 插件加载异常不应导致设备失去控制平面连接。

可以复用的模式：

- 独立 IPC postfix；
- UI 事件分发；
- 配置与运行时分离；
- 插件失败与 RustDesk 核心隔离。

NexusFlow 使用 `_nexus` IPC，而不是复用 `_plugin` 业务协议。

## 9. 目标 Git 仓库结构

### 9.1 根产品清单仓库

建立 `nexusflow-manifest`，作为根目录正式 Git 仓库：

```text
nexusflow-manifest/
├── .git/
├── .gitmodules
├── docs/
│   └── 系统方案/
├── components/
│   ├── rustdesk-client/
│   ├── rustdesk-server/
│   ├── rustdesk-server-pro/
│   ├── nexus-tunnel/
│   └── nexus-platform/
├── deploy/
│   ├── docker/
│   ├── kubernetes/
│   └── environments/
├── release/
│   └── bom.toml
├── tools/
└── README.md
```

根仓库只管理：

- 文档；
- 子模块 commit；
- 兼容版本矩阵；
- CI/CD；
- Docker/Kubernetes；
- 环境配置模板；
- Release BOM；
- 跨组件端到端测试入口。

根仓库不保存组件的大量业务源码。

### 9.2 `nexus-rustdesk`

定位：RustDesk Client 的公司正式 fork。

包含：

- RustDesk 上游历史；
- 少量上游挂载补丁；
- `libs/nexus_client`；
- `src/nexus.rs`；
- NexusFlow Flutter 页面；
- 产品品牌和构建配置；
- 客户端集成测试。

Git remotes：

```text
origin    公司内部或授权 fork
upstream  https://github.com/rustdesk/rustdesk.git
```

当前 `origin` 直接指向官方仓库，正式开发前应调整为公司 fork，并新增 `upstream` 指向官方。

### 9.3 `nexus-tunnel`

定位：Cloud 与 frp-rs 合并后的唯一 Tunnel 产品源码仓库。

推荐最小 workspace：

```text
nexus-tunnel/
├── Cargo.toml
├── crates/
│   ├── tunnel-core/
│   ├── tunnel-client/
│   └── tunnel-server/
├── tests/
└── docs/
```

#### `tunnel-core`

- CPCC V2/Presence 协议；
- Service、Route、Policy 基础模型；
- 配置版本和错误模型；
- 客户端与服务端共享 DTO；
- 不包含数据库和管理后台业务。

#### `tunnel-client`

- Cloud UDP Presence Client；
- frp-rs ClientService 封装；
- Tunnel 状态机；
- 配置校验、重载和回滚；
- 对 RustDesk 暴露稳定库接口。

#### `tunnel-server`

- Presence Gateway；
- frp-rs Server/Relay；
- Relay 节点注册；
- 连接和流量事件；
- 与统一控制平面的适配接口。

Cloud 旧仓库在迁移完成后归档，不再作为产品构建依赖。现有 frp-rs 代码迁移并保留来源和兼容测试。

### 9.4 `nexus-platform`

定位：由 authi-server 演进的统一商业控制平面。

初期结构：

```text
nexus-platform/
├── control-plane/
│   ├── identity/
│   ├── devices/
│   ├── remote-desktop/
│   ├── tunnel/
│   ├── agent/
│   ├── billing/
│   └── audit/
├── admin-web/
├── migrations/
├── tests/
└── deploy/
```

控制平面与 Admin Web 初期放在同一个仓库，等团队、发布和部署节奏确实独立后再拆分。

### 9.5 `nexus-rustdesk-server-pro`

定位：完整授权后的 RustDesk Server Pro fork、内部镜像或正式源码仓库。

职责：

- RustDesk ID/Relay；
- Remote Desktop 设备管理；
- 地址簿和设备组；
- 远程访问策略；
- RustDesk 审计；
- RustDesk Pro License；
- 统一 Identity、Device Registry 和 Entitlement 适配。

不负责：

- 实现全部 Tunnel 控制面；
- 实现 Authi Agent 业务；
- 作为全平台唯一商业数据库；
- 替代统一 Admin Web。

### 9.6 `rustdesk-server`

RustDesk OSS Server 可以继续作为：

- 上游参考；
- 协议兼容测试目标；
- RustDesk Pro 底层依赖；
- 开源部署兼容目标。

如果生产系统完全使用 Server Pro，OSS Server 不需要承载 NexusFlow 商业控制面代码。

## 10. Git submodule 规划

### 10.1 根仓库 submodule

推荐：

```text
components/rustdesk-client      -> nexus-rustdesk
components/rustdesk-server      -> rustdesk-server fork/mirror
components/rustdesk-server-pro  -> authorized Pro fork/mirror
components/nexus-tunnel         -> nexus-tunnel
components/nexus-platform       -> nexus-platform
```

每次 NexusFlow 产品发布由根仓库 commit 和 `release/bom.toml` 共同确定所有组件版本。

### 10.2 何时使用 submodule

适合使用 submodule：

- 独立上游历史；
- 独立发布节奏；
- 独立授权边界；
- 独立部署；
- 需要精确锁定 commit。

不适合使用 submodule：

- 单个 Rust module；
- 单个 Flutter 页面；
- 只在一个 crate 内使用的 DTO；
- 尚未形成独立版本的内部工具；
- 只是为了看起来“模块化”的小目录。

### 10.3 不推荐 Git subtree

不建议把 RustDesk、Cloud、frp-rs 或 Authi 使用 subtree 合入一个仓库，原因：

- 上游历史和产品历史混合；
- 同步来源不清晰；
- 大型 upstream merge 难审查；
- 组件独立发布困难；
- 许可证和来源追踪更复杂。

### 10.4 Rust crate 依赖方式

`nexus-rustdesk` 依赖 `nexus-tunnel-client` 时，推荐顺序：

1. 内部 Cargo Registry 固定语义版本；
2. 尚未建立 Registry 时使用固定 Git `rev`；
3. 本地开发通过 Cargo patch 指向本地 checkout；
4. 禁止依赖浮动分支；
5. 发布构建必须由 Cargo.lock 和 BOM 固定源码版本。

不建议在 RustDesk fork 内再创建大量嵌套 Git submodule。

## 11. Git 分支模型

### 11.1 RustDesk fork

```text
upstream/master               RustDesk 官方远端跟踪分支，只读
origin/main                   NexusFlow 稳定开发分支
origin/release/<version>      商业发布维护分支
origin/sync/upstream-<date>   临时上游同步分支
origin/feature/<name>         功能分支
origin/fix/<name>             修复分支
```

长期共享分支使用 merge，不反复 rebase 和 force-push。这样可以准确记录每次引入的 RustDesk 官方版本。

### 11.2 NexusFlow 自有仓库

```text
main                          可发布主分支
release/<version>             稳定维护分支
feature/<name>                功能开发
fix/<name>                    修复
```

只有需要长期维护多个商业版本时才建立 release 分支，避免为每个内部迭代创建永久分支。

## 12. RustDesk 上游同步流程

### 12.1 同步步骤

```text
1. fetch upstream
2. 选择官方稳定 tag 或明确 commit
3. 创建 sync/upstream-YYYYMMDD
4. merge upstream/master 或指定 tag
5. 解决原生薄挂载点冲突
6. 构建 nexus feature 关闭版本
7. 构建 nexus feature 开启版本
8. 执行 RustDesk 原生回归
9. 执行 Tunnel/Authi 集成回归
10. 生成兼容报告
11. 合并 origin/main
12. 更新根仓库 submodule 和 BOM
```

### 12.2 上游同步优先顺序

1. 先保证 Nexus feature 关闭时接近上游行为；
2. 再修复 `src/nexus.rs` 生命周期适配；
3. 再修复 `_nexus` IPC/FFI；
4. 最后修复 Flutter 页面和产品品牌；
5. 不在同步 PR 中同时加入新业务功能。

### 12.3 冲突处理原则

- 上游原生行为优先；
- 适配逻辑向新的上游结构迁移；
- 不为保留旧挂载点而恢复已被上游删除的结构；
- 如果上游提供了新的稳定扩展点，应迁移过去；
- 冲突解决提交只解决同步问题，不混入功能开发；
- 记录每次冲突发生的文件和原因，形成高风险文件清单。

## 13. 提交组织

RustDesk fork 的自有补丁建议按职责形成少量清晰提交：

```text
1. build: add nexus feature and nexus_client dependency
2. client: add nexus runtime lifecycle adapter
3. ipc: add nexus local IPC and FFI bridge
4. ui: add NexusFlow settings and status pages
5. brand: apply product branding and distribution settings
```

业务功能开发提交集中在 `libs/nexus_client` 和 `flutter/lib/nexus`。避免一个提交同时大范围修改原生 RustDesk 文件和 NexusFlow 业务模块。

每次上游同步后可使用提交范围或 `range-diff` 检查自有补丁是否仍保持清晰。

## 14. 版本与发布 BOM

根仓库 `release/bom.toml` 建议记录：

```toml
[product]
version = "x.y.z"

[rustdesk_client]
repository = "..."
commit = "..."
upstream_commit = "..."

[rustdesk_server]
commit = "..."

[rustdesk_server_pro]
commit = "..."

[nexus_tunnel]
version = "..."
commit = "..."
protocol_version = "..."

[nexus_platform]
version = "..."
commit = "..."
api_version = "..."

[compatibility]
min_client_version = "..."
min_tunnel_protocol = "..."
min_control_plane_api = "..."
```

BOM 是发布产物追溯的唯一入口，但不替代各组件自己的 Cargo.lock、数据库迁移版本和容器 digest。

## 15. CI 与兼容性门禁

### 15.1 RustDesk Client CI

- Nexus feature 关闭构建；
- Nexus feature 开启构建；
- Windows 构建；
- Linux 构建；
- macOS 构建；
- Android/iOS 按支持范围构建；
- RustDesk 原生单元和集成测试；
- `nexus_client` 测试；
- `_nexus` IPC 兼容测试；
- Tunnel Client 与 Relay 兼容测试；
- Agent Supervisor 进程隔离测试。

### 15.2 上游差异门禁

CI 应检查 RustDesk 原生文件修改范围。允许列表以本文档第 7.1 节为基础。

出现以下情况时阻止直接合并：

- Nexus 业务代码进入 `client.rs` 或 `server/connection.rs`；
- 无必要修改 `hbb_common`；
- 新建平台专用启动逻辑但没有统一适配入口；
- `nexus` feature 关闭后仍改变原生行为；
- Cargo 依赖使用浮动 Git 分支；
- Flutter 页面直接持有设备密钥或启动第三方进程。

### 15.3 根仓库 CI

- 初始化所有 submodule；
- 验证 BOM 和 submodule commit 一致；
- 构建客户端、控制平面和 Relay；
- 执行端到端注册、远程控制、Tunnel 和 Agent 场景；
- 生成 SBOM；
- 检查许可证和第三方来源；
- 构建并签名发布产物；
- 记录容器 digest、客户端哈希和数据库迁移版本。

## 16. 实施顺序

### 阶段 1：根仓库治理

- 将根目录初始化为产品清单仓库；
- 将现有文档纳入 Git；
- 确定组件仓库正式地址；
- 建立 `.gitmodules`；
- 建立 BOM 模板；
- 不立即移动大量源码。

### 阶段 2：RustDesk fork

- 创建公司 `nexus-rustdesk` fork；
- 设置 `origin` 为公司 fork；
- 设置 `upstream` 为官方仓库；
- 保持官方 master 历史；
- 建立 Nexus feature 关闭构建基线。

### 阶段 3：Nexus 客户端骨架

- 新建 `libs/nexus_client`；
- 新建 `src/nexus.rs`；
- 建立 `_nexus` IPC；
- 在 `--server` 生命周期加入薄挂载；
- 先只上报 RustDesk ID 和健康状态。

### 阶段 4：Tunnel 仓库

- 将 Cloud Presence 设计迁入 `nexus-tunnel`；
- 将 frp-rs ClientService/Server 整理为三个目标 crate；
- 建立协议和兼容测试；
- 由 `nexus_client::tunnel` 接入；
- 停止新增 Cloud 旧数据面功能。

### 阶段 5：Authi 客户端迁移

- 将设备注册改为统一身份；
- 将 Authi Client 能力迁入 `nexus_client::control/agent`；
- 保留第三方 Agent 子进程模型；
- 将 authi-server 演进为 `nexus-platform`。

### 阶段 6：上游同步演练

- 选择一个新的 RustDesk 官方 tag；
- 完整执行同步流程；
- 统计冲突文件和处理时间；
- 评估适配层是否仍足够薄；
- 将结果作为后续架构调整依据。

## 17. 验收标准

### 17.1 上游兼容

- `upstream` 明确指向 RustDesk 官方仓库；
- 能够在独立同步分支合并新的上游 tag；
- Nexus feature 关闭后保持原生主要行为；
- 原生修改集中在允许文件；
- 不需要手工复制大量上游文件；
- 不使用长期无法重放的临时 patch 脚本。

### 17.2 客户端组织

- NexusFlow 业务代码集中在 `libs/nexus_client`；
- RustDesk 原生文件只保留薄挂载；
- Tunnel/Authi 运行在原生 `--server` 进程；
- GUI 退出不影响 Presence 和 Tunnel；
- 不存在独立 Cloud/frpc 客户端进程；
- Agent 子进程退出不影响 RustDesk；
- Flutter 不直接管理敏感凭据和后台长连接。

### 17.3 Git 组织

- 根产品仓库可以固定所有组件 commit；
- RustDesk、Tunnel、Platform 和 Pro 保留独立历史；
- 发布版本可以从 BOM 完整重建；
- submodule 只用于独立组件，不用于小模块；
- Cloud 旧仓库和 frp-rs 迁移来源可追溯；
- 所有生产组件均有正式 Git 仓库和 CI。

## 18. 明确不采用的方案

- 不把 RustDesk 官方仓库直接作为公司开发仓库的 `origin`。
- 不在根目录简单复制四个项目而不建立产品清单仓库。
- 不把所有项目历史通过 Git subtree 合并。
- 不把每个 Rust module 建成一个 Git submodule。
- 不把 Tunnel/Authi 业务堆入 `core_main.rs`、`client.rs`、`server.rs` 或 `flutter_ffi.rs`。
- 不分别修改三个平台 `start_os_service()` 来启动 NexusFlow。
- 不依赖当前 Plugin Framework 承载必须常驻的 Tunnel Presence。
- 不修改 RustDesk 原生 ID 生成逻辑。
- 不把 Cloud 与 frp-rs 保留为两个独立客户端产品。
- 不使用浮动 Git 分支作为发布依赖。
- 不在上游同步 PR 中同时开发新功能。

## 19. 决策摘要

1. RustDesk 使用公司 fork，并保留官方 `upstream` remote。
2. RustDesk 原生 ID、生命周期和构建入口保持不变。
3. NexusFlow 常驻能力挂载在 RustDesk 原生 `--server` 进程。
4. 新增 `src/nexus.rs` 作为唯一原生适配入口。
5. 新增单一 `libs/nexus_client` crate，初期不进行过度拆分。
6. Flutter 新页面集中到 `flutter/lib/nexus`。
7. GUI 与服务进程通过独立 `_nexus` IPC 通信。
8. Cloud 与 frp-rs 合并为独立 `nexus-tunnel` 仓库。
9. authi-server 演进为 `nexus-platform`。
10. 根目录建立 `nexusflow-manifest`，通过 submodule 和 BOM 固定产品版本。
11. Git submodule 只用于独立发布、授权或部署的组件。
12. RustDesk 上游同步使用临时 sync 分支和明确的回归门禁。

## 20. 代码依据

- `rustdesk/rustdesk/Cargo.toml`：RustDesk package、feature、依赖和 workspace；
- `rustdesk/rustdesk/.gitmodules`：`hbb_common` submodule；
- `rustdesk/rustdesk/src/lib.rs`：客户端主模块组织；
- `rustdesk/rustdesk/src/core_main.rs`：GUI、`--service` 和 `--server` 命令入口；
- `rustdesk/rustdesk/src/server.rs`：RustDesk 主机服务和 RendezvousMediator 生命周期；
- `rustdesk/rustdesk/src/platform/windows.rs`：Windows OS Service；
- `rustdesk/rustdesk/src/platform/linux.rs`：Linux OS Service 和用户会话监督；
- `rustdesk/rustdesk/src/platform/macos.rs`：macOS Service；
- `rustdesk/rustdesk/src/plugin/`：Plugin Framework 和 `_plugin` IPC 模式；
- `rustdesk/rustdesk/libs/hbb_common/src/config.rs`：RustDesk 原生 ID 和配置；
- `frp-rs/client-rs/src/service.rs`：frp-rs 可重载客户端运行时；
- `frp-rs/server-rs/crates/frps/src/server/mod.rs`：frp-rs 服务端生命周期；
- `authi/authi-server/`：统一控制平面演进基础；
- `cloud/doc/CloudProxy_upgrade_plan.md`：Cloud Presence 和 Tunnel 产品需求基础。

---

本规划是仓库初始化、RustDesk fork 建立、Nexus Client 骨架和上游同步流程的执行基线。涉及原生修改范围、Git 仓库拆分、客户端常驻进程或上游同步策略的变更，必须先更新本文档。
