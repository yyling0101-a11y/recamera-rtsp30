#!/bin/bash
# Cross-compile rtsp30 for Seeed reCamera (SG2002 / CV181X, riscv64 musl).
#
# External dependencies (not in git, see docs/BUILD.md):
#   vendor/sg2002_sdk               extracted Sophgo sg2002_reCamera SDK
#   vendor/sscma-example-sg200x     provides components/sophgo + solutions/video_demo
#   TOOLCHAIN_PATH                  host-tools dir with bin/riscv64-unknown-linux-musl-gcc
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

SG200X_SDK_PATH="${SG200X_SDK_PATH:-$ROOT/vendor/sg2002_sdk/sg2002_recamera_emmc}"
SRC_PATH="${SRC_PATH:-$ROOT/vendor/sscma-example-sg200x}"
TOOLCHAIN_PATH="${TOOLCHAIN_PATH:-/home/seeed/work/host-tools/gcc/riscv64-linux-musl-x86_64}"
OUT="${OUT:-$ROOT/out}"

CROSS="$TOOLCHAIN_PATH/bin/riscv64-unknown-linux-musl-"
SYSROOT="$SG200X_SDK_PATH/buildroot-2021.05/output/cvitek_CV181X_musl_riscv64/host/riscv64-buildroot-linux-musl/sysroot"
SOPHGO="$SRC_PATH/components/sophgo"
RTSPDEMO="$SRC_PATH/solutions/video_demo/main"

for d in "$SG200X_SDK_PATH" "$SYSROOT" "$SOPHGO" "$RTSPDEMO"; do
    [ -d "$d" ] || { echo "missing: $d" >&2; exit 1; }
done
command -v "${CROSS}g++" >/dev/null || { echo "missing toolchain: ${CROSS}g++" >&2; exit 1; }

mkdir -p "$OUT/obj"

ARCH="-mcpu=c906fdv -march=rv64gcv0p7_zfh_xthead -mabi=lp64d"

INC=(
    -I"$SOPHGO/common"
    -I"$SOPHGO/video"
    -I"$SOPHGO/video/include"
    -I"$RTSPDEMO"
    -I"$SG200X_SDK_PATH/osdrv/interdrv/include/chip/cv181x/uapi"
    -I"$SG200X_SDK_PATH/osdrv/interdrv/include/common/uapi"
    -I"$SG200X_SDK_PATH/osdrv/interdrv/include/common/uapi/linux"
    -I"$SG200X_SDK_PATH/cvi_mpi/include"
    -I"$SG200X_SDK_PATH/cvi_mpi/modules/isp/cv181x/isp-daemon2/inc"
    -I"$SG200X_SDK_PATH/cvi_mpi/modules/isp/common/raw_dump/inc"
    -I"$SG200X_SDK_PATH/cvi_mpi/modules/isp/include/cv181x"
    -I"$SG200X_SDK_PATH/cvi_rtsp/install/include/cvi_rtsp"
    -I"$SYSROOT/usr/include"
)

LIBDIRS=(
    -L"$SG200X_SDK_PATH/cvi_mpi/lib"
    -L"$SG200X_SDK_PATH/cvi_mpi/lib/3rd"
    -L"$SG200X_SDK_PATH/cvi_rtsp/install/lib"
    -L"$SYSROOT/usr/lib"
)

LIBS=(
    -lcvi_rtsp
    -lae -laf -lawb -lcvi_bin -lcvi_bin_isp -lgdc -lisp -lisp_algo
    -lsys -lvenc -lvpss -lvi -lvo -lraw_dump -lvdec -lrgn -lcvi_ispd2
    -lsns_ov5647 -lsns_gc2053 -lini -ljson-c
    -lpthread -ldl -lm -latomic
)

CFLAGS="$ARCH -O2 -fno-strict-aliasing -D__CV181X__ -Wno-unused-result"

SRCS_C=()
while IFS= read -r f; do SRCS_C+=("$f"); done < <(find "$SOPHGO/video" "$SOPHGO/common" -name '*.c' | sort)
SRCS_C+=("$RTSPDEMO/rtsp_demo.c")

OBJS=()
for s in "${SRCS_C[@]}"; do
    obj="$OUT/obj/$(echo "${s#$SRC_PATH/}" | tr '/' '_' | sed 's/\.c$/.o/')"
    if [ ! -f "$obj" ] || [ "$s" -nt "$obj" ]; then
        echo "CC  $(basename "$s")"
        "${CROSS}gcc" $CFLAGS "${INC[@]}" -c "$s" -o "$obj"
    fi
    OBJS+=("$obj")
done

MAIN_OBJ="$OUT/obj/main.o"
if [ ! -f "$MAIN_OBJ" ] || [ "$HERE/main.cpp" -nt "$MAIN_OBJ" ]; then
    echo "CXX main.cpp"
    "${CROSS}g++" $CFLAGS -std=c++14 -fno-exceptions -fno-rtti "${INC[@]}" \
        -c "$HERE/main.cpp" -o "$MAIN_OBJ"
fi
OBJS+=("$MAIN_OBJ")

echo "LD  rtsp30"
"${CROSS}g++" $ARCH -O2 "${OBJS[@]}" "${LIBDIRS[@]}" "${LIBS[@]}" -o "$OUT/rtsp30"
"${CROSS}strip" --strip-unneeded "$OUT/rtsp30" 2>/dev/null || true
ls -l "$OUT/rtsp30"
file "$OUT/rtsp30" 2>/dev/null || true
