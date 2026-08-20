# 客户端

## gvgl_query.py（CLI 参考客户端）

```bash
python3 client/gvgl_query.py status                          # 守护进程状态
python3 client/gvgl_query.py list                            # 桌面概览（App/窗口/CG 校验）
python3 client/gvgl_query.py query --role AXButton --label 登录 --pixels
python3 client/gvgl_query.py query --role AXButton --label 登录 --top 3 --json
python3 client/gvgl_query.py query --role AXButton --cell r1c2 --json   # 网格预过滤（需 --index-grid）
python3 client/gvgl_query.py query --role AXButton --reference pid:123:0-1 --relation right-of
python3 client/gvgl_query.py subscribe --pull                # 推送订阅 + 增量拉取
python3 client/gvgl_query.py watch --interval 0.5            # 轮询观察 version（备选）
```

- `--cliclick` 打印可执行命令；`--execute` 直接执行（需 `brew install cliclick`）。
- `--json` 输出机器可读结果（含 `status`/`hits`/`best`/`elements`）。
- socket 可用 `--socket PATH` 或环境变量 `GVGL_SOCKET` 指定。

## GVGL.app（单一 GUI 应用）

```bash
scripts/package-apps.sh --install   # 打包安装 /Applications/GVGL.app
open /Applications/GVGL.app
```

一个应用包含三部分：

| 部分 | 功能 |
| :--- | :--- |
| **审查台窗口** | 桌面画布（按角色着色、窗口上方标注 App 名称、**前台窗口加粗标记**、**菜单栏色带**、**焦点元素黄色描边**、点击高亮）、**实体详情面板**（点选后右侧显示全字段：value/subrole/focused/selected/placeholder/zIndex/三层几何/像素中心/**层次视图：祖先链 + 直接子节点**/AX 操作）、侧栏（应用概览；**角色过滤器动态生成**；标题/value/ID 过滤；**事件流**：每次帧变化的 version 与变更 App）、指令面板（自然语言指令 + 五维评分 + 定位/点击） |
| **菜单栏监控** | 标题栏图标（已连接 `network` / 断开 `network.slash`），菜单显示连接状态/监控 App 数/帧状态/AX 权限/version，操作：打开审查台、启动/重启守护进程、暂停监控、立即刷新、退出 |
| **内嵌守护进程助手** | `Contents/Resources/gvgl`，启动时若守护进程未运行则自动拉起（--reconcile 3） |

指令面板即"人工指令模拟 AI 指令测试"：输入与 Agent 相同的自然语言指令，查看
评分与候选，确认后执行点击（CGEvent）。执行前需在侧栏开启「允许执行点击」。

能力观测路径（V3）：打字/切焦点/开菜单 → 侧栏「事件流」立即出现对应 App 的
version 跳变；点选任意实体 → 详情面板核对 value/focused/zIndex/local；
画布顶部色带 = 菜单栏几何，蓝色加粗边框 + 「前台」标记 = frontmostApp 窗口。

TCC：首次使用在 系统设置 → 辅助功能 勾选「GVGL」（含其内嵌守护进程），
守护进程未授权时会自动打开设置面板。**重新打包安装后需重新勾选一次**
（ad-hoc 签名变化会使既有授权失效）；授权即时生效，无需重启应用。

## GVGLQuery 库（程序化集成）

`Sources/GVGLQuery/` 提供：

- `GVGLClient`：UDS NDJSON 客户端（getFrame / getFrameSince / subscribe）。
- `QueryEngine`：五维评分 + 置信度门限 + 像素换算。
- `InstructionParser`：自然语言/CLI 指令解析。

Agent 可直接依赖该库，与审查台共享同一套评分语义。
