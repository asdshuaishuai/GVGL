# 动作层（gvglact）— 无截图的 computer use

`gvgl` 守护进程仍然**完全只读**。`gvglact` 是它旁边的执行器：用帧定位元素，用
macOS Accessibility 语义动作操作，用回读验证结果。**全程不截图、不 OCR。**

```
gvgl (只读模型) ──UDS 帧──► gvglact ──AX 动作 / 合成事件──► 目标 App
                                  └── 回读元素 + 轮询 version ──► 验证结果
```

## 为什么动作不在守护进程里

| 理由 | 说明 |
| :--- | :--- |
| 权限分离 | 读帧只需 socket；执行才需要辅助功能权限，由调用方进程承担 |
| 可审计 | 守护进程仍是"零写调用"，只读性可机械验证 |
| 隔离 | 执行器崩溃不会带走常驻模型 |

## 后台隔离（默认）

目标：agent 在后台干活，前台用户继续用电脑——不改前台 App、不动指针、不抢键盘、
不覆盖剪贴板。macOS 没有公开 API 给 agent 开一个输入隔离的“第二桌面”，因此 GVGL
的隔离方式是**不碰共享输入通路**：只调用 Accessibility 语义动作（AXPress /
AXSetValue / AXScrollBar）并回读验证。

| 动作 | 后台模式行为 |
| :--- | :--- |
| `press` / `click`(left,1) / `set` / `focus` / 读取类 | 允许；`click` 变成目标控件的 AX 语义激活，不是坐标点击 |
| `type`(auto) | 仅当 AXValue 可写；不移动焦点、不发按键 |
| `scroll` | 写 AXScrollBar 的 AXValue；`--to top/bottom` 直接到位；无滚动条则拒绝 |
| `menu` | 仅当目标 App 已在前台；不主动激活 |
| `key` / `hover` / `drag` / 非 left click / `type --method keys|paste` / `--submit` | `blocked_by_policy` |
| `app launch` | 允许，但 `activates=false`，不抢前台 |
| `app activate` / `clipboard set` | `blocked_by_policy`（读剪贴板允许） |

`--mode foreground` 恢复合成鼠标/键盘路径（只适合 agent 独占的机器）。每条结果的
`isolation` 字段标明本次动作运行在哪种模式；`status` 额外返回 `frontmost_pid` /
`frontmost_name` / `cursor` / `clipboard_change_count`，动作前后比对即可机械证明
“没有碰前台”。

边界：语义动作直接投递给目标 App，App 自己可能因业务逻辑激活窗口——那是 App 的
行为，不是 GVGL 合成的输入。像素级界面（游戏/画布）和必须按键的流程在 macOS 上
无法隔离，后台模式会明确拒绝，不会偷偷退回合成事件。

## 命令

```bash
gvglact status                                   # AX 权限 + 守护进程状态
gvglact transcript --app pid:123                 # 把窗口读成文本（替代截图）
gvglact find --role AXButton --label 登录         # 只定位，不动作
gvglact press --id pid:123:0-2                   # AXPress（不是坐标点击）
gvglact click --id pid:123:0-2                   # 后台=语义激活；双击需 --mode foreground
gvglact type --id pid:123:0-1 --text "你好 hello" # 后台=AXValue；其余回退需 foreground
gvglact key --chord "cmd+s" --app pid:123        # 需 --mode foreground
gvglact scroll --id pid:123:0-5 --down 5         # 后台写 AXScrollBar 值
gvglact hover  --id pid:123:0-5                 # 工具提示/悬停显现（需 foreground）
gvglact drag --from pid:123:0-2 --to pid:123:0-3 # 需 --mode foreground
gvglact menu --app pid:123 --path "文件/新建窗口" # 后台要求该 App 已在前台
gvglact text --id pid:123:0-1                    # 读该元素完整 AXValue
gvglact set --id pid:123:0-1 --value "abc"       # 原子写 AXValue
gvglact focus --id pid:123:0-1
gvglact app activate --target com.apple.finder   # 需 --mode foreground
gvglact clipboard get
gvglact wait --since 120 --timeout 3
```

输出恒为单行 JSON（`--pretty` 美化）。退出码：`0` 成功 / `1` 动作失败 / `2` 用法错误。

## 目标选择

- `--id pid:NNN:0-2-3` — 帧里的元素 ID（`root` / `mb` 前缀同样支持）。
- 或查询参数：`--role`、`--label`、`--region`、`--display`、`--app`、`--reference` + `--relation`。
- `--role` 是**硬过滤**（兼容角色仍可达，如 Button ↔ MenuItem）。
- 前两名分差 < 0.05 视为平票，拒绝执行；`--allow-ambiguous` 可覆盖。

## 结果语义

| 字段 | 含义 |
| :--- | :--- |
| `ok` | 操作已执行 |
| `changed` | 桌面确实有反应（版本推进或元素状态变化） |
| `verified` | 反应符合该动作的预期（输入回读一致、关闭后元素消失等） |
| `method` | 实际路径：`ax_press` / `ax_set_value` / `ax_scrollbar` / `cg_click` / `cg_key` … |
| `isolation` | `background` / `foreground`：本次动作是否允许合成输入 |
| `before` / `after` | 元素状态与版本的前后快照 |
| `warnings` | 非致命信息（回退、重定位、低置信度） |

"点了但没变化"不是失败；"变化来自别处"也不等于成功。两者分开上报，调用方才能
决定下一步。

## 安全护栏

- **命中测试**（仅前台模式）：坐标点击前用 `AXUIElementCopyElementAtPosition`
  确认落点是目标本身、其后代或（容器目标的）祖先；否则 `target_obscured` 拒绝。
  没有截图也能避免点穿。后台模式不做坐标动作，自然也不需要命中测试。
- **默认不干扰**：`--mode background` 从策略层禁止合成输入、激活和剪贴板写入；
  拒绝发生在解析目标和任何写入之前。
- **新鲜度校验**：ID 是地址不是句柄。每次动作都重新解析元素，role/identifier/位置
  不符时刷新模型并唯一重定位一次，仍不符则 `stale_reference`。
- **输入前置条件**：打字前必须确认焦点在目标上，否则 `focus_failed`——绝不向未知
  控件输入。
- **安全输入框**：默认拒绝写入，且不回读值。
- **作用域**：`--allow-app pid:123,com.apple.finder` 限定可操作 App。
- **试运行**：`--dry-run` 只解析与校验，不激活 App、不发事件、不改焦点。

## 错误码

`not_found` · `ambiguous_match` · `stale_reference` · `target_obscured` ·
`action_unsupported` · `focus_failed` · `permission_denied` · `blocked_by_policy` ·
`app_not_running` · `timeout` · `invalid_argument` · `internal_error`

## 权限

执行需要**调用方进程**具备辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能）。
读帧不需要。两者相互独立，因此一个只读消费者可以完全不申请权限。

## 零截图是机械约束

```bash
scripts/audit_no_screenshot.sh   # 命中截图/OCR API 即失败
```

## 端到端验证

```bash
.build/release/gvgl --socket /tmp/gvgl-act.sock &
python3 scripts/act_smoke.py --socket /tmp/gvgl-act.sock
```

脚本会临时弹出一个 dialog，完成：读文本 → 定位 → 输入 → 回读 → `AXPress` 取消 →
确认进程退出。任何一步失败都会以非零退出码结束。

## 审查台（gvglui）

审查台不再自带点击代码，而是调用同一个 `ActionExecutor`——人类在控制台里按下的按钮，
和 agent 调 `gvglact` 走的是同一条路径。

- **动作条**：语义按下 / 指针点击 / 输入 / 按键 / 滚动 / 读窗口文本
- **动作日志**（侧栏）：方法 / 是否变化 / 是否验证 / 耗时 / 错误码
- **窗口文本面板**：读选中窗口或前台 App 的 AX 文本，替代截图
- **允许执行动作**：唯一闸门；读取窗口文本始终可用
- **后台模式（不干扰前台）**：默认开启；关闭后才允许指针/键盘类动作。动作日志会
  标注每条是「后台」还是「前台」执行

重 App（SwiftUI/Electron）超出默认 3000 节点预算时，控制台会显示 `partial`；启动
守护进程时调大预算：

```bash
.build/release/gvgl --node-budget 20000 --capture-time 12
```

## Python 封装

`client/gvgl_act.py` 是 gvglact 的薄封装：只做参数拼装、NDJSON 解析、错误码
翻译——动作逻辑零重复（评分那一份双实现由向量夹具钉住，动作不应再造第二份）。

```python
from gvgl_act import ActClient
client = ActClient(socket="/tmp/gvgl.sock")    # 默认 mode="background"
client.press("pid:123:0-2")                    # 语义按下
client.type(text="你好", target="pid:123:0-1") # AXValue 写入，不动焦点
client.transcript(app="pid:123")               # 读窗口文本
```

CLI 同样默认后台隔离，必要时 `--mode foreground`。失败抛 `ActError`（`.code` 为
稳定错误码）。包装层门禁：

```bash
python3 scripts/test_act_client.py
```

## 已知限制

- 画布/游戏等无 AX 语义的界面只能坐标点击：后台模式直接 `blocked_by_policy`；
  需要 `--mode foreground`。前台模式命中测试不可用时仍默认拒绝（可用
  `--allow-blind-click` 显式放开）。
- macOS 没有公开 API 创建输入隔离的“第二桌面”。后台模式保证的是**不碰共享输入**
  （指针/键盘/激活/剪贴板），不能阻止目标 App 因自身业务逻辑激活窗口或弹窗；
  真正的独立桌面需要第二用户会话或虚拟机，超出本工具范围。
- 后台 `type` 走 AXValue 原子写入，不产生逐键事件：依赖 `keyDown`、输入法或
  search-as-you-type 的控件可能出现“值已写入但业务逻辑未触发”。这类流程需要
  `--mode foreground` 的真实按键；回读验证能发现差异（`changed` 为真而业务没动）。
- Electron/Chromium 的 Web 树取决于其辅助功能是否被触发；未暴露时只能看到外壳控件。
- 覆盖式滚动条通常不在 AX 树中：后台模式会拒绝（没有 AXScrollBar 可写），前台
  模式用滚轮并以“内容是否变化”验证。若目标本身是 `AXScrollBar`，则直接读其
  0…1 的位置值（`--to top/bottom` 会据此判定终点）。
- 菜单项仅在展开时存在，`menu` 是多步动作；失败会指出具体段落。
- 不提供 quit / 改窗口几何等破坏性动词。
- **锁屏时不要操作**：macOS 只服务 loginwindow 的 AX，帧会退化为空、动作会
  失败。先看 `gvglact status` 的 `screen_locked`（或 `get_status` 的
  `screenLocked`），等解锁后再继续——0 实体不等于空桌面。
