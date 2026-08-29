# 查询与评分

查询在**客户端本地**执行（Agent / gvgl_query.py / gvglui 审查台），不经过守护
进程——帧就是查询输入。守护进程只提供数据。

## 查询流程

```
Step 0 屏过滤（V5）：display 指定（CG display id，见 get_map）→ 过滤
Step 1 空间过滤：region 指定 → index.byRegion[region]（无则全量）；
     region 语义 = 元素所在屏的象限（V5，Display Space 派生）
Step 2 角色过滤：role 指定 → 过滤
Step 3 全量评分（不截断候选）
Step 4 排序 → Top N + 置信度状态
```

四级空间寻址（V5）：`display（哪块屏）× region（哪个象限）× app（哪个应用）
× role/label（什么控件/文本）`，每级独立过滤键，例如
`query --display 3 --region q4 --role AXWindow`。

## 五维评分（§6.2）

```
Score = Semantic×0.35 + Role×0.20 + SpatialRelation×0.25 + Size×0.10 + Topology×0.10

Semantic   title 精确=1.0 / title 包含=0.7 / placeholder 包含=0.65（V3）/
           detail 包含=0.6 / value 包含=0.55（V3）/ identifier 包含=0.5
Role       精确=1.0 / 兼容（Button↔MenuItem, CheckBox↔Radio, TextField↔TextArea/
           SecureTextField/ComboBox, ComboBox↔PopUpButton）=0.6
Spatial    V4 起几何按需计算（帧不再携带关系表）：满足方向=1.0 / near=0.7 /
           与参考实体同象限=0.5；同窗口对用窗口空间、跨窗口对用屏幕空间
Size       area∈[0.001,0.05]=1.0 / ∈[0.0005,0.1]=0.6 / 其他=0.2
Topology   有 windowID=+0.3 / enabled=+0.3 / 有 actions=+0.4
```

**方向判定（V4 几何化）**：查询 "right-of" 即"候选左缘 > 参考右缘"（above/
below/left-of 以此类推），直接从 rect 判定——无存储方向关系、无镜像问题；
inside 祖先对不参与方向档（R12），near（中心距 <0.05）与象限档不受影响。

## 置信度门限

| Top1 得分 | 状态 | 行为 |
| :--- | :--- | :--- |
| ≥ 0.7 | `hit` | 返回最佳 + 像素 |
| 0.4 ~ 0.7 | `ambiguous` | 返回候选列表（含 `best`），上层决策 |
| < 0.4 | `not_found` | 不生成虚假坐标 |
| — | `ax_weak` | 角色命中但元素无可用文本（title/detail/identifier/value/placeholder 全空）→ 返回结构化元素摘要 |

注意：角色 + 默认尺寸 + 完整拓扑的底分是 0.4，因此"有角色但标题不符"通常落在
`ambiguous`；`ax_weak` 只对弱元素（小尺寸/禁用/无操作，得分 <0.4）触发。

## 指令解析（gvglui 与 Agent 复用）

自然语言 → 结构化查询：

```
"点击 登录 按钮"                     → click + label=登录 + role=AXButton
"点击右上角的登录按钮"                → click + region=q2 + label=登录 + role=AXButton
"在 搜索框 右侧的 关闭 按钮"          → query + refDir=rightOf + label=关闭
                                        + role=AXButton + reference(搜索框, AXTextField)
"query --role AXButton --label 登录" → CLI 透传
```

角色词表：按钮/按键→AXButton，输入框/文本框/搜索框→AXTextField，复选框→
AXCheckBox，单选框→AXRadioButton，窗口→AXWindow，图片→AXImage，文本/标签→
AXStaticText，菜单项→AXMenuItem，链接→AXLink，滑块→AXSlider，下拉/组合框→
AXComboBox。

区域词表：左上角→q1，右上角→q2，左下角→q3，右下角→q4。

关系词表：右侧/右边→rightOf，左侧/左边→leftOf，上方/上面→above，下方/下面→
below，附近/旁边→near。

## 像素换算（执行时）

```
pixelX = centerX × screenW
pixelY = centerY × screenH     // Quartz 全局坐标（左上原点），多显示器直接可用
```
