/*
 * rtsp30 - reCamera (SG2002) 1080p30 H.264 RTSP publisher.
 *
 * Same VI -> ISP -> VPSS -> VENC -> cvi_rtsp pipeline as the stock video_demo,
 * but the buffer/frame-rate parameters that throttle the stock pipeline to
 * 10 fps are reconfigured here instead of in the vendor component sources.
 *
 * Every knob can be overridden from the environment so the pipeline can be
 * swept without rebuilding.
 */
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

#include <cvi_sys.h>
#include <cvi_venc.h>
#include <cvi_vpss.h>

#include "rtsp_demo.h"

/* Defined by the vendor rtsp_demo.c; used to detect a failed server create. */
extern "C" APP_PARAM_RTSP_T *pstRtspCtx;
#define g_rtspCtx pstRtspCtx
#include "video.h"

namespace {

int envInt(const char *name, int def) {
    const char *value = getenv(name);
    if (value == nullptr || *value == '\0') {
        return def;
    }
    const int parsed = atoi(value);
    return parsed > 0 ? parsed : def;
}

/* Variant that accepts -1 ("no limit") and 0, which the vendor APIs treat as
   meaningful values rather than as "unset". */
int envIntSigned(const char *name, int def) {
    const char *value = getenv(name);
    if (value == nullptr || *value == '\0') {
        return def;
    }
    return atoi(value);
}

struct Options {
    uint32_t width;
    uint32_t height;
    uint32_t fps;
    uint32_t vbBlkNum;
    uint32_t vpssDepth;
    uint32_t bitrateKbps;
    uint32_t gop;
    uint32_t esBufBytes;
    int viVpssMode;
    int vpssChnCompress;
    int grpSrcFps;
    int grpDstFps;
    int chnSrcFps;
    int chnDstFps;
    bool noTuning;
};

Options loadOptions() {
    Options opt{};
    opt.width          = (uint32_t)envInt("RC_WIDTH", 1920);
    opt.height         = (uint32_t)envInt("RC_HEIGHT", 1080);
    opt.fps            = (uint32_t)envInt("RC_FPS", 30);
    opt.vbBlkNum       = (uint32_t)envInt("RC_VB_BLKS", 8);
    /* 0 is meaningful here (no user-retrieval queue), so clamp instead of
       treating non-positive as "unset". */
    const int depth = envIntSigned("RC_VPSS_DEPTH", 1);
    opt.vpssDepth      = (uint32_t)(depth < 0 ? 0 : (depth > 8 ? 8 : depth));
    opt.bitrateKbps    = (uint32_t)envInt("RC_BITRATE", 4096);
    opt.gop            = (uint32_t)envInt("RC_GOP", 30);
    opt.esBufBytes     = (uint32_t)envInt("RC_ESBUF_KB", 1024) * 1024;
    opt.viVpssMode     = envIntSigned("RC_VIVPSS_MODE", VI_OFFLINE_VPSS_ONLINE);
    opt.vpssChnCompress = envIntSigned("RC_VI_COMPRESS", COMPRESS_MODE_TILE);
    opt.noTuning       = getenv("RC_NO_TUNING") != nullptr;
    opt.grpSrcFps       = envIntSigned("RC_VPSS_GRP_SRC_FPS", -1);
    opt.grpDstFps       = envIntSigned("RC_VPSS_GRP_DST_FPS", -1);
    opt.chnSrcFps       = envIntSigned("RC_VPSS_CHN_SRC_FPS", -1);
    opt.chnDstFps       = envIntSigned("RC_VPSS_CHN_DST_FPS", -1);
    return opt;
}

void applyTuning(const Options &opt, video_ch_index_t ch) {
    if (opt.noTuning) {
        /* Reproduce the stock video_demo parameter set exactly, so a single
           knob can be re-enabled on top of it and measured. */
        std::printf("[rtsp30] RC_NO_TUNING: stock vendor parameters, %ux%u\n",
                    opt.width, opt.height);
        std::fflush(stdout);
        return;
    }

    APP_PARAM_SYS_CFG_S *sys = app_ipcam_Sys_Param_Get();
    sys->vb_pool[ch].vb_blk_num      = opt.vbBlkNum;
    sys->stVIVPSSMode.aenMode[0]     = (VI_VPSS_MODE_E)opt.viVpssMode;

    APP_PARAM_VPSS_CFG_T *vpss = app_ipcam_Vpss_Param_Get();
    APP_VPSS_GRP_CFG_T *grp    = &vpss->astVpssGrpCfg[0];
    grp->stVpssGrpAttr.u32MaxW = opt.width;
    grp->stVpssGrpAttr.u32MaxH = opt.height;
    grp->stVpssGrpAttr.stFrameRate.s32SrcFrameRate = opt.grpSrcFps;
    grp->stVpssGrpAttr.stFrameRate.s32DstFrameRate = opt.grpDstFps;

    VPSS_CHN_ATTR_S *vpssChn = &grp->astVpssChnAttr[ch];
    vpssChn->u32Depth                        = opt.vpssDepth;
    vpssChn->stFrameRate.s32SrcFrameRate     = opt.chnSrcFps;
    vpssChn->stFrameRate.s32DstFrameRate     = opt.chnDstFps;

    APP_PARAM_VI_CTX_S *vi = app_ipcam_Vi_Param_Get();
    vi->astChnInfo[0].u32Width       = opt.width;
    vi->astChnInfo[0].u32Height      = opt.height;
    vi->astChnInfo[0].f32Fps         = (CVI_FLOAT)opt.fps;
    vi->astChnInfo[0].enCompressMode = (COMPRESS_MODE_E)opt.vpssChnCompress;
    vi->astSensorCfg[0].s32Framerate = (CVI_S32)opt.fps;
    vi->astPipeInfo[0].enMastPipeMode = (VI_VPSS_MODE_E)opt.viVpssMode;

    APP_PARAM_VENC_CTX_S *venc = app_ipcam_Venc_Param_Get();
    APP_VENC_CHN_CFG_S *vchn   = &venc->astVencChnCfg[ch];
    vchn->u32Width         = opt.width;
    vchn->u32Height        = opt.height;
    vchn->u32SrcFrameRate  = opt.fps;
    vchn->u32DstFrameRate  = opt.fps;
    vchn->u32BitRate       = opt.bitrateKbps;
    vchn->u32MaxBitRate    = opt.bitrateKbps;
    vchn->u32Gop           = opt.gop;
    vchn->u32StreamBufSize = opt.esBufBytes;

    std::printf("[rtsp30] %ux%u@%u  vb_blks=%u vpss_depth=%u  venc=%ukbps gop=%u esbuf=%uK"
                "  vi_vpss_mode=%d  vpss_frate=%d/%d,%d/%d\n",
                opt.width, opt.height, opt.fps, opt.vbBlkNum, opt.vpssDepth,
                opt.bitrateKbps, opt.gop, opt.esBufBytes / 1024, opt.viVpssMode,
                opt.grpSrcFps, opt.grpDstFps, opt.chnSrcFps, opt.chnDstFps);
    std::fflush(stdout);
}

/* Teardown for a pipeline that reached the running state. This mirrors the
   vendor deinitVideo() order exactly: VENC must stop pulling VPSS frames, and
   every VPSS channel must be disabled before its group is destroyed. Calling
   CVI_VPSS_StopGrp()/DestroyGrp() directly on a group with enabled channels
   wedges the VPSS driver and can take the kernel down with it. */
void teardownRunning() {
    app_ipcam_Venc_Stop(APP_VENC_ALL);
    app_ipcam_Vpss_DeInit();
    app_ipcam_Vi_DeInit();
    app_ipcam_Sys_DeInit();
}

/* A SIGKILLed instance also leaves the VPSS -> VENC bind and the VENC channel
   alive in the driver. The recreated channel then never dequeues its input
   (dmesg: "vb_qbuf: VENC waitq is full. drop new one.") and the pipeline stalls
   at 0 fps until the board is rebooted. Drop both before re-initialising; the
   calls fail harmlessly when nothing is stale. Must run before the VPSS group
   is destroyed, while the bound source channel still exists. */
void clearStaleVencPath(video_ch_index_t ch) {
    APP_VENC_CHN_CFG_S *cfg = &app_ipcam_Venc_Param_Get()->astVencChnCfg[ch];

    CVI_SYS_UnBind(&cfg->astChn[0], &cfg->astChn[1]);
    CVI_VENC_StopRecvFrame(cfg->VencChn);
    CVI_VENC_ResetChn(cfg->VencChn);
    CVI_VENC_DestroyChn(cfg->VencChn);
}

/* Recover from a previous run that died without cleaning up (SIGKILL, crash).
   Channels are disabled first so the group can be destroyed safely. Errors are
   expected when nothing is stale and are ignored. */
void clearStaleVpssGroup(VPSS_GRP grp) {
    for (VPSS_CHN chn = 0; chn < VPSS_MAX_PHY_CHN_NUM; chn++) {
        CVI_VPSS_DisableChn(grp, chn);
    }
    CVI_VPSS_StopGrp(grp);
    CVI_VPSS_DestroyGrp(grp);
}

void onSignal(int signo) {
    signal(SIGINT, SIG_IGN);
    signal(SIGTERM, SIG_IGN);
    teardownRunning();
    deinitRtsp();
    std::printf("[rtsp30] terminated by signal %d\n", signo);
    std::fflush(stdout);
    _exit(0);
}

}  // namespace

int main() {
    const video_ch_index_t ch = VIDEO_CH2;
    const Options opt = loadOptions();

    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);

    if (initVideo() != 0) {
        std::fprintf(stderr, "[rtsp30] initVideo failed\n");
        return -1;
    }

    video_ch_param_t param{};
    param.format = VIDEO_FORMAT_H264;
    param.width  = opt.width;
    param.height = opt.height;
    param.fps    = (uint8_t)opt.fps;

    if (setupVideo(ch, &param) != 0) {
        std::fprintf(stderr, "[rtsp30] setupVideo failed\n");
        return -1;
    }
    registerVideoFrameHandler(ch, 0, fpStreamingSendToRtsp, nullptr);

    applyTuning(opt, ch);

    /* initRtsp() always returns 0; the server context is the real success flag.
       A still-bound 8554 from a previous run shows up here. */
    initRtsp((uint8_t)(0x01 << ch));
    if (g_rtspCtx == nullptr || g_rtspCtx->pstServerCtx == nullptr) {
        std::fprintf(stderr, "[rtsp30] RTSP server create failed (port %d busy?)\n", 8554);
        std::fflush(stderr);
        return -1;
    }

    /* Expanded from startVideo() so a failure is fatal instead of leaving a
       half-initialised pipeline spinning in the idle loop. */
    /* NOTE: the vendor init functions already run their own teardown on failure
       (app_ipcam_Vpss_Create's VPSS_EXIT path calls Vpss/Vi/Sys DeInit), so we
       must NOT tear down again here - a second CVI_VB_Exit()/CVI_SYS_Exit()
       pair double-frees driver state and crashes the kernel. Startup self-heal
       below recovers any residue left by a failed or SIGKILLed run. */
    if (app_ipcam_Sys_Init() != 0) {
        std::fprintf(stderr, "[rtsp30] sys init failed\n");
        std::fflush(stderr);
        return -1;
    }
    if (app_ipcam_Vi_Init() != 0) {
        std::fprintf(stderr, "[rtsp30] vi init failed\n");
        std::fflush(stderr);
        return -1;
    }

    /* Self-heal: an instance killed with SIGKILL leaves group 0 allocated in the
       VPSS driver, which makes CVI_VPSS_CreateGrp fail with EN_ERR_EXIST
       (0xC0068004) on the next start. */
    clearStaleVencPath(ch);
    clearStaleVpssGroup(0);

    if (app_ipcam_Vpss_Init() != 0) {
        std::fprintf(stderr, "[rtsp30] vpss init failed\n");
        std::fflush(stderr);
        return -1;
    }

    if (app_ipcam_Venc_Init(APP_VENC_ALL) != 0) {
        std::fprintf(stderr, "[rtsp30] venc init failed\n");
        std::fflush(stderr);
        teardownRunning();
        return -1;
    }
    if (app_ipcam_Venc_Start(APP_VENC_ALL) != 0) {
        std::fprintf(stderr, "[rtsp30] venc start failed\n");
        std::fflush(stderr);
        teardownRunning();
        return -1;
    }

    std::printf("[rtsp30] pipeline started, rtsp://<dev>:8554/live0\n");
    std::fflush(stdout);

    while (true) {
        sleep(1);
    }
    return 0;
}
