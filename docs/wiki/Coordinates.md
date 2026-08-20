# 坐标系

## M0 实测结论（2026-08-11）

`kAXPositionAttribute` 返回 **Quartz 全局显示坐标——原点左上、Y 轴向下**，
与 CGWindow 边界逐像素一致（delta x=0, delta y=0）。早期设计稿的"Cocoa 左下
原点 + Y 翻转"假设被实测否定，**所有转换不做 Y 翻转**。

## 三层坐标空间

| 空间 | 原点 | 范围 | 解决的问题 |
| :--- | :--- | :--- | :--- |
| Screen Space | 主屏左上角 | [0,1]×[0,1]（次屏元素可为负/超界） | 分辨率变化 |
| Window Space | 所属窗口左上角 | [0,1]×[0,1] | 窗口移动/缩放漂移 |
| Local Space | 最近实体祖先（entityParentID）左上角 | [0,1]×[0,1]（可越界；无实体祖先时为 unit） | 容器内相对定位（V3 落地） |

## 转换公式（原始文档公式，实测锁定）

```
转换 1  Quartz 像素 → Screen Space 归一化（主屏尺寸）
    screen.x = rect.x / screenW
    screen.y = rect.y / screenH
转换 2  Screen Space → Window Space（相对所属窗口的 Screen rect）
    window.x = (e.x - w.x) / w.w
    window.y = (e.y - w.y) / w.h
转换 2b Screen Space → Local Space（相对最近实体祖先的 Screen rect，V3）
    local.x = (e.x - p.x) / p.w
    local.y = (e.y - p.y) / p.h
    local.w = e.w / p.w ；local.h = e.h / p.h
转换 3  Screen Space → 物理像素（执行时，Quartz 系）
    pixelX = centerX * screenW
    pixelY = centerY * screenH
```

- 窗口自身的 window space = unit rect。
- 无窗口祖先的实体 window space 回退为 screen space。
- 无实体祖先（窗口根、菜单栏根、孤儿实体）的 local = unit rect；
  父子同空间相除，分辨率在比值中抵消，天然分辨率无关。
- 子元素内部点位（如"按钮的 30%,50%"）无需存储：客户端用
  `screen 原点 + 分率 × screen 尺寸` 即可表达——这正是原始文档预留
  local 的意图，V3 将其升格为承载真实几何的父容器空间。
- 多显示器：坐标一律主屏归一化（原始文档 V1 只支持主屏）；`screen.displays[]`
  与实体 `displayID` 是信息性元数据，不改变坐标语义。

## 派生几何量

```
centerX = x + w/2    centerY = y + h/2
area = w * h         aspect = w / h
```

## 空间标签

四象限（由 screen 中心计算）：

```
Q1: centerX < 0.5 AND centerY < 0.5   （帧内序列化为 "q1"）
Q2: centerX >= 0.5 AND centerY < 0.5  （"q2"）
Q3: centerX < 0.5 AND centerY >= 0.5  （"q3"）
Q4: centerX >= 0.5 AND centerY >= 0.5 （"q4"）
```

九宫格（阈值 0.33/0.66）：`left/center/right × top/center/bottom`，
帧内序列化为驼峰如 `rightBottom`（与原始文档的 "right-bottom" 命名等价）。
