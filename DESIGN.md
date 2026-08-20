# GVGL 设计说明书（V1.8 完整版）

> 侧挂于真实桌面旁、完全只读的守护进程。通过 macOS Accessibility API 维持一个
> 常驻的虚拟桌面**层次场景图**（事件驱动 + 周期校准），经 Unix Socket 的
> `get_frame` 对外暴露。Agent/CLI 自行解析帧、自行执行操作，GVGL 不参与执行路径。
>
> 本文件是唯一权威规格：实现与实测优先于早期设计稿；所有偏离均在正文标注。

## 0. 定位

- **一句话定义**：GVGL = AX 树 → 三层归一化几何虚拟桌面帧的**半同步转换器**。
- **位置**：真实桌面旁路（Sidecar），不在 Agent→桌面 的执行路径上。
- **性质**：完全只读（Passive Observer），模型驻留，帧是模型视图。
- **数据源**：唯一来源 macOS Accessibility API（CGWindow 仅作可选诊断，默认关闭）。
- **接口**：`get_frame` / `get_status` / `subscribe`（Unix Socket + NDJSON）。

### 0.1 与原始设计说明书的偏离审计

原始说明书（2026-08-11 版）为本项目权威基线；本表记录全部偏离及依据。

| # | 原始条款 | 现状 | 类别 |
| :--- | :--- | :--- | :--- |
| 1 | §2.2 转换1/3：Cocoa 左下原点 + Y 翻转 | 无翻转（M0 实测：AX 与 CG 同为 Quartz 左上原点，delta=0） | ✅ 用户批准（"先实测再锁定"） |
| 2 | §1.2 无状态；§6.1 每次请求捕获，不主动轮询 | 模型驻留 + 事件驱动 + 周期校准（半同步） | ✅ 用户批准（半同步决策） |
| 3 | §5.1 唯一接口 GET /frame | 新增 get_status（诊断）、subscribe/since（用户批准的路线图 V1.6-1） | ✅ 用户批准（路线图） |
| 4 | §3.1 3.3/3.4 near/aligned 所有实体两两 | 已恢复：每 App 流水线内全局两两（同窗窗口空间、跨窗屏幕空间）；方向关系按 §3.2 同一父窗口内全量判定。**跨 App 对不生成**（原始文档捕获单元 = 单目标 App，见 §3.1 Step 0） | ✅ 已对齐 |
| 5 | §2.5 near 阈值 0.05；§3.1 方向关系无距离裁剪 | 保留原始阈值与全量判定；**仅保留输出硬上限**（每窗口组 500 / 每 App 全局 5000，inside/contains 除外） | ⚠️ 工程必要：实测 Chrome 密集页无上限时单帧数百 MB、序列化秒级，违反 §6.3 性能目标 |
| 6 | §1.3 不包含"多屏幕复杂投影（V1 只支持主屏）"；§2.2 除以主屏尺寸 | 坐标一律主屏归一化（原始公式，次屏元素为负/超界坐标）；`screen.displays[]`/`displayID` 仅作信息元数据，不影响几何语义 | ✅ 已对齐（元数据为附加字段） |
| 7 | §6.2 不融合 CGWindow（V1 单一 AX 数据源） | CGWindowProbe 默认关闭（--cg-check 开启），默认链路纯 AX | ✅ 已对齐 |
| 8 | §3.1 Step 4 空间索引 by_region/by_role/by_window 线性扫描 | 默认线性（gridSize 0，帧结构同原始：无网格键）；`--index-grid N` 可选网格扩展 | ✅ 已对齐（默认） |
| 9 | §4.3 失败模式 ax_weak（有元素无标题 → 元素摘要列表） | 客户端 query 实现 ax_weak 状态 + elements 摘要 | ✅ 已补齐 |
| 10 | §2.1 Window Space"窗口内容区" | 以窗口整体 AXFrame 为窗口 rect（含标题栏），非严格内容区 | ⚠️ 待办：内容区需额外 AX 几何，V1 不强制（§12 记录） |
| 11 | §6.3 请求响应 <100ms | 缓存命中（同 version）≈0ms；全桌面大帧（9MB/4756 实体最坏场景）物化+编码+传输 ~200-300ms；单 App 过滤帧毫秒级。偏离原因：原始目标按单 App 帧设定，半同步全桌面帧是用户批准的规模扩展 | ⚠️ 说明（规模扩展） |
| 12 | §4.2 SpatialRelationScore"在参考点的同象限: 0.5" | 曾误用查询参数 region；已修正为与**参考实体**同象限（reference 的 geometry.region） | ✅ 已修正 |
| 13 | §4.3 ambiguous 响应 `{status, best:{id,score}, candidates}` | 已补 `best` 字段 | ✅ 已修正 |
| 14 | §6.1 权限检测 + 引导弹窗（必须） | 已补：未授权时打开系统设置辅助功能面板 + 提示 | ✅ 已修正 |
| 15 | §3.1 Step 4 索引仅 by_region/by_role/by_window | 附加 by_app（按 App 过滤的便利索引，不改变语义） | ⚠️ 附加字段 |
| 16 | §2.4 象限符号 Q1-Q4 / 九宫格 "right-bottom" | 帧内序列化为 q1-q4 / leftTop 驼峰（JSON 键风格统一）；客户端 --region q1 与之对应 | ⚠️ 命名差异（语义等价） |
| 17 | §2.6 Semantic Graph 保留完整 AX 树 | 仅暴露 axParentID/entityParentID 祖先链；完整树不随帧输出（只读侧挂定位：执行由调用方按 element_path 自建引用，见 V1.6-4） | ⚠️ 裁剪（定位一致） |
| 18 | §3.1 Step 1 角色白名单 13 种 | V3 扩充至 29 种（+AXTextArea/AXSecureTextField/AXPopUpButton/AXMenuButton/AXDisclosureTriangle/AXTabGroup/AXTab/AXToolbar/AXList/AXOutline/AXTable/AXRow/AXCell/AXSheet/AXDrawer/AXHeading/AXProgressIndicator/AXSplitter） | ✅ 用户批准（V3：AI 行为桌面完备性） |
| 19 | §2.1 Entity 字段无 value/focused 等 | V3 新增 value（≤512 字符，与 title 去重）/subrole/focused/selected/placeholder；旧帧解码兼容（decodeIfPresent 默认值） | ✅ 用户批准（V3） |
| 20 | §6.1 校准每 tick ≤3 App 按名轮换 | V3 改为按 staleness 排序（最旧优先）+ 自适应批次（目标 15s 全量扫一轮，默认 tick 3s → 80 App 16/tick）；冷却中 App 不占批次 | ✅ 用户批准（V3 校准提速） |
| 21 | §5.1 通知集合仅窗口级 4 种 + WindowCreated | V3 扩充：App 级 +FocusedUIElementChanged/FocusedWindowChanged/MainWindowChanged/MenuOpened/MenuClosed；窗口级 +Miniaturized/Deminiaturized/SheetCreated/DrawerCreated；**焦点跟随**的 ValueChanged/SelectedTextChanged（只挂焦点元素，每 App 一个）；元素级事件沿 AXParent 解析所属窗口后走子树重捕，菜单事件回退全量 | ✅ 用户批准（V3 缺口补全） |
| 22 | §6.2 不融合 CGWindow（V1 单一 AX 数据源，#7） | V3 起 CG 探针**常开**：每次采集一次 CGWindowList（纯本地调用，无目标 App IPC），用于窗口实体 `zIndex`（全局前后序，on-screen 才有）；交叉校验诊断（cgWindowCount/missingWindowTitles）仍由 --cg-check 控制。几何与校验仍以 AX 为准 | ✅ 用户批准（V3，修订 #7） |
| 23 | §3.1 Step 0 捕获单元 = App AXChildren | V3 新增菜单栏子树：AXMenuBar 挂在应用 AXMenuBar 属性下，作为第二根捕获；ID 前缀 `mb`（数值路径解析对它失败 → 子树重捕自动跳过，回退全量）；菜单项仅在菜单打开时存在（AX 限制） | ✅ 用户批准（V3） |
| 24 | §5.1 帧结构无焦点态 | V3 帧新增 `frontmostApp`（NSWorkspace didActivate 监听 + 启动时播种，变化即 version++）；实体级 `focused` 见 #19 | ✅ 用户批准（V3） |
| 25 | §6.1 显示器枚举变化在下一校准 tick 生效 | V3 改为 CGDisplayRegisterReconfigurationCallback 事件驱动：立即刷新屏幕几何并标记全部 App 重捕（beginConfiguration 阶段忽略） | ✅ 用户批准（V3） |
| 26 | §2.2 Local Space 预留（默认 unit，元素自身坐标系） | V3 落地为**父容器归一化 rect**（最近实体祖先坐标系；无实体祖先保持 unit；父子同空间相除，分辨率抵消）。原始"元素内部点位"语义不需存储——客户端用 screen 原点 + 分率即可表达 | ✅ 用户批准（V3，G6） |
| 27 | §3 帧 = 平铺 entities[] + relations[] | **V4 层次场景图**：帧改携 `scene[]`（每 App 一根：窗口/菜单栏/孤儿为顶层，Entity 递归 children，自然 AX 序）；inside/contains 由树结构表达；方向/near/aligned **不再随帧序列化**，客户端按几何规则对候选按需计算（语义不变，且跨窗口对首次可用、无 500/5000 截断——#5 的上限问题随之消失）；`get_frame?depth=N` 按层剪枝（prunedChildCount 标注），概览帧体积大幅收敛（实测 Finder 823 实体 → depth=1 仅 143 根） | ✅ 用户批准（V4 重设计主线） |

## 1. 设计铁律

| 铁律 | 含义 |
| :--- | :--- |
| 只读 | 只调用 AX 读取类 API，绝不调用任何修改类 API |
| 无鼠标副作用 | 不调用 CGWarp / CGEvent / cliclick 等 |
| 无截图 | 不调用任何截图 API |
| 无系统修改 | 不修改窗口、不注入事件、不改变焦点 |
| 模型驻留，帧是视图 | 虚拟桌面模型常驻内存；`get_frame` 只读物化模型，不做 AX 调用 |
| 侧挂不居中 | 执行操作由调用方负责（`client/gvgl_query.py --cliclick`） |

## 2. 坐标系（M0 实测锁定）

**实测结论（spike/m0_spike.swift，2026-08-11）**：`kAXPositionAttribute` 返回
Quartz 全局显示坐标——**原点左上、Y 轴向下**，与 CGWindow 边界逐像素一致
（delta x=0, delta y=0）。早期设计稿假设的"Cocoa 左下原点 + Y 翻转"被实测否定，
转换 1/3 一律不做 Y 翻转。

```
转换 1  Quartz 像素 → Screen Space 归一化（主屏尺寸，原始公式）
    screen.x = rect.x / screenW
    screen.y = rect.y / screenH
转换 2  Screen Space → Window Space（相对所属窗口的 Screen rect）
    window.x = (e.x - w.x) / w.w
    window.y = (e.y - w.y) / w.h
    window.w = e.w / w.w ；window.h = e.h / w.h
转换 2b Screen Space → Local Space（相对最近实体祖先的 Screen rect，V3）
    local.x = (e.x - p.x) / p.w ；local.y = (e.y - p.y) / p.h
    local.w = e.w / p.w ；local.h = e.h / p.h
转换 3  Screen Space → 物理像素（执行时，Quartz 系）
    pixelX = centerX * screenW
    pixelY = centerY * screenH
```

窗口自身的 window space 为 unit rect；无窗口祖先的实体 window space 回退为
screen space。坐标允许超出 [0,1]（次屏/负坐标）——原始文档明确 V1 只支持主屏
归一化；`screen.displays[]` 与实体 `displayID` 为信息性元数据，不改变坐标语义。

## 3. 数据模型

### 3.1 Entity

| 字段 | 说明 |
| :--- | :--- |
| `id` | 稳定 ID（见 3.4） |
| `role/title/detail/identifier/enabled/actions` | AX 语义，评分依据 |
| `value`（V3） | AXValue 短串化（≤512 字符）：输入框内容/勾选状态/滑块值；与 title 相同则去重为 nil |
| `subrole`（V3） | AXSubrole（区分搜索框/密码框/关闭按钮等） |
| `focused` / `selected`（V3） | AXFocused / AXSelected（键盘焦点、选中态） |
| `placeholder`（V3） | AXPlaceholderValue（空输入框提示语） |
| `axParentID` | AX 原始父节点 id（可能是非实体，如 AXGroup） |
| `entityParentID` | 最近实体祖先 id（`inside` 关系依据） |
| `windowID` / `appID` / `pid` / `displayID` | 归属：所属窗口实体、App（"pid:NNN"）、进程、物理显示器（元数据） |
| `zIndex`（V3） | 全局前后序（0 = 最前），仅窗口实体、仅 on-screen 当前 Space；其余为 nil |
| `geometry.screen/window/local` | 三层归一化 Rect（screen 主屏归一化；window 相对所属窗口；local 相对最近实体祖先，V3 落地） |
| `geometry.centerX/centerY/area/aspect` | 派生量 |
| `geometry.region`（q1~q4）/ `geometry.region9` | 空间标签，由 screen 中心计算 |

### 3.2 Relation

| 类型 | 依据与判定 |
| :--- | :--- |
| `inside` / `contains` | 实体树直接派生（entityParentID），不做几何判定 |
| `above` / `below` / `left-of` / `right-of` | 同一父窗口内几何判定（全量对，无距离裁剪） |
| `aligned` | **所有实体两两**：`abs(dy) < min(h)*0.5`（水平行）或 x 轴同理（垂直列） |
| `near` | **所有实体两两**，欧氏距离 < 0.05（带 `distance` 字段） |

**R12 裁剪**：方向关系只存规范方向（`above(A,B)` 存在则不加 `below(B,A)`）；
`inside` 存在时裁剪该对的全部方向关系。

**保护性偏离（有实测证据，见 §0.1）**：仅保留输出硬上限——每窗口组 500 条
方向/对齐关系、全局 5000 条/App（inside/contains 除外）。无上限时 Chrome 密集
Web 页（单窗数千 AXStaticText）可产生数百万对关系、单帧数百 MB，违反 §9
性能目标。**关系作用域 = 单目标 App**（原始文档 §3.1 Step 0 的捕获单元即单个
App）：每个 App 的流水线内做"所有实体两两"（同窗口对用窗口空间、跨窗口对用
屏幕空间），跨 App 对不产生关系——与原始文档一致（V1 本无跨 App 概念）。

### 3.3 场景图结构（V4）

| 层 | 内容 | 用途 |
| :--- | :--- | :--- |
| **Scene Graph** | 帧全量暴露：`scene[]` 每 App 一根（SceneApp 携带 appKey/pid/name/status/entityCount/CG 诊断 + children 树）；Entity 递归 `children`，顶层 = 窗口/菜单栏/孤儿（entityParentID 为 nil 或父节点不在实体集），子节点按自然 AX 序（数值路径比较，mb 前缀先于窗口） | AI 按层消费：概览 → 窗口 → 容器 → 控件 |
| **Spatial 关系** | 不随帧序列化（V4）：客户端从几何按需计算（同窗口对用窗口空间、跨窗口对用屏幕空间；inside 对裁剪方向档——R12 精神保留）；`get_frame?depth=N` 控制树深，被剪节点标 `prunedChildCount` | 消灭 O(N²) 关系载荷与截断上限 |
| **Semantic Graph** | 部分暴露：`axParentID` / `entityParentID` 链仍随每个节点保留（拍平消费/祖先行走用） | 调用方按 ID 回查结构 |

V1.5 执行路径不需要 AX 引用（坐标 + cliclick/CGEvent 即可）。若未来需要
`AXPress` 类语义操作，可新增 `get_element_tree` 或 `act` 方法（见路线图 V1.6-4）。

### 3.4 Element ID 稳定策略

ID = `"pid:NNN:路径-索引"`（App 进程隔离）。AX 树结构变动会使路径漂移，因此
**跨全量重建**时用 `IDStabilizer` 做启发式稳定：对 (role, 所属窗口,
title/identifier, window-space 位置) **唯一**匹配的实体复用旧 ID；歧义/失配
保留新路径 ID（保守）。ID 是不透明令牌，客户端引用跨帧语义 = "同一个 UI 元素"。

## 4. 转换流水线

```
AX 树（每 App 独立）
  → Step0 快照：DFS + AXUIElementCopyMultipleAttributeValues 批量读属性；
      菜单栏（AXMenuBar 属性）作为第二根捕获，ID 前缀 mb
  → Step1 实体提取：角色白名单（V3 共 31 种：AXButton/TextField/TextArea/
      SecureTextField/CheckBox/RadioButton/Menu/MenuItem/MenuBar/MenuBarItem/
      MenuButton/PopUpButton/Link/ComboBox/Slider/Stepper/Window/Image/
      StaticText/TabGroup/Tab/Toolbar/List/Outline/Table/Row/Cell/Sheet/
      Drawer/Heading/ProgressIndicator/DisclosureTriangle/Splitter）；
      丢弃 AXGroup/ScrollArea/ClipView；丢弃 zero/超小 frame
  → Step2 归一化：转换 1→2，派生量，空间标签
  → Step2.5 Z-order：窗口实体匹配 CG on-screen 窗口（中心距 <24px）→ zIndex
  → Step3 拓扑：关系计算默认关闭（V4：帧不再携带关系；`computeRelations`
      仅供测试/直接消费者）；inside 语义由 Step5 的场景树结构表达
  → Step4 索引：byRegion / byRole / byWindow / byApp
  → Step5 组装帧（DesktopModel 物化，O(N)，无 AX 调用）：
      平铺实体 → SceneTree 嵌套树（entityParentID → children，自然 AX 序，
      孤儿挂 App 根）→ 可选 depth 剪枝（prunedChildCount 标注）
```

快照预算：节点 3000 / App，深度 64，墙钟 1s（超限截断，帧标 `partial`）。

## 5. 半同步引擎

```
AXObserver（每 App 一个，专用 RunLoop 线程）
  ├─ 窗口级：Moved / Resized / Destroyed / TitleChanged
  │    / Miniaturized / Deminiaturized / SheetCreated / DrawerCreated（V3）
  │    └─ 回调携带窗口当前 rect → per-window 子树增量重捕（V1.6-2）：
  │       匹配模型中的窗口 → 按旧 ID 路径只重捕该窗口子树 → 与该 App 其他
  │       窗口的既有实体合并（其他窗口字节级零变化）；匹配失败回退全量重捕
  ├─ App 级：WindowCreated → 全量重捕；
  │    FocusedUIElementChanged / FocusedWindowChanged / MainWindowChanged（V3）
  │    → 焦点跟随：ValueChanged / SelectedTextChanged 只挂当前焦点元素；
  │    MenuOpened / MenuClosed → 全量重捕（菜单可游离于窗口外）
  ├─ 元素级事件沿 AXParent 解析所属窗口 → 子树重捕；无窗口祖先回退全量
  └─ 50ms 去抖合并 → 增量同步 → DesktopModel 应用 → version++

NSWorkspace：启停跟踪 + didActivate → 帧 frontmostApp（V3）
CGDisplayRegisterReconfigurationCallback：显示器插拔/改分辨率
  → 立即刷新屏幕几何 + 全部 App 重捕（V3，不再等校准 tick）

Reconciler（默认 2~3s；V3 自适应批次：staleness 最旧优先，
  目标 15s 内扫完全部监视 App，冷却中 App 不占批次）
  └─ 兜底：AX 通知是 best-effort → 周期校准保证最终一致

防护：
  ├─ 快照墙钟 1s          （不响应 App 不拖垮队列）
  ├─ 单 App 最小采集间隔 0.15s（通知风暴不驱动采集循环）
  ├─ 错误/慢采集冷却 30s  （不锤击）
  └─ 白名单 allowedBundleIDs（--only-apps）
```

事件→模型目标延迟 <200ms（实测 <0.8s，含去抖与采集）；校准修复静默漂移。

## 6. 查询与评分（客户端契约）

查询在客户端本地执行，**不经过守护进程**。帧即查询输入。

### 6.1 查询流程

```
Step1 空间过滤：region 指定 → index.byRegion[region]（无则全量）
Step2 角色过滤：role 指定 → 过滤
Step3 全量评分（不截断候选）
Step4 排序 → Top N + 置信度状态
```

### 6.2 五维评分

```
Score = Semantic*0.35 + Role*0.20 + SpatialRelation*0.25 + Size*0.10 + Topology*0.10

Semantic: title 精确=1.0 / title 包含=0.7 / placeholder 包含=0.65（V3）/
          detail 包含=0.6 / value 包含=0.55（V3）/ identifier 包含=0.5
Role:     精确=1.0 / 兼容（Button↔MenuItem, CheckBox↔Radio, TextField↔TextArea/
          SecureTextField/ComboBox, ComboBox↔PopUpButton）=0.6
Spatial:  V4 起几何按需计算（同规则：满足方向=1.0 / near=0.7 / 同象限=0.5）；
          同窗口对用窗口空间、跨窗口对用屏幕空间；inside 对裁剪方向档（R12 精神）
Size:     area∈[0.001,0.05]=1.0 / ∈[0.0005,0.1]=0.6 / 其他=0.2
Topology: 有 windowID=+0.3 / enabled=+0.3 / 有 actions=+0.4
```

方向归一化（V4）：方向判定改为客户端几何按需计算（`right-of` 即候选 x > 参考
右缘，以此类推），不再依赖帧内存储的规范方向关系，镜像问题随之消失。

### 6.3 置信度门限

| Top1 得分 | 状态 | 行为 |
| :--- | :--- | :--- |
| ≥ 0.7 | `hit` | 返回最佳 + 像素 |
| 0.4 ~ 0.7 | `ambiguous` | 返回候选列表，由上层 LLM 决策 |
| < 0.4 | `not_found` | 不生成虚假坐标 |

## 7. 失败模式

| 场景 | 表现 |
| :--- | :--- |
| AX 权限未授予 | `get_frame` → `{"error":{"code":"permission_denied"}}`；帧不可用 |
| App 无窗口 / AX 不可用 | 该 App `status=unavailable`，其余正常 |
| 首次捕获未完成 | 帧 `status=warming` |
| 快照超预算/墙钟 | 帧 `status=partial`（数据不完整但可用） |
| 单 App 权限缺失 | 帧 `status=permissionDenied` |
| 空模型 | 帧 `status=unavailable` |
| 查询无匹配 / 多匹配 | 客户端 `not_found` / `ambiguous`（§6.3） |

帧级状态优先级：`warming > permissionDenied > partial > ok`。

## 8. 交互协议

Unix Domain Socket（默认 `~/.gvgl/gvgl.sock`），NDJSON 一行一答；`subscribe`
为长连接多行推送。

```
→ {"method":"get_frame"}                       ← {"result": GVGLFrame}（V4 场景图）
→ {"method":"get_frame","app":"pid:123"}       ← 单 App 过滤帧
→ {"method":"get_frame","depth":2}             ← V4：按层剪枝（prunedChildCount 标注）
→ {"method":"get_frame","since":123}           ← 增量拉取：
                                                 {"result":{"event":"no_change","version":123}}
                                                 或 {"result":{"event":"changed","version":N,
                                                               "changed_apps":[...],"frame":{...}}}
→ {"method":"subscribe","since":123}           ← 长连接推送：
                                                 {"result":{"event":"subscribed","version":N}}
                                                 之后每版本变化一行：
                                                 {"event":"frame","version":N,"changed_apps":[...]}
                                                 静默期每 60s 一行 {"event":"ping",...}
→ {"method":"get_status"}                      ← {"result":{monitoredApps,version,permissionGranted,uptime,socket,frameStatus}}
→ 其他/坏 JSON                                 ← {"error":{"code":"invalid_method"|"invalid_request","message"}}
```

帧结构（V4）：`frameID / version(单调) / createdAt / syncedAt / screen{...} /
scene[SceneApp{appKey,pid,bundleID,name,status,capturedAt,entityCount,
cgWindowCount?,axWindowCount?,missingWindowTitles?,children[Entity 递归]}] /
index{byRegion,byRole,byWindow,byApp} / frontmostApp / status`。
Entity 节点保留全部 V3 字段（含 axParentID/entityParentID 祖先链）+
`children?` + `prunedChildCount?`。时间戳为毫秒 epoch；JSON 单行。

## 9. 实测指标与目标对照（本机，2026-08-11，80 App 在线）

| 指标 | 目标 | 实测 | 说明 |
| :--- | :--- | :--- | :--- |
| get_frame 延迟（缓存命中） | <100ms | ~1ms | 同 version 请求走物化缓存，仅剩网络写 |
| get_frame 延迟（全桌面大帧） | <100ms | ~200-300ms | 最坏场景 9MB/4756 实体（物化 ~50ms + 编码 ~84ms + 传输）；原始目标按单 App 帧设定，全桌面帧为半同步规模扩展（§0.1 #11） |
| get_frame 延迟（单 App 过滤） | <100ms | 毫秒级 | `app` 参数过滤帧，交互查询推荐路径 |
| get_status 延迟 | — | ~1ms | |
| 事件→模型延迟 | <200ms | <0.8s | 实测移窗 version 178→181；含去抖+重捕 |
| subscribe 事件延迟 | ≤200ms | 事件驱动，无轮询 | 模型 version 变化即推送 |
| 校准周期 | 2~3s | 2s | V3：staleness 优先 + 自适应批次，15s 目标内扫完全部监视 App |
| 单 App 快照 | <50ms | ≤1s（墙钟上限） | 常态 App 远快于此；子树重捕仅需子窗口部分 |
| 内存 | <80MB | ~100MB | 80 App 全模型驻留 |
| 磁盘/网络 IO | 0 | 0 | 纯内存 + UDS |

## 10. 代码结构

```
Sources/GVGLCore/   流水线（纯逻辑，合成 fixture 可单测）
  Models.swift        Entity(递归 children)/SceneApp/GVGLFrame/Index(+Grid)/DisplayInfo/AppSnapshot
  SceneTree.swift     V4 场景树构建/拍平/自然 AX 序/depth 剪枝
  AXSnapshot.swift    DFS 快照 + 批量属性 + 预算/墙钟 + 子树快照 + 菜单栏第二根 + CG 探针接线
  CGWindowProbe.swift CGWindowList 第二数据源（窗口级交叉校验，V2-3）
  Geometry.swift      坐标转换（M0 锁定版 + 多屏）
  Topology.swift      关系 + R12 裁剪 + 上限
  SpatialIndex.swift  索引 + GridIndexBuilder/LinearScanIndexBuilder（V2-1 可替换缝）
  Pipeline.swift      快照 → 实体/关系/索引（显示器解析 + CG 缺失窗口检测）
  IDStabilizer.swift  跨重建 ID 稳定 + PipelineOutput.remapped
Sources/GVGLSync/   半同步引擎
  DesktopModel.swift  常驻模型 + version + 变更日志 + 帧物化
  ObserverRegistry.swift  每 App AXObserver（专用 RunLoop 线程，回调携带窗口 rect）
  WorkspaceTracker.swift  NSWorkspace 启停跟踪
  SyncEngine.swift    去抖/增量同步/子树重捕/Reconciler/节流/白名单/屏幕刷新
Sources/GVGLServer/  UDS 服务（get_frame/since/subscribe 推送/get_status）
Sources/gvgl/       守护进程入口（参数/信号/显示器枚举）
client/gvgl_query.py 参考客户端（status/frame/list/query/subscribe/watch + --json/--cell）
scripts/             launchd 安装/卸载脚本（V2-5）
Tests/              104 个单测（不依赖真实 AX）
```

## 11. 运行参数

| 参数 | 说明 |
| :--- | :--- |
| `--socket PATH` | 覆盖默认 `~/.gvgl/gvgl.sock` |
| `--reconcile SECONDS` | 校准周期，默认 3s |
| `--only-apps b1,b2` | bundle id 白名单 |
| `--index-grid N` | 帧索引网格（默认 0 = 线性扫描，原始帧结构；N = N×N 网格） |
| `--cg-check` | CGWindow 交叉校验诊断（cgWindowCount/missingWindowTitles）；Z-order 排名自 V3 起常开、与此开关无关 |
| `--verbose` | 连接日志 |
| `--version` / `--print-socket` | 辅助 |

## 12. 已知限制

- 关系不再随帧序列化（V4）：客户端按几何规则按需计算；跨窗口/跨 App 方向
  判定首次可用（屏幕空间），语义与同窗口一致。inside/contains 由场景树表达。
- 全桌面帧（80 App、数千实体）仍可达数 MB；交互式查询推荐
  `get_frame?app=pid:NNN`（单 App）或 `?depth=N`（按层概览，V4），均为毫秒级。
- `subscribe` 推送的是变更事件（version + 变更 App 列表），实体级 diff 由
  `get_frame?since` 返回完整帧实现；真正的实体增量 diff（只推变更实体）未实现。
- CGWindow 校验（--cg-check）与 `zIndex` 只覆盖当前 Space 的 on-screen 窗口
  （AX 可见全部 Space）：`missingWindowTitles` 为空不代表 AX 完整；其他
  Space/最小化窗口的 `zIndex` 为 nil。
- 菜单栏实体（AXMenuBar/AXMenuBarItem）始终可见；下拉菜单内的 AXMenuItem
  仅在菜单打开时存在（AX 限制），菜单开/关由事件驱动即时重捕。
- 非原生 App（Electron 等）AX 行为参差，靠校准兜底。
- TCC 权限挂在启动终端名下；launchd 启动需单独授权二进制本体（安装脚本有提示）。
- Window Space 以窗口整体 AXFrame 为窗口 rect（含标题栏），原始文档"内容区"
  语义未严格实现（内容区需额外 AX 几何，V1 不强制）。
- 显示器插拔/分辨率变化由 CGDisplayRegisterReconfigurationCallback 事件驱动
  立即生效（V3）；displayID 为元数据，坐标始终按主屏归一化（原始公式）。
- AXValue 批量读取对巨型 TextArea（终端回滚缓冲、大文档）会一次性传输大文本：
  实体 `value` 截断 512 字符控制帧体积，快照墙钟 1s 保护采集预算。

## 13. 路线图

### V1.6（近期，全部基于现架构增量）

| # | 项 | 状态 |
| :--- | :--- | :--- |
| 1 | **SUB 推送订阅 + since 增量拉取**：`subscribe` 长连接按版本推送 `{event,version,changed_apps}`；`get_frame?since=N` 无变化返回 no_change，有变化返回完整帧 + 变更 App 列表 | ✅ 已实现 |
| 2 | **per-window 子树增量重捕**：窗口级通知只重捕该窗口子树并与既有实体合并（未变化窗口字节级零变化）；匹配失败自动回退全量重捕 | ✅ 已实现 |
| 3 | **多屏投影** | ⏸ 已收敛：原始文档 §1.3 明确 V1 只支持主屏 → 坐标保持主屏归一化（原始公式）；`screen.displays[]`/`displayID` 仅作信息元数据。真正的每屏投影若要做，需用户决策升级基线 |
| 4 | **语义操作桥（可选）**：`act`（AXPress 等） | ⏸ 待决策（需突破"只读"铁律）。**非突破部分已满足**：`entity.id` 即 element_path（"pid:NNN:路径"），调用方可自行构造 AX 引用执行操作 |

### V2（中期）

| # | 项 | 状态 |
| :--- | :--- | :--- |
| 1 | **可替换空间索引**：`SpatialIndexBuilding` 协议缝 + `GridIndexBuilder`/`LinearScanIndexBuilder`；**默认线性扫描（原始帧结构 by_region/by_role/by_window）**，`--index-grid N` 可选网格（byGrid 空间哈希 + 客户端 `--cell` 预过滤）。说明：R-Tree 不实现——查询按设计在客户端执行，帧内索引需要哈希查找而非服务端空间树 | ✅ 已实现（默认对齐原始） |
| 2 | **Polygon 几何** | ⏸ 延后：价值低（V1 明确 Rect 优先），复杂度高（AX 形状 API 不稳定），等有真实用例再做 |
| 3 | **CGWindow 交叉校验**：`CGWindowProbe` 诊断（cgWindowCount/missingWindowTitles）由 `--cg-check` 开启；**V3 起探针常开**用于窗口 zIndex（本地调用，几何仍以 AX 为准，见 §0.1 #22） | ✅ 已实现（V3 修订默认） |
| 4 | **弱 AX 兜底（OCR/Vision）** | ⏸ 延后：大范围独立进程（守护进程保持无截图铁律），待有明确需求立项 |
| 5 | **launchd 服务化**：`scripts/install-gvgl-launchagent.sh`（RunAtLoad + KeepAlive + 日志）；TCC 一次性授权二进制本体 | ✅ 已实现 |

### V3（AI 行为桌面完备性，2026-08-16）

| # | 项 | 状态 |
| :--- | :--- | :--- |
| 1 | **角色白名单扩充**：13 → 31 种（输入/弹按钮/标签页/列表表格/Sheet/工具栏/菜单栏等） | ✅ 已实现 |
| 2 | **实体状态属性**：value（≤512 字符、与 title 去重）/subrole/focused/selected/placeholder；评分链接入 placeholder 0.65 / value 0.55；兼容角色扩充；旧帧解码兼容 | ✅ 已实现 |
| 3 | **校准提速**：staleness 排序（最旧优先）+ 自适应批次（15s 全量扫一轮，80 App 从 ~80s 收敛到 ~15s）；冷却 App 不占批次 | ✅ 已实现 |
| 4 | **Observer 重注册修复**：窗口识别从指针相等（=== 永不命中）改为 CFEqual 令牌比较；已销毁窗口通知同步移除，registeredWindows 不再无限增长 | ✅ 已实现 |
| 5 | **元素级通知**：焦点/主窗口/菜单开关/Sheet/Drawer/最小化事件驱动；**焦点跟随**的 ValueChanged/SelectedTextChanged（只挂焦点元素）；元素事件沿 AXParent 解析窗口走子树重捕 | ✅ 已实现（实测：激活 TextEdit 1.5s 内 5 次 version 递增，全程无校准介入） |
| 6 | **显示器配置事件监听**：CGDisplayRegisterReconfigurationCallback → 立即刷新屏幕几何 + 全量重捕 | ✅ 已实现 |
| 7 | **菜单栏几何**：AXMenuBar 属性路径第二根捕获（mb 前缀 ID）；AXMenuBar/AXMenuBarItem 入白名单 | ✅ 已实现（实测单帧 285 个菜单栏实体） |
| 8 | **窗口 Z-order**：CG 探针常开（本地调用），窗口实体带全局前后序 `zIndex`；CG 诊断仍由 --cg-check 控制 | ✅ 已实现 |
| 9 | **帧级 frontmostApp**：NSWorkspace 激活监听 + 启动播种，变化即 version++ | ✅ 已实现 |
| 10 | **存量修复**：--only-apps 白名单不再放行 nil bundleID；IDStabilizer.remapped 保留 CG 统计 | ✅ 已实现 |
| 11 | **Local Space 落地**（G6）：实体 `geometry.local` = 最近实体祖先坐标系归一化 rect（原为恒 unit 占位）；无实体祖先保持 unit | ✅ 已实现 |

### V4（层次场景图重设计，2026-08-16）

| # | 项 | 状态 |
| :--- | :--- | :--- |
| 1 | **帧 = 层次场景图**：`scene[]` 每 App 一根（窗口/菜单栏/孤儿顶层），Entity 递归 children，自然 AX 序；平铺 entities[]/relations[]/apps[] 下线 | ✅ 已实现（实测：访达窗口 → AXOutline → AXRow → AXCell → StaticText 完整嵌套） |
| 2 | **关系转为客户端几何按需计算**：评分语义不变（方向 1.0/near 0.7/同象限 0.5），跨窗口对首次可用，O(N²) 载荷与 500/5000 截断消失；守护进程默认关闭关系计算 | ✅ 已实现（实测：left-of 查询空间档 1.0/0.7 正确） |
| 3 | **`get_frame?depth=N` 按层剪枝**：prunedChildCount 标注，概览体积大幅收敛（实测 823 实体 → depth=1 仅 143 根）；物化缓存按 depth 分键 | ✅ 已实现 |
| 4 | **消费方全量迁移**：Python 客户端（flatten/评分/list）、GVGLQuery、gvglui（画布/侧栏/详情面板"层次"视图） | ✅ 已实现 |

## 14. 构建与运行

```
swift build -c release
.build/release/gvgl &                        # 或 --only-apps com.a,com.b --reconcile 3
python3 client/gvgl_query.py status
python3 client/gvgl_query.py list
python3 client/gvgl_query.py query --role AXButton --label 登录 --pixels
python3 client/gvgl_query.py query --role AXButton --reference pid:xxx:0-1 --relation right-of
python3 client/gvgl_query.py watch --interval 0.5
swift test                                    # 104 个单测
```
