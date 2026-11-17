# 跨平台实现方案抽象（macOS 已落地；Linux / Windows 同构）

> 本文把 V6 的实现抽象成"与平台无关的不变量 + 平台适配层"，让 Linux / Windows
> 移植有据可依，而不是重写一遍产品。结论先行：**帧契约、评分、动作算法、安全
> 护栏、零截图门禁全部与平台无关；只有感知遍历和输入合成两处必须按平台实现。**

## 1. 平台无关不变量（产品契约，移植时逐条保持）

| # | 不变量 | 为什么不能动 |
| :--- | :--- | :--- |
| 1 | 守护进程只读；模型驻留，帧是视图 | 审计面与权限模型的基础 |
| 2 | 帧 = 场景树 + 四层归一化几何 + index；`version` 单调、变更日志、`since` 增量、象限掩码订阅 | 客户端契约（Python/CLI/审查台/Agent 都依赖） |
| 3 | 评分在客户端（五维，§6.2），服务端不做空间树 | 消灭 O(N²) 载荷；双端实现用同一向量夹具钉住 |
| 4 | 执行器是独立进程，与守护进程分离 | 权限分离（读帧不需辅助功能权限）、事故隔离 |
| 5 | 动作算法：解析 → 新鲜度校验 → 命中测试 → 语义动作优先 → 合成事件兜底 → 回读验证 | 这是"标准 computer use"与"会点错东西的工具"的分界线 |
| 6 | `changed` 与 `verified` 分离上报 | "点了没反应"不是失败；"变化来自别处"不等于成功 |
| 7 | 元素 ID 是地址不是句柄；每次动作重新解析+校验+唯一重定位 | AX/AT-SPI/UIA 树都会在两次读取之间漂移 |
| 8 | 零截图是机械门禁（`audit_no_screenshot.sh`），无"截图兜底"开关 | 产品定位；权限与信任面的边界 |
| 9 | transcript 读窗口文本替代截图 | 感知层的第一公民，不是附加功能 |
| 10 | 感知退化如实上报：`partial` / `warming` / `permissionDenied` / `screenLocked` | 锁屏时 AX 只服务 loginwindow，其余 App 退化为 0 实体；"0 实体 ≠ 空桌面"，agent 必须能区分（macOS 用 `CGSessionCopyCurrentDictionary`，本地查询） |

## 2. 平台映射表

| 概念 | macOS（已实现） | Linux | Windows |
| :--- | :--- | :--- | :--- |
| 感知源 | ApplicationServices AX | AT-SPI（libatspi / rust-atspi） | UI Automation（UIA / FlaUI） |
| 事件驱动 | AXObserver + 专用 RunLoop | AT-SPI registryd 事件订阅 | `AutomationEventHandler` / `FocusChangedEventHandler` |
| 窗口枚举 / z-order | CGWindowList（layer 0~20，含 layer 8 对话框） | X11：`_NET_CLIENT_LIST` + `wmctrl`；Wayland：compositor 受限 | `EnumWindows` + `GetWindow` Z 序 |
| 坐标空间 | Quartz 全局（左上原点） | X root 坐标 / Wayland 逻辑坐标 | screen 坐标（需 DPI 感知） |
| 输入合成 | CGEvent（HID 流） | XTest / uinput（Wayland 需 compositor 授权） | `SendInput` |
| 菜单驱动 | `AXMenuBar` 属性 + `AXShowMenu` | AT-SPI menu / app menu | UIA MenuBar + `InvokePattern` |
| 剪贴板 | NSPasteboard | wl-clipboard / xclip | Win32 clipboard |
| 进程发现（无 bundle 对话框） | NSWorkspace + CGWindow 双来源 | wnck / /proc + X | ShellWindows / WMI |
| 锁屏检测 | `CGSessionCopyCurrentDictionary` → `CGSSessionScreenIsLocked` | loginctl / DBus（`org.freedesktop.ScreenSaver`、`org.gnome.ScreenSaver`） | `SystemParametersInfo(SPI_GETSCREENSAVERRUNNING)` / WTS 会话态 |
| 屏幕枚举与坐标基准 | `CGGetOnlineDisplayList` + 主屏归一化 | XRandR / Wayland output 协议 | `EnumDisplayMonitors` + DPI 感知 |
| 元素标签来源 | title；SwiftUI/Electron 走 description | AT-SPI Name（同理可能落在 description） | UIA Name / AutomationId |

## 3. 可直接复用的模块（纯逻辑，零平台依赖）

- `GVGLCore`：Geometry/NormRect/Region/Region9（Display Space 象限语义）、SceneTree、
  IDStabilizer、Pipeline（除采集器与 CG 探针）、SpatialIndex。
- `GVGLQuery`：QueryEngine（五维评分）、InstructionParser、GVGLClient（UDS 契约）。
- `GVGLAction` 的纯逻辑部分：ElementPath（ID 文法）、KeyChord、JSONValue/ActionResult、
  ActionFailure、ClickGuard 的判定规则、transcript 的标签优先级（title → placeholder →
  detail，value 作内容）。
- 协议与 CLI 表面、Python 参考客户端、全部审计脚本（几何/覆盖/零截图/评分向量）。

## 4. 必须按平台重写的适配层（接口已按此划分）

| 适配层 | macOS 实现 | 替换为 |
| :--- | :--- | :--- |
| `Snapshotter`（DFS + 批量属性 + 预算/墙钟） | AXUIElementCopyMultipleAttributeValues | AT-SPI 批量遍历 / UIA TreeWalker |
| `AXResolver`（ID → 元素） | AXChildren 索引 + `mb` 前缀 | 平台元素路径解析 |
| `AXElementState`（读/写属性、actions、settable） | AXValue/AXFocused 写入 | ValuePattern / InvokePattern / LegacyIAccessible |
| `InputSynthesizer` | CGEvent | XTest/uinput / SendInput |
| `ObserverRegistry`（事件 + 焦点跟随） | AXObserver | AT-SPI 事件 / UIA 事件 |
| `WorkspaceTracker` + `CGWindowProbe` | NSWorkspace + CGWindowList | 平台进程/窗口源 |
| `ClipboardService` | NSPasteboard | 平台剪贴板 |

## 5. 迁移步骤（建议顺序）

1. 新增 `GVGLSense-<platform>` 与 `gvgl-<platform>` 两个 target，只实现第 4 节适配层；
   **帧 JSON 契约零变化**，客户端与评分一行不改。
2. 用同一份 `Tests/Fixtures/query_vectors.json` 做三端一致性门（Swift 测试 +
   `scripts/test_scoring_parity.py`）。
3. `scripts/act_smoke.py` 参数化"生成一次性对话框"的方式（osascript →
   zenity/yad → PowerShell `[System.Windows.Forms]`），零截图审计与守卫逻辑不变。
4. 先 Linux X11（输入合成最完整），再 Windows（UIA 模式映射最完整）。

## 6. 平台特有难点（提前记录，避免移植时踩坑）

- **Wayland**：无全局输入合成（需 compositor 授权 / xdg-desktop-portal），
  AT-SPI 覆盖随工具包差异大；`gvglact` 的命中测试护栏在此反而更重要。
- **Windows UAC**：目标进程权限必须 ≤ 执行器进程，否则 UIA 调用静默失败；
  `permission_denied` 与 `action_unsupported` 的区分要靠错误码而非异常。
- **DPI**：Windows 的 screen 坐标需 `SetProcessDpiAwareness`，否则归一化与像素
  换算在缩放下错位——对应 macOS 的"主屏归一化 + 执行时乘回主屏尺寸"语义。
- **多屏**：Region 按 Display Space 派生（V5）的语义必须原样保留，否则副屏象限
  重蹈"恒 q1/q3 垃圾标签"的覆辙。
