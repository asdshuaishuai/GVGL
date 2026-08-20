# 协议

Unix Domain Socket（默认 `~/.gvgl/gvgl.sock`，可用 `GVGL_SOCKET` 环境变量或
`--socket` 覆盖），NDJSON 一行一答；`subscribe` 为长连接多行推送。

## 方法

```
→ {"method":"get_frame"}                       ← {"result": GVGLFrame}
→ {"method":"get_frame","app":"pid:123"}       ← 单 App 过滤帧
→ {"method":"get_frame","since":123}           ← 增量拉取
→ {"method":"subscribe","since":123}           ← 长连接推送
→ {"method":"get_status"}                      ← 守护进程状态
```

### get_frame?since 增量拉取

```
无变化: {"result":{"event":"no_change","version":123}}
有变化: {"result":{"event":"changed","version":N,
                    "changed_apps":[...],"frame":{...}}}
```

### subscribe 长连接推送

```
{"result":{"event":"subscribed","version":N}}
之后每 version 变化推送一行：
{"event":"frame","version":N,"changed_apps":[...]}
静默期每 60s 一行：{"event":"ping","version":N}
```

## 错误码

```
{"error":{"code":"permission_denied","message":"..."}}
{"error":{"code":"invalid_method","message":"..."}}
{"error":{"code":"invalid_request","message":"..."}}
{"error":{"code":"internal","message":"..."}}
```

## 帧结构（V4 层次场景图）

```json
{
  "frameID": "UUID",
  "version": 123,                // 单调递增
  "createdAt": 1786462962790,    // 毫秒 epoch
  "syncedAt": 1786462962790,
  "screen": {"width": 3440, "height": 1440, "scaleFactor": 1, "displays": [...]},
  "scene": [SceneApp],           // 每 App 一根，children 递归嵌套
  "index": {"byRegion": {...}, "byRole": {...}, "byWindow": {...}, "byApp": {...}},
  "frontmostApp": "pid:722",     // 前台 App 的 appKey
  "status": "ok"
}
```

V4 变更：平铺 `entities[]`/`relations[]`/`apps[]` 下线。包含关系由树结构
表达；方向/near 等空间关系不再随帧序列化，由客户端按几何规则按需计算
（同窗口对用窗口空间、跨窗口对用屏幕空间，语义不变且无截断上限）。
`get_frame?depth=N` 按层剪枝：被剪节点 `children` 缺省并标
`prunedChildCount`（直接子节点数），用于概览 → 下钻。

### SceneApp

```json
{
  "appKey": "pid:722", "pid": 722, "bundleID": "com.x", "name": "示例",
  "status": "synced", "capturedAt": 1786462962000, "entityCount": 321,
  "cgWindowCount": null, "axWindowCount": null, "missingWindowTitles": null,
  "children": [Entity]           // 顶层：AXWindow / AXMenuBar / 孤儿实体，自然 AX 序
}
```

### Entity

```json
{
  "id": "pid:722:0-0-0-1",          // 稳定 ID（含 element_path 语义）
  "role": "AXButton",
  "title": "登录", "detail": null, "identifier": null,
  "value": null,                     // V3：AXValue 短串（≤512 字符，与 title 去重）
  "subrole": null,                   // V3：AXSubrole
  "focused": false, "selected": false, // V3：焦点/选中态
  "placeholder": null,               // V3：空输入框提示语
  "enabled": true, "actions": ["AXPress"],
  "axParentID": "pid:722:0-0-0",     // AX 原始父节点
  "entityParentID": "pid:722:0-0",   // 最近实体祖先（inside 依据）
  "windowID": "pid:722:0-0-0",
  "appID": "pid:722", "pid": 722, "displayID": 3,
  "zIndex": 12,                      // V3：窗口全局前后序（0=最前，仅 on-screen）
  "children": [...],                 // V4：场景树子节点（平铺场景缺省）
  "prunedChildCount": null,          // V4：depth 剪枝时 = 直接子节点数
  "geometry": {
    "screen": {"x": 0.2, "y": 0.3, "w": 0.05, "h": 0.05},
    "window": {"x": 0.5, "y": 0.6, "w": 0.1, "h": 0.1},
    "local": {"x": 0.1, "y": 0.2, "w": 0.5, "h": 0.5},  // V3：父容器归一化
    "centerX": 0.225, "centerY": 0.325,
    "area": 0.0025, "aspect": 1.0,
    "region": "q1", "region9": "leftTop"
  }
}
```

### 空间关系（V4：客户端按需计算）

帧不再携带 relations 数组。客户端用节点几何自行判定：

- 方向（above/below/leftOf/rightOf）：同窗口对比较 window rect，跨窗口对
  比较 screen rect；inside 祖先对不参与方向判定（R12）。
- near：中心距 < 0.05（同窗口用窗口空间中心，跨窗口用屏幕空间中心）。
- inside/contains：即场景树的父子结构（entityParentID 链）。

## 失败模式（帧级 status）

| 值 | 含义 |
| :--- | :--- |
| `ok` | 全部 App 同步完成 |
| `warming` | 有 App 首次捕获未完成（优先级最高） |
| `partial` | 有 App 快照超预算/墙钟被截断 |
| `permissionDenied` | 有 App 无 AX 权限 |
| `unavailable` | 模型为空 |

优先级：`warming > permissionDenied > partial > ok`。
