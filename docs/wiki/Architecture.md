# 架构

## 定位

GVGL = AX 树 → 四层归一化几何虚拟桌面帧的**半同步转换器**。

- **位置**：真实桌面旁路（Sidecar），不在 Agent→桌面 的执行路径上。
- **性质**：守护进程完全只读（Passive Observer），模型驻留，帧是模型视图；执行由
  独立执行器 `gvglact` 完成（见 [动作层](Act.md)）。
- **数据源**：唯一来源 macOS Accessibility API（CGWindowList 自 V3 起常开，仅用于
  窗口 z-order 与诊断；几何仍以 AX 为准）。
- **接口**：`get_frame` / `get_status` / `subscribe`（Unix Socket + NDJSON）。

## 设计铁律（守护进程）

以下约束针对 `gvgl` 守护进程。执行器 `gvglact` 是独立进程，按 V6 设计承担动作
（见 [动作层](Act.md)），它的事件注入不改变守护进程的只读性质。

| 铁律 | 含义 |
| :--- | :--- |
| 只读 | 只调用 AX 读取类 API，绝不调用任何修改类 API |
| 无鼠标副作用 | 不调用 CGWarp / CGEvent / cliclick 等 |
| 无截图 | 不调用任何截图 API |
| 无系统修改 | 不修改窗口、不注入事件、不改变焦点 |
| 模型驻留，帧是视图 | 虚拟桌面模型常驻内存；`get_frame` 只读物化模型，不做 AX 调用 |
| 侧挂不居中 | 执行操作由调用方负责（`gvglact`、gvglui 的"点击"、`--cliclick` 均属调用方） |

## 半同步引擎

```
AXObserver（每 App 一个，专用 RunLoop 线程）
  ├─ 窗口级：Moved / Resized / Destroyed / TitleChanged
  │    / Miniaturized / Deminiaturized / SheetCreated / DrawerCreated（V3）
  │    └─ 回调携带窗口当前 rect → per-window 子树增量重捕：
  │       匹配模型中的窗口 → 按旧 ID 路径只重捕该窗口子树 → 与其他窗口
  │       既有实体合并（未变化窗口字节级零变化）；匹配失败回退全量重捕
  ├─ App 级：WindowCreated → 全量重捕；
  │    FocusedUIElementChanged / FocusedWindowChanged / MainWindowChanged（V3）
  │    → 焦点跟随：ValueChanged / SelectedTextChanged 只挂当前焦点元素；
  │    MenuOpened / MenuClosed → 全量重捕（菜单可游离于窗口外）
  ├─ 元素级事件沿 AXParent 解析所属窗口 → 子树重捕；无窗口祖先回退全量
  └─ 50ms 去抖合并 → 增量同步 → DesktopModel 应用 → version++

NSWorkspace：启停跟踪 + didActivate → 帧 frontmostApp（V3）
CGDisplayRegisterReconfigurationCallback：显示器变化 → 立即刷新 + 全量重捕（V3）

Reconciler（默认 2~3s；V3 自适应批次：staleness 最旧优先，
  目标 15s 内扫完全部监视 App，冷却中 App 不占批次）
  └─ 兜底：AX 通知是 best-effort → 周期校准保证最终一致

防护：
  ├─ 快照墙钟 1s（不响应 App 不拖垮队列）
  ├─ 单 App 最小采集间隔 0.15s（通知风暴不驱动采集循环）
  ├─ 错误/慢采集冷却 30s（不锤击）
  └─ 白名单 allowedBundleIDs（--only-apps）
```

## 代码结构

```
Sources/GVGLCore/    流水线（纯逻辑，合成 fixture 可单测）
  Screen.swift        DisplayInfo/ScreenInfo（主屏归一化 + displays 元数据）
  NormRect.swift      归一化矩形
  Region.swift        Region/Region9（Display Space 象限）
  Geometry.swift      Geometry（四层归一化 rect）+ 坐标转换（M0 锁定版 + 多屏）
  Entity.swift        Entity（递归 children）
  SpatialIndex.swift  帧索引 + grid/cellKey
  Frame.swift         SyncStatus/AppSnapshot/FrameStatus/SceneApp/GVGLFrame
  DesktopMap.swift    MapDisplay/MapWindow/DesktopMap + 派生
  FrameCoding.swift   JSONEncoder/JSONDecoder 策略
  SceneTree.swift     V4 场景树构建/拍平/自然 AX 序/depth 剪枝
  AXSnapshot.swift    DFS 快照 + 批量属性 + 预算/墙钟 + 子树快照 + 菜单栏第二根 + CG 探针接线
  AXValueCoercion.swift  AXValue 统一强转（感知与动作验证共用）
  CGWindowProbe.swift CGWindowList 第二数据源（z-order 常开；诊断受 --cg-check 控制）
  Geometry.swift      坐标转换（M0 锁定版 + 多屏）
  Pipeline.swift      快照 → 实体/索引
  IDStabilizer.swift  跨重建 ID 稳定 + PipelineOutput.remapped

Sources/GVGLSync/    半同步引擎
  DesktopModel.swift  常驻模型 + version + 变更日志 + 帧物化缓存
  ObserverRegistry.swift  每 App AXObserver（专用 RunLoop 线程）
  WorkspaceTracker.swift  NSWorkspace 启停跟踪
  SyncEngine.swift    去抖/增量同步/子树重捕/Reconciler/节流/白名单/屏幕刷新

Sources/GVGLServer/  UDS 服务（get_frame/since/subscribe 推送/get_status）
Sources/gvgl/        守护进程入口（参数/信号/显示器枚举/权限引导）
Sources/GVGLAction/  computer-use 执行层（元素解析/语义动作/合成事件/命中测试/验证）
Sources/gvglact/     执行器 CLI

Sources/GVGLQuery/   查询引擎 + 指令解析器 + UDS 客户端（gvglui 与 Agent 复用）
Sources/gvglui/      SwiftUI 审查台（桌面画布/实体列表/指令面板/执行点击）

client/gvgl_query.py 参考 CLI 客户端
scripts/             launchd 脚本 + 几何/覆盖审计 + 零截图审计 + 端到端 smoke
docs/wiki/           本 Wiki
```

## 关键工程决策

1. **模型驻留 + version**：帧是模型只读视图；同 version 请求走物化缓存（~1ms）。
2. **关系作用域 = 单目标 App**（原始文档捕获单元）：每 App 流水线内"所有实体
   两两"（near/aligned），方向关系限"同一父窗口内"；跨 App 不产生关系。
3. **关系输出硬上限**（保护性偏离）：每窗口组 500 / 每 App 全局 5000，无上限时
   密集 Web 页单帧可达数百 MB。
4. **Element ID 稳定**：`pid:NNN:路径-索引` + 跨重建启发式匹配复用旧 ID，
   树结构漂移不破坏客户端引用。
