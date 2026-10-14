# 根因分析：为什么原厂只有 10 fps

结论：**不是传感器、不是编码器、不是网络，是视频缓冲池（VB pool）被 VPSS 通道的
用户取帧队列占满，反压到 ISP，使 ISP 每 3 帧只处理 1 帧。**

## 现象

原厂 `video_demo`（`sscma-example-sg200x/solutions/video_demo`）声明 1080p30，
实测 RTSP 输出恒定 10.00 fps：

```
url=rtsp://192.168.4.82:8554/live0 frames=127 span=12.603s avg_fps=10.00
delta_ms: min=90.7 max=110.9 mean=100.02      <- 帧间隔精确 100ms
```

同一时刻的内核计数器（`/proc/cvitek/*`）：

```
VIDevFPS : 30          VIFPS : 10             传感器 30fps，ISP 只出 10fps
VISofCh0Cnt 3360       VIPostCnt 1134         每 3 帧只处理 1 帧
VIDropCnt 0                                   VI 没有主动丢帧
VPSS DEV1 TrigCnt 3362  FailCnt 2227          2/3 的触发因为“忙”失败
VPSS GRP  CostTime 99945us  HwCost 67287us    单帧 ~100ms
VPSS chn2 SendOK 1132   FrameRate 10
VB pool2  BlkCnt 8      Free 0   MinFree 0    缓冲池彻底耗尽
VENC      EncFramePerSec 10
```

`VIDropCnt=0` + `FailCnt=2227` 是关键：帧不是被丢掉的，是**下游拿不到缓冲，
上游被迫等待**，等待时间累积成 100ms/帧，于是稳定在 10 fps。

## 参数层面的原因

原厂默认值在 `sscma-example-sg200x/components/sophgo/video/src/video_paramparse.c`：

| 参数 | 位置 | 默认值 | 影响 |
| --- | --- | --- | --- |
| `vbpool.vb_blk_num` | `video_paramparse.c:11` | **4** | 1080p NV21 公共池只有 4 块（每块 3110400 B） |
| `chn_attr.u32Depth` | `video_paramparse.c:98` | **3** | VPSS chn2 的用户取帧队列独占 3 块 |
| `astChnInfo[0].f32Fps` | `video_paramparse.c:78` | -1 | 帧率未显式设置 |
| `venc.u32SrcFrameRate` | `video_paramparse.c:161` | -1 | 同上 |

一块 1080p 帧要同时被 VI 写、VPSS 读/写、VENC 读。4 块的池子里 3 块被
`u32Depth=3` 的用户队列钉住，剩下 1 块在流水线里转，`Free` 长期为 0 —— 
VPSS 每次想输出新帧都拿不到块，只能等，等待就是那 100ms。

注意 H.264 通道是 **bind 到 VENC** 的（`enBindMode = VENC_BIND_VPSS`），
数据由内核直接送到编码器，**根本不需要用户取帧队列**，`u32Depth` 应该是 0/1。
原厂把它设成 3 是这套参数模板的疏漏。

## A/B 实测（同一个二进制，只改环境变量）

| 配置 | VIFPS | RTSP 实测 |
| --- | --- | --- |
| 原厂 `video_demo` | 10 | **10.00 fps** |
| `RC_NO_TUNING=1`（本程序 + 原厂参数） | 10 | **10.00 fps** |
| `RC_VB_BLKS=4 RC_VPSS_DEPTH=3`（= 原厂缓冲配置） | 10 | **9.99 fps** |
| `RC_VB_BLKS=4`（depth 保持 1） | 30 | **30.00 fps** |
| `RC_VPSS_DEPTH=3`（blk 保持 8） | 30 | **29.99 fps** |
| 默认 `RC_VB_BLKS=8 RC_VPSS_DEPTH=1` | 30 | **29.99 fps** |
| `RC_FPS=10`（其余默认） | 30 | **29.99 fps** |
| `RC_VIVPSS_MODE=0`（VI/VPSS 全 offline） | 30 | 无输出（管线卡死） |

三条结论：

1. **卡住 10fps 的是缓冲预算，不是帧率参数。** `RC_FPS=10` 时 VI 依然 30fps，
   说明 `f32Fps`/`u32SrcFrameRate` 不是那个 10 的来源。
2. **块数和 depth 只要不同时紧张就能跑满**：`4 块 + depth 1` 和 `8 块 + depth 3`
   都是 30fps；只有原厂的 `4 块 + depth 3` 会把池子钉死。
3. **`RC_VIVPSS_MODE` 必须保持 1**（`VI_OFFLINE_VPSS_ONLINE`，也是原厂 paramparse
   的实际取值）；强制 0 会让管线完全不出帧。

修复后：VPSS 单帧 cost 从 ~100ms 降到 ~24-33ms，`VB pool2 Free=5/8 MinFree=5`，
`VIDropCnt=0`，VENC `SendFramePerSec=30 EncFramePerSec=30 HwEncTime≈12ms`。

## 默认参数选择

```
RC_VB_BLKS=8        8 x 3.1MB ≈ 25MB，ION 余量足够，实测常驻 Free=5
RC_VPSS_DEPTH=1     bind 到 VENC 的通道不需要用户队列，留 1 便于抓帧调试
RC_BITRATE=4096     原厂 1000kbps 对 1080p30 太低，画质糊
RC_GOP=30           1 秒一个 I 帧，拉流首屏快
RC_ESBUF_KB=1024    原厂 512KB，码率提高后容易溢出
```

## 对 `reCamera_2002w_sdk` 的同类问题

`backend/sg200x/camera_backend.cpp` 只提高了块数，没有下调 VPSS 的 `u32Depth`：

```cpp
const auto vbBlocks = static_cast<uint32_t>(config.queueDepth < 3 ? 3 : config.queueDepth);
sys->vb_pool[channel_].vb_blk_num = vbBlocks;   // queueDepth 默认 2 -> vbBlocks = 3
// 缺少：vpss->astVpssGrpCfg[0].astVpssChnAttr[channel_].u32Depth = 1;
```

`include/recamera/camera.hpp` 里 `queueDepth = 2`，于是 `vbBlocks = 3` 而
`u32Depth` 仍是原厂默认 3 —— 3 块的池子被 depth 全部钉住，必然复现 10fps。
两种改法任选：在 `vb_blk_num` 赋值旁边把 `u32Depth` 设为 1；或把 `queueDepth`
提到 `depth + 2` 以上（例如 6）。
