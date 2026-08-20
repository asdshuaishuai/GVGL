# GVGL Wiki 首页

> 几何虚拟桌面守护进程 — macOS Accessibility → 三层归一化几何空间

GVGL（Geometric Virtual GUI Layer）是**侧挂于真实桌面旁、完全只读**的守护进程。
它通过 macOS Accessibility API 维持一个常驻的虚拟桌面几何模型（事件驱动 + 周期
校准），经 Unix Socket 暴露帧数据。Agent/CLI/审查台自行解析帧、自行执行操作，
GVGL 不参与执行路径。

## 快速开始

```bash
swift build -c release
.build/release/gvgl &                    # 守护进程（默认 socket ~/.gvgl/gvgl.sock）
.build/release/gvglui                    # SwiftUI 审查台（可视化 + 指令模拟）
python3 client/gvgl_query.py status      # CLI 客户端
```

## 页面导航

| 页面 | 内容 |
| :--- | :--- |
| [架构](Architecture.md) | 定位、设计铁律、半同步引擎、代码结构 |
| [坐标系](Coordinates.md) | 三层坐标空间、转换公式（M0 实测锁定）、派生量与空间标签 |
| [协议](Protocol.md) | UDS/NDJSON、get_frame/since/subscribe、帧结构、失败模式 |
| [查询与评分](Query.md) | 查询流程、五维评分算法、置信度门限、指令解析 |
| [客户端](Client.md) | gvgl_query.py 与 gvglui 审查台用法 |
| [运维](Ops.md) | 构建、launchd 常驻、TCC 权限、性能指标 |
| [路线图](Roadmap.md) | V1.6/V2 状态、偏离审计索引、已知限制 |
| [测试](Testing.md) | 单测清单、真机验证方法 |

## 权威文档

- **DESIGN.md**（仓库根目录）— 唯一权威规格：全部实现细节 + 与原始设计说明书的
  偏离审计表（17 项）。
- 原始技术设计说明书 — 本项目基线，Wiki 与 DESIGN.md 均以其为准。

## 数据流总览

```
真实桌面 (macOS AX API)
   │  AXObserver 事件（窗口移动/缩放/创建/销毁/标题/最小化/Sheet/焦点/菜单）+ 周期校准
   ▼
GVGL 守护进程（只读）
   │  快照 → 归一化 → 拓扑 → 索引 → DesktopModel（version 单调）
   ▼
Unix Socket（NDJSON）
   │  get_frame / get_frame?since / subscribe / get_status
   ▼
消费方：gvglui 审查台 / gvgl_query.py / 任意 Agent
   │  本地评分 → 像素坐标 → cliclick / CGEvent（由调用方执行）
   ▼
真实桌面（操作生效）
```
