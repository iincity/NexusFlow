# NexusFlow

NexusFlow 将 RustDesk 远程桌面、Cloud/frp-rs 穿透能力和 Authi Agent 控制统一为一个产品。

## 当前目录

- `components/nexus-rustdesk/`：以 iincity RustDesk fork 为主体的统一客户端宿主。
- `components/rustdesk-server/`：RustDesk OSS Server 兼容基线。
- `components/nexus-platform/`：由 Authi Server 演进的统一商业控制平面仓库；服务位于 `control-plane/`，Admin Web 位于同级目录。
- `components/nexus-tunnel/`：Cloud Presence 与 frp-rs 数据面的合并组件。
- `components/rustdesk-server-pro/`：授权 Pro 服务端适配入口。
- `deploy/`、`release/`、`tests/e2e/`、`tools/`：跨组件交付资产。
- `ref/`：迁移参考源码，只读且不纳入产品构建。

架构与仓库规则见 [`docs/系统方案/NexusFlow统一系统方案.md`](docs/系统方案/NexusFlow统一系统方案.md) 和 [`docs/系统方案/RustDesk上游兼容与项目组织结构规划.md`](docs/系统方案/RustDesk上游兼容与项目组织结构规划.md)。

## 初始化

```powershell
git submodule update --init --recursive
cargo check --manifest-path components/nexus-tunnel/Cargo.toml
cargo check --manifest-path components/nexus-platform/control-plane/Cargo.toml --locked
cargo check --manifest-path components/nexus-rustdesk/Cargo.toml -p nexus_client
```

RustDesk Client/Server 的 `origin` 指向 iincity fork，`upstream` 指向 RustDesk 官方仓库。`nexus-platform`、`nexus-tunnel` 和 RustDesk Server Pro 已接入对应 iincity 远程仓库；`release/bom.toml` 固定当前组件版本。Pro 仓库当前是授权安装/发布入口，后续可直接更新其 submodule commit。
