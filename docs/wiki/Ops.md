# 运维

## 构建

```bash
swift build -c release
# 产物：
#   .build/release/gvgl     守护进程
#   .build/release/gvglui   单一 GUI 应用（审查台 + 菜单栏监控 + 内嵌守护进程）
# scripts/package-apps.sh --install → /Applications/GVGL.app
```

## 运行

```bash
.build/release/gvgl &         # 默认 socket: ~/.gvgl/gvgl.sock
# 可选参数：
#   --socket PATH            覆盖 socket 路径
#   --reconcile SECONDS      校准周期（默认 3）
#   --only-apps com.a,com.b  bundle id 白名单（严格：无 bundle id 的 App 不放行）
#   --index-grid N           帧索引网格（默认 0 = 线性扫描）
#   --cg-check               CGWindow 交叉校验诊断（z-order 排名 V3 起常开，与此无关）
#   --verbose                连接日志
```

## TCC 权限

- 从终端启动：辅助功能权限归属终端 App，在
  系统设置 → 隐私与安全性 → 辅助功能 中勾选终端。
- 守护进程启动时若未授权：自动打开系统设置辅助功能面板（§6.1 引导弹窗）。
- 从 launchd 启动：权限归属 gvgl 二进制本体，需单独勾选。

## launchd 常驻

```bash
scripts/install-gvgl-launchagent.sh
#   - RunAtLoad + KeepAlive，日志 ~/.gvgl/logs/
#   - 安装后一次性：系统设置 → 辅助功能 → 启用 gvgl 二进制本体
scripts/uninstall-gvgl-launchagent.sh
```

## 性能指标（本机实测，80 App 在线）

| 指标 | 实测 |
| :--- | :--- |
| get_frame（缓存命中） | ~1ms |
| get_frame（全桌面大帧 9MB/4756 实体） | ~200-300ms |
| get_frame（单 App 过滤） | 毫秒级 |
| 事件→模型延迟 | <0.8s（含 50ms 去抖 + 重捕） |
| subscribe 事件 | 模型 version 变化即推送 |
| 校准周期 | 2~3s，V3 自适应批次（staleness 优先，15s 内扫完全部 App） |
| 单 App 快照 | ≤1s（墙钟上限） |
| 内存 | ~100MB（80 App 全模型驻留） |

提示：交互式查询优先用 `get_frame?app=pid:NNN` 单 App 过滤帧。

## 故障排查

| 现象 | 排查 |
| :--- | :--- |
| get_frame 返回 permission_denied | 检查 TCC 授权（见上） |
| 某 App entityCount=0 | 该 App 当前无窗口或 AX 不可用（status=unavailable） |
| 帧 status=partial | 大 App 快照被预算/墙钟截断，数据不完整但可用 |
| 守护进程不可杀 | 用 `kill -TERM <pid>`（SIGTERM 干净退出），勿用 SIGKILL |
| launchd 版本不工作 | 检查 ~/.gvgl/logs/gvgl.err.log；确认二进制本体已授权 |
