# 从源码重新编译

**绝大多数用户不需要编译**：`bin/rtsp30` 已经是编译好的 riscv64 musl 可执行文件，
直接在板子上跑 `install.sh` 即可。本文只在你要改 `src/main.cpp` 时才需要。

## 依赖

| 依赖 | 放到哪里 | 来源 |
| --- | --- | --- |
| Sophgo SG2002 reCamera SDK（解压后） | `vendor/sg2002_sdk/sg2002_recamera_emmc` | `https://github.com/Seeed-Studio/sg2002_reCamera_sdk`（或 Seeed 提供的 `sg2002_reCamera_*_emmc_sdk.tar.gz`） |
| sscma-example-sg200x 源码 | `vendor/sscma-example-sg200x` | `git clone https://github.com/Seeed-Studio/sscma-example-sg200x.git` |
| riscv64 musl 交叉工具链 | `$TOOLCHAIN_PATH` | Sophgo `host-tools`：`gcc/riscv64-linux-musl-x86_64` |

`vendor/` 已在 `.gitignore` 中（约 1.8 GB，不进仓库）。目录结构必须是：

```
vendor/
├── sg2002_sdk/sg2002_recamera_emmc/{cvi_mpi,cvi_rtsp,osdrv,buildroot-2021.05}
└── sscma-example-sg200x/{components/sophgo,solutions/video_demo}
```

编译用到 SDK 里的：
- 头文件 `cvi_mpi/include`、`osdrv/interdrv/include/...`、`cvi_rtsp/install/include`
- 静态/动态库 `cvi_mpi/lib`、`cvi_mpi/lib/3rd`、`cvi_rtsp/install/lib`
- buildroot sysroot `buildroot-2021.05/output/cvitek_CV181X_musl_riscv64/host/riscv64-buildroot-linux-musl/sysroot`

以及 sscma-example 里的 `components/sophgo/{common,video}`（VI/ISP/VPSS/VENC 封装）
和 `solutions/video_demo/main/rtsp_demo.c`（cvi_rtsp 封装）。
**这些 vendor 源码一行都没改**，所有调参都在 `src/main.cpp` 里做。

## 编译

```bash
export TOOLCHAIN_PATH=/path/to/host-tools/gcc/riscv64-linux-musl-x86_64
bash src/build.sh                 # -> out/rtsp30
file out/rtsp30
# ELF 64-bit LSB executable, UCB RISC-V, RVC, double-float ABI,
# interpreter /lib/ld-musl-riscv64v0p7_xthead.so.1, stripped
```

可覆盖的变量：`SG200X_SDK_PATH`、`SRC_PATH`、`TOOLCHAIN_PATH`、`OUT`。
架构 flag 固定为 `-mcpu=c906fdv -march=rv64gcv0p7_zfh_xthead -mabi=lp64d`
（SG2002 的 C906 核，带 0.7 版 vector 和 xthead 扩展，不能换成通用 rv64gc）。

编译完更新交付物：

```bash
cp out/rtsp30 bin/rtsp30
(cd bin && sha256sum rtsp30 > rtsp30.sha256)   # install.sh 会校验这个值
```

## main.cpp 做了什么

`src/main.cpp` 与原厂 `video_demo` 走完全相同的
`VI/ISP → VPSS(grp0 chn2) → VENC(chn2) → cvi_rtsp` 链路，区别只有三点：

1. **`applyTuning()`**：在 `app_ipcam_Param_Load()` 之后、管线启动之前，
   改写 VB 块数、VPSS depth、VENC 码率/GOP/ES 缓冲、VI-VPSS 工作模式。
   全部可用 `RC_*` 环境变量覆盖，方便不重编译直接扫参。
2. **启动自愈 `clearStaleVpssGroup()` / `clearStaleVencPath()`**：上一个实例若异常退出，
   会残留 VPSS group（`CVI_VPSS_CreateGrp` 报 `EN_ERR_EXIST 0xC0068004`）和
   VPSS→VENC 的 bind，启动时先清掉再初始化。
3. **失败即退出 + 干净 teardown**：`SIGTERM/SIGINT` 走
   `Venc_Stop → Vpss_DeInit → Vi_DeInit → Sys_DeInit`（与 vendor `deinitVideo()` 同序），
   1 秒内释放 8554 端口，供守护进程重启。

## 验证方法

```bash
# PC 侧实测客户端收到的帧率
./scripts/probe.sh rtsp://<device-ip>:8554/live0 20
TRANSPORT=tcp ./scripts/probe.sh rtsp://<device-ip>:8554/live0 20

# 板侧逐级帧率，定位丢帧位置
./tools/dsh.py 'sh /root/rtsp30-sample.sh 10'
./tools/dsh.py 'sh /root/rtsp30-status.sh'
```
