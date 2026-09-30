# 测试

## 单测（133 个，不依赖真实 AX，全部用合成 fixture）

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

## 并发验证（Thread Sanitizer）

模型快照一致性、订阅游标等改动都是并发正确性改动，单测跑绿**不能**证明没有
数据竞争——`swift test` 不带竞态检测。改完必须再跑一次：

```bash
swift test --sanitize=thread
```

全绿标准：`0` 个 `WARNING: ThreadSanitizer`，且全部测试通过（TSan 默认在第一处
竞争即中止，进程会以 signal 6 退出，所以"跑完"本身就是关键信号）。

当前状态：**133 个用例，0 竞争，0 失败**。

> 踩过的坑：`SyncEngineTests.MockCapturer` 曾是 `@unchecked Sendable` + 裸可变
> 字段，采集在 `syncQueue`、测试线程在配置与轮询计数器，于是 TSan 稳定报 10 处
> 竞争并中止整个套件——**测试替身**的竞争会掩盖生产代码的结论，也让 TSan 这道
> 闸门没法用。现已全部字段加锁（闭包在锁内取出、锁外调用）。
> 新增共享状态的测试替身请一并加锁。

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

## 数据完整性审计

`audit_geometry.py` 查坐标**对不对**；`audit_coverage.py` 查字段**有没有值**。
后者针对的是本项目最危险的一类缺陷——**静默产出错误数据**：字段存在、类型正确、
能 JSON 往返、参与评分、打进日志，然后恒为空。

已栽在这类缺陷上的真实例子：

| 缺陷 | 症状 | 为什么测试没抓到 |
|---|---|---|
| 失步客户端被判"无变化" | 客户端永久停在旧视图 | 无任何报错 |
| 静止桌面每秒 6~7 次版本递增 | 订阅者被多 MB 帧淹没 | version 语义本就"每次变更递增" |
| `Entity.actions` 全空 | "这个元素能做什么操作"永远答不出 | 字段类型正确、参与评分、只是恒空 |

```bash
.build/release/gvgl --socket /tmp/gvgl-audit.sock &
python3 scripts/audit_coverage.py --socket /tmp/gvgl-audit.sock
```

检查项：

- **hard**：可按下的元素（按钮/菜单项/复选框/链接…）必须有 actions 与 enabled；
  id 唯一；每个实体都有几何；至少一个 app 是 synced；frontmostApp 在场景中；
  **没有 app 报告 action 探测失败**。
- **coverage**：逐字段人口率。**某个字段 0% 会被标为 `<-- SUSPICIOUS`**——
  这是通用探测器：不需要事先知道哪个字段会坏。
- **info**：role 分布、app 状态、显示器分布、文本输入类元素的 actions 覆盖率。

文本输入类角色（TextField/TextArea/…）**不**纳入 hard 不变式：实测终端的
AXTextArea 由 AX 明确返回"成功但空列表"，把它当硬不变式只会制造假警报——而
假警报是让审计被人忽略的最快方式。

脚本**双向验证过**：对 actions 恒空的版本 exit 1（`0/702`，且
`actions 0/2743 0.0% <-- SUSPICIOUS`），对修复后版本 exit 0。

## 端到端验收（核心承诺）

前面每一项都在**孤立**验证链路的一环。真正把环闭上——拿 GVGL 给出的坐标
**真的点下去**并观察到效果——的只有这一项：

```bash
.build/release/gvgl --socket /tmp/gvgl-smoke.sock &
python3 scripts/agent_smoke.py --socket /tmp/gvgl-smoke.sock
```

流程：起一个一次性 `display dialog` → 让 daemon 定位指定按钮 → **守卫** →
点击 → 断言对话框真的关闭了。

**守卫是 fail-closed 的**（跑在真实桌面上，必须如此）：
- 目标必须是我们自己起的那个对话框；
- 返回的像素中心必须**严格落在** daemon 报告的对话框矩形内，否则**拒绝点击**。
  因此最坏情况是点在对话框自己身上（无害），绝不会误伤桌面上的其它东西；
- 永远只点"取消"这类非破坏性控件。
- 找不到目标时直接失败，绝不盲点。

实测连续 4 次通过；`--label 登录` 同样通过，点击坐标 (1870,436) 与人工从
截图推算的值完全一致（两个独立来源互相印证）；不存在的按钮 exit 1 且不点击。

`--dry-run` 只定位与校验守卫，不点击。

## 负载 / 健壮性检查

单测从不同时开超过个位数连接——守护进程曾经**带着全绿的测试**上线了一个可用性
缺陷：推送循环阻塞在处理请求的同一个并发队列上，63 个长连接就把整个守护进程
静默饿死（不报错、不退出、只是再也不响应）。这类问题只能靠压测发现。

```bash
.build/debug/gvgl --socket /tmp/gvgl-load.sock &
python3 scripts/load_check.py --socket /tmp/gvgl-load.sock
```

覆盖：基线延迟 / N 并发订阅不拖垮服务 / 超限显式拒绝 / 槽位归还 /
连接churn 后 fd 与线程不泄漏 / 半截请求不卡死。退出码 0 = 全过。

改动 socket 层（连接、订阅、线程模型）后必须跑这一项。

## 已知曾修复的问题（回归参考）

| 问题 | 修复 |
| :--- | :--- |
| 客户端断开订阅后守护进程被 SIGPIPE 杀死 | `signal(SIGPIPE, SIG_IGN)` |
| 脏标记风暴 → 97% CPU / 1GB 内存 | 快照墙钟 1s + 采集节流 0.15s + 错误冷却 30s |
| 密集 Web 页关系爆炸（单帧百 MB） | 关系硬上限（500/组、5000/App） |
| 全量测试偶发失败（读帧竞态） | 测试等待模型状态而非快照计数 |
| 镜像方向评分错误 | 查询方向翻转匹配（rightOf↔leftOf 等） |
