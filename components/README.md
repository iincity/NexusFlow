# NexusFlow Components

这里放置可独立发布、可固定版本的组件。所有正式组件均通过根仓库 Git submodule 固定 commit：`nexus-rustdesk`、RustDesk Server、RustDesk Server Pro、`nexus-platform` 和 `nexus-tunnel` 使用 iincity 远程仓库。

规划文档中的 `nexus-platform` 是统一商业控制平面的仓库角色名称；其服务实现位于 `control-plane/`，Cargo package/binary 使用用户确认的产品名 `nexus-control-plane`。`rustdesk-server-pro` 当前远程仓库内容是授权 Pro 的安装/发布入口，待获得完整 Pro 源码或正式镜像后可在不改变根路径的情况下更新 submodule 指针。
