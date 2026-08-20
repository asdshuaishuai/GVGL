# 测试

## 单测（104 个，不依赖真实 AX，全部用合成 fixture）

```bash
swift test
```

| 套件 | 覆盖 |
| :--- | :--- |
| GVGLCoreTests | 坐标转换（无翻转/主屏公式）、拓扑关系（方向/对齐/near/裁剪/上限）、索引（网格/线性/向后兼容）、ID 稳定（树漂移/歧义/位置匹配/remap/CG 统计保留）、管线（实体提取/窗口空间/次屏元数据/CG 缺失窗口检测/V3 角色扩充/属性映射/value 去重与截断/菜单栏子树/Z-order/诊断门控/旧帧解码兼容）、场景树（嵌套/自然序/孤儿挂根/depth 剪枝/拍平/帧 JSON roundtrip） |
| GVGLSyncTests | DesktopModel（聚合/过滤/状态机/version/变更日志/等待通知/frontmostApp/V4 depth 剪枝与缓存分键）、SyncEngine（采集/去抖合并/白名单含 nil bundleID 拒绝/屏幕刷新/显示器重配置全量重捕/校准批次 staleness 排序与自适应/ID 稳定集成/子树重捕/回退/失配）、订阅服务器（真实 UDS：since 增量/subscribe 推送） |
| GVGLQueryTests | 查询引擎（五维评分逐项/权重合成/置信度门限/同象限/V4 几何按需方向判定含 R12 裁剪/像素换算/value 与 placeholder 评分/扩充兼容角色）、指令解析（点击/粘合词/两阶段关系/CLI 透传/空输入）、客户端-服务端真实 UDS roundtrip（场景帧/大帧/增量） |

测试原则：

- 等待模型状态而非快照计数（快照计数在 Pipeline/upsert 完成前自增，直接读
  模型会产生竞态——已踩坑修复）。
- 时序敏感测试（订阅推送、去抖）用真实 UDS + 轮询等待，全量连跑验证稳定性。

## 真机验证方法

```bash
# 1. 启动守护进程（前台观察日志）
.build/release/gvgl --socket /tmp/gvgl-test.sock --reconcile 2 --verbose

# 2. 基础查询
python3 client/gvgl_query.py --socket /tmp/gvgl-test.sock status
python3 client/gvgl_query.py --socket /tmp/gvgl-test.sock list

# 3. 事件驱动同步延迟：移动窗口后观察 version 变化
osascript -e 'tell application "System Events" to set position of window 1 of process "Google Chrome" to {80, 120}'
python3 client/gvgl_query.py --socket /tmp/gvgl-test.sock subscribe --pull

# 4. 订阅断开存活（SIGPIPE 修复验证）：subscribe 连接断开后守护进程仍在
# 5. 多屏/次屏坐标：查 displayID 非主屏实体，验证像素换算
# 6. gvglui 审查台：点击桌面画布实体 → 指令面板输入"点击 登录 按钮" → 评分 → 执行
```

## 已知曾修复的问题（回归参考）

| 问题 | 修复 |
| :--- | :--- |
| 客户端断开订阅后守护进程被 SIGPIPE 杀死 | `signal(SIGPIPE, SIG_IGN)` |
| 脏标记风暴 → 97% CPU / 1GB 内存 | 快照墙钟 1s + 采集节流 0.15s + 错误冷却 30s |
| 密集 Web 页关系爆炸（单帧百 MB） | 关系硬上限（500/组、5000/App） |
| 全量测试偶发失败（读帧竞态） | 测试等待模型状态而非快照计数 |
| 镜像方向评分错误 | 查询方向翻转匹配（rightOf↔leftOf 等） |
