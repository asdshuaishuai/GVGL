# GVGL — 几何虚拟桌面守护进程

侧挂于真实桌面旁、完全只读的守护进程。通过 macOS Accessibility API 维持常驻的
虚拟桌面几何模型（事件驱动 + 周期校准），经 Unix Socket 暴露给 Agent/CLI 推理。
GVGL 不执行任何操作——点击/输入由调用方完成。

详见 [DESIGN.md](DESIGN.md)（权威规格：坐标系实测结论、半同步架构、性能数据、
偏离审计表）与 [Wiki](docs/wiki/Home.md)（架构/坐标/协议/查询/客户端/运维/路线图/测试）。

## 审查台（人工指令模拟 AI 指令测试）

```bash
swift build -c release
.build/release/gvgl &        # 先启动守护进程
.build/release/gvglui        # 单一 GUI 应用（审查台窗口 + 菜单栏监控 + 内嵌守护进程）
open /Applications/GVGL.app
```

审查台能力观测面：桌面画布（前台窗口标记/菜单栏色带/焦点描边）、实体详情面板
（value/subrole/focused/zIndex/三层几何/关系摘要）、侧栏事件流（帧变化与变更
App 实时可见）、指令面板（NL 指令 → 五维评分 → 定位/点击）。

## 构建

```bash
swift build -c release        # 产物 .build/release/{gvgl, gvglui}
scripts/package-apps.sh --install   # 打包并安装 /Applications/GVGL.app
```

## 运行

```bash
.build/release/gvgl &         # 默认 socket: ~/.gvgl/gvgl.sock（单一 AX 数据源，线性索引）
# 或
.build/release/gvgl --only-apps com.microsoft.edgemac,com.apple.finder  # 白名单模式
.build/release/gvgl --reconcile 3 --index-grid 4 --cg-check --verbose   # 网格索引/CG 诊断/日志
```

首次运行需在 系统设置 → 隐私与安全性 → 辅助功能 中授予终端权限。

### launchd 常驻（V2-5）

```bash
scripts/install-gvgl-launchagent.sh      # RunAtLoad + KeepAlive，日志 ~/.gvgl/logs
# 一次性：系统设置 → 辅助功能 → 启用 gvgl 二进制本体（launchd 身份独立于终端）
scripts/uninstall-gvgl-launchagent.sh
```

## 查询客户端

```bash
python3 client/gvgl_query.py status                          # 守护进程状态
python3 client/gvgl_query.py map                             # 象限地图（每屏 2×2，agent 首次拉取）
python3 client/gvgl_query.py list                            # 桌面概览（App/窗口/显示器/CG 校验）
python3 client/gvgl_query.py query --role AXButton --label 登录 --pixels
python3 client/gvgl_query.py query --role AXButton --label 登录 --top 3 --json
python3 client/gvgl_query.py query --display 3 --region q4 --role AXWindow   # 某块屏的某象限
python3 client/gvgl_query.py query --role AXButton --label 登录 --cell r1c2 --json   # 网格预过滤
python3 client/gvgl_query.py query --role AXButton --reference pid:123:0-1 --relation right-of
python3 client/gvgl_query.py subscribe --pull                # 推送订阅 + 增量拉取
python3 client/gvgl_query.py subscribe --regions d1q2 sys    # 象限掩码订阅（V5.1）
python3 client/gvgl_query.py watch --interval 0.5            # 轮询观察 version（备选）
```

`query` 输出置信度状态：`hit`（≥0.7）/ `ambiguous`（0.4~0.7）/ `not_found`（<0.4）。
`--cliclick` 打印可执行命令，`--execute` 直接执行（需 `brew install cliclick`）。
`socket` 可用 `--socket PATH` 或环境变量 `GVGL_SOCKET` 指定。

## 协议

Unix Domain Socket + NDJSON（V4：帧为层次场景图，关系由客户端几何按需计算）：

```
{"method":"get_frame"}                              → {"result": GVGLFrame（scene 树）}
{"method":"get_frame","app":"pid:123"}              → 单 App 过滤帧
{"method":"get_frame","depth":2}                    → 按层剪枝（prunedChildCount 标注）
{"method":"get_map"}                                → 粗粒度象限地图（displays+windows+象限/zIndex，V5）
{"method":"get_frame","since":123}                  → 增量：no_change / changed+changed_apps+frame
{"method":"subscribe"}                              → 长连接推送版本事件（frame/ping）
{"method":"get_status"}                             → {"result": {...}}
```

## 测试

```bash
swift test        # 122 个单测：几何/显示空间/拓扑/索引/CG 校验/ID 稳定/子树重捕/订阅/评分/指令解析（合成 fixture）
```

## 几何审计（真机不变量检查）

```bash
python3 scripts/audit_geometry.py     # 拉取实时帧，校验硬性不变量（重复 ID/非有限坐标/零尺寸）
                                      # 与信息性指标（AX 结构性几何奇异，见脚本头注释）
```

