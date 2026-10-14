# 排障

## 安装脚本下载失败

板子上的 `curl`/`wget` 都可用，但常见两个坑：

1. **DNS 解析不到 github.com**。实测某网络下 `baidu.com` 能解析，
   `github.com` / `raw.githubusercontent.com` 返回 `No answer`（DNS 污染），
   但 `ping 223.5.5.5` 通、出站 HTTP 也通。此时用局域网镜像或离线安装：

   ```bash
   # PC 上（仓库根目录）
   ./scripts/serve.sh 8000
   # 板子上
   wget -qO- http://<PC_IP>:8000/install.sh | sh -s -- --base-url http://<PC_IP>:8000
   # 或者离线
   scp -r . root@<device-ip>:/tmp/repo
   ssh root@<device-ip> 'sh /tmp/repo/install.sh --from-dir /tmp/repo'
   ```

2. **HTTPS 证书校验失败**（固件没装 `ca-certificates`，也没有 `openssl`）。
   `curl` 会报 SSL 错误。用 HTTP 的局域网镜像即可绕开；`install.sh` 会做
   sha256 校验，所以走 HTTP 镜像也不会装错文件。

`install.sh` 默认会依次尝试 GitHub raw 和几个 ghproxy 镜像；
也可以用 `RTSP30_REPO=owner/name` 或 `--branch` 指定仓库和分支。

## 装完 0 fps / 拉不到流

按顺序排查：

```sh
sh /root/rtsp30-status.sh          # 一站式：进程/VI/VPSS/VENC/VB/端口/6秒实测帧率
tail -50 /tmp/rtsp30.log
dmesg | tail -20
```

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `dmesg: vb_qbuf: VENC waitq is full. drop new one.`，VENC 0fps | 上一个推流进程被 `kill -9`，VENC/VPSS 驱动状态残留 | `reboot`。守护进程的看门狗也会在 ~2 分钟内自动重启板子 |
| 日志 `RTSP server create failed (port 8554 busy?)` | 8554 被别的进程占着 | `netstat -ltnp \| grep 8554`，停掉对方；`install.sh` 已会自动停 `video_demo`/`rtsp30`/`fps30` |
| `init vpss module failed ... 0xc0068004` | VPSS group 残留（`EN_ERR_EXIST`） | 程序启动时会自动清理；仍失败就 `reboot` |
| 帧率恒定 10.00 fps | 缓冲池被钉死，见 `docs/ROOT_CAUSE.md` | 确认 `RC_VB_BLKS>=8`、`RC_VPSS_DEPTH=1`（`rtsp30.sh` 已显式导出） |
| 帧率 30 但客户端花屏 / `non-existing PPS 0 referenced` | 固件 `libcvi_rtsp.so` 不拆分 SPS/PPS/IDR，客户端从 GOP 中间加入 | 等一个 GOP（≤1s）自动恢复；严格 NVR 客户端可换用 `reCamera_2002w_sdk/third_party/cvi_rtsp` 里修好的库 |
| 画面卡顿但板侧 30fps | 网络。`eth0` 常协商到 100Mbps，UDP 丢包 | 用 TCP 拉流：`ffplay -rtsp_transport tcp rtsp://<ip>:8554/live0` |

## 服务管理

```sh
/etc/init.d/S99rtsp30 start|stop|restart
tail -f /tmp/rtsp30.log
sh /root/uninstall-rtsp30.sh          # 完全卸载（原厂固件未被修改，重启即回到出厂行为）
```

- **绝对不要 `kill -9 /root/rtsp30`**：只发 SIGTERM，程序会在 1 秒内干净 teardown。
- 守护脚本 `rtsp30.sh` 带单实例锁（`/var/run/rtsp30.sup`），重复执行 `start`
  不会起第二份。
- 看门狗：连续 30 秒没有新编码帧 → SIGTERM 重启进程；连续 3 次无效 → `reboot`。

## 与板子上其它服务冲突

VI/VPSS/VENC 管线和 8554 端口是独占的，同一时刻只能有一个推流程序。
如果 sscma 相关服务在跑，`install.sh` 会打印告警，按提示禁用：

```sh
mkdir -p /etc/init.d/disabled
mv /etc/init.d/S91sscma-node /etc/init.d/S92node-red /etc/init.d/S93sscma-supervisor /etc/init.d/disabled/
```

（`/etc` 是挂在 `/userdata` 上的 overlay，禁用和安装都是掉电保留的。）
