项目里面有四个独立的子项目，其中：
1.cloud,用于局域网代理转发中继穿透
2.frp-rs,用于局域网代理转发中继穿透
3.rustdesk，用于远程桌面控制
4.authi，用于通过手机端，web端控制局域网电脑控制AI Agent进行工作

现在需要将这些服务进行统一：
1.运行在用户PC或者设备的上程序要统一成一个，将这些工能全部集成在一个用户端程序中，但是可以在整个链条中提供独立的服务(cloud与frp-rs要合并成一个子服务功能，对外最终也是一个穿透中继服务)，后台系统以及后台管理也是围绕这样的原则；
2.用于支撑管理这些用户端程序的后端系统服务要统一，后台管理也是一个，用于商业运营服务；
3.cloud与frp-rs要合并成一个子服务功能，用于提供穿透服务
4.如果authi能与frp-rs合并最好，这个不是强制的，是要看从系统设计实现上能否统一

“
1."Authi AI Agent 执行也完全不创建子进程"这个不需要集成到一个进程里面。本身执行AI AGENT也是第三方的程序，这个只是启动并接管输入输出而已。这个地方你理解不对
2.“保留 RustDesk 无人值守/UAC/登录界面能力且只有一个 OS 进程”，rustdesk现有的架构保持不变
3.“把四个项目源码原样拼进一个 Cargo workspace”。后面cloud与frp-rs是合并的，authi客户端也可以合并到用户端程序中去，这些项目源码组成都可以进行调整，以rustdesk为主体
”
根据上述需求分析现有代码文档，给出方案


CloudProxy_upgrade_plan.md


1.我现在将所有前面参考分析的项目目录全部一打欧移到了ref/目录下,本目录下的任何内容不允许进行修改
2.现在需要你根据文档“RustDesk上游兼容与项目组织结构规划.md”在本项目目录创建服务端（统一控制平面:nexus-control-plane）、客户端宿主(RustDesk Client)以及相关目录
3.对建好目录并按照规划初始化项目，其中：
  - rustdesk:https://github.com/iincity/rustdesk.git
  - rustdesk-server:https://github.com/iincity/rustdesk-server.git
  - hbb_common:https://github.com/iincity/hbb_common.git
  - nexus-platform:https://github.com/iincity/nexus-platform.git
  - nexus-tunnel:https://github.com/iincity/nexus-tunnel.git
  - rustdesk-server-pro:https://github.com/iincity/rustdesk-server-pro.git
  需要的rustdesk项目的代码都在 https://github.com/iincity这个目录下，如果还缺什么内容，你可以发出来，我确认
NexusFlow本身做为一个项目，仓库为:https://github.com/iincity/NexusFlow.git
