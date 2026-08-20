# 路线图与偏离审计

## 路线图状态

### V1.6（已完成）

| # | 项 | 状态 |
| :--- | :--- | :--- |
| 1 | SUB 推送订阅 + since 增量拉取 | ✅ |
| 2 | per-window 子树增量重捕（未变化窗口字节级零变化） | ✅ |
| 3 | 多屏投影 | ⏸ 已收敛：坐标保持主屏归一化（原始文档 V1 只支持主屏），displays/displayID 仅作元数据 |
| 4 | 语义操作桥（AXPress） | ⏸ 待决策（需突破"只读"铁律）；非突破部分已满足——`entity.id` 即 element_path |

### V2（部分完成）

| # | 项 | 状态 |
| :--- | :--- | :--- |
| 1 | 可替换空间索引（默认线性，`--index-grid N` 可选网格） | ✅（默认对齐原始） |
| 2 | Polygon 几何 | ⏸ 延后（低价值高复杂度） |
| 3 | CGWindow 交叉校验（`--cg-check` 诊断；V3 起探针常开用于 zIndex） | ✅（V3 修订默认） |
| 4 | 弱 AX 兜底（OCR/Vision） | ⏸ 延后（需独立进程立项） |
| 5 | launchd 服务化 | ✅ |

### V3（AI 行为桌面完备性，2026-08-16，已完成）

| # | 项 | 状态 |
| :--- | :--- | :--- |
| 1 | 角色白名单扩充：13 → 31 种（输入/弹按钮/标签页/列表表格/Sheet/工具栏/菜单栏等） | ✅ |
| 2 | 实体状态属性：value（≤512 字符、与 title 去重）/subrole/focused/selected/placeholder；评分链 placeholder 0.65 / value 0.55；兼容角色扩充；旧帧解码兼容 | ✅ |
| 3 | 校准提速：staleness 最旧优先 + 自适应批次（15s 目标全量扫一轮，80 App 从 ~80s → ~15s）；冷却 App 不占批次 | ✅ |
| 4 | Observer 重注册修复：窗口识别从 `===`（永不命中）改为 CFEqual 令牌比较；已销毁窗口通知移除，registeredWindows 不再无限增长 | ✅ |
| 5 | 元素级通知：焦点/主窗口/菜单开关/Sheet/Drawer/最小化；焦点跟随的 ValueChanged/SelectedTextChanged；元素事件沿 AXParent 解析窗口走子树重捕 | ✅（实测事件驱动 1.5s 内生效） |
| 6 | 显示器配置事件监听：CGDisplayRegisterReconfigurationCallback → 立即刷新 + 全量重捕 | ✅ |
| 7 | 菜单栏几何：AXMenuBar 属性路径第二根捕获（mb 前缀 ID）；AXMenuBar/AXMenuBarItem 入白名单 | ✅（实测单帧 285 个菜单栏实体） |
| 8 | 窗口 Z-order：CG 探针常开，窗口实体带全局前后序 `zIndex`；CG 诊断仍由 `--cg-check` 控制 | ✅ |
| 9 | 帧级 frontmostApp：NSWorkspace 激活监听 + 启动播种 | ✅ |
| 10 | 存量修复：白名单不再放行 nil bundleID；remapped 保留 CG 统计 | ✅ |

### V4（层次场景图重设计，2026-08-16，已完成）

| # | 项 | 状态 |
| :--- | :--- | :--- |
| 1 | 帧 = 层次场景图：`scene[]` 每 App 一根（窗口/菜单栏/孤儿顶层），Entity 递归 children，自然 AX 序；平铺 entities/relations/apps 下线 | ✅ |
| 2 | 关系转为客户端几何按需计算：语义不变（方向 1.0/near 0.7/同象限 0.5），跨窗口对首次可用，O(N²) 载荷与截断上限消失；守护进程默认关闭关系计算 | ✅ |
| 3 | `get_frame?depth=N` 按层剪枝（prunedChildCount 标注），概览体积大幅收敛（实测 823 实体 → depth=1 仅 143 根） | ✅ |
| 4 | 消费方全量迁移：Python 客户端、GVGLQuery、gvglui（画布/侧栏/详情"层次"视图） | ✅ |

### 已交付附加能力

- SwiftUI 审查台（gvglui）+ 自然语言指令模拟
- GVGLQuery 库（程序化集成：客户端/评分/指令解析）
- Wiki 文档

## 偏离审计（完整版见 DESIGN.md §0.1，17 项）

| 类别 | 数量 | 说明 |
| :--- | :--- | :--- |
| ✅ 用户批准修订 | 3 | 坐标无翻转（M0 实测）、半同步模型驻留、接口扩展 |
| ✅ 已对齐/已修正 | 11 | 关系作用域、索引默认线性、CG 默认关闭、ax_weak、权限引导等 |
| ⚠️ 工程必要（有实测证据） | 1 | 关系输出硬上限（无上限时单帧数百 MB） |
| ⚠️ 说明（规模扩展） | 1 | 全桌面帧性能（原始目标按单 App 设定） |
| ⚠️ 附加/命名/裁剪 | 3 | by_app 索引、q1/驼峰命名、Semantic Graph 祖先链裁剪 |

## 已知限制

- 关系不随帧序列化（V4）：客户端按几何规则按需计算；跨窗口/跨 App 方向
  判定首次可用（屏幕空间），inside/contains 由场景树表达。
- `subscribe` 推送变更事件（version + changed_apps）；实体级 diff 由
  `get_frame?since` 返回完整帧实现，真正的实体增量 diff 未实现。
- Window Space 以窗口整体 AXFrame 为基准（含标题栏），非严格"内容区"。
- 非原生 App（Electron 等）AX 行为参差，靠校准兜底。
- TCC 权限归属：终端启动挂终端，launchd 启动需单独授权二进制。
