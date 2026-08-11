# NexusFlow 开发计划

> 状态：执行中  
> 架构基线：`NexusFlow统一系统方案.md`、`RustDesk上游兼容与项目组织结构规划.md`  
> 首次制定：2026-08-10

## 1. 目标与边界

交付一个以 RustDesk 为唯一用户端宿主、以 `nexus-platform` 为统一控制平面、以 `nexus-tunnel` 为唯一穿透产品的数据与控制体系。

- RustDesk 原生公开 ID、`--server` 生命周期、无人值守、UAC、登录界面、协议与构建入口保持兼容。
- Tunnel 客户端作为 RustDesk 服务进程内的库运行；空闲时只维护受认证的 UDP Presence，实际代理数据通道按需启动。
- Authi 的控制与 Agent 管理并入同一设备、权限、审计和权益模型；第三方 Agent 仍是被监督的外部子进程。
- RustDesk Pro 只承担远程桌面域能力，通过授权 API/SSO/适配器接入，不成为账户与商业数据的第二事实来源。

本计划不把 `ref/` 中的迁移参考源码纳入产品构建，也不通过 Git subtree 混合上游历史。

## 2. 当前基线（2026-08-10）

| 领域 | 已具备 | 主要缺口 |
|---|---|---|
| 产品仓库 | 根 manifest、BOM、五个组件 submodule | 根 CI、SBOM、发布签名与 E2E 门禁 |
| RustDesk 客户端 | `nexus` feature、`src/nexus.rs`、`libs/nexus_client` 骨架、Flutter 目录 | `--server` 生命周期挂载、版本化 `_nexus` IPC、控制面连接、真实 Tunnel/Agent 监督 |
| Tunnel | 三 crate workspace 骨架 | CPCC V2、认证 Presence、配置签名、frp-rs runtime/relay 适配、路由与流量遥测 |
| 控制平面 | Authi/Happy 兼容的账户、机器、Socket.IO、Agent、存储与指标基础 | 统一 `device_uid`、租户 RBAC、Desired State、Tunnel 域、权益/计费/审计域、统一 Admin API |
| RustDesk Pro | 已固定授权仓库入口 | 正式 API/源码镜像接入、SSO 与设备/审计适配 |

## 3. 交付顺序

### M0：治理与可重建基线（完成）

1. 固定全部组件 Git 仓库、submodule 和 BOM。
2. 客户端与服务端的 `hbb_common` 固定到 iincity mirror。
3. 验收：干净 checkout 可初始化子模块；BOM 与 Gitlink 一致；组件基础检查通过。

### M1：设备、Desired State 与 Tunnel 生命周期纵向切片（进行中）

1. 在 `nexus-tunnel/tunnel-core` 定义版本化、可验证的 Tunnel Desired State、服务/路由策略和状态机输入输出。
2. 在 `tunnel-client` 实现确定性生命周期：`Disabled → PresenceOnly → Activating → Active → Draining → PresenceOnly` 与退避、版本拒绝、回滚语义。
3. 在 `nexus_client` 保持 RustDesk ID 只读，并持有内部 `device_uid`、能力、控制面连接与 Tunnel 状态快照。
4. 使用固定 Git revision 依赖 `nexus-tunnel-client`，禁止浮动 Git 分支。
5. 验收：状态机与版本回滚单元测试；`nexus_client` 不生成或替代 RustDesk ID；默认 RustDesk feature 关闭时不链接 Nexus 模块。

### M2：RustDesk 服务生命周期与本地 IPC

1. 仅在 `src/server.rs` 增加 feature-gated 薄挂载：启动 `NexusRuntime`，在退出前有序停止。
2. `src/nexus.rs` 保持唯一原生适配点；不在 `core_main.rs`、`client.rs`、`server/connection.rs` 实现 Nexus 业务。
3. 定义版本化 `_nexus` 请求/响应 DTO，GUI 只能查询状态和提交白名单配置。
4. 验收：关闭 `nexus` feature 的原生回归；生命周期单测；IPC 兼容与错误隔离测试。

### M3：统一控制面设备域

1. 在 `nexus-platform/control-plane` 增加 `identity`、`devices`、`tunnel`、`commercial`、`governance` 的独立域边界，保留 Authi 兼容接口。
2. 新设备注册使用 RustDesk ID + 公钥创建不可变 `device_uid`；绑定、轮换、解绑和转移均审计。
3. 实现签名 Desired State、版本/摘要/生效期、应用结果与回滚记录。
4. 验收：PostgreSQL 迁移、幂等注册、权限拒绝、签名验证、设备/审计 API 集成测试。

### M4：Presence、Tunnel 配置编译与 Relay

1. 实现 CPCC V2 UDP Presence Gateway：Cookie Challenge、设备签名、重放保护、限速和轻量版本通知。
2. 基于 Service/Route/Policy 编译短期、版本化 frp-rs 配置；数据库不保存原始 FRP 配置作为主模型。
3. 适配 frp-rs ClientService reload/cancel 与 Server/Relay 生命周期；连接/字节/错误事件进入控制面。
4. 验收：模拟 NAT 场景、错误重试、配置回滚、TCP/UDP 发布和访问 E2E；空闲客户端不保留 FRP 数据通道。

### M5：Agent、后台、权益与 Pro 适配

1. `agent` 模块使用受限 `Command` 启动第三方 Agent，接管标准流、取消、超时、退出码与审计；Agent 崩溃不得结束 RustDesk/Tunnel。
2. Admin Web 以统一用户、租户、设备、Tunnel、Agent、用量、审计和订阅 API 为唯一入口。
3. 增加产品、套餐、订阅、权益、支付幂等、欠费治理和用量聚合；将 RustDesk Pro 接入统一 Identity/SSO 与权益检查。
4. 验收：角色越权、支付重复回调、权益撤销、Agent 进程隔离、Pro Adapter 契约测试。

### M6：生产门禁与上游同步

1. 根 CI 校验 BOM/Gitlink、许可证、来源、SBOM、子模块、容器 digest 和 E2E。
2. Client CI 同时构建 Nexus feature 关闭与开启版本，检查允许修改范围并执行平台矩阵。
3. 对 RustDesk 官方 tag 进行一次同步演练，记录冲突、验证原生行为与 Nexus 适配层。
4. 验收：可从 BOM 重建；发布证据齐全；上游同步不依赖大规模临时 patch。

## 4. 依赖与执行规则

```text
M1 → M2 → M3 → M4 → M5 → M6
            └─────── 控制面接口先稳定，再接入真实数据面 ───────┘
```

- 先提交并推送独立组件，再更新根仓库 submodule 指针与 `release/bom.toml`。
- 每个阶段必须先有可执行契约与测试，再接入下一个网络或平台边界。
- 所有网络凭据、签名密钥和支付密钥只使用环境/密钥管理系统；不得提交到仓库。
- 缺少 RustDesk Pro 正式 API/源码或支付提供方凭据时，实现 Adapter 与契约测试，不伪造生产集成。

## 5. 完成定义

项目满足总体方案的条件是：一个安装包在保持 RustDesk 原生行为的基础上，能以同一个 `rustdesk_id` 注册统一设备、以低资源 Presence 维持在线、按策略启动 Tunnel、受控运行 Agent；运营人员能在一个后台以统一权限和权益管理 Remote/Tunnel/Agent；并且所有关键操作、配置和用量可审计、可回滚、可通过 BOM 复现。

## 6. 本轮实施记录

- M0 已完成，见根提交与 `release/bom.toml`。
- 当前正在实施 M1：先完成共享 Tunnel 模型和确定性状态机，再把客户端骨架改为依赖该稳定接口。
- 2026-08-11：`nexus-tunnel` 已落地版本化 `TunnelDesiredState`、配置摘要校验、状态机与单元测试；`nexus-rustdesk/libs/nexus_client` 已改为复用 `nexus-tunnel-client` 固定 Git revision，并验证本地运行时状态可跟随共享 Tunnel 状态机。
- 2026-08-11：`nexus-rustdesk/src/server.rs` 已在 RustDesk 原生 `start_server()` 生命周期中 feature-gated 挂载 `NexusRuntime`；`src/nexus.rs` 现承担唯一适配点职责，并提供最小 `_nexus` 版本化请求/响应 DTO 与状态查询处理入口。
