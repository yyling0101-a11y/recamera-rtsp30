# recamera-rtsp30 — reCamera (SG2002) RTSP 10 fps → 30 fps

Seeed reCamera（SG2002 / CV181X，riscv64）原厂 `video_demo` 推出的
`rtsp://<ip>:8554/live0` 只有 **10 fps**，而传感器 OV5647 一直在跑 30 fps。
本项目定位到根因（VB 缓冲池被 VPSS 通道的用户取帧队列钉死，反压到 ISP），
在 MPI 参数层修好它，并提供一个**免编译、一条命令安装**的成品。

```
修复前  10.00 fps   VIDevFPS=30 VIFPS=10   VPSS cost≈100ms   VB Free=0
修复后  29.99 fps   VIDevFPS=30 VIFPS=30   VPSS cost≈ 33ms   VB Free=5/8
```

- 码流：`rtsp://<device-ip>:8554/live0`，1920×1080 H.264 CBR 4 Mbps，GOP 30
- 链路：`VI/ISP → VPSS(grp0 chn2) → VENC(chn2) → cvi_rtsp`（与原厂完全一致）
- 交付物：`bin/rtsp30`，52 KB，riscv64 musl，已 strip，直接跑

## 安装（在 PC 上执行）

reCamera 无法访问 GitHub，因此请在能访问 GitHub、且与设备网络互通的 PC 上运行部署脚本。脚本会提示输入设备 IP、SSH 用户名和密码；PC 下载仓库里的可执行程序及配置，通过 SSH 上传到设备，再配置并启动 RTSP 服务。默认仓库为 `yyling0101-a11y/recamera-rtsp30` 的 `main` 分支。

### Linux

```bash
curl -fLO https://raw.githubusercontent.com/yyling0101-a11y/recamera-rtsp30/main/scripts/install-linux.sh
chmod +x install-linux.sh
./install-linux.sh
```

需要 Python 3 和 pip；首次运行会在 PC 上安装 Paramiko（SSH/SFTP 依赖）。

### Windows PowerShell

在 PowerShell 中执行：

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/yyling0101-a11y/recamera-rtsp30/main/scripts/install-windows.ps1 -OutFile install-windows.ps1
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

需要安装 Python 3。脚本会在 PC 上下载部署工具，首次运行会安装 Paramiko。

部署时会将 `/etc/init.d/S03node-red`、`/etc/init.d/S91sscma-node` 和 `/etc/init.d/S93sscma-supervisor` 移到 `/etc/init.d/disable/`，停止占用摄像头的旧进程，安装开机启动项并启动 rtsp30。成功后视频地址为 `rtsp://<device-ip>:8554/live0`。

如果仓库或分支不同，可在运行脚本前设置 `RTSP30_REPO=owner/repo` 和 `RTSP30_BRANCH=branch`。

## 验证

```bash
./scripts/probe.sh rtsp://<device-ip>:8554/live0 20      # PC 侧实测帧率
ffplay rtsp://<device-ip>:8554/live0                     # 直接看画面
```
```sh
sh /root/rtsp30-status.sh     # 板侧：进程 / VI / VPSS / VENC / VB / 端口 / 6秒实测
tail -f /tmp/rtsp30.log
```

实测记录（192.168.4.82，OV5647，`eth0` 100 Mbps）：

```
udp  frames=607  span=20.2s  avg_fps=29.99   delta_ms min=25.6 mean=33.34 max=41.6
udp  frames=1168 span=38.9s  avg_fps=29.99
tcp  frames=307  span=10.2s  avg_fps=29.99
VI   VIDevFPS=30 VIFPS=30 VIDropCnt=0
VENC SendFramePerSec=30 EncFramePerSec=30 HwEncTime≈12ms
VB   pool2 BlkCnt=8 Free=5 MinFree=5
```

## 用法

```sh
/etc/init.d/S99rtsp30 start|stop|restart    # 服务控制（stop 走 SIGTERM）
sh /root/uninstall-rtsp30.sh                # 完全卸载，原厂固件未被修改
RC_BITRATE=8192 RC_GOP=60 /root/rtsp30      # 临时改参数前台跑
```

可调参数（环境变量，`/root/rtsp30.sh` 里已显式导出默认值）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `RC_VB_BLKS` | 8 | 1080p VB 公共池块数（**关键**，必须 > depth + 在途帧数） |
| `RC_VPSS_DEPTH` | 1 | VPSS 通道用户取帧队列深度（**关键**，bind 到 VENC 的通道不需要） |
| `RC_WIDTH` / `RC_HEIGHT` | 1920 / 1080 | 输出分辨率 |
| `RC_FPS` | 30 | VI 通道 / VENC 帧率字段 |
| `RC_BITRATE` | 4096 | CBR 码率 kbps（原厂 1000，1080p30 偏糊） |
| `RC_GOP` | 30 | I 帧间隔 |
| `RC_ESBUF_KB` | 1024 | 码流缓冲（原厂 512） |
| `RC_VIVPSS_MODE` | 1 | 必须为 1（`VI_OFFLINE_VPSS_ONLINE`），设 0 管线不出帧 |
| `STALL_LIMIT` / `REBOOT_LIMIT` | 6 / 3 | 看门狗：30s 无新编码帧重启进程，连续 3 次无效重启板子 |

## 根因（一句话版）

原厂默认 `vb_blk_num = 4` 且 VPSS 通道 `u32Depth = 3`：3 块被用户队列钉住，
1 块在流水线里转，池子长期 `Free=0`；VPSS 拿不到输出缓冲 → 触发失败 2227/3362 次
→ 单帧耗时涨到 ~100ms → 反压使 ISP 每 3 帧只处理 1 帧 → 恒定 10 fps。
把块数提到 8、depth 降到 1（任一改动单独都够）即可跑满 30 fps。

完整推导、内核计数器、8 组 A/B 实测数据见 **[docs/ROOT_CAUSE.md](docs/ROOT_CAUSE.md)**。
里面还包含对 `reCamera_2002w_sdk` 的同类问题分析（`queueDepth=2` → `vb_blk_num=3`
而 `u32Depth` 未下调，会复现同样的 10 fps）。

## 目录结构

```
scripts/install-linux.sh   Linux PC 侧下载并部署
scripts/install-windows.ps1 Windows PC 侧下载并部署
tools/pc-deploy.py         PC 侧 GitHub 下载、SSH/SFTP 上传和安装
scripts/remote-install.sh  设备侧停服务、安装并启动（由 PC 脚本调用）
bin/rtsp30                 预编译可执行文件（riscv64 musl，已 strip）
bin/rtsp30.sha256          校验值，设备侧部署器会核对
etc/rtsp30.sh              板端守护脚本：显式参数 + 自动重启 + 停帧看门狗
etc/S99rtsp30              板端 /etc/init.d 开机自启
scripts/rtsp30-status.sh   板端一站式健康检查
scripts/uninstall-rtsp30.sh 板端卸载
scripts/sample.sh          板端逐级帧率采样，定位丢帧位置
scripts/probe.sh           PC 端 ffprobe 帧率实测
scripts/serve.sh           PC 端起局域网 HTTP 镜像
src/main.cpp               推流程序源码
src/build.sh               交叉编译脚本
tools/dsh.py               PC 端 SSH 执行助手（开发用）
tools/deploy.py            PC 端推送部署（开发用）
docs/ROOT_CAUSE.md         根因分析 + A/B 数据
docs/BUILD.md              编译环境与依赖
docs/TROUBLESHOOTING.md    排障手册
vendor/                    外部依赖（1.8 GB，已 gitignore，不进仓库）
```

## 重要注意事项

- **不要 `kill -9` 推流进程。** 强杀会把 VPSS→VENC 的 bind 和 VENC 通道留在驱动里，
  下次启动 `VENC 0fps`、`dmesg: vb_qbuf: VENC waitq is full`，只能重启板子。
  程序正确处理 SIGTERM（1 秒内释放 8554），设备侧部署器会先发 SIGTERM。
  万一真被强杀，看门狗会在 ~2 分钟内自动重启板子恢复。
- **管线和 8554 端口是独占的。** 装本项目前要停掉 `video_demo`、sscma 相关服务
  （PC 部署脚本会自动停用相关启动项）。
- **不修改原厂固件和 vendor 源码**：所有调参都在 `src/main.cpp` 里，通过
  `app_ipcam_*_Param_Get()` 拿到参数结构体后改写，卸载后重启即恢复出厂行为。
- `/etc` 和 `/root` 是挂在 `/userdata` 上的 overlay，所以安装和开机自启掉电保留；
  根文件系统只读，设备侧部署器需要时会自动 `rootfs_rw on`。

## 重新编译

```bash
export TOOLCHAIN_PATH=/path/to/host-tools/gcc/riscv64-linux-musl-x86_64
bash src/build.sh          # -> out/rtsp30
cp out/rtsp30 bin/rtsp30 && (cd bin && sha256sum rtsp30 > rtsp30.sha256)
```

依赖放 `vendor/`（约 1.8 GB，不进 git），详见 **[docs/BUILD.md](docs/BUILD.md)**。
