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

## 命令

```bash
gvglact status                                   # AX 权限 + 守护进程状态
gvglact transcript --app pid:123                 # 把窗口读成文本（替代截图）
gvglact find --role AXButton --label 登录         # 只定位，不动作
gvglact press --id pid:123:0-2                   # AXPress（不是坐标点击）
gvglact click --id pid:123:0-2 --count 2         # 命中测试后的双击
gvglact type --id pid:123:0-1 --text "你好 hello" # AXValue → 粘贴 → Unicode 按键
gvglact key --chord "cmd+s" --app pid:123
gvglact scroll --id pid:123:0-5 --down 5
gvglact drag --from pid:123:0-2 --to pid:123:0-3
gvglact menu --app pid:123 --path "文件/新建窗口"
gvglact text --id pid:123:0-1                    # 读该元素完整 AXValue
gvglact set --id pid:123:0-1 --value "abc"       # 原子写 AXValue
gvglact focus --id pid:123:0-1
gvglact app activate --target com.apple.finder
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
| `method` | 实际路径：`ax_press` / `ax_set_value` / `cg_click` / `cg_key` … |
| `before` / `after` | 元素状态与版本的前后快照 |
| `warnings` | 非致命信息（回退、重定位、低置信度） |

"点了但没变化"不是失败；"变化来自别处"也不等于成功。两者分开上报，调用方才能
决定下一步。

## 安全护栏

- **命中测试**：点击前用 `AXUIElementCopyElementAtPosition` 确认落点是目标本身、
  其后代或（容器目标的）祖先；否则 `target_obscured` 拒绝。没有截图也能避免点穿。
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

重 App（SwiftUI/Electron）超出默认 3000 节点预算时，控制台会显示 `partial`；启动
守护进程时调大预算：

```bash
.build/release/gvgl --node-budget 20000 --capture-time 12
```

## 已知限制

- 画布/游戏等无 AX 语义的界面只能坐标点击；命中测试不可用时默认拒绝（可用
  `--allow-blind-click` 显式放开）。
- Electron/Chromium 的 Web 树取决于其辅助功能是否被触发；未暴露时只能看到外壳控件。
- 覆盖式滚动条通常不在 AX 树中：此时滚动以"内容是否变化"验证。若目标本身是
  `AXScrollBar`，则直接读其 0…1 的位置值（`--to top/bottom` 会据此判定终点）。
- 菜单项仅在展开时存在，`menu` 是多步动作；失败会指出具体段落。
- 不提供 quit / 改窗口几何等破坏性动词。
