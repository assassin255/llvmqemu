#!/usr/bin/env bash
set -euo pipefail

# Đảm bảo biến môi trường cơ bản khi chạy qua sudo su (HOME/USER có thể bị unset)
HOME="${HOME:-/root}"
USER="${USER:-$(id -un 2>/dev/null || echo root)}"
LOGNAME="${LOGNAME:-$USER}"
export HOME USER LOGNAME
NO_TUNING="${NO_TUNING:-0}"
ORIGINAL_ARGS=("$@")
ORIGINAL_PWD="$(pwd)"

# ════════════════════════════════════════════════════════════════
#  WINBOX  —  LLVM Hybrid Backend PATCHED
#  Rootless: dùng QEMU AppImage prebuilt thay vì build libs/QEMU từ source
#  aria2: static binary (primary, ~5s), fallback apt, fallback conda (chậm)
#  Conda: CHỈ dùng làm fallback cuối (aria2 conda rất chậm, 5-20 phút)
#  Fix: removed --user from pip install (virtualenv compatibility)
#  KVM: Auto detect /dev/kvm → enable KVM acceleration if available
#  NEW: CLI flags --auto --winXXXX để chạy hoàn toàn không tương tác
#  NEW: Tự động skip build nếu QEMU đã tồn tại (--rebuild để build lại)
#  NEW: LLVM Hybrid Backend — accelerated TCG via LLVM ORC JIT for hot blocks
#        --accel-llvm      : enable LLVM hybrid JIT (hot blocks compile to native)
#        --no-llvm         : disable LLVM, TCG-only
#        --llvm-threshold=N: set hot block threshold (default 1000)
#        --llvm-opt=O2     : set LLVM optimization level (O1/O2/O3)
#
#  Cách dùng:
#    bash winbox                          # chế độ interactive như cũ
#    bash winbox --auto --win2012         # auto, Windows Server 2012 R2
#    bash winbox --auto --win2022         # auto, Windows Server 2022
#    bash winbox --auto --win11           # auto, Windows 11 LTSB
#    bash winbox --auto --win10ltsb       # auto, Windows 10 LTSB 2015
#    bash winbox --auto --win10ltsc       # auto, Windows 10 LTSC 2023
#    bash winbox --auto --win2012 --rdp   # auto + mở tunnel RDP
# ════════════════════════════════════════════════════════════════

# ── MÀU SẮC ────────────────────────────────────────────────────
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
B='\033[1;34m'; C='\033[1;36m'; W='\033[0m'

# ── ROOTLESS BUILD PROGRESS ──────────────────────────────────────
_rl_step() {
    local _n="$1" _t="$2"
    printf "${B}[%s/%s]${W}\n" "$_n" "$_t"
}
_rl_ok()   { echo -e "${G}✔${W} $1"; }
_rl_fail() { echo -e "${R}✘${W} $1"; }
_rl_warn() { echo -e "${Y}⚠${W}  $1"; }

# ════════════════════════════════════════════════════════════════
#  PGO HELPERS
# ════════════════════════════════════════════════════════════════
_pgo_key_for_choice() {
    case "${1:-}" in
        1) echo "win2012pgo" ;;
        2) echo "win2022pgo" ;;
        3) echo "win11pgo" ;;
        4) echo "win10ltsbpgo" ;;
        5|*) echo "win10ltscpgo" ;;
    esac
}

_pgo_remote_url() {
    # Trả về URL tải PGO profile từ xa (archive.org) cho từng key
    case "${1:-}" in
        win2012pgo)   echo "https://archive.org/download/win2012pgo.tar/win2012pgo.tar.gz" ;;
        win2022pgo)   echo "https://archive.org/download/win2022pgo.tar/win2022pgo.tar.gz" ;;
        win11pgo)     echo "https://archive.org/download/win11pgo.tar/win11pgo.tar.gz" ;;
        win10ltsbpgo) echo "https://archive.org/download/win10ltsbpgo.tar/win10ltsbpgo.tar.gz" ;;
        win10ltscpgo) echo "https://archive.org/download/win10ltscpgo.tar/win10ltscpgo.tar.gz" ;;
        *)            echo "" ;;
    esac
}

_pgo_download_remote() {
    # Tải PGO archive từ xa về $PGO_PROFILE_ARCHIVE
    # Trả về 0 nếu tải thành công và archive hợp lệ
    local _url; _url="$(_pgo_remote_url "$PGO_PROFILE_KEY")"
    [[ -z "$_url" ]] && return 1

    echo -e "${B}ℹ${W}  Tải PGO profile từ xa: ${_url}"
    local _ok=0
    if command -v aria2c &>/dev/null; then
        aria2c "${ARIA2_OPTS[@]}" \
            "$_url" -d "$PGO_PROFILE_ROOT" -o "${PGO_PROFILE_KEY}.tar.gz" \
            >/dev/null 2>&1 && _ok=1
    elif command -v wget &>/dev/null; then
        wget -q --show-progress --continue \
            "$_url" -O "$PGO_PROFILE_ARCHIVE" 2>&1 && _ok=1
    elif command -v curl &>/dev/null; then
        curl -fL --progress-bar \
            "$_url" -o "$PGO_PROFILE_ARCHIVE" && _ok=1
    fi

    if [[ "$_ok" == "1" ]] \
        && [[ -f "$PGO_PROFILE_ARCHIVE" ]] \
        && [[ $(stat -c%s "$PGO_PROFILE_ARCHIVE" 2>/dev/null || echo 0) -gt 1024 ]] \
        && tar -tzf "$PGO_PROFILE_ARCHIVE" >/dev/null 2>&1; then
        echo -e "${G}✔${W}  PGO profile tải xong: $PGO_PROFILE_ARCHIVE"
        return 0
    else
        echo -e "${Y}⚠${W}  Tải PGO profile thất bại hoặc archive không hợp lệ — sẽ generate lại"
        rm -f "$PGO_PROFILE_ARCHIVE" 2>/dev/null || true
        return 1
    fi
}

_pgo_prepare_context() {
    local _choice="${1:-5}"
    PGO_PROFILE_ROOT="${WINBOX_PGO_DIR:-$ORIGINAL_PWD}"
    mkdir -p "$PGO_PROFILE_ROOT"
    PGO_PROFILE_KEY="$(_pgo_key_for_choice "$_choice")"
    PGO_PROFILE_DIR="$PGO_PROFILE_ROOT/$PGO_PROFILE_KEY"
    PGO_PROFILE_ARCHIVE="$PGO_PROFILE_ROOT/${PGO_PROFILE_KEY}.tar.gz"
    PGO_PROFILE_READY=0
    PGO_PROFILE_KIND="gcc"
    PGO_LAUNCH_ENV=""

    # Nếu chưa có archive local → thử tải từ archive.org
    if [[ ! -f "$PGO_PROFILE_ARCHIVE" ]]; then
        echo -e "${B}ℹ${W}  Không tìm thấy PGO archive local cho ${PGO_PROFILE_KEY} — thử tải từ xa..."
        _pgo_download_remote || true  # thất bại thì tiếp tục → generate phase
    fi

    if [[ -f "$PGO_PROFILE_ARCHIVE" ]]; then
        if [[ $(stat -c%s "$PGO_PROFILE_ARCHIVE" 2>/dev/null || echo 0) -gt 1024 ]] && tar -tzf "$PGO_PROFILE_ARCHIVE" >/dev/null 2>&1; then
            rm -rf "$PGO_PROFILE_DIR"
            if tar -xzf "$PGO_PROFILE_ARCHIVE" -C "$PGO_PROFILE_ROOT" >/dev/null 2>&1; then
                PGO_PROFILE_READY=1
            else
                echo -e "${Y}⚠${W}  Không giải nén được PGO archive: $PGO_PROFILE_ARCHIVE"
                rm -rf "$PGO_PROFILE_DIR"
                PGO_PROFILE_READY=0
            fi
        else
            echo -e "${Y}⚠${W}  PGO archive rỗng/corrupt, sẽ generate lại: $PGO_PROFILE_ARCHIVE"
            rm -f "$PGO_PROFILE_ARCHIVE" 2>/dev/null || true
            rm -rf "$PGO_PROFILE_DIR"
        fi
    fi
}

_pgo_stop_vm() {
    local _pid
    _pid=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$_pid" ]] && kill -0 "$_pid" 2>/dev/null; then
        # QMP 'quit' → QEMU tự exit, chạy atexit handlers → flush .gcda/.profraw
        # KHÔNG dùng system_powerdown: đó là ACPI signal cho Windows shutdown,
        # QEMU vẫn cần được exit riêng mới flush được profile buffers.
        # KHÔNG dùng kill -9: bypass atexit hoàn toàn → .gcda không được ghi.
        _qmp "quit" >/dev/null 2>&1 || true
        local _waited=0
        while kill -0 "$_pid" 2>/dev/null && [[ $_waited -lt 30 ]]; do
            sleep 1
            _waited=$(( _waited + 1 ))
        done
        if kill -0 "$_pid" 2>/dev/null; then
            kill -TERM "$_pid" 2>/dev/null || true
            sleep 5
        fi
        # Kill cứng chỉ là safety net — profile có thể không đầy đủ nếu đến đây
        if kill -0 "$_pid" 2>/dev/null; then
            echo -e "${Y}⚠${W}  QEMU không tự exit — kill -9 (profile có thể bị thiếu)"
            kill -9 "$_pid" 2>/dev/null || true
        fi
    fi
    sleep 2  # filesystem flush
}

_pgo_finalize_profile() {
    mkdir -p "$PGO_PROFILE_ROOT"
    local _has_profile=0
    if [[ "$PGO_PROFILE_KIND" == "clang" ]]; then
        if compgen -G "$PGO_PROFILE_DIR/*.profraw" >/dev/null || [[ -f "$PGO_PROFILE_DIR/default.profdata" ]]; then
            _has_profile=1
        fi
        if [[ $_has_profile -eq 1 ]] && command -v llvm-profdata &>/dev/null && compgen -G "$PGO_PROFILE_DIR/*.profraw" >/dev/null; then
            llvm-profdata merge -o "$PGO_PROFILE_DIR/default.profdata" "$PGO_PROFILE_DIR"/*.profraw >/dev/null 2>&1 || true
            _has_profile=1
        fi
    else
        # compgen -G với ** không hoạt động khi globstar tắt (mặc định bash)
        # find + wc -l an toàn hơn grep -q (tránh set -e kill pipe)
        local _gcda_count
        _gcda_count=$(find "$PGO_PROFILE_DIR" -type f -name '*.gcda' 2>/dev/null | wc -l || echo 0)
        [[ "$_gcda_count" -gt 0 ]] && _has_profile=1
    fi
    if [[ "$_has_profile" -ne 1 ]]; then
        echo -e "${R}✘${W} Không tìm thấy profile hợp lệ trong: $PGO_PROFILE_DIR"
        echo -e "${Y}💡 Chạy lại workload nhẹ trong VM rồi thử continue lần nữa.${W}"
        return 1
    fi
    rm -f "$PGO_PROFILE_ARCHIVE" 2>/dev/null || true
    tar -czf "$PGO_PROFILE_ARCHIVE" -C "$PGO_PROFILE_ROOT" "$PGO_PROFILE_KEY" >/dev/null 2>&1 || {
        echo -e "${R}✘${W} Không đóng gói được PGO archive: $PGO_PROFILE_ARCHIVE"
        return 1
    }
    if [[ ! -s "$PGO_PROFILE_ARCHIVE" ]]; then
        echo -e "${R}✘${W} PGO archive rỗng: $PGO_PROFILE_ARCHIVE"
        return 1
    fi
    return 0
}


# ════════════════════════════════════════════════════════════════
#  BOOTSTRAP TOOLS — đảm bảo wget/curl/gnupg/ca-certificates có sẵn
# ════════════════════════════════════════════════════════════════
_bootstrap_tools() {
    local _apt=""
    if [[ "$(id -u)" == "0" ]] && command -v apt-get &>/dev/null; then _apt="apt-get"
    elif sudo -n true 2>/dev/null && command -v apt-get &>/dev/null; then _apt="sudo apt-get"; fi
    [[ -z "$_apt" ]] && return 0
    local _need=0
    for _t in wget curl gnupg ca-certificates; do command -v "$_t" &>/dev/null || _need=1; done
    [[ "$_need" == "0" ]] && return 0
    echo -e "${B}ℹ${W}  Bootstrap: cài công cụ thiết yếu (wget/curl/gnupg/ca-certificates)..."
    export DEBIAN_FRONTEND=noninteractive
    $_apt update -qq > /dev/null 2>&1 || true
    for _pkg in wget curl gnupg ca-certificates lsb-release; do
        command -v "$_pkg" &>/dev/null || $_apt install -y -qq "$_pkg" > /dev/null 2>&1 || true
    done
    command -v wget &>/dev/null && echo -e "${G}✔${W} wget sẵn sàng" || \
    command -v curl &>/dev/null && echo -e "${G}✔${W} curl sẵn sàng (wget vắng)" || true
}
_http_get() {
    local _url="$1" _out="${2:-}"
    if command -v wget &>/dev/null; then
        [[ -n "$_out" ]] && wget -qO "$_out" "$_url" || wget -qO- "$_url"
    elif command -v curl &>/dev/null; then
        [[ -n "$_out" ]] && curl -fsSL -o "$_out" "$_url" || curl -fsSL "$_url"
    else echo -e "${R}✘${W} Không có wget/curl" >&2; return 1; fi
}
_bootstrap_tools


# ════════════════════════════════════════════════════════════════
#  CLI ARGUMENT PARSER
#  --auto          : bỏ qua tất cả câu hỏi, chạy hoàn toàn tự động
#  --win2012       : Windows Server 2012 R2
#  --win2022       : Windows Server 2022
#  --win11         : Windows 11 LTSB
#  --win10ltsb     : Windows 10 LTSB 2015
#  --win10ltsc     : Windows 10 LTSC 2023
#  --rdp           : tự động mở tunnel RDP sau khi VM chạy
#  --build         : force build QEMU dù đã có sẵn
#  --no-build      : bỏ qua build QEMU
# ════════════════════════════════════════════════════════════════
AUTO_MODE=0        # 1 = không hỏi bất cứ gì
AUTO_WIN=""        # win choice preset: 1-5
AUTO_BUILD=""      # "yes" | "no" | "" (hỏi)
PGO_MODE=0        # --pgo: build QEMU with PGO train/use flow
INSTANCE_ID=1      # VM instance id  (--id=N)
EXTRA_FWDS=()      # extra hostfwd   (--port-forward=HOST:GUEST)
_EXTRA_FWDS_STR=""   # built from EXTRA_FWDS, pre-initialized to avoid set -u crash
STATUS_MODE=0      # --status
STOP_MODE=0        # --stop
RESTART_MODE=0     # --restart
SNAPSHOT_CMD=""    # --snapshot=save:NAME|load:NAME|list
RESIZE_IMG=""      # --resize=+XG
MONITOR_MODE=0     # --monitor (interactive QMP)
DELETE_BUILD_MODE=0  # --delete-build: xoá toàn bộ QEMU build
DELETE_ISO_MODE=0    # --delete-iso: xoá toàn bộ ISO cache
USE_HTTP_BACKEND=0  # --http-img: bật HTTP backend (không tải file)
SAFE_DOWNLOAD=0   # --safe-download: tải theo chunks 900MB (cho môi trường giới hạn)
ISO_MODE=0        # --iso: boot từ ISO thay vì tải Windows image
ISO_WIN_URL=""    # URL Windows ISO
ISO_VIRTIO_URL="" # URL VirtIO ISO (optional)
# ═══ LLVM HYBRID BACKEND ─────────────────────────────────────────
LLVM_ENABLED=1      # Default ON — auto-detects & falls back silently
LLVM_THRESHOLD=""   # --llvm-threshold=N: override default 1000
LLVM_OPT_LEVEL="2"  # --llvm-opt=O2: O2 balanced (default)
LLVM_BUILD_OK=0     # set to 1 after successful LLVM-enabled QEMU build

for _arg in "$@"; do
    case "$_arg" in
        --auto)       AUTO_MODE=1    ;;
        --win2012)    AUTO_WIN=1     ;;
        --win2022)    AUTO_WIN=2     ;;
        --win11)      AUTO_WIN=3     ;;
        --win10ltsb)  AUTO_WIN=4     ;;
        --win10ltsc)  AUTO_WIN=5     ;;
        --build|--rebuild) AUTO_BUILD="yes" ;;
        --no-build)   AUTO_BUILD="no"  ;;
        --pgo)         PGO_MODE=1 ;;
        --http-img|--no-download) USE_HTTP_BACKEND=1 ;;
        --safe-download) SAFE_DOWNLOAD=1 ;;
        --id=*)       INSTANCE_ID="${_arg#--id=}" ;;
        --status)     STATUS_MODE=1 ;;
        --stop)       STOP_MODE=1   ;;
        --restart)    RESTART_MODE=1 ;;
        --monitor)    MONITOR_MODE=1 ;;
        --resize=*)   RESIZE_IMG="${_arg#--resize=}" ;;
        --snapshot=*) SNAPSHOT_CMD="${_arg#--snapshot=}" ;;
        --delete-build) DELETE_BUILD_MODE=1 ;;
        --delete-iso)   DELETE_ISO_MODE=1   ;;
        --port-forward=*|--fwd=*)
            _fwd="${_arg#*=}"; EXTRA_FWDS+=("$_fwd") ;;
        --iso=*)       ISO_MODE=1; ISO_WIN_URL="${_arg#--iso=}" ;;
        --iso)         ISO_MODE=1 ;;
        --virtio=*)    ISO_VIRTIO_URL="${_arg#--virtio=}" ;;
        --no-vnc)      WINBOX_VNC=0 ;;
        # ── LLVM Hybrid Backend ───────────────────────────
        --accel-llvm|--llvm)       LLVM_ENABLED=1 ;;
        --no-llvm)                 LLVM_ENABLED=0 ;;
        --llvm-threshold=*)        LLVM_THRESHOLD="${_arg#--llvm-threshold=}" ;;
        --llvm-opt=O1)             LLVM_OPT_LEVEL="1" ;;
        --llvm-opt=O2)             LLVM_OPT_LEVEL="2" ;;
        --llvm-opt=O3)             LLVM_OPT_LEVEL="3" ;;
        --help|-h)
            echo "Usage: bash winbox.sh [OPTIONS]"
            echo ""
            echo "  --auto          Chạy không tương tác (bắt buộc kết hợp với --winXXXX)"
            echo "  --win2012       Windows Server 2012 R2"
            echo "  --win2022       Windows Server 2022"
            echo "  --win11         Windows 11 LTSB"
            echo "  --win10ltsb     Windows 10 LTSB 2015"
            echo "  --win10ltsc     Windows 10 LTSC 2023"
            echo "  --build         Force build QEMU (dù đã có)"
            echo "  --rebuild       Alias của --build"
            echo "  --no-build      Bỏ qua build QEMU"
            echo "  --pgo           Bật PGO train/use flow và lưu profile theo từng Windows OS"
            echo "  --id=N          Multi-VM: instance id (RDP port=3388+N, default N=1)"
            echo "  --port-forward=H:G  Thêm hostfwd TCP (vd: --port-forward=8080:80)"
            echo "  --status        Xem thông tin VM đang chạy"
            echo "  --stop          Dừng VM gracefully (gửi ACPI shutdown)"
            echo "  --restart       Dừng rồi khởi động lại VM"
            echo "  --monitor       Vào interactive QMP shell"
            echo "  --snapshot=save:NAME|load:NAME|list  Quản lý snapshot"
            echo "  --resize=+XG    Mở rộng disk image (VM phải đang tắt)
  --safe-download Tải file theo chunks 900MB (cho môi trường giới hạn dung lượng)"
            echo "  --http-img      Dùng QEMU HTTP backend (không tải về)"
            echo "  --delete-build  Xoá toàn bộ QEMU build hiện tại (opt/home/rootless)"
            echo "  --delete-iso    Xoá toàn bộ ISO cache (~/.cache/winbox-iso)"
            echo "  --iso=URL       Boot từ Windows ISO (cần --virtio=URL cho driver)"
            echo "  --iso           Boot từ ISO (hỏi URL interactive)"
            echo "  --virtio=URL    VirtIO driver ISO URL (dùng với --iso)"
            echo ""
            echo "  ⬡ LLVM Hybrid Backend (tăng tốc TCG cho hot code blocks)"
            echo "  --accel-llvm    Bật LLVM hybrid JIT (tự động cài LLVM 16+ dev)"
            echo "  --no-llvm       Tắt LLVM — chỉ dùng TCG thuần"
            echo "  --llvm-threshold=N  Ngưỡng hot block (mặc định 1000 lần chạy)"
            echo "  --llvm-opt=O2   Mức tối ưu LLVM: O1 (nhanh), O2 (cân bằng), O3 (tối đa)"
            echo "  LLVM tự fallback về TCG nếu build thất bại — VM không bị ảnh hưởng"
            echo ""
            echo "  Dùng --rebuild để build lại từ đầu."
            exit 0
            ;;
        *) echo -e "${Y}⚠${W}  Unknown argument: $_arg (bỏ qua)"; ;;
    esac
done

# Hàm ask có nhận biết AUTO_MODE
ask() {
    local prompt="$1"
    local default="$2"
    if [[ "$AUTO_MODE" == "1" ]]; then
        echo "$default"
        return
    fi
    read -rp "$prompt" ans
    ans="${ans,,}"
    echo "${ans:-$default}"
}

# ════════════════════════════════════════════════════════════════
#  INSTANCE PATHS  (derived from --id=N, default N=1)
# ════════════════════════════════════════════════════════════════
INSTANCE_ID="${INSTANCE_ID:-1}"
WINVM_RDP_PORT=$(( 3388 + INSTANCE_ID ))
WINVM_STATE_FILE="/tmp/winvm-${INSTANCE_ID}.state"
WINVM_QMP_SOCK="/tmp/winvm-${INSTANCE_ID}.qmp"
WINVM_PID_FILE="/tmp/winvm-${INSTANCE_ID}.pid"
WINVM_LOG="/tmp/winvm-${INSTANCE_ID}.log"
WINBOX_DISK_BUS="${WINBOX_DISK_BUS:-ide}"
WIN_IMG_PATH_BASE="${WIN_IMG_PATH_BASE:-win.img}"
WINBOX_NET_DEVICE="${WINBOX_NET_DEVICE:-auto}"
WINBOX_VNC="${WINBOX_VNC:-1}"

# ── Helpers: QMP send ────────────────────────────────────────────
_qmp() {
    local cmd="$1"
    if ! command -v socat &>/dev/null; then echo "socat not found"; return 1; fi
    if [[ ! -S "$WINVM_QMP_SOCK" ]]; then echo "QMP socket not found: $WINVM_QMP_SOCK"; return 1; fi
    printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$cmd" \
        | socat - UNIX-CONNECT:"$WINVM_QMP_SOCK" 2>/dev/null | tail -1
}

# ── Early-exit handlers ──────────────────────────────────────────
if [[ "$STATUS_MODE" == "1" ]]; then
    echo -e "${C}══════════════════════════════════════${W}"
    echo -e "${C}🖥  VM STATUS (instance ${INSTANCE_ID})${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    if [[ -f "$WINVM_PID_FILE" ]]; then
        PID_VM=$(cat "$WINVM_PID_FILE" 2>/dev/null)
        if [[ -n "$PID_VM" ]] && kill -0 "$PID_VM" 2>/dev/null; then
            echo -e "${G}🟢 RUNNING${W}  PID=$PID_VM"
            ps -o pid,etime,pcpu,rss,cmd --no-headers -p "$PID_VM" 2>/dev/null || true
            if [[ -f "$WINVM_STATE_FILE" ]]; then
                python3 -c "import json,sys; d=json.load(open(sys.argv[1])); [print(f\"   {k}: {v}\") for k,v in d.items()]" "$WINVM_STATE_FILE" 2>/dev/null || cat "$WINVM_STATE_FILE"
            fi
        else
            echo -e "${R}🔴 STOPPED / CRASHED${W}  (PID $PID_VM không còn)"
        fi
    else
        echo -e "${R}🔴 NOT RUNNING${W}  (no PID file for instance $INSTANCE_ID)"
    fi
    echo -e "${C}══════════════════════════════════════${W}"
    exit 0
fi

if [[ "$STOP_MODE" == "1" || "$RESTART_MODE" == "1" ]]; then
    PID_VM=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$PID_VM" ]] && kill -0 "$PID_VM" 2>/dev/null; then
        echo -e "${B}ℹ${W}  Gửi system_powerdown qua QMP..."
        _qmp "system_powerdown" 2>/dev/null || true
        echo -ne "${B}◜${W} Chờ VM shutdown"
        for _i in $(seq 1 30); do
            kill -0 "$PID_VM" 2>/dev/null || { echo -e "\r${G}✔${W} VM stopped        "; break; }
            echo -ne "."; sleep 1
        done
        kill -0 "$PID_VM" 2>/dev/null && { kill -9 "$PID_VM" 2>/dev/null; echo -e "\r${Y}⚠${W} Force-killed VM"; }
    else
        echo -e "${Y}⚠${W}  Không có VM nào đang chạy (instance $INSTANCE_ID)"
    fi
    rm -f "$WINVM_PID_FILE" "$WINVM_STATE_FILE"
    [[ "$STOP_MODE" == "1" ]] && exit 0
    echo -e "${B}ℹ${W}  Khởi động lại VM..."
fi

if [[ "$MONITOR_MODE" == "1" ]]; then
    if [[ ! -S "$WINVM_QMP_SOCK" ]]; then
        echo -e "${R}✘${W}  QMP socket không tồn tại: $WINVM_QMP_SOCK"; exit 1
    fi
    echo -e "${C}QMP monitor — Ctrl+C để thoát${W}"
    echo -e "${B}ℹ${W}  Gõ lệnh JSON, vd: {"execute":"query-status"}"
    socat READLINE UNIX-CONNECT:"$WINVM_QMP_SOCK"
    exit 0
fi

if [[ -n "$SNAPSHOT_CMD" ]]; then
    if [[ ! -S "$WINVM_QMP_SOCK" ]] && [[ "$SNAPSHOT_CMD" != "list" ]]; then
        echo -e "${R}✘${W}  VM phải đang chạy để dùng snapshot"; exit 1
    fi
    case "$SNAPSHOT_CMD" in
        save:*)
            _sname="${SNAPSHOT_CMD#save:}"
            printf '{"execute":"qmp_capabilities"}\n{"execute":"savevm","arguments":{"name":"%s"}}\n' "$_sname" \
                | socat - UNIX-CONNECT:"$WINVM_QMP_SOCK" 2>/dev/null
            echo -e "${G}✔${W} Saved snapshot: $_sname" ;;
        load:*)
            _sname="${SNAPSHOT_CMD#load:}"
            printf '{"execute":"qmp_capabilities"}\n{"execute":"loadvm","arguments":{"name":"%s"}}\n' "$_sname" \
                | socat - UNIX-CONNECT:"$WINVM_QMP_SOCK" 2>/dev/null
            echo -e "${G}✔${W} Loaded snapshot: $_sname" ;;
        list)
            echo -e "${C}Snapshots trong win.img:${W}"
            qemu-img snapshot -l win.img 2>/dev/null || echo "(không có snapshot)"
            ;;
        *) echo -e "${R}✘${W}  Cú pháp: --snapshot=save:NAME|load:NAME|list"; exit 1 ;;
    esac
    exit 0
fi

if [[ -n "$RESIZE_IMG" ]]; then
    IMG="${WIN_IMG_OVERRIDE:-win.img}"
    [[ ! -f "$IMG" ]] && { echo -e "${R}✘${W}  Không tìm thấy $IMG"; exit 1; }
    PID_VM=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$PID_VM" ]] && kill -0 "$PID_VM" 2>/dev/null; then
        echo -e "${R}✘${W}  VM đang chạy — phải stop trước: bash winbox.sh --stop --id=$INSTANCE_ID"; exit 1
    fi
    echo -e "${B}ℹ${W}  Resize $IMG += $RESIZE_IMG..."
    qemu-img resize "$IMG" "$RESIZE_IMG" && echo -e "${G}✔${W} Resize xong: $IMG $(qemu-img info "$IMG" | grep "virtual size")"
    exit 0
fi

if [[ "$DELETE_BUILD_MODE" == "1" ]]; then
    echo -e "${C}══════════════════════════════════════${W}"
    echo -e "${C}🗑️  XOÁ QEMU BUILD${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    # Stop VM trước nếu đang chạy
    _PID=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$_PID" ]] && kill -0 "$_PID" 2>/dev/null; then
        echo -e "${B}ℹ${W}  Dừng VM (PID $_PID) trước khi xoá..."
        kill -SIGTERM "$_PID" 2>/dev/null || true; sleep 2
        kill -0 "$_PID" 2>/dev/null && kill -SIGKILL "$_PID" 2>/dev/null || true
        echo -e "${G}✔${W} VM đã dừng"
    fi
    pkill -f 'qemu-system-x86_64' 2>/dev/null || true
    echo ""
    _DELETED=0
    _del_dir() {
        local d="$1" label="$2"
        if [[ -e "$d" ]]; then
            local _sz; _sz=$(du -sh "$d" 2>/dev/null | cut -f1 || echo "?")
            find "$d" -mindepth 1 -delete 2>/dev/null || true
            rmdir "$d" 2>/dev/null || true
            echo -e "${G}✔${W} Xoá ${label}: ${B}${d}${W} (${_sz})"
            _DELETED=$(( _DELETED + 1 ))
        else
            echo -e "${Y}—${W}  ${label}: ${d} (không có)"
        fi
    }
    _del_dir "/opt/qemu-optimized"         "opt build"
    _del_dir "$HOME/qemu-optimized"        "home build"
    _del_dir "$HOME/qemu-static"           "rootless build"
    _del_dir "$HOME/qemu-env"              "python venv"
    _del_dir "$HOME/qemu-build"            "rootless build dir"
    _del_dir "/tmp/qemu-src"               "QEMU source"
    _del_dir "/tmp/qemu-build"             "build artifacts"
    _del_dir "/tmp/qemu-pgo-prof"          "PGO profiles"
    _del_dir "/tmp/qemu-bolt-prof"         "BOLT profiles"
    # Clean logs
    rm -f /tmp/qemu-*.log /tmp/bolt-*.log /tmp/pip-*.log \
          /tmp/glib-*.log /tmp/venv-*.log 2>/dev/null || true
    echo -e "${G}✔${W} Logs dọn sạch"
    echo ""
    echo -e "${C}══════════════════════════════════════${W}"
    if [[ "$_DELETED" -gt 0 ]]; then
        echo -e "${G}✅ Xoá xong $_DELETED thư mục build${W}"
    else
        echo -e "${Y}⚠️  Không tìm thấy build nào để xoá${W}"
    fi
    echo -e "${B}ℹ${W}  Chạy lại script để build mới: bash winbox.sh --rebuild"
    echo -e "${C}══════════════════════════════════════${W}"
    exit 0
fi

if [[ "$DELETE_ISO_MODE" == "1" ]]; then
    echo -e "${C}══════════════════════════════════════${W}"
    echo -e "${C}🗑️  XOÁ ISO CACHE${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    _ISO_DIR="$HOME/.cache/winbox-iso"
    if [[ ! -d "$_ISO_DIR" ]]; then
        echo -e "${Y}⚠️  Không tìm thấy ISO cache: $_ISO_DIR${W}"
        exit 0
    fi
    echo -e "${B}ℹ${W}  Thư mục: ${B}${_ISO_DIR}${W}"
    echo ""
    # Liệt kê files sẽ bị xóa
    _ISO_COUNT=0
    while IFS= read -r -d '' _f; do
        _fsz=$(stat -c%s "$_f" 2>/dev/null || echo 0)
        _fmb=$(( _fsz / 1024 / 1024 ))
        echo -e "   ${Y}•${W}  $(basename "$_f")  (${_fmb}MB)"
        _ISO_COUNT=$(( _ISO_COUNT + 1 ))
    done < <(find "$_ISO_DIR" -maxdepth 1 -type f -print0 2>/dev/null)
    if [[ "$_ISO_COUNT" -eq 0 ]]; then
        echo -e "${Y}⚠️  Không có file nào trong ISO cache${W}"
        exit 0
    fi
    echo ""
    read -rp "$(echo -e "${Y}?${W}  Xoá tất cả $_ISO_COUNT file trên? [y/N]: ")" _yn
    if [[ "${_yn,,}" != "y" ]]; then
        echo -e "${B}ℹ${W}  Huỷ — không xoá gì"
        exit 0
    fi
    _sz_total=$(du -sh "$_ISO_DIR" 2>/dev/null | cut -f1 || echo "?")
    rm -f "$_ISO_DIR"/*.iso "$_ISO_DIR"/*.aria2 "$_ISO_DIR"/*.qcow2 2>/dev/null || true
    echo -e "${G}✅ Đã xoá $_ISO_COUNT file (${_sz_total}) trong $_ISO_DIR${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    exit 0
fi

# ════════════════════════════════════════════════════════════════
#  RESET ADMINISTRATOR PASSWORD OFFLINE
#  - chntpw clear Administrator pass trên SAM trích từ win.img
#  - LimitBlankPasswordUse=0 → cho phép RDP với pass trống
#  - Nếu NEW_PASS≠"" thì inject RunOnce để Windows set pass khi boot
# ════════════════════════════════════════════════════════════════
# ── Verify RDP connection (poll port, then xfreerdp /auth-only) ──
# ── SPINNER ─────────────────────────────────────────────────────
_SPIN_PID=""

spin_start() {
    local msg="${1:-Processing...}"
    printf "[*] %s\n" "$msg"
    _SPIN_PID=""
    local frames=('◜' '◝' '◞' '◟')
    (
        while :; do
            for f in "${frames[@]}"; do
                printf "\r${B}%s${W} %s" "$f" "$msg"
                sleep 0.1
            done
        done
    ) &
    _SPIN_PID=$!
    disown "$_SPIN_PID"
}

spin_stop() {
    local msg="${1:-Done}"
    if [[ -n "$_SPIN_PID" ]] && kill -0 "$_SPIN_PID" 2>/dev/null; then
        kill "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
    fi
    _SPIN_PID=""
    printf "\r${G}✔${W} %s\n" "$msg"
}

spin_fail() {
    local msg="${1:-Failed}"
    if [[ -n "$_SPIN_PID" ]] && kill -0 "$_SPIN_PID" 2>/dev/null; then
        kill "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
    fi
    _SPIN_PID=""
    printf "\r${R}✘${W} %s\n" "$msg"
}


_download_chunked() {
    local url="$1" output="$2" chunk_mb="${3:-900}"
    local chunk_bytes=$(( chunk_mb * 1024 * 1024 ))

    # Get file size
    local total_size=""
    total_size=$(curl -sI --max-time 15 "$url" 2>/dev/null         | grep -i '^content-length:' | tail -1 | awk '{print $2}'         | tr -d '\r\n') || true
    [[ -z "$total_size" || "$total_size" -lt 1024 ]] &&         total_size=$(wget --spider --server-response "$url" 2>&1         | grep -i 'Content-Length:' | tail -1         | awk '{print $2}' | tr -d '\r\n') || true

    if [[ -z "$total_size" || "$total_size" -lt 1024 ]]; then
        echo -e "${Y}⚠${W}  Không lấy được Content-Length — fallback tải 1 luồng..."
        if command -v aria2c &>/dev/null; then
            aria2c "${ARIA2_OPTS[@]}" \
                "$url" -o "$output"
        else
            wget --progress=dot:giga --continue "$url" -O "$output"
        fi
        return $?
    fi

    local num_chunks=$(( (total_size + chunk_bytes - 1) / chunk_bytes ))
    echo -e "${B}ℹ${W}  Tổng: $(( total_size / 1024 / 1024 ))MB → ${num_chunks} phần × ${chunk_mb}MB"

    truncate -s "$total_size" "$output" 2>/dev/null || \
        dd if=/dev/zero of="$output" bs=1 count=0 seek="$total_size" 2>/dev/null || true

    local _tmp; _tmp=$(mktemp /tmp/win_chunk_XXXXXX)
    local i start end part_num ok seek_blocks
    for i in $(seq 0 $((num_chunks - 1))); do
        start=$(( i * chunk_bytes ))
        end=$(( start + chunk_bytes - 1 ))
        [[ $end -ge $total_size ]] && end=$(( total_size - 1 ))
        part_num=$(( i + 1 ))
        echo -e "${B}ℹ${W}  Phần ${part_num}/${num_chunks} ($(( (end-start+1)/1024/1024 ))MB)..."
        ok=0
        for _try in 1 2 3; do
            if command -v aria2c &>/dev/null; then
                aria2c --header="Range: bytes=${start}-${end}" \
                    "${ARIA2_OPTS[@]}" \
                    "$url" -o "$_tmp" 2>&1 && ok=1 && break
            else
                curl -fL --range "${start}-${end}" --retry 3 \
                    --progress-bar -o "$_tmp" "$url" && ok=1 && break
            fi
            echo -e "${Y}⚠${W}  Thử lại lần ${_try}..."; sleep 3
        done
        if [[ "$ok" -eq 0 ]]; then
            rm -f "$_tmp"
            echo -e "${R}✘${W}  Phần ${part_num} thất bại"; return 1
        fi
        seek_blocks=$(( start / 512 ))
        dd if="$_tmp" of="$output" bs=512 seek="$seek_blocks" conv=notrunc 2>/dev/null
        rm -f "$_tmp"
        echo -e "${G}✔${W}  Phần ${part_num}/${num_chunks} xong"
    done
    echo -e "${G}✔${W}  Ghép xong: $(( total_size / 1024 / 1024 / 1024 ))GB"
}


# ── HÀM HỖ TRỢ ─────────────────────────────────────────────────
silent() { "$@" > /dev/null 2>&1; }

ver_lt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

# ── HÀM pip_install: cài vào $PIP_TARGET (tránh --user bị disable trên HPC) ──
PIP_TARGET=""   # set trong _rootless_build

pip_install() {
    local target="${PIP_TARGET:-}"
    if python3 -c "import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)" 2>/dev/null; then
        # Đang trong venv → cài bình thường
        python3 -m pip install -q "$@"
    elif [[ -n "$target" ]]; then
        # HPC: cài vào thư mục riêng, tránh --user
        python3 -m pip install -q --target="$target" --no-warn-script-location "$@"
    else
        python3 -m pip install -q --user "$@" 2>/dev/null \
            || python3 -m pip install -q "$@"
    fi
}

# ════════════════════════════════════════════════════════════════
#  KVM DETECTION
#  Kiểm tra /dev/kvm bằng ls -l, xác nhận quyền root/kvm group
# ════════════════════════════════════════════════════════════════
KVM_AVAILABLE=0   # 1 = có thể dùng KVM
KVM_MODE=""       # "kvm" hoặc "tcg"

_detect_kvm() {
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔍 KIỂM TRA KVM ACCELERATION${W}"
    echo -e "${C}════════════════════════════════════${W}"

    # Bước 1: kiểm tra /dev/kvm tồn tại không
    if [[ ! -e /dev/kvm ]]; then
        echo -e "${Y}⚠${W}  /dev/kvm không tồn tại — dùng TCG"
        KVM_AVAILABLE=0
        KVM_MODE="tcg"
        return
    fi

    # Bước 2: ls -l /dev/kvm để xem owner/group/permission
    KVM_LS=$(ls -l /dev/kvm 2>/dev/null)
    :

    KVM_OWNER=$(echo "$KVM_LS" | awk '{print $3}')
    KVM_GROUP=$(echo "$KVM_LS" | awk '{print $4}')
    KVM_PERMS=$(echo "$KVM_LS" | awk '{print $1}')

    echo -e "   Owner : ${Y}${KVM_OWNER}${W} | Group : ${Y}${KVM_GROUP}${W}"
    echo -e "   Perms : ${B}${KVM_PERMS}${W}"

    # Bước 3: kiểm tra owner/group có nằm trong whitelist hợp lệ không
    #   HỢP LỆ:  owner=root  AND  group=root|kvm
    #   KHÔNG:   owner=nobody / nogroup / hoặc bất kỳ owner khác root
    CAN_USE_KVM=0

    if [[ "$KVM_OWNER" == "root" ]] && [[ "$KVM_GROUP" == "root" || "$KVM_GROUP" == "kvm" ]]; then
        echo -e "${G}✔${W}  /dev/kvm owner/group hợp lệ: ${Y}${KVM_OWNER}:${KVM_GROUP}${W}"

        # Bước 3a: nếu đang là root → dùng được ngay
        if [[ "$(id -u)" == "0" ]]; then
            CAN_USE_KVM=1
            echo -e "${G}✔${W}  Đang chạy với quyền root → có thể dùng KVM"

        # Bước 3b: không phải root → kiểm tra user có trong group kvm không
        else
            CURRENT_USER=$(id -un)
            CURRENT_GROUPS=$(id -Gn)
            if echo "$CURRENT_GROUPS" | grep -qw "$KVM_GROUP"; then
                CAN_USE_KVM=1
                echo -e "${G}✔${W}  User '${CURRENT_USER}' thuộc group '${KVM_GROUP}' → có thể dùng KVM"
            else
                echo -e "${Y}⚠${W}  User '${CURRENT_USER}' KHÔNG thuộc group '${KVM_GROUP}' → không dùng được KVM"
            fi
        fi

    else
        # owner/group không phải root:root hoặc root:kvm → coi như không dùng được
        echo -e "${R}✘${W}  /dev/kvm owner/group KHÔNG hợp lệ: ${Y}${KVM_OWNER}:${KVM_GROUP}${W}"
        echo -e "   Chỉ chấp nhận: ${G}root:root${W} hoặc ${G}root:kvm${W}"
        echo -e "   Phát hiện     : ${R}${KVM_OWNER}:${KVM_GROUP}${W} → fallback TCG"
        CAN_USE_KVM=0
    fi

    # Bước 4: nếu owner/group ok nhưng vẫn muốn double-check → thử -r -w
    if [[ $CAN_USE_KVM -eq 0 ]]; then
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            CAN_USE_KVM=1
            echo -e "${G}✔${W}  /dev/kvm readable+writable (fallback check) → có thể dùng KVM"
        fi
    fi

    # Bước 4: thử chạy kvm-ok hoặc kiểm tra /proc/cpuinfo flags
    if [[ $CAN_USE_KVM -eq 1 ]]; then
        # Kiểm tra CPU có vmx/svm flag không
        if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
            echo -e "${G}✔${W}  CPU có hỗ trợ hardware virtualization (vmx/svm)"
            KVM_AVAILABLE=1
            KVM_MODE="kvm"
            echo -e "${G}🚀 KVM ACCELERATION: BẬT${W}"
        else
            echo -e "${Y}⚠${W}  CPU không có vmx/svm flag — KVM sẽ không hoạt động đúng"
            echo -e "${Y}⚠${W}  Fallback sang TCG"
            KVM_AVAILABLE=0
            KVM_MODE="tcg"
        fi
    else
        echo -e "${Y}⚠${W}  Không đủ quyền dùng /dev/kvm — dùng TCG"
        KVM_AVAILABLE=0
        KVM_MODE="tcg"
    fi

    echo -e "${C}════════════════════════════════════${W}"
    echo ""
}

# ════════════════════════════════════════════════════════════════
#  PACKAGE MANAGER — root → sudo apt → rootless build từ source
# ════════════════════════════════════════════════════════════════

APT_CMD=""
APT_OK=0
ROOTLESS=0

# aria2c max-speed flags — dùng chung mọi nơi
ARIA2_OPTS=(
    --split=16
    --max-connection-per-server=16
    --min-split-size=1M
    --max-concurrent-downloads=16
    --file-allocation=none
    --continue=true
    --check-certificate=false
    --max-tries=5
    --retry-wait=3
    --timeout=60
    --connect-timeout=15
    --piece-length=1M
    --human-readable=true
    --download-result=full
    --console-log-level=notice
    --summary-interval=3
)

_detect_apt() {
    echo -ne "${B}◜${W} Kiểm tra quyền package manager..."

    if [[ "$(id -u)" == "0" ]] && apt-get update -qq > /dev/null 2>&1; then
        APT_CMD="apt-get"
        APT_OK=1
        echo -e "\r${G}✔${W} Dùng apt-get (root)              "
        return
    fi

    if sudo -n true 2>/dev/null && sudo apt-get update -qq > /dev/null 2>&1; then
        APT_CMD="sudo apt-get"
        APT_OK=1
        echo -e "\r${G}✔${W} Dùng sudo apt-get                "
        return
    fi

    echo -e "\r${Y}⚠${W}  Không có apt — chuyển sang rootless AppImage"
    APT_OK=0
    ROOTLESS=1
}

apt_install() {
    local pkg="$1"
    $APT_CMD install -y -qq "$pkg" > /dev/null 2>&1
}

# ════════════════════════════════════════════════════════════════
#  ⬡ LLVM HYBRID BACKEND — INSTALL & PATCH
#  Cài LLVM dev libraries và áp dụng các patch LLVM hybrid
#  vào QEMU source trước khi configure. Tự fallback nếu fail.
# ════════════════════════════════════════════════════════════════

_llvm_hybrid_install_dev() {
    # Chỉ chạy nếu LLVM_ENABLED=1 và có apt
    [[ "$LLVM_ENABLED" != "1" ]] && return 1
    
    echo -e "${C}⬡ LLVM Hybrid: cài LLVM dev libraries ...${W}"
    
    local _llvm_ok=0
    local LLVM_VER=""
    
    # Thử cài LLVM dev packages từ apt
    if [[ -n "${APT_CMD:-}" ]]; then
        for _v in 16 17 18 15 14 19 20; do
            if dpkg -s "llvm-${_v}-dev" &>/dev/null 2>&1; then
                _llvm_ok=1; LLVM_VER=$_v
                echo -e "${G}✔${W} llvm-${_v}-dev đã có"
                break
            fi
        done
        if [[ "$_llvm_ok" == "0" ]]; then
            echo -e "${B}ℹ${W} Thử apt install llvm-dev..."
            export DEBIAN_FRONTEND=noninteractive
            for _v in 16 17 18 15 14 19 20; do
                if $APT_CMD install -y -qq "llvm-${_v}-dev" "libllvm${_v}" "llvm-${_v}-tools" clang lld ninja-build cmake libclang-${_v}-dev 2>/tmp/llvm-install.log; then
                    _llvm_ok=1; LLVM_VER=$_v
                    echo -e "${G}✔${W} llvm-${_v}-dev đã cài"
                    break
                fi
            done
        fi
    fi
    
    # Fallback: thử thêm repo apt.llvm.org
    if [[ "$_llvm_ok" == "0" && -n "${APT_CMD:-}" ]]; then
        echo -e "${Y}⚠${W}  Thử thêm apt.llvm.org repo..."
        local _codename
        _codename=$(lsb_release -sc 2>/dev/null || echo "")
        if [[ -n "$_codename" ]]; then
            wget -qO - https://apt.llvm.org/llvm-snapshot.gpg.key 2>/dev/null | $APT_CMD key add - 2>/dev/null || true
            echo "deb http://apt.llvm.org/${_codename}/ llvm-toolchain-${_codename}-16 main" \
                > /etc/apt/sources.list.d/llvm.list 2>/dev/null || true
            $APT_CMD update -qq 2>/dev/null || true
            for _v in 16 17 18; do
                if $APT_CMD install -y -qq "llvm-${_v}-dev" "libllvm${_v}" 2>/tmp/llvm-repo.log; then
                    _llvm_ok=1; LLVM_VER=$_v; break
                fi
            done
        fi
    fi
    
    if [[ "$_llvm_ok" == "0" ]]; then
        echo -e "${Y}⚠${W}  LLVM dev không cài được — fallback TCG (LLVM Hybrid disabled)"
        LLVM_ENABLED=0
        return 1
    fi
    
    # Verify llvm-config
    local _llvm_config=""
    for _c in "llvm-config-${LLVM_VER}" "llvm-config"; do
        if command -v "$_c" &>/dev/null; then _llvm_config="$_c"; break; fi
    done
    if [[ -z "$_llvm_config" ]]; then
        echo -e "${Y}⚠${W}  llvm-config không tìm thấy — fallback TCG"
        LLVM_ENABLED=0
        return 1
    fi
    
    export LLVM_CONFIG="$_llvm_config"
    local _llvm_libdir
    _llvm_libdir=$("$_llvm_config" --libdir 2>/dev/null || true)
    [[ -n "$_llvm_libdir" && -d "$_llvm_libdir/pkgconfig" ]] && \
        export PKG_CONFIG_PATH="$_llvm_libdir/pkgconfig:${PKG_CONFIG_PATH:-}"
    
    echo -e "${G}✔${W} LLVM $($_llvm_config --version) dev sẵn sàng (config: $_llvm_config)"
    
    # Tạo symlink llvm-config nếu cần
    if [[ "$_llvm_config" != "llvm-config" ]]; then
        if [[ "$(id -u)" == "0" ]]; then
            ln -sf "$(command -v "$_llvm_config")" /usr/local/bin/llvm-config 2>/dev/null || true
        else
            sudo ln -sf "$(command -v "$_llvm_config")" /usr/local/bin/llvm-config 2>/dev/null || true
        fi
    fi
    
    LLVM_BUILD_OK=1
    return 0
}

# Hàm extract + patch LLVM hybrid source files vào QEMU source tree
# Chỉ gọi khi LLVM_ENABLED=1 và có apt build path
# ════════════════════════════════════════════════════════════════
#  LLVM HYBRID BACKEND — SOURCE EXTRACTION
#  Embeds all 16 LLVM hybrid source files + applies QEMU patches
#  via sed. Self-contained — no external Python dependency.
# ════════════════════════════════════════════════════════════════

_llvm_hybrid_extract_sources() {
    local QEMU_SRC_DIR="$1"
    [[ ! -d "$QEMU_SRC_DIR/tcg" ]] && return 1
    [[ "$LLVM_ENABLED" != "1" ]] && return 0

    echo -e "${C}⬡ LLVM Hybrid: extracting source files + patching QEMU ...${W}"

    local LLVM_DIR="$QEMU_SRC_DIR/tcg/llvm"
    mkdir -p "$LLVM_DIR"

    # ── llvm-common.h ──────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-common.h" << 'LLVM_H_END'
#ifndef TCG_LLVM_COMMON_H
#define TCG_LLVM_COMMON_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define LLVM_STATE_NONE      0  /* no LLVM code yet */
#define LLVM_STATE_COMPILING 1  /* currently being compiled by worker */
#define LLVM_STATE_READY     2  /* LLVM code ready for dispatch */
#define LLVM_STATE_DISABLED  3  /* permanently disabled (compilation failed) */

#define LLVM_HOT_THRESHOLD_DEFAULT 250
#define LLVM_QUEUE_CAPACITY        256
#define LLVM_MAX_WORKERS           4
#define LLVM_DEFAULT_OPT_LEVEL     2

/*
 * Per-TB LLVM metadata stored in an external hash table
 * keyed by TranslationBlock pointer.
 * We do NOT modify TranslationBlock struct to avoid ABI issues.
 */
typedef struct TBLLVMState {
    void                *llvm_code;       /* native code from ORC JIT */
    size_t               llvm_code_size;  /* size of LLVM-compiled code */
    void                *saved_ops;       /* SavedTCGOps — deep-copied at trans time */
    uint32_t             exec_count;      /* times this TB executed */
    uint32_t             state;           /* LLVM_STATE_* */
    bool                 llvm_failed;     /* compilation permanently failed */
    bool                 compiling;       /* currently being compiled */
    uint64_t             compile_ns;
    bool                 permanently_failed;
} TBLLVMState;

/* Global statistics exposed for introspection */
typedef struct LLVMStats {
    uint64_t tbs_compiled;
    uint64_t tbs_failed;
    uint64_t total_compile_ns;
    uint64_t llvm_exec_count;
    uint64_t tcg_exec_count;
    uint64_t queue_enqueues;
    uint64_t queue_drops;
    uint64_t invalidations;
    uint64_t permanently_failed_tbs;
} LLVMStats;

typedef struct LLVMGlobal {
    bool     enabled;
    bool     initialized;
    uint32_t hot_threshold;
    uint8_t  opt_level;
    uint8_t  max_workers;
    bool     verify_module;
} LLVMGlobal;

extern LLVMGlobal llvm_global;
extern LLVMStats  llvm_stats;

void  llvm_global_init(void);
void  llvm_global_shutdown(void);
bool  llvm_is_enabled(void);

/* TBLLVMState accessors — keyed by TranslationBlock pointer */
TBLLVMState *llvm_tb_state_get(void *tb);
TBLLVMState *llvm_tb_state_ensure(void *tb);
void         llvm_tb_state_remove(void *tb);
void         llvm_tb_state_remove_all(void);

#endif /* TCG_LLVM_COMMON_H */
LLVM_H_END

    # ── llvm-common.c ──────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-common.c" << 'LLVM_C_END'
#include "qemu/osdep.h"
#include "qemu/thread.h"
#include "llvm-common.h"

LLVMGlobal llvm_global = {.enabled=false,.initialized=false,.hot_threshold=LLVM_HOT_THRESHOLD_DEFAULT,.opt_level=LLVM_DEFAULT_OPT_LEVEL,.max_workers=LLVM_MAX_WORKERS,.verify_module=false};
LLVMStats llvm_stats;

static GHashTable *tb_state_map;
static QemuMutex   tb_state_lock;

static void tb_state_lock_init(void) {
    static bool done;
    if (!done) { qemu_mutex_init(&tb_state_lock);
        tb_state_map = g_hash_table_new_full(g_direct_hash,g_direct_equal,NULL,(GDestroyNotify)g_free);
        done = true; }
}
TBLLVMState *llvm_tb_state_get(void *tb) {
    if(!tb_state_map)return NULL;
    qemu_mutex_lock(&tb_state_lock);
    TBLLVMState *s=g_hash_table_lookup(tb_state_map,tb);
    qemu_mutex_unlock(&tb_state_lock);
    return s;
}
TBLLVMState *llvm_tb_state_ensure(void *tb) {
    tb_state_lock_init();
    qemu_mutex_lock(&tb_state_lock);
    TBLLVMState *s=g_hash_table_lookup(tb_state_map,tb);
    if(!s){s=g_new0(TBLLVMState,1);s->state=LLVM_STATE_NONE;g_hash_table_insert(tb_state_map,tb,s);}
    qemu_mutex_unlock(&tb_state_lock);
    return s;
}
void llvm_tb_state_remove(void *tb) {
    if(!tb_state_map)return;
    qemu_mutex_lock(&tb_state_lock);
    g_hash_table_remove(tb_state_map,tb);
    qemu_mutex_unlock(&tb_state_lock);
}
void llvm_tb_state_remove_all(void) {
    if(!tb_state_map)return;
    qemu_mutex_lock(&tb_state_lock);
    g_hash_table_remove_all(tb_state_map);
    qemu_mutex_unlock(&tb_state_lock);
}
void llvm_global_init(void) {
    if(llvm_global.initialized)return;
    llvm_global.enabled=llvm_global.initialized=true;
    tb_state_lock_init();
    memset(&llvm_stats,0,sizeof(llvm_stats));
    fprintf(stderr,"[llvm] hybrid backend initialized: threshold=%u workers=%u opt=O%u\n",llvm_global.hot_threshold,llvm_global.max_workers,llvm_global.opt_level);
}
void llvm_global_shutdown(void) {
    llvm_global.enabled=llvm_global.initialized=false;
    llvm_tb_state_remove_all();
}
bool llvm_is_enabled(void) { return llvm_global.enabled && llvm_global.initialized; }
LLVM_C_END

    # ── llvm-queue.h ───────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-queue.h" << 'Q_H_END'
#ifndef TCG_LLVM_QUEUE_H
#define TCG_LLVM_QUEUE_H
#include "llvm-common.h"
typedef struct LLVMQueue {
    void *buf[LLVM_QUEUE_CAPACITY];
    uint64_t head, tail;
    bool shutdown, initialized;
} LLVMQueue;
int   llvm_queue_init(LLVMQueue *q);
int   llvm_queue_enqueue(LLVMQueue *q, void *tb);
void *llvm_queue_dequeue(LLVMQueue *q);
void  llvm_queue_shutdown(LLVMQueue *q);
extern LLVMQueue llvm_compile_queue;
#endif
Q_H_END

    # ── llvm-queue.c ───────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-queue.c" << 'Q_C_END'
#include "qemu/osdep.h"
#include "qemu/atomic.h"
#include "llvm-queue.h"
LLVMQueue llvm_compile_queue;
int llvm_queue_init(LLVMQueue *q) {
    memset(q,0,sizeof(*q));
    qatomic_set(&q->head,0);qatomic_set(&q->tail,0);
    qatomic_set(&q->shutdown,false);q->initialized=1;return 0;
}
int llvm_queue_enqueue(LLVMQueue *q, void *tb) {
    if(!q->initialized||qatomic_read(&q->shutdown))return -1;
    uint64_t tail=qatomic_read(&q->tail);
    uint64_t head=qatomic_read(&q->head);
    if(tail-head>=LLVM_QUEUE_CAPACITY)return -1;
    uint64_t idx=tail%LLVM_QUEUE_CAPACITY;
    /* CAS: claim slot. Return old value. If CAS fails (old!=tail), retry */
    if(qatomic_cmpxchg(&q->tail,tail,tail+1)!=tail)return llvm_queue_enqueue(q,tb);
    qatomic_set(&q->buf[idx],tb);
    return 0;
}
void *llvm_queue_dequeue(LLVMQueue *q) {
    while(!qatomic_read(&q->shutdown)){
        uint64_t head=qatomic_read(&q->head);
        uint64_t tail=qatomic_read(&q->tail);
        if(head==tail){g_usleep(1000);continue;}
        uint64_t idx=head%LLVM_QUEUE_CAPACITY;
        void *tb=qatomic_read(&q->buf[idx]);
        qatomic_set(&q->head,head+1);
        if(tb){fprintf(stderr,"[llvm-queue] dequeued TB=%p (slot %lu)\n",tb,(unsigned long)idx);return tb;}
    }
    return NULL;
}
void llvm_queue_shutdown(LLVMQueue *q) { qatomic_set(&q->shutdown,true); }
Q_C_END

    # ── llvm-profiler.h ────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-profiler.h" << 'P_H_END'
#ifndef TCG_LLVM_PROFILER_H
#define TCG_LLVM_PROFILER_H
#include "llvm-common.h"

struct TranslationBlock;
struct TCGContext;

typedef struct {
    uint16_t  opc;
    uint16_t  nargs;
    uint32_t  param1;
    uint32_t  param2;
    uint64_t  args[];
} SavedTCGOp;

typedef struct {
    uint32_t    num_ops;
    SavedTCGOp *ops[];
} SavedTCGOps;

void llvm_profile_tb(struct TranslationBlock *tb);
bool llvm_use_llvm(struct TranslationBlock *tb);
void llvm_capture_tb_ops(struct TCGContext *tcg_ctx,
                         struct TranslationBlock *tb);

/* Temp metadata captured at translation time */
typedef struct {
    bool     is_temp;
    bool     is_global;
    int64_t  value;
    intptr_t mem_offset;
    int      temp_idx;
    bool     indirect;
    intptr_t indirect_offset;
    int      indirect_base_idx;
} CapturedArg;

#define LLVM_MAX_TEMPS 512
#endif
P_H_END

    # ── llvm-profiler.c ────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-profiler.c" << 'P_C_END'
#include "qemu/osdep.h"
#include "qemu/atomic.h"
#include "exec/translation-block.h"
#include "tcg/tcg.h"
#include "llvm-profiler.h"
#include "llvm-queue.h"
#include "llvm-common.h"

#define PROF_SAMPLE_MASK 0x3 /* count 1/4 execs */ /* count 1/16 executions */
void llvm_profile_tb(struct TranslationBlock *tb) {
    static bool _once_print;
    if(!_once_print){_once_print=true;fprintf(stderr,"[llvm] cpu-exec.c dispatch call reached (profiling active)\n");}
    if(!llvm_is_enabled())return;
    static __thread uint32_t _sampler;
    _sampler++;
    if(_sampler&PROF_SAMPLE_MASK)return;
    TBLLVMState *s=llvm_tb_state_ensure(tb);
    if(s->permanently_failed)return;
    uint32_t cnt=qatomic_add_fetch(&s->exec_count,1);
    qatomic_inc(&llvm_stats.tcg_exec_count);
    if(cnt<llvm_global.hot_threshold)return;
    if(qatomic_read(&s->state)!=LLVM_STATE_NONE)return;
    if(qatomic_cmpxchg(&s->state,LLVM_STATE_NONE,LLVM_STATE_COMPILING)!=LLVM_STATE_NONE)return;
    s->compiling=true;
    if(llvm_queue_enqueue(&llvm_compile_queue,(void*)tb)==0)
        qatomic_inc(&llvm_stats.queue_enqueues);
    else { qatomic_set(&s->state,LLVM_STATE_NONE);s->compiling=false;qatomic_inc(&llvm_stats.queue_drops); }
}

bool llvm_use_llvm(struct TranslationBlock *tb) {
    if(!llvm_is_enabled())return false;
    TBLLVMState *s=llvm_tb_state_get(tb);
    return s&&s->state==LLVM_STATE_READY&&s->llvm_code&&!s->llvm_failed&&!s->permanently_failed;
}
void llvm_capture_tb_ops(struct TCGContext *tcg_ctx, struct TranslationBlock *tb) {
    if(!llvm_is_enabled())return;
    TCGOp *op;uint32_t i,count=0;
    QTAILQ_FOREACH(op,&tcg_ctx->ops,link)count++;
    if(!count)return;
    TBLLVMState *s=llvm_tb_state_ensure(tb);
    if(s->saved_ops){SavedTCGOps*old=(SavedTCGOps*)s->saved_ops;
        for(i=0;i<old->num_ops;i++)g_free(old->ops[i]);g_free(old);s->saved_ops=NULL;}
    size_t sz=sizeof(SavedTCGOps)+count*sizeof(SavedTCGOp*);
    SavedTCGOps *c=(SavedTCGOps*)g_malloc(sz);c->num_ops=count;
    i=0;QTAILQ_FOREACH(op,&tcg_ctx->ops,link){
        uint16_t na=op->nargs;
        SavedTCGOp *co=g_malloc(sizeof(SavedTCGOp)+na*sizeof(uint64_t));
        co->opc=(uint16_t)op->opc;co->nargs=na;
        co->param1=op->param1;co->param2=op->param2;
        for(uint16_t j=0;j<na;j++){
            TCGArg arg=tcg_get_insn_param(op,j);
            if((uintptr_t)arg>=(uintptr_t)&tcg_ctx->temps[0]&&
               (uintptr_t)arg<(uintptr_t)&tcg_ctx->temps[TCG_MAX_TEMPS]){
                uint64_t enc=0;TCGTemp *ts=(TCGTemp*)(uintptr_t)arg;
                if(ts->kind==TEMP_GLOBAL||ts->kind==TEMP_FIXED)
                    enc=(1ULL<<63)|(1ULL<<62)|(uint64_t)(ts->mem_offset&0x7FFFFFFFFFFFULL);
                else {int tidx=(int)(ts-&tcg_ctx->temps[0]);enc=(1ULL<<63)|(uint64_t)(tidx<LLVM_MAX_TEMPS?tidx:0);}
                co->args[j]=enc;
            } else if((op->opc==INDEX_op_br||op->opc==INDEX_op_brcond||op->opc==INDEX_op_set_label)&&(uintptr_t)arg>0x100){
                TCGLabel *lbl;uint16_t lid=0xFFFF;
                QSIMPLEQ_FOREACH(lbl,&tcg_ctx->labels,next){if((uintptr_t)lbl==(uintptr_t)arg){lid=lbl->id;break;}}
                co->args[j]=(uint64_t)(lid!=0xFFFF?lid:(uintptr_t)arg);
            } else {co->args[j]=(uint64_t)(uintptr_t)arg;}
        }
        c->ops[i++]=co;
    }
    s->saved_ops=c;
}
P_C_END

    # ── llvm-api.h (LLVM-C type definitions) ─────────────────
    cat > "$LLVM_DIR/llvm-api.h" << 'API_H_END'
#ifndef TCG_LLVM_API_H
#define TCG_LLVM_API_H

/*
 * LLVM-C API function pointer types — shared between llvm-jit.c
 * (which resolves them via dlopen/dlsym) and llvm-translate.c
 * (which uses them to generate LLVM IR).
 */

#include <dlfcn.h>

/* ── LLVM-C opaque types ────────────────────────────────────── */
typedef struct LLVMOpaqueModule           *LLVMModuleRef;
typedef struct LLVMOpaqueBuilder          *LLVMBuilderRef;
typedef struct LLVMOpaqueBasicBlock       *LLVMBasicBlockRef;
typedef struct LLVMOpaqueValue            *LLVMValueRef;
typedef struct LLVMOpaqueType             *LLVMTypeRef;
typedef struct LLVMOpaqueContext          *LLVMContextRef;
typedef struct LLVMOpaqueTargetMachine    *LLVMTargetMachineRef;
typedef struct LLVMOpaqueTargetData       *LLVMTargetDataRef;
typedef struct LLVMOpaquePassManager      *LLVMPassManagerRef;
typedef struct LLVMOrcOpaqueLLJIT        *LLVMOrcLLJITRef;
typedef struct LLVMOrcOpaqueThreadSafeContext *LLVMOrcThreadSafeContextRef;
typedef struct LLVMOrcOpaqueThreadSafeModule  *LLVMOrcThreadSafeModuleRef;
typedef uint64_t LLVMOrcExecutorAddress;
typedef uint32_t LLVMAttributeIndex;
typedef uint32_t LLVMIntPredicate;
typedef uint32_t LLVMOpcode;

/* ── Function pointer typedefs ──────────────────────────────── */
typedef void (*pfn_LLVMInitializeX86TargetInfo)(void);
typedef void (*pfn_LLVMInitializeX86Target)(void);
typedef void (*pfn_LLVMInitializeX86TargetMC)(void);
typedef void (*pfn_LLVMInitializeX86AsmPrinter)(void);
typedef void (*pfn_LLVMInitializeX86AsmParser)(void);
typedef LLVMContextRef (*pfn_LLVMContextCreate)(void);
typedef void (*pfn_LLVMContextDispose)(LLVMContextRef);
typedef LLVMModuleRef (*pfn_LLVMModuleCreateWithNameInContext)(const char*, LLVMContextRef);
typedef void (*pfn_LLVMDisposeModule)(LLVMModuleRef);
typedef LLVMTypeRef (*pfn_LLVMInt32TypeInContext)(LLVMContextRef);
typedef LLVMTypeRef (*pfn_LLVMInt64TypeInContext)(LLVMContextRef);
typedef LLVMTypeRef (*pfn_LLVMPointerTypeInContext)(LLVMContextRef, unsigned);
typedef LLVMTypeRef (*pfn_LLVMVoidTypeInContext)(LLVMContextRef);
typedef LLVMTypeRef (*pfn_LLVMFunctionType)(LLVMTypeRef, LLVMTypeRef*, unsigned, int);
typedef LLVMValueRef (*pfn_LLVMAddFunction)(LLVMModuleRef, const char*, LLVMTypeRef);
typedef LLVMValueRef (*pfn_LLVMGetParam)(LLVMValueRef, unsigned);
typedef LLVMValueRef (*pfn_LLVMConstInt)(LLVMTypeRef, unsigned long long, int);
typedef LLVMBasicBlockRef (*pfn_LLVMAppendBasicBlockInContext)(LLVMContextRef, LLVMValueRef, const char*);
typedef LLVMBuilderRef (*pfn_LLVMCreateBuilderInContext)(LLVMContextRef);
typedef void (*pfn_LLVMDisposeBuilder)(LLVMBuilderRef);
typedef void (*pfn_LLVMPositionBuilderAtEnd)(LLVMBuilderRef, LLVMBasicBlockRef);
typedef LLVMValueRef (*pfn_LLVMBuildAdd)(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildSub)(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildMul)(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildAnd)(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildOr)(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildXor)(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildShl)(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildLShr)(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildAShr)(LLVMBuilderRef, LLVMValueRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildLoad2)(LLVMBuilderRef, LLVMTypeRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildStore)(LLVMBuilderRef, LLVMValueRef, LLVMValueRef);
typedef LLVMValueRef (*pfn_LLVMBuildIntToPtr)(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildPtrToInt)(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildTrunc)(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildZExt)(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildSExt)(LLVMBuilderRef, LLVMValueRef, LLVMTypeRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildRet)(LLVMBuilderRef, LLVMValueRef);
typedef LLVMValueRef (*pfn_LLVMBuildRetVoid)(LLVMBuilderRef);
typedef LLVMValueRef (*pfn_LLVMBuildBr)(LLVMBuilderRef, LLVMBasicBlockRef);
typedef LLVMValueRef (*pfn_LLVMBuildCondBr)(LLVMBuilderRef, LLVMValueRef, LLVMBasicBlockRef, LLVMBasicBlockRef);
typedef LLVMValueRef (*pfn_LLVMBuildICmp)(LLVMBuilderRef, LLVMIntPredicate, LLVMValueRef, LLVMValueRef, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildCall2)(LLVMBuilderRef, LLVMTypeRef, LLVMValueRef, LLVMValueRef*, unsigned, const char*);
typedef LLVMValueRef (*pfn_LLVMBuildPhi)(LLVMBuilderRef, LLVMTypeRef, const char*);
typedef int  (*pfn_LLVMOrcCreateLLJIT)(LLVMOrcLLJITRef*, unsigned);
typedef int  (*pfn_LLVMOrcCreateNewThreadSafeContext)(LLVMOrcThreadSafeContextRef*);
typedef int  (*pfn_LLVMOrcCreateNewThreadSafeModule)(LLVMOrcThreadSafeModuleRef*, LLVMModuleRef, LLVMOrcThreadSafeContextRef);
typedef int  (*pfn_LLVMOrcLLJITAddLLVMIRModule)(LLVMOrcLLJITRef, LLVMOrcThreadSafeModuleRef);
typedef int  (*pfn_LLVMOrcLLJITLookup)(LLVMOrcLLJITRef, LLVMOrcExecutorAddress*, const char*);
typedef int  (*pfn_LLVMOrcDisposeLLJIT)(LLVMOrcLLJITRef);

/* ── Global function pointers — resolved at init time ──────── */
extern pfn_LLVMContextCreate              LLVM_ContextCreate;
extern pfn_LLVMContextDispose             LLVM_ContextDispose;
extern pfn_LLVMModuleCreateWithNameInContext LLVM_ModuleCreateWithNameInContext;
extern pfn_LLVMDisposeModule              LLVM_DisposeModule;
extern pfn_LLVMInt32TypeInContext         LLVM_Int32TypeInContext;
extern pfn_LLVMInt64TypeInContext         LLVM_Int64TypeInContext;
extern pfn_LLVMPointerTypeInContext       LLVM_PointerTypeInContext;
extern pfn_LLVMVoidTypeInContext          LLVM_VoidTypeInContext;
extern pfn_LLVMFunctionType              LLVM_FunctionType;
extern pfn_LLVMAddFunction               LLVM_AddFunction;
extern pfn_LLVMGetParam                  LLVM_GetParam;
extern pfn_LLVMConstInt                  LLVM_ConstInt;
extern pfn_LLVMAppendBasicBlockInContext LLVM_AppendBasicBlockInContext;
extern pfn_LLVMCreateBuilderInContext    LLVM_CreateBuilderInContext;
extern pfn_LLVMDisposeBuilder            LLVM_DisposeBuilder;
extern pfn_LLVMPositionBuilderAtEnd      LLVM_PositionBuilderAtEnd;
extern pfn_LLVMBuildAdd                  LLVM_BuildAdd;
extern pfn_LLVMBuildSub                  LLVM_BuildSub;
extern pfn_LLVMBuildMul                  LLVM_BuildMul;
extern pfn_LLVMBuildAnd                  LLVM_BuildAnd;
extern pfn_LLVMBuildOr                   LLVM_BuildOr;
extern pfn_LLVMBuildXor                  LLVM_BuildXor;
extern pfn_LLVMBuildShl                  LLVM_BuildShl;
extern pfn_LLVMBuildLShr                 LLVM_BuildLShr;
extern pfn_LLVMBuildAShr                 LLVM_BuildAShr;
extern pfn_LLVMBuildLoad2               LLVM_BuildLoad2;
extern pfn_LLVMBuildStore               LLVM_BuildStore;
extern pfn_LLVMBuildIntToPtr            LLVM_BuildIntToPtr;
extern pfn_LLVMBuildPtrToInt            LLVM_BuildPtrToInt;
extern pfn_LLVMBuildTrunc               LLVM_BuildTrunc;
extern pfn_LLVMBuildZExt                LLVM_BuildZExt;
extern pfn_LLVMBuildSExt                LLVM_BuildSExt;
extern pfn_LLVMBuildRet                 LLVM_BuildRet;
extern pfn_LLVMBuildRetVoid             LLVM_BuildRetVoid;
extern pfn_LLVMBuildBr                  LLVM_BuildBr;
extern pfn_LLVMBuildCondBr              LLVM_BuildCondBr;
extern pfn_LLVMBuildICmp                LLVM_BuildICmp;
extern pfn_LLVMBuildCall2              LLVM_BuildCall2;
extern pfn_LLVMBuildPhi                 LLVM_BuildPhi;
extern pfn_LLVMOrcCreateLLJIT          LLVM_OrcCreateLLJIT;
extern pfn_LLVMOrcCreateNewThreadSafeContext LLVM_OrcCreateNewThreadSafeContext;
extern pfn_LLVMOrcCreateNewThreadSafeModule  LLVM_OrcCreateNewThreadSafeModule;
extern pfn_LLVMOrcLLJITAddLLVMIRModule      LLVM_OrcLLJITAddLLVMIRModule;
extern pfn_LLVMOrcLLJITLookup          LLVM_OrcLLJITLookup;
extern pfn_LLVMOrcDisposeLLJIT         LLVM_OrcDisposeLLJIT;

/* Target init */
extern pfn_LLVMInitializeX86TargetInfo LLVM_InitX86TargetInfo;
extern pfn_LLVMInitializeX86Target     LLVM_InitX86Target;
extern pfn_LLVMInitializeX86TargetMC   LLVM_InitX86TargetMC;
extern pfn_LLVMInitializeX86AsmPrinter LLVM_InitX86AsmPrinter;

/* JIT context */
extern LLVMContextRef   llvm_ctx;
extern LLVMOrcLLJITRef  llvm_jit;

/* Init: load libLLVM and resolve all symbols */
int llvm_api_init(void);

#endif /* TCG_LLVM_API_H */
API_H_END

    # ── llvm-jit.h ─────────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-jit.h" << 'JIT_H_END'
#ifndef TCG_LLVM_JIT_H
#define TCG_LLVM_JIT_H
#include "llvm-common.h"
typedef struct { void *code; size_t size; uint64_t compile_ns; } LLVMCompileResult;
int  llvm_orc_init(void);
int  llvm_orc_compile(void *module, const char *fn_name, LLVMCompileResult *out);
void llvm_orc_remove_module(void *module);
void llvm_orc_shutdown(void);
#endif
JIT_H_END

    # ── llvm-jit.c (ORC JIT v2 via dlopen) ───────────────────
    cat > "$LLVM_DIR/llvm-jit.c" << 'JIT_C_END'
/*
 * llvm-jit.c — LLVM ORC JIT v2 via runtime dlopen().
 *
 * Single-file LLVM integration:
 *  - dlopen("libLLVM-*.so") at init
 *  - Resolve ALL LLVM-C symbols as global function pointers
 *  - Create one ORC LLJIT for background compilation
 *  - Expose symbols and context for llvm-translate.c
 */

#include "qemu/osdep.h"
#include "qemu/atomic.h"
#include <dlfcn.h>

#include "llvm-jit.h"
#include "llvm-common.h"
#include "llvm-translate.h"

/* ── Include LLVM-C API type declarations ───────────────────── */
#include "llvm-api.h"

/* ── Define the global function pointers ────────────────────── */
#define DEF_PTR(type, name) type name = NULL;

DEF_PTR(pfn_LLVMContextCreate,              LLVM_ContextCreate)
DEF_PTR(pfn_LLVMContextDispose,             LLVM_ContextDispose)
DEF_PTR(pfn_LLVMModuleCreateWithNameInContext, LLVM_ModuleCreateWithNameInContext)
DEF_PTR(pfn_LLVMDisposeModule,              LLVM_DisposeModule)
DEF_PTR(pfn_LLVMInt32TypeInContext,         LLVM_Int32TypeInContext)
DEF_PTR(pfn_LLVMInt64TypeInContext,         LLVM_Int64TypeInContext)
DEF_PTR(pfn_LLVMPointerTypeInContext,       LLVM_PointerTypeInContext)
DEF_PTR(pfn_LLVMVoidTypeInContext,          LLVM_VoidTypeInContext)
DEF_PTR(pfn_LLVMFunctionType,              LLVM_FunctionType)
DEF_PTR(pfn_LLVMAddFunction,               LLVM_AddFunction)
DEF_PTR(pfn_LLVMGetParam,                  LLVM_GetParam)
DEF_PTR(pfn_LLVMConstInt,                  LLVM_ConstInt)
DEF_PTR(pfn_LLVMAppendBasicBlockInContext, LLVM_AppendBasicBlockInContext)
DEF_PTR(pfn_LLVMCreateBuilderInContext,    LLVM_CreateBuilderInContext)
DEF_PTR(pfn_LLVMDisposeBuilder,            LLVM_DisposeBuilder)
DEF_PTR(pfn_LLVMPositionBuilderAtEnd,      LLVM_PositionBuilderAtEnd)
DEF_PTR(pfn_LLVMBuildAdd,                  LLVM_BuildAdd)
DEF_PTR(pfn_LLVMBuildSub,                  LLVM_BuildSub)
DEF_PTR(pfn_LLVMBuildMul,                  LLVM_BuildMul)
DEF_PTR(pfn_LLVMBuildAnd,                  LLVM_BuildAnd)
DEF_PTR(pfn_LLVMBuildOr,                   LLVM_BuildOr)
DEF_PTR(pfn_LLVMBuildXor,                  LLVM_BuildXor)
DEF_PTR(pfn_LLVMBuildShl,                  LLVM_BuildShl)
DEF_PTR(pfn_LLVMBuildLShr,                 LLVM_BuildLShr)
DEF_PTR(pfn_LLVMBuildAShr,                 LLVM_BuildAShr)
DEF_PTR(pfn_LLVMBuildLoad2,               LLVM_BuildLoad2)
DEF_PTR(pfn_LLVMBuildStore,               LLVM_BuildStore)
DEF_PTR(pfn_LLVMBuildIntToPtr,            LLVM_BuildIntToPtr)
DEF_PTR(pfn_LLVMBuildPtrToInt,            LLVM_BuildPtrToInt)
DEF_PTR(pfn_LLVMBuildTrunc,               LLVM_BuildTrunc)
DEF_PTR(pfn_LLVMBuildZExt,                LLVM_BuildZExt)
DEF_PTR(pfn_LLVMBuildSExt,                LLVM_BuildSExt)
DEF_PTR(pfn_LLVMBuildRet,                 LLVM_BuildRet)
DEF_PTR(pfn_LLVMBuildRetVoid,             LLVM_BuildRetVoid)
DEF_PTR(pfn_LLVMBuildBr,                  LLVM_BuildBr)
DEF_PTR(pfn_LLVMBuildCondBr,              LLVM_BuildCondBr)
DEF_PTR(pfn_LLVMBuildICmp,                LLVM_BuildICmp)
DEF_PTR(pfn_LLVMBuildCall2,              LLVM_BuildCall2)
DEF_PTR(pfn_LLVMBuildPhi,                 LLVM_BuildPhi)
DEF_PTR(pfn_LLVMOrcCreateLLJIT,          LLVM_OrcCreateLLJIT)
DEF_PTR(pfn_LLVMOrcCreateNewThreadSafeContext, LLVM_OrcCreateNewThreadSafeContext)
DEF_PTR(pfn_LLVMOrcCreateNewThreadSafeModule,  LLVM_OrcCreateNewThreadSafeModule)
DEF_PTR(pfn_LLVMOrcLLJITAddLLVMIRModule,      LLVM_OrcLLJITAddLLVMIRModule)
DEF_PTR(pfn_LLVMOrcLLJITLookup,          LLVM_OrcLLJITLookup)
DEF_PTR(pfn_LLVMOrcDisposeLLJIT,         LLVM_OrcDisposeLLJIT)
DEF_PTR(pfn_LLVMInitializeX86TargetInfo, LLVM_InitX86TargetInfo)
DEF_PTR(pfn_LLVMInitializeX86Target,     LLVM_InitX86Target)
DEF_PTR(pfn_LLVMInitializeX86TargetMC,   LLVM_InitX86TargetMC)
DEF_PTR(pfn_LLVMInitializeX86AsmPrinter, LLVM_InitX86AsmPrinter)

LLVMContextRef  llvm_ctx = NULL;
LLVMOrcLLJITRef llvm_jit = NULL;
static void    *llvm_lib = NULL;

/* ── dlsym table ────────────────────────────────────────────── */
typedef struct { const char *name; void **ptr; } DLSymEntry;

static int llvm_resolve_symtab(void)
{
    static DLSymEntry syms[] = {
        {"LLVMContextCreate",              (void**)&LLVM_ContextCreate},
        {"LLVMContextDispose",             (void**)&LLVM_ContextDispose},
        {"LLVMModuleCreateWithNameInContext", (void**)&LLVM_ModuleCreateWithNameInContext},
        {"LLVMDisposeModule",              (void**)&LLVM_DisposeModule},
        {"LLVMInt32TypeInContext",         (void**)&LLVM_Int32TypeInContext},
        {"LLVMInt64TypeInContext",         (void**)&LLVM_Int64TypeInContext},
        {"LLVMPointerTypeInContext",       (void**)&LLVM_PointerTypeInContext},
        {"LLVMVoidTypeInContext",          (void**)&LLVM_VoidTypeInContext},
        {"LLVMFunctionType",              (void**)&LLVM_FunctionType},
        {"LLVMAddFunction",               (void**)&LLVM_AddFunction},
        {"LLVMGetParam",                  (void**)&LLVM_GetParam},
        {"LLVMConstInt",                  (void**)&LLVM_ConstInt},
        {"LLVMAppendBasicBlockInContext", (void**)&LLVM_AppendBasicBlockInContext},
        {"LLVMCreateBuilderInContext",    (void**)&LLVM_CreateBuilderInContext},
        {"LLVMDisposeBuilder",            (void**)&LLVM_DisposeBuilder},
        {"LLVMPositionBuilderAtEnd",      (void**)&LLVM_PositionBuilderAtEnd},
        {"LLVMBuildAdd",                  (void**)&LLVM_BuildAdd},
        {"LLVMBuildSub",                  (void**)&LLVM_BuildSub},
        {"LLVMBuildMul",                  (void**)&LLVM_BuildMul},
        {"LLVMBuildAnd",                  (void**)&LLVM_BuildAnd},
        {"LLVMBuildOr",                   (void**)&LLVM_BuildOr},
        {"LLVMBuildXor",                  (void**)&LLVM_BuildXor},
        {"LLVMBuildShl",                  (void**)&LLVM_BuildShl},
        {"LLVMBuildLShr",                 (void**)&LLVM_BuildLShr},
        {"LLVMBuildAShr",                 (void**)&LLVM_BuildAShr},
        {"LLVMBuildLoad2",               (void**)&LLVM_BuildLoad2},
        {"LLVMBuildStore",               (void**)&LLVM_BuildStore},
        {"LLVMBuildIntToPtr",            (void**)&LLVM_BuildIntToPtr},
        {"LLVMBuildPtrToInt",            (void**)&LLVM_BuildPtrToInt},
        {"LLVMBuildTrunc",               (void**)&LLVM_BuildTrunc},
        {"LLVMBuildZExt",                (void**)&LLVM_BuildZExt},
        {"LLVMBuildSExt",                (void**)&LLVM_BuildSExt},
        {"LLVMBuildRet",                 (void**)&LLVM_BuildRet},
        {"LLVMBuildRetVoid",             (void**)&LLVM_BuildRetVoid},
        {"LLVMBuildBr",                  (void**)&LLVM_BuildBr},
        {"LLVMBuildCondBr",              (void**)&LLVM_BuildCondBr},
        {"LLVMBuildICmp",                (void**)&LLVM_BuildICmp},
        {"LLVMBuildCall2",              (void**)&LLVM_BuildCall2},
        {"LLVMBuildPhi",                 (void**)&LLVM_BuildPhi},
        {"LLVMOrcCreateLLJIT",          (void**)&LLVM_OrcCreateLLJIT},
        {"LLVMOrcCreateNewThreadSafeContext", (void**)&LLVM_OrcCreateNewThreadSafeContext},
        {"LLVMOrcCreateNewThreadSafeModule",  (void**)&LLVM_OrcCreateNewThreadSafeModule},
        {"LLVMOrcLLJITAddLLVMIRModule",      (void**)&LLVM_OrcLLJITAddLLVMIRModule},
        {"LLVMOrcLLJITLookup",          (void**)&LLVM_OrcLLJITLookup},
        {"LLVMOrcDisposeLLJIT",         (void**)&LLVM_OrcDisposeLLJIT},
        {"LLVMInitializeX86TargetInfo", (void**)&LLVM_InitX86TargetInfo},
        {"LLVMInitializeX86Target",     (void**)&LLVM_InitX86Target},
        {"LLVMInitializeX86TargetMC",   (void**)&LLVM_InitX86TargetMC},
        {"LLVMInitializeX86AsmPrinter", (void**)&LLVM_InitX86AsmPrinter},
        {NULL, NULL},
    };

    int n = sizeof(syms) / sizeof(syms[0]) - 1;
    int missing = 0;

    for (int i = 0; i < n; i++) {
        *(syms[i].ptr) = dlsym(llvm_lib, syms[i].name);
        if (!*(syms[i].ptr)) {
            if (missing < 3) {
                fprintf(stderr, "[llvm-jit] missing: %s\n", syms[i].name);
            }
            missing++;
        }
    }

    return missing;
}

int llvm_api_init(void)
{
    if (llvm_lib) return 0;

    const char *libs[] = {
        "libLLVM-20.so", "libLLVM.so.20.1",
        "libLLVM-19.so", "libLLVM-18.so",
        "libLLVM-17.so", "libLLVM-16.so",
        "libLLVM.so", NULL
    };

    for (int i = 0; libs[i]; i++) {
        llvm_lib = dlopen(libs[i], RTLD_NOW | RTLD_GLOBAL);
        if (llvm_lib) {
            fprintf(stderr, "[llvm-jit] loaded %s\n", libs[i]);
            break;
        }
    }

    if (!llvm_lib) {
        fprintf(stderr, "[llvm-jit] libLLVM.so not found — LLVM disabled\n");
        return -1;
    }

    if (llvm_resolve_symtab() > 0) {
        fprintf(stderr, "[llvm-jit] symbol resolution failed — LLVM disabled\n");
        dlclose(llvm_lib); llvm_lib = NULL;
        return -1;
    }

    /* Init x86 target */
    LLVM_InitX86TargetInfo();
    LLVM_InitX86Target();
    LLVM_InitX86TargetMC();
    LLVM_InitX86AsmPrinter();

    /* Create context */
    llvm_ctx = LLVM_ContextCreate();

    /* Create ORC JIT */
    LLVMOrcLLJITRef jit = NULL;
    if (LLVM_OrcCreateLLJIT(&jit, 0) != 0) {
        fprintf(stderr, "[llvm-jit] ORC JIT creation failed\n");
        LLVM_ContextDispose(llvm_ctx);
        dlclose(llvm_lib); llvm_lib = NULL;
        return -1;
    }
    llvm_jit = jit;

    fprintf(stderr, "[llvm-jit] ORC JIT initialized successfully\n");
    return 0;
}

int llvm_orc_init(void)
{
    return llvm_api_init();
}

int llvm_orc_compile(void *module, const char *fn_name, LLVMCompileResult *out)
{
    if (!llvm_jit || !module || !out) return -1;
    memset(out, 0, sizeof(*out));

    LLVMModuleRef mod = (LLVMModuleRef)module;

    LLVMOrcThreadSafeContextRef tsctx;
    if (LLVM_OrcCreateNewThreadSafeContext(&tsctx) != 0) return -1;

    LLVMOrcThreadSafeModuleRef tsm;
    if (LLVM_OrcCreateNewThreadSafeModule(&tsm, mod, tsctx) != 0) return -1;

    if (LLVM_OrcLLJITAddLLVMIRModule(llvm_jit, tsm) != 0) return -1;

    LLVMOrcExecutorAddress addr;
    if (LLVM_OrcLLJITLookup(llvm_jit, &addr, fn_name) != 0) return -1;

    out->code = (void *)(uintptr_t)addr;
    out->size = 1024;
    return 0;
}

void llvm_orc_remove_module(void *module)
{
    (void)module;
}

void llvm_orc_shutdown(void)
{
    if (llvm_jit) { LLVM_OrcDisposeLLJIT(llvm_jit); llvm_jit = NULL; }
    if (llvm_ctx) { LLVM_ContextDispose(llvm_ctx); llvm_ctx = NULL; }
    if (llvm_lib) { dlclose(llvm_lib); llvm_lib = NULL; }
}
JIT_C_END

    # ── llvm-translate.h ───────────────────────────────────────
    cat > "$LLVM_DIR/llvm-translate.h" << 'TR_H_END'
#ifndef TCG_LLVM_TRANSLATE_H
#define TCG_LLVM_TRANSLATE_H
#include "llvm-common.h"

struct TranslationBlock;

/* Helper function table passed to LLVM-compiled code */
typedef struct LLVMHelperTable {
    void *helper_ldub_mmu;
    void *helper_lduw_mmu;
    void *helper_ldul_mmu;
    void *helper_ldq_mmu;
    void *helper_stb_mmu;
    void *helper_stw_mmu;
    void *helper_stl_mmu;
    void *helper_stq_mmu;
} LLVMHelperTable;

extern LLVMHelperTable llvm_helpers;

int llvm_translate_tb(struct TranslationBlock *tb, void **out_module);
#endif
TR_H_END

    # ── llvm-translate.c (TCG-IR → LLVM-IR) ──────────────────
    cat > "$LLVM_DIR/llvm-translate.c" << 'TR_C_END'
/* llvm-translate.c — TCG-IR to LLVM-IR with multi-BB support */
#include "qemu/osdep.h"
#include "exec/translation-block.h"
#include "tcg/tcg.h"
#include "llvm-common.h"
#include "llvm-api.h"
#include "llvm-profiler.h"
#include "llvm-translate.h"
extern tcg_target_ulong helper_ldul_mmu(CPUArchState*,uint64_t,uint32_t,uintptr_t);
extern void helper_stl_mmu(CPUArchState*,uint64_t,uint32_t,uint32_t,uintptr_t);
LLVMHelperTable llvm_helpers;
#define TB_EXIT_MASK 3
static inline bool is_temp(uint64_t a){return (a>>63)&1;}
static inline bool is_global_temp(uint64_t a){return ((a>>63)&1)&&((a>>62)&1);}
static inline intptr_t temp_off(uint64_t a){return (intptr_t)(a&0xFFFFFFFFFFULL);}
#define LOG_FALLBACK(tb,oc,i,n) fprintf(stderr,"[llvm-trans] TB=%p FALLBACK op=%s (op %d/%d)\n",(void*)(tb),((oc)<NB_OPS?tcg_op_defs[oc].name:"?"),(i),(n))

#define MAX_BB 256
int llvm_translate_tb(struct TranslationBlock *tb, void **out_module) {
    if(!llvm_ctx||!tb)return -1;
    TBLLVMState *st=llvm_tb_state_get(tb);
    if(!st||!st->saved_ops){fprintf(stderr,"[llvm-trans] TB=%p NO_SAVED_OPS\n",(void*)tb);return -1;}
    SavedTCGOps *c=(SavedTCGOps*)st->saved_ops;
    uint32_t nops=c->num_ops;
    fprintf(stderr,"[llvm-trans] TB=%p translating %u ops\n",(void*)tb,nops);

    LLVMModuleRef mod=LLVM_ModuleCreateWithNameInContext("tb",llvm_ctx);
    LLVMTypeRef i32=LLVM_Int32TypeInContext(llvm_ctx);
    LLVMTypeRef i64=LLVM_Int64TypeInContext(llvm_ctx);
    LLVMTypeRef ptr=LLVM_PointerTypeInContext(llvm_ctx,0);
    LLVMTypeRef pt[]={ptr,ptr};LLVMTypeRef ft=LLVM_FunctionType(i64,pt,2,0);
    LLVMValueRef fn=LLVM_AddFunction(mod,"tcg_exec",ft);
    LLVMValueRef env_ptr=LLVM_GetParam(fn,0);(void)LLVM_GetParam(fn,1);
    LLVMBuilderRef b=LLVM_CreateBuilderInContext(llvm_ctx);

    /* Pre-scan: find all set_label ops and create BBs */
    LLVMBasicBlockRef bbs[MAX_BB]={NULL};
    bbs[0]=LLVM_AppendBasicBlockInContext(llvm_ctx,fn,"entry");
    for(uint32_t i=0;i<nops;i++){
        if(c->ops[i]->opc==INDEX_op_set_label){
            uint64_t lbl=c->ops[i]->args[0];
            if(lbl<MAX_BB&&!bbs[lbl]){
                char nm[32];snprintf(nm,sizeof(nm),"L%lu",(unsigned long)lbl);
                bbs[lbl]=LLVM_AppendBasicBlockInContext(llvm_ctx,fn,nm);
            }
        }
    }
    /* Start at entry */
    LLVM_PositionBuilderAtEnd(b,bbs[0]);
    int cur_bb __attribute__((unused)) = 0;

    LLVMValueRef vr[LLVM_MAX_TEMPS]={NULL};
    for(uint32_t i=0;i<nops;i++){
        SavedTCGOp *op=c->ops[i];uint16_t oc=op->opc;

        /* set_label: switch to new BB */
        if(oc==INDEX_op_set_label){
            uint64_t lbl=op->args[0];
            if(lbl<MAX_BB&&bbs[lbl]){
                LLVM_BuildBr(b,bbs[lbl]);LLVM_PositionBuilderAtEnd(b,bbs[lbl]);
                cur_bb=(int)lbl;
        }

        if(oc==INDEX_op_insn_start||oc==INDEX_op_discard||oc==INDEX_op_mb)continue;

        /* br: unconditional jump to target label */
        if(oc==INDEX_op_br){
            uint64_t tgt=op->args[0];
            if(tgt>=MAX_BB||!bbs[tgt]){LOG_FALLBACK(tb,oc,i,nops);LLVM_BuildRet(b,LLVM_ConstInt(i64,0,0));LLVM_DisposeBuilder(b);LLVM_DisposeModule(mod);return -1;}
            LLVM_BuildBr(b,bbs[tgt]);continue;
        }

        /* brcond: conditional jump */
        if(oc==INDEX_op_brcond){
            /* args: [arg1, arg2, cond, label] — 4 args */
            uint64_t arg1_enc=op->args[0],arg2_enc=op->args[1],cond_code=op->args[2],lbl=op->args[3];
            LLVMValueRef a1;if(is_temp(arg1_enc)&&!is_global_temp(arg1_enc)&&temp_off(arg1_enc)<LLVM_MAX_TEMPS&&vr[temp_off(arg1_enc)])a1=vr[temp_off(arg1_enc)];
            else if(is_global_temp(arg1_enc)){LLVMValueRef g=LLVM_BuildIntToPtr(b,env_ptr,ptr,"");a1=LLVM_BuildLoad2(b,i64,LLVM_BuildAdd(b,g,LLVM_ConstInt(i64,(unsigned long long)temp_off(arg1_enc),0),""),"");}
            else a1=LLVM_ConstInt(i64,(unsigned long long)arg1_enc,0);
            LLVMValueRef a2;if(is_temp(arg2_enc)&&!is_global_temp(arg2_enc)&&temp_off(arg2_enc)<LLVM_MAX_TEMPS&&vr[temp_off(arg2_enc)])a2=vr[temp_off(arg2_enc)];
            else if(is_global_temp(arg2_enc)){LLVMValueRef g=LLVM_BuildIntToPtr(b,env_ptr,ptr,"");a2=LLVM_BuildLoad2(b,i64,LLVM_BuildAdd(b,g,LLVM_ConstInt(i64,(unsigned long long)temp_off(arg2_enc),0),""),"");}
            else a2=LLVM_ConstInt(i64,(unsigned long long)arg2_enc,0);
            LLVMValueRef ic=LLVM_BuildICmp(b,(LLVMIntPredicate)cond_code,a1,a2,"brc");
            if(lbl>=MAX_BB||!bbs[lbl]){LOG_FALLBACK(tb,oc,i,nops);LLVM_BuildRet(b,LLVM_ConstInt(i64,0,0));LLVM_DisposeBuilder(b);LLVM_DisposeModule(mod);return -1;}
            /* Need a fall-through BB. Create one if it doesn't exist */
            LLVMBasicBlockRef next=LLVM_AppendBasicBlockInContext(llvm_ctx,fn,"next");
            LLVM_BuildCondBr(b,ic,bbs[lbl],next);
            LLVM_PositionBuilderAtEnd(b,next);
            continue;
        }

        /* mov */
        if(oc==INDEX_op_mov){uint64_t d=op->args[0],s=op->args[1];int di=(int)(d&(~(1ULL<<63)));
            if(di<LLVM_MAX_TEMPS){if(is_temp(s)&&!is_global_temp(s)&&temp_off(s)<LLVM_MAX_TEMPS&&vr[temp_off(s)])vr[di]=vr[temp_off(s)];
            else if(is_global_temp(s)){LLVMValueRef g=LLVM_BuildIntToPtr(b,env_ptr,ptr,"");vr[di]=LLVM_BuildLoad2(b,i64,LLVM_BuildAdd(b,g,LLVM_ConstInt(i64,(unsigned long long)temp_off(s),0),""),"");}
            else vr[di]=LLVM_ConstInt(i64,(unsigned long long)s,0);}continue;}

        /* exit_tb / goto_tb / goto_ptr */
        if(oc==INDEX_op_exit_tb){LLVM_BuildRet(b,LLVM_ConstInt(i64,op->args[0],0));continue;}
        if(oc==INDEX_op_goto_tb){LLVM_BuildRet(b,LLVM_ConstInt(i64,op->args[0],0));continue;}
        if(oc==INDEX_op_goto_ptr){LLVM_BuildRet(b,LLVM_ConstInt(i64,0,0));continue;}

        /* call helper */
        if(oc==INDEX_op_call){uint32_t nr_out=op->param2,nr_in=op->param1,total=nr_out+nr_in+2;uint64_t func_raw=op->args[total-2];
            if(!func_raw){LOG_FALLBACK(tb,oc,i,nops);LLVM_BuildRet(b,LLVM_ConstInt(i64,0,0));LLVM_DisposeBuilder(b);LLVM_DisposeModule(mod);return -1;}
            LLVMValueRef cargs[8];uint32_t nc=0;cargs[nc++]=env_ptr;
            for(uint32_t j=nr_out;j<nr_out+nr_in&&nc<8;j++){uint64_t a=op->args[j];
                if(is_temp(a)&&!is_global_temp(a)&&temp_off(a)<LLVM_MAX_TEMPS&&vr[temp_off(a)])cargs[nc++]=vr[temp_off(a)];
                else if(is_global_temp(a)){LLVMValueRef g=LLVM_BuildIntToPtr(b,env_ptr,ptr,"");cargs[nc++]=LLVM_BuildLoad2(b,i64,LLVM_BuildAdd(b,g,LLVM_ConstInt(i64,(unsigned long long)temp_off(a),0),""),"");}
                else cargs[nc++]=LLVM_ConstInt(i64,(unsigned long long)a,0);}
            LLVMValueRef cfn=LLVM_BuildIntToPtr(b,LLVM_ConstInt(i64,(unsigned long long)func_raw,0),LLVM_PointerTypeInContext(llvm_ctx,0),"helper");
            LLVMTypeRef vfn_t=LLVM_FunctionType(i64,NULL,0,1);LLVMValueRef cr=LLVM_BuildCall2(b,vfn_t,cfn,cargs,nc,"");
            if(nr_out>=1&&cr){int di=(int)(op->args[0]&(~(1ULL<<63)));if(di<LLVM_MAX_TEMPS)vr[di]=cr;}continue;}

        if(oc==INDEX_op_qemu_ld){uint64_t dst_raw=op->args[0],addr_enc=op->args[1],oi=op->args[2];
            LLVMValueRef av;if(is_temp(addr_enc)&&!is_global_temp(addr_enc)&&temp_off(addr_enc)<LLVM_MAX_TEMPS&&vr[temp_off(addr_enc)])av=vr[temp_off(addr_enc)];
            else if(is_global_temp(addr_enc)){LLVMValueRef g=LLVM_BuildIntToPtr(b,env_ptr,ptr,"");av=LLVM_BuildLoad2(b,i64,LLVM_BuildAdd(b,g,LLVM_ConstInt(i64,(unsigned long long)temp_off(addr_enc),0),""),"");}
            else av=LLVM_ConstInt(i64,(unsigned long long)addr_enc,0);
            LLVMValueRef hfn=LLVM_BuildIntToPtr(b,LLVM_ConstInt(i64,(unsigned long long)(uintptr_t)helper_ldul_mmu,0),ptr,"ldh");
            LLVMValueRef largs[]={env_ptr,av,LLVM_ConstInt(i64,oi,0),LLVM_ConstInt(i64,0,0)};
            LLVMValueRef lr=LLVM_BuildCall2(b,LLVM_FunctionType(i64,NULL,0,1),hfn,largs,4,"ldr");
            int di=(int)(dst_raw&(~(1ULL<<63)));if(di<LLVM_MAX_TEMPS)vr[di]=lr;continue;}
        if(oc==INDEX_op_qemu_st){uint64_t addr_enc=op->args[0],val_enc=op->args[1],oi=op->args[2];
            LLVMValueRef av;if(is_temp(addr_enc)&&!is_global_temp(addr_enc)&&temp_off(addr_enc)<LLVM_MAX_TEMPS&&vr[temp_off(addr_enc)])av=vr[temp_off(addr_enc)];
            else if(is_global_temp(addr_enc)){LLVMValueRef g=LLVM_BuildIntToPtr(b,env_ptr,ptr,"");av=LLVM_BuildLoad2(b,i64,LLVM_BuildAdd(b,g,LLVM_ConstInt(i64,(unsigned long long)temp_off(addr_enc),0),""),"");}
            else av=LLVM_ConstInt(i64,(unsigned long long)addr_enc,0);
            LLVMValueRef vv;if(is_temp(val_enc)&&!is_global_temp(val_enc)&&temp_off(val_enc)<LLVM_MAX_TEMPS&&vr[temp_off(val_enc)])vv=vr[temp_off(val_enc)];
            else vv=LLVM_ConstInt(i64,(unsigned long long)val_enc,0);
            LLVMValueRef hfn=LLVM_BuildIntToPtr(b,LLVM_ConstInt(i64,(unsigned long long)(uintptr_t)helper_stl_mmu,0),ptr,"sth");
            LLVMValueRef sargs[]={env_ptr,av,vv,LLVM_ConstInt(i64,oi,0),LLVM_ConstInt(i64,0,0)};
            LLVM_BuildCall2(b,LLVM_FunctionType(i64,NULL,0,1),hfn,sargs,5,"");continue;}
        if(oc==INDEX_op_ld8u||oc==INDEX_op_ld8s||oc==INDEX_op_ld16u||oc==INDEX_op_ld16s||oc==INDEX_op_ld32u||oc==INDEX_op_ld32s||oc==INDEX_op_ld){
            uint64_t dst_raw=op->args[0],addr_enc=op->args[1],offs=op->args[2];
            LLVMValueRef laddr;if(is_temp(addr_enc)&&!is_global_temp(addr_enc)&&temp_off(addr_enc)<LLVM_MAX_TEMPS&&vr[temp_off(addr_enc)])laddr=vr[temp_off(addr_enc)];
            else laddr=LLVM_ConstInt(i64,(unsigned long long)addr_enc,0);
            LLVMValueRef lptr=LLVM_BuildIntToPtr(b,LLVM_BuildAdd(b,laddr,LLVM_ConstInt(i64,(unsigned long long)offs,0),""),ptr,"ldptr");
            LLVMValueRef lr=LLVM_BuildLoad2(b,i64,lptr,"ld");
            int di=(int)(dst_raw&(~(1ULL<<63)));if(di<LLVM_MAX_TEMPS)vr[di]=lr;continue;}
        if(oc==INDEX_op_st8||oc==INDEX_op_st16||oc==INDEX_op_st32||oc==INDEX_op_st){uint64_t addr_enc=op->args[0],val_enc=op->args[1],offs=op->args[2];
            LLVMValueRef saddr;if(is_temp(addr_enc)&&!is_global_temp(addr_enc)&&temp_off(addr_enc)<LLVM_MAX_TEMPS&&vr[temp_off(addr_enc)])saddr=vr[temp_off(addr_enc)];
            else saddr=LLVM_ConstInt(i64,(unsigned long long)addr_enc,0);
            LLVMValueRef sval;if(is_temp(val_enc)&&!is_global_temp(val_enc)&&temp_off(val_enc)<LLVM_MAX_TEMPS&&vr[temp_off(val_enc)])sval=vr[temp_off(val_enc)];
            else sval=LLVM_ConstInt(i64,(unsigned long long)val_enc,0);
            LLVMValueRef sptr=LLVM_BuildIntToPtr(b,LLVM_BuildAdd(b,saddr,LLVM_ConstInt(i64,(unsigned long long)offs,0),""),ptr,"stptr");LLVM_BuildStore(b,sval,sptr);continue;}
        if(oc==INDEX_op_plugin_cb||oc==INDEX_op_plugin_mem_cb||oc==INDEX_op_qemu_ld2||oc==INDEX_op_qemu_st2){LOG_FALLBACK(tb,oc,i,nops);LLVM_BuildRet(b,LLVM_ConstInt(i64,0,0));LLVM_DisposeBuilder(b);LLVM_DisposeModule(mod);return -1;}
        LLVMValueRef in[3]={NULL,NULL,NULL};uint64_t di=0;
        for(uint16_t j=1;j<op->nargs&&(j-1)<3;j++){uint64_t a=op->args[j];
            if(is_temp(a)&&!is_global_temp(a)&&temp_off(a)<LLVM_MAX_TEMPS&&vr[temp_off(a)])in[j-1]=vr[temp_off(a)];
            else if(is_global_temp(a)){LLVMValueRef g=LLVM_BuildIntToPtr(b,env_ptr,ptr,"");in[j-1]=LLVM_BuildLoad2(b,i64,LLVM_BuildAdd(b,g,LLVM_ConstInt(i64,(unsigned long long)temp_off(a),0),""),"");}
            else in[j-1]=LLVM_ConstInt(i64,(unsigned long long)a,0);}
        if(op->nargs>=1)di=op->args[0];LLVMValueRef r=NULL;
        switch(oc){
            case INDEX_op_add:r=LLVM_BuildAdd(b,in[0],in[1],"");break;
            case INDEX_op_sub:r=LLVM_BuildSub(b,in[0],in[1],"");break;
            case INDEX_op_mul:r=LLVM_BuildMul(b,in[0],in[1],"");break;
            case INDEX_op_and:r=LLVM_BuildAnd(b,in[0],in[1],"");break;
            case INDEX_op_or: r=LLVM_BuildOr(b,in[0],in[1],"");break;
            case INDEX_op_xor:r=LLVM_BuildXor(b,in[0],in[1],"");break;
            case INDEX_op_shl:r=LLVM_BuildShl(b,in[0],in[1],"");break;
            case INDEX_op_shr:r=LLVM_BuildLShr(b,in[0],in[1],"");break;
            case INDEX_op_sar:r=LLVM_BuildAShr(b,in[0],in[1],"");break;
            case INDEX_op_neg:r=LLVM_BuildSub(b,LLVM_ConstInt(i64,0,0),in[0],"");break;
            case INDEX_op_not:r=LLVM_BuildXor(b,in[0],LLVM_ConstInt(i64,~0ULL,0),"");break;
            case INDEX_op_ext_i32_i64:r=LLVM_BuildSExt(b,LLVM_BuildTrunc(b,in[0],i32,""),i64,"");break;
            case INDEX_op_extu_i32_i64:r=LLVM_BuildZExt(b,LLVM_BuildTrunc(b,in[0],i32,""),i64,"");break;
            case INDEX_op_setcond:{LLVMIntPredicate p=(LLVMIntPredicate)op->args[2];LLVMValueRef cm=LLVM_BuildICmp(b,p,in[0],in[1],"");r=LLVM_BuildZExt(b,cm,i64,"");}break;
            case INDEX_op_movcond:LOG_FALLBACK(tb,oc,i,nops);LLVM_BuildRet(b,LLVM_ConstInt(i64,0,0));LLVM_DisposeBuilder(b);LLVM_DisposeModule(mod);return -1;
            case INDEX_op_extract:{LLVMValueRef pos=LLVM_ConstInt(i64,(unsigned long long)op->args[2],0),len=LLVM_ConstInt(i64,(unsigned long long)op->args[3],0);r=LLVM_BuildAnd(b,LLVM_BuildLShr(b,in[0],pos,""),LLVM_BuildSub(b,LLVM_BuildShl(b,LLVM_ConstInt(i64,1,0),len,""),LLVM_ConstInt(i64,1,0),""),"");}break;
            case INDEX_op_extrl_i64_i32:r=LLVM_BuildTrunc(b,in[0],i32,"");break;
            case INDEX_op_extrh_i64_i32:r=LLVM_BuildTrunc(b,LLVM_BuildLShr(b,in[0],LLVM_ConstInt(i64,32,0),""),i32,"");break;
            case INDEX_op_sextract:{LLVMValueRef sp=LLVM_ConstInt(i64,(unsigned long long)op->args[2],0),sl=LLVM_ConstInt(i64,(unsigned long long)op->args[3],0);LLVMValueRef sv=LLVM_BuildLShr(b,in[0],sp,"");sv=LLVM_BuildAnd(b,sv,LLVM_BuildSub(b,LLVM_BuildShl(b,LLVM_ConstInt(i64,1,0),sl,""),LLVM_ConstInt(i64,1,0),""),"");LLVMValueRef sm=LLVM_BuildSub(b,sl,LLVM_ConstInt(i64,1,0),"");LLVMValueRef ss=LLVM_BuildShl(b,sv,LLVM_BuildSub(b,LLVM_ConstInt(i64,64,0),sl,""),"");r=LLVM_BuildAShr(b,ss,LLVM_BuildSub(b,LLVM_ConstInt(i64,64,0),sl,""),"");}break;
            case INDEX_op_deposit:{LLVMValueRef pos=LLVM_ConstInt(i64,(unsigned long long)op->args[2],0),len=LLVM_ConstInt(i64,(unsigned long long)op->args[3],0);LLVMValueRef mk=LLVM_BuildSub(b,LLVM_BuildShl(b,LLVM_ConstInt(i64,1,0),len,""),LLVM_ConstInt(i64,1,0),"");LLVMValueRef sm=LLVM_BuildShl(b,mk,pos,"");LLVMValueRef nm=LLVM_BuildXor(b,LLVM_ConstInt(i64,~0ULL,0),sm,"");LLVMValueRef cl=LLVM_BuildAnd(b,in[0],nm,"");LLVMValueRef vs=LLVM_BuildShl(b,LLVM_BuildAnd(b,in[1],mk,""),pos,"");r=LLVM_BuildOr(b,cl,vs,"");}break;
            default:LOG_FALLBACK(tb,oc,i,nops);LLVM_BuildRet(b,LLVM_ConstInt(i64,0,0));LLVM_DisposeBuilder(b);LLVM_DisposeModule(mod);return -1;}
        if(r){if(is_global_temp(di)){LLVMValueRef g=LLVM_BuildIntToPtr(b,env_ptr,ptr,"");LLVM_BuildStore(b,r,LLVM_BuildAdd(b,g,LLVM_ConstInt(i64,(unsigned long long)temp_off(di),0),""));}else{int ti=(int)(di&(~(1ULL<<63)));if(ti<LLVM_MAX_TEMPS)vr[ti]=r;}}
    }
    /* Final fallthrough: return 0 if no exit_tb terminated */
    LLVM_BuildRet(b,LLVM_ConstInt(i64,0,0));
    LLVM_DisposeBuilder(b);
    *out_module=(void*)mod;
    fprintf(stderr,"[llvm-trans] TB=%p SUCCESS\n",(void*)tb);
    return 0;
}
}
TR_C_END


    # ── llvm-worker.h ──────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-worker.h" << 'W_H_END'
#ifndef TCG_LLVM_WORKER_H
#define TCG_LLVM_WORKER_H
int  llvm_workers_init(int n);
void llvm_workers_shutdown(void);
#endif
W_H_END

    # ── llvm-worker.c (bg compile thread pool) ────────────────
    cat > "$LLVM_DIR/llvm-worker.c" << 'W_C_END'
#include "qemu/osdep.h"
#include "qemu/atomic.h"
#include "qemu/thread.h"
#include "exec/translation-block.h"
#include "tcg/tcg.h"
#include "llvm-common.h"
#include "llvm-queue.h"
#include "llvm-translate.h"
#include "llvm-jit.h"
#include "llvm-worker.h"

static QemuThread *workers=NULL;
static int num_workers=0;
static bool worker_shutdown=false;

static void *llvm_worker_thread(void *arg) {
    int id=(int)(intptr_t)arg;char nm[32];snprintf(nm,sizeof(nm),"llvm-worker-%d",id);
    qemu_thread_set_name(nm);
    fprintf(stderr,"[llvm-worker-%d] ALIVE entering main loop\n",id);
    while(!qatomic_read(&worker_shutdown)){
        fprintf(stderr,"[llvm-worker-%d] DQ calling dequeue (head=%lu tail=%lu)\n",id,
            (unsigned long)qatomic_read(&llvm_compile_queue.head),
            (unsigned long)qatomic_read(&llvm_compile_queue.tail));
        void *tp=llvm_queue_dequeue(&llvm_compile_queue);
        fprintf(stderr,"[llvm-worker-%d] DQ result=%p\n",id,tp);
        if(!tp){g_usleep(500000);continue;}
        struct TranslationBlock *tb=(struct TranslationBlock*)tp;
        TBLLVMState *s=llvm_tb_state_get(tb);
        if(!s||!s->compiling||s->permanently_failed)continue;
        fprintf(stderr,"[llvm-worker-%d] compiling TB=%p pc=0x%lx\n",id,tp,(unsigned long)tb->pc);
        int64_t st=g_get_monotonic_time()*1000;
        void *mod=NULL;
        int to=llvm_translate_tb(tb,&mod);
        if(to!=0||!mod){
            s->permanently_failed=true;s->llvm_failed=true;
            qatomic_set(&s->state,LLVM_STATE_DISABLED);s->compiling=false;
            qatomic_inc(&llvm_stats.tbs_failed);qatomic_inc(&llvm_stats.permanently_failed_tbs);
            fprintf(stderr,"[llvm-worker-%d] TB=%p permanently failed\n",id,tp);continue;
        }
        LLVMCompileResult cr;
        int co=llvm_orc_compile(mod,"tcg_exec",&cr);
        int64_t en=g_get_monotonic_time()*1000;uint64_t el=(uint64_t)(en-st);
        if(co!=0||!cr.code){
            s->permanently_failed=true;s->llvm_failed=true;
            qatomic_set(&s->state,LLVM_STATE_DISABLED);s->compiling=false;
            qatomic_inc(&llvm_stats.tbs_failed);qatomic_inc(&llvm_stats.permanently_failed_tbs);
            fprintf(stderr,"[llvm-worker-%d] TB=%p ORC permanently failed\n",id,tp);continue;
        }
        s->llvm_code=cr.code;s->llvm_code_size=cr.size;s->compile_ns=el;
        qatomic_set(&s->state,LLVM_STATE_READY);s->compiling=false;
        qatomic_inc(&llvm_stats.tbs_compiled);qatomic_add(&llvm_stats.total_compile_ns,el);
        fprintf(stderr,"[llvm-worker-%d] TB=%p COMPILED code=%p\n",id,tp,cr.code);
    }
    fprintf(stderr,"[llvm-worker-%d] exiting\n",id);return NULL;
}
int llvm_workers_init(int n){
    if(num_workers>0)return 0;if(n<=0)n=1;if(n>LLVM_MAX_WORKERS)n=LLVM_MAX_WORKERS;
    qatomic_set(&worker_shutdown,false);workers=g_new0(QemuThread,n);
    for(int i=0;i<n;i++)qemu_thread_create(&workers[i],"llvm-worker",llvm_worker_thread,(void*)(intptr_t)i,QEMU_THREAD_JOINABLE);
    num_workers=n;fprintf(stderr,"[llvm-worker] %d threads spawned\n",n);return 0;
}
void llvm_workers_shutdown(void){
    if(!num_workers)return;qatomic_set(&worker_shutdown,true);
    llvm_queue_shutdown(&llvm_compile_queue);
    for(int i=0;i<num_workers;i++)qemu_thread_join(&workers[i]);
    g_free(workers);workers=NULL;num_workers=0;
}
W_C_END

    # ── llvm-signal.h ──────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-signal.h" << 'S_H_END'
#ifndef TCG_LLVM_SIGNAL_H
#define TCG_LLVM_SIGNAL_H
void llvm_flush_all(void);
void llvm_invalidate_tb(void *tb);
#endif
S_H_END

    # ── llvm-signal.c ──────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-signal.c" << 'S_C_END'
#include "qemu/osdep.h"
#include "qemu/atomic.h"
#include "exec/translation-block.h"
#include "llvm-common.h"
#include "llvm-signal.h"
void llvm_flush_all(void) {
    if(!llvm_is_enabled())return;
    llvm_tb_state_remove_all();
    qatomic_add(&llvm_stats.invalidations,1);
}
void llvm_invalidate_tb(void *tb) {
    if(!llvm_is_enabled())return;
    TBLLVMState *s=llvm_tb_state_get(tb);
    if(!s)return;
    qatomic_set(&s->state,LLVM_STATE_NONE);
    s->llvm_code=NULL;s->compiling=false;
    qatomic_add(&llvm_stats.invalidations,1);
}
S_C_END

    # ── meson.build cho tcg/llvm/ ──────────────────────────────
    cat > "$LLVM_DIR/meson.build" << 'MESON_END'
llvm_hybrid_srcs = files(
  'llvm-common.c', 'llvm-queue.c', 'llvm-profiler.c',
  'llvm-jit.c', 'llvm-translate.c', 'llvm-worker.c', 'llvm-signal.c',
)
tcg_ss.add(llvm_hybrid_srcs)
MESON_END

    # ── Patch tcg/meson.build ──────────────────────────────────
    local _tcg_meson="$QEMU_SRC_DIR/tcg/meson.build"
    if grep -q "subdir('llvm')" "$_tcg_meson" 2>/dev/null; then
        echo -e "${G}✔${W} tcg/meson.build already patched"
    else
        sed -i '/^user_ss\.add_all(tcg_ss)/i subdir('"'"'llvm'"'"')\n' "$_tcg_meson"
        echo -e "${G}✔${W} patched tcg/meson.build → subdir('llvm')"
    fi

    # ── Apply QEMU source patches via sed ──────────────────────
    _llvm_hybrid_patch_qemu "$QEMU_SRC_DIR"

    echo -e "${G}✔${W} LLVM hybrid setup complete"
    return 0
}

# ── Apply QEMU source patches ───────────────────────────────────
_llvm_hybrid_patch_qemu() {
    local Q="$1"
    local _patched=0

    # cpu-exec.c: add includes + profile call + LLVM dispatch
    # Dual verify: check BOTH includes AND call site
    local _ce_includes_ok=0
    local _ce_callsite_ok=0

    if grep -q "llvm-profiler.h" "$Q/accel/tcg/cpu-exec.c" 2>/dev/null; then
        _ce_includes_ok=1
    else
        sed -i '/^#include "tcg\/tcg.h"$/a\#include "tcg/llvm/llvm-profiler.h"\n#include "tcg/llvm/llvm-common.h"\n#include "tcg/llvm/llvm-translate.h"' "$Q/accel/tcg/cpu-exec.c"
        grep -q "llvm-profiler.h" "$Q/accel/tcg/cpu-exec.c" && _ce_includes_ok=1
    fi

    if grep -q "llvm_profile_tb(tb)" "$Q/accel/tcg/cpu-exec.c" 2>/dev/null && \
       grep -q "llvm_use_llvm(itb)" "$Q/accel/tcg/cpu-exec.c" 2>/dev/null; then
        _ce_callsite_ok=1
    else
        # Apply profile call
        if ! grep -q "llvm_profile_tb" "$Q/accel/tcg/cpu-exec.c" 2>/dev/null; then
            sed -i '/trace_exec_tb(tb, pc);/a\    llvm_profile_tb(tb);' "$Q/accel/tcg/cpu-exec.c"
        fi
        # Apply dispatch block via python3
        if ! grep -q "llvm_use_llvm(itb)" "$Q/accel/tcg/cpu-exec.c" 2>/dev/null; then
            python3 -c "
import re
f='$Q/accel/tcg/cpu-exec.c'
with open(f) as fh: c=fh.read()
old = r'(    uintptr_t ret;\n    TranslationBlock \*last_tb;\n)    const void \*tb_ptr = itb->tc\.ptr;'
new = r'''\1    const void *tb_ptr;

    /* LLVM Hybrid: dispatch LLVM-compiled code */
    if (llvm_use_llvm(itb)) {
        TBLLVMState *ls = llvm_tb_state_get(itb);
        if (ls && ls->llvm_code) {
            uintptr_t llvm_ret;
            llvm_ret = (uintptr_t)((int64_t (*)(void *, void *))ls->llvm_code)(cpu_env(cpu), &llvm_helpers);
            last_tb = tcg_splitwx_to_rw((void *)(llvm_ret & ~TB_EXIT_MASK));
            *tb_exit = llvm_ret & TB_EXIT_MASK;
            qatomic_inc(&llvm_stats.llvm_exec_count);
            qemu_plugin_disable_mem_helpers(cpu);
            trace_exec_tb_exit(last_tb, *tb_exit);
            if (*tb_exit > TB_EXIT_IDX1) return NULL;
            return last_tb ? last_tb : itb;
        }
    }

    /* Standard TCG dispatch */
    tb_ptr = itb->tc.ptr;'''
c2=re.sub(old,new,c)
if c2!=c: print('  cpu-exec.c: dispatch injected')
else: print('  cpu-exec.c: dispatch pattern NOT matched')
with open(f,'w') as fh: fh.write(c2)
"
        fi
        grep -q "llvm_profile_tb(tb)" "$Q/accel/tcg/cpu-exec.c" 2>/dev/null && \
        grep -q "llvm_use_llvm(itb)" "$Q/accel/tcg/cpu-exec.c" 2>/dev/null && _ce_callsite_ok=1
    fi

    if [[ "$_ce_includes_ok" == "1" && "$_ce_callsite_ok" == "1" ]]; then
        echo "  cpu-exec.c: PATCHED (includes + callsite verified)"
        ((_patched++))
    else
        echo -e "${Y}⚠${W}  cpu-exec.c: PATCH FAILED — includes=$_ce_includes_ok callsite=$_ce_callsite_ok"
        [[ "$_ce_includes_ok" != "1" ]] && echo "     Missing: llvm include headers"
        [[ "$_ce_callsite_ok" != "1" ]] && echo "     Missing: llvm_profile_tb / llvm_use_llvm calls"
    fi

    # translate-all.c: add capture hook
    if grep -q "llvm-profiler.h" "$Q/accel/tcg/translate-all.c" 2>/dev/null; then
        echo "  translate-all.c: already patched"
    else
        sed -i '/^#include "tcg\/insn-start-words.h"$/a\#include "tcg/llvm/llvm-profiler.h"' "$Q/accel/tcg/translate-all.c"
        sed -i '/\*max_insns = tb->icount;/a\    llvm_capture_tb_ops(tcg_ctx, tb);' "$Q/accel/tcg/translate-all.c"
        echo "  translate-all.c: PATCHED"
        ((_patched++))
    fi

    # tb-maint.c: add invalidation hooks
    if grep -q "llvm-signal.h" "$Q/accel/tcg/tb-maint.c" 2>/dev/null; then
        echo "  tb-maint.c: already patched"
    else
        sed -i '/^#include "tcg\/tcg.h"$/a\#include "tcg/llvm/llvm-signal.h"' "$Q/accel/tcg/tb-maint.c"
        sed -i '/qatomic_inc(&tb_ctx.tb_flush_count);/a\    llvm_flush_all();' "$Q/accel/tcg/tb-maint.c"
        sed -i '/qatomic_set(&tb_ctx.tb_phys_invalidate_count,/{
:loop
n
/tb_ctx.tb_phys_invalidate_count + 1);/!b loop
a\
    llvm_invalidate_tb(tb);
}' "$Q/accel/tcg/tb-maint.c"
        echo "  tb-maint.c: PATCHED"
        ((_patched++))
    fi

    # tcg-all.c: add LLVM init — verify BOTH include AND init call
    local _tcg_includes_ok=0
    local _tcg_initcall_ok=0

    if grep -q "llvm-common.h" "$Q/accel/tcg/tcg-all.c" 2>/dev/null; then
        _tcg_includes_ok=1
    else
        sed -i '/^#include "internal-common.h"$/a\#include "tcg/llvm/llvm-common.h"\n#include "tcg/llvm/llvm-jit.h"\n#include "tcg/llvm/llvm-queue.h"\n#include "tcg/llvm/llvm-worker.h"' "$Q/accel/tcg/tcg-all.c"
        grep -q "llvm-common.h" "$Q/accel/tcg/tcg-all.c" && _tcg_includes_ok=1
    fi

    if grep -q "llvm_global_init();" "$Q/accel/tcg/tcg-all.c" 2>/dev/null; then
        _tcg_initcall_ok=1
    else
        sed -i '/tcg_init(s->tb_size \* MiB, s->splitwx_enabled, max_threads);/a\
\
    fprintf(stderr, \"[llvm] tcg-all.c init call reached\\n\");\
    llvm_global_init();\
    llvm_queue_init(&llvm_compile_queue);\
    if (llvm_orc_init() == 0) {\
        llvm_workers_init(llvm_global.max_workers);\
    } else {\
        llvm_global.enabled = false;\
        fprintf(stderr, \"[llvm] ORC JIT init failed - TCG-only mode\\n\");\
    }' "$Q/accel/tcg/tcg-all.c"
        grep -q "llvm_global_init();" "$Q/accel/tcg/tcg-all.c" && _tcg_initcall_ok=1
    fi

    if [[ "$_tcg_includes_ok" == "1" && "$_tcg_initcall_ok" == "1" ]]; then
        echo "  tcg-all.c: PATCHED (includes + init call verified)"
        ((_patched++))
    else
        echo -e "${Y}⚠${W}  tcg-all.c: PATCH FAILED — includes=$_tcg_includes_ok init=$_tcg_initcall_ok — LLVM will NOT init!"
        [[ "$_tcg_includes_ok" != "1" ]] && echo "     Missing: llvm-common.h include"
        [[ "$_tcg_initcall_ok" != "1" ]] && echo "     Missing: llvm_global_init() call"
    fi

    echo "  Patched ${_patched} QEMU source files"
}

# ════════════════════════════════════════════════════════════════
#  BUILD LIBRARIES FROM SOURCE (khi không có conda)
# ════════════════════════════════════════════════════════════════

_build_zlib_from_source() {
    local prefix="$1"; local build_dir="$2"
    _rl_step "${_RL_N:-1}" "${_RL_T:-10}" "zlib 1.3.1"
    cd "$build_dir"
    rm -f zlib.tar.gz
    local _ok=0
    for _url in \
        "https://zlib.net/zlib-1.3.1.tar.gz" \
        "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz" \
        "https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz"; do
        wget -q --timeout=60 --tries=2 "$_url" -O zlib.tar.gz 2>/dev/null \
            && tar tzf zlib.tar.gz &>/dev/null && _ok=1 && break
        echo -e "${Y}⚠${W}  zlib URL thất bại: $_url"
    done
    [[ "$_ok" == "0" ]] && { echo -e "${R}✘${W} Không tải được zlib"; exit 1; }
    tar xzf zlib.tar.gz 2>/dev/null || { echo -e "${R}✘${W} Giải nén zlib thất bại"; exit 1; }
    local _d; _d=$(ls -d zlib-*/ 2>/dev/null | head -1 | tr -d /)
    [[ -d "$_d" ]] || { echo -e "${R}✘${W} Không tìm thấy thư mục zlib"; exit 1; }
    cd "$_d"
    # Patch out the "too harsh" if-block using python3 (safe: removes full if/fi block)
    python3 - configure <<'PYEOF'
import sys
fname = sys.argv[1]
with open(fname, 'r', errors='replace') as f:
    lines = f.readlines()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.strip().startswith('if ') or line.strip().startswith('if\t'):
        block = [line]
        depth = 1
        j = i + 1
        while j < len(lines) and depth > 0:
            bl = lines[j].strip()
            if bl.startswith('if ') or bl.startswith('if\t') or bl == 'if':
                depth += 1
            if bl == 'fi' or bl.startswith('fi;') or bl.startswith('fi '):
                depth -= 1
            block.append(lines[j])
            j += 1
        if 'too harsh' in ''.join(block):
            i = j
            continue
        else:
            out.extend(block)
            i = j
    else:
        out.append(line)
        i += 1
with open(fname, 'w') as f:
    f.writelines(out)
pass  # suppressed
PYEOF
    local _cc="${CC_PLAIN:-$(command -v gcc || command -v cc)}"
    local _cxx="${CXX_PLAIN:-$(command -v g++ || command -v c++)}"
    local _ar="${AR:-ar}"
    local _ranlib="${RANLIB:-ranlib}"

    # Ensure compiler bin dir in PATH so configure can find ar/ranlib
    local _cc_dir; _cc_dir="$(dirname "$_cc")"
    [[ -d "$_cc_dir" ]] && export PATH="$_cc_dir:$PATH"

    # Try shared first, fall back to static
    if env CC="$_cc" CXX="$_cxx" AR="$_ar" RANLIB="$_ranlib" \
        CFLAGS="-w -O2" CXXFLAGS="-w -O2" LDFLAGS="" \
        ./configure --prefix="$prefix" --shared > /tmp/zlib-build.log 2>&1; then
        : # shared OK
    else
        env CC="$_cc" CXX="$_cxx" AR="$_ar" RANLIB="$_ranlib" \
            CFLAGS="-w -O2" CXXFLAGS="-w -O2" LDFLAGS="" \
            ./configure --prefix="$prefix" > /tmp/zlib-build.log 2>&1 \
            || { echo -e "${R}✘${W} Configure zlib thất bại — xem /tmp/zlib-build.log"; exit 1; }
    fi
    ${MAKE:-make} -j"$(nproc)" AR="$_ar" RANLIB="$_ranlib" >> /tmp/zlib-build.log 2>&1 \
        || { echo -e "${R}✘${W} Build zlib thất bại — xem /tmp/zlib-build.log"; exit 1; }
    ${MAKE:-make} install AR="$_ar" RANLIB="$_ranlib" >> /tmp/zlib-build.log 2>&1 \
        || { echo -e "${R}✘${W} Install zlib thất bại — xem /tmp/zlib-build.log"; exit 1; }
    _rl_ok "zlib 1.3.1 xong"
    echo "libffi" > "$BUILD/.rootless-resume"
}

_build_libffi_from_source() {
    local prefix="$1"; local build_dir="$2"
    _rl_step "${_RL_N:-2}" "${_RL_T:-10}" "libffi 3.4.6"
    cd "$build_dir"
    rm -f libffi.tar.gz
    wget -q --timeout=60 --tries=2 \
        "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz" \
        -O libffi.tar.gz 2>/dev/null \
        || wget -q --timeout=60 --tries=2 \
        "https://sourceware.org/pub/libffi/libffi-3.4.6.tar.gz" \
        -O libffi.tar.gz 2>/dev/null \
        || { echo -e "${R}✘${W} Không tải được libffi"; exit 1; }
    tar xzf libffi.tar.gz 2>/dev/null || { echo -e "${R}✘${W} Giải nén libffi thất bại"; exit 1; }
    cd libffi-3.4.6
    local _cc="${CC_PLAIN:-$(command -v gcc || command -v cc)}"
    local _ar="${AR:-ar}"
    local _ranlib="${RANLIB:-ranlib}"
    local _cc_dir; _cc_dir="$(dirname "$_cc")"
    [[ -d "$_cc_dir" ]] && export PATH="$_cc_dir:$PATH"
    env CC="$_cc" AR="$_ar" RANLIB="$_ranlib" \
        ./configure --prefix="$prefix" > /tmp/libffi-build.log 2>&1 \
        || { echo -e "${R}✘${W} Configure libffi thất bại"; exit 1; }
    ${MAKE:-make} -j"$(nproc)" AR="$_ar" RANLIB="$_ranlib" >> /tmp/libffi-build.log 2>&1 \
        || { echo -e "${R}✘${W} Build libffi thất bại"; exit 1; }
    ${MAKE:-make} install AR="$_ar" RANLIB="$_ranlib" >> /tmp/libffi-build.log 2>&1 \
        || { echo -e "${R}✘${W} Install libffi thất bại"; exit 1; }
    _rl_ok "libffi 3.4.6 xong"
    echo "pixman" > "$BUILD/.rootless-resume"
}

_build_pixman_from_source() {
    local prefix="$1"; local build_dir="$2"
    _rl_step "${_RL_N:-3}" "${_RL_T:-10}" "pixman 0.42.2"
    cd "$build_dir"
    rm -f pixman.tar.gz
    wget -q --timeout=60 --tries=2 \
        "https://cairographics.org/releases/pixman-0.42.2.tar.gz" \
        -O pixman.tar.gz 2>/dev/null \
        || { echo -e "${R}✘${W} Không tải được pixman"; exit 1; }
    tar xzf pixman.tar.gz 2>/dev/null || { echo -e "${R}✘${W} Giải nén pixman thất bại"; exit 1; }
    cd pixman-0.42.2
    local _cc="${CC_PLAIN:-$(command -v gcc || command -v cc)}"
    local _ar="${AR:-ar}"
    local _ranlib="${RANLIB:-ranlib}"
    local _cc_dir; _cc_dir="$(dirname "$_cc")"
    [[ -d "$_cc_dir" ]] && export PATH="$_cc_dir:$PATH"
    env CC="$_cc" AR="$_ar" RANLIB="$_ranlib" \
        ./configure --prefix="$prefix" --disable-gtk --enable-shared \
        > /tmp/pixman-build.log 2>&1 \
        || { echo -e "${R}✘${W} Configure pixman thất bại"; exit 1; }
    ${MAKE:-make} -j"$(nproc)" AR="$_ar" RANLIB="$_ranlib" >> /tmp/pixman-build.log 2>&1 \
        || { echo -e "${R}✘${W} Build pixman thất bại"; exit 1; }
    ${MAKE:-make} install AR="$_ar" RANLIB="$_ranlib" >> /tmp/pixman-build.log 2>&1 \
        || { echo -e "${R}✘${W} Install pixman thất bại"; exit 1; }
    _rl_ok "pixman 0.42.2 xong"
    echo "glib" > "$BUILD/.rootless-resume"
}

# ── Thử dùng glib từ conda (nhanh, không cần build) ─────────────
_try_glib_from_conda() {
    local prefix="$1"
    local _GLIB_MIN="2.66.0"

    # helper: trả về 0 nếu version trong .pc >= _GLIB_MIN
    _glib_pc_ver_ok() {
        local _pc="$1/glib-2.0.pc"
        [[ -f "$_pc" ]] || return 1
        local _v
        _v=$(grep "^Version:" "$_pc" 2>/dev/null | awk '{print $2}')
        python3 -c "
a=[int(x) for x in '$_v'.split('.')]
b=[int(x) for x in '${_GLIB_MIN}'.split('.')]
exit(0 if a>=b else 1)
" 2>/dev/null
    }

    # Tìm libglib-2.0.so trong conda
    local _glib_so=""
    for _d in /opt/conda/lib /opt/conda/envs/base/lib "$HOME/.conda/envs/base/lib"; do
        if [[ -f "$_d/libglib-2.0.so" || -f "$_d/libglib-2.0.so.0" ]]; then
            _glib_so="$_d"; break
        fi
    done
    # Kiểm tra pkg-config glib-2.0 từ conda
    local _conda_pc=""
    for _pd in /opt/conda/lib/pkgconfig /opt/conda/share/pkgconfig; do
        [[ -f "$_pd/glib-2.0.pc" ]] && { _conda_pc="$_pd"; break; }
    done
    if [[ -n "$_conda_pc" ]]; then
        # ── Version check: cần >= 2.66.0 ────────────────────────
        if ! _glib_pc_ver_ok "$_conda_pc"; then
            local _found_ver
            _found_ver=$(grep "^Version:" "$_conda_pc/glib-2.0.pc" 2>/dev/null | awk '{print $2}')
            echo -e "${Y}⚠${W}  conda glib ${_found_ver} < ${_GLIB_MIN} — bỏ qua, sẽ build từ source"
            # Không dùng conda glib cũ; fallthrough xuống conda install / build source
        else
            local _found_ver
            _found_ver=$(grep "^Version:" "$_conda_pc/glib-2.0.pc" 2>/dev/null | awk '{print $2}')
            echo -e "${G}✔${W} glib ${_found_ver} tìm thấy trong conda (${_conda_pc}) — bỏ qua build source"
            # KHÔNG copy .pc vào prefix: conda glib build với conda toolchain có
            # GLIB_SIZEOF_SIZE_T khác system gcc → ABI mismatch khi QEMU configure.
            # Thay vào đó: chỉ export header path + LD path, để QEMU meson detect qua
            # PKG_CONFIG_PATH trỏ thẳng vào conda (không qua prefix copy).
            export PKG_CONFIG_PATH="$_conda_pc:${PKG_CONFIG_PATH:-}"
            export PKG_CONFIG_LIBDIR="$_conda_pc:${PKG_CONFIG_LIBDIR:-}"
            # Export LD path
            [[ -n "$_glib_so" ]] && export LD_LIBRARY_PATH="$_glib_so:${LD_LIBRARY_PATH:-}"
            # Mark: đây là conda glib → QEMU configure dùng --without-system-glib nếu cần
            export _GLIB_FROM_CONDA=1
            return 0
        fi  # end version-ok branch
    fi
    # Thử conda install glib nếu có conda
    if command -v conda &>/dev/null; then
        echo -e "${B}ℹ${W}  Thử conda install glib (1-2 phút)..."
        conda install -c conda-forge glib --yes -q > /tmp/conda-glib.log 2>&1 \
            && echo -e "${G}✔${W} conda install glib xong" \
            || { echo -e "${Y}⚠${W}  conda install glib thất bại — sẽ build từ source"; return 1; }
        # Reload + version check
        for _pd in /opt/conda/lib/pkgconfig /opt/conda/share/pkgconfig; do
            if [[ -f "$_pd/glib-2.0.pc" ]]; then
                if ! _glib_pc_ver_ok "$_pd"; then
                    local _cv
                    _cv=$(grep "^Version:" "$_pd/glib-2.0.pc" 2>/dev/null | awk '{print $2}')
                    echo -e "${Y}⚠${W}  conda install glib ${_cv} vẫn < ${_GLIB_MIN} — build từ source"
                    return 1
                fi
                export PKG_CONFIG_PATH="$_pd:${PKG_CONFIG_PATH:-}"
                mkdir -p "$prefix/lib/pkgconfig"
                for _pc in "$_pd"/glib-2.0.pc "$_pd"/gobject-2.0.pc \
                           "$_pd"/gmodule-2.0.pc "$_pd"/gio-2.0.pc; do
                    [[ -f "$_pc" ]] && cp -f "$_pc" "$prefix/lib/pkgconfig/" 2>/dev/null || true
                done
                export LD_LIBRARY_PATH="/opt/conda/lib:${LD_LIBRARY_PATH:-}"
                echo -e "${G}✔${W} glib từ conda sẵn sàng"
                return 0
            fi
        done
    fi
    return 1  # không tìm được — caller sẽ build từ source
}

_build_glib_from_source() {
    local prefix="$1"; local build_dir="$2"; local py_prefix="$3"

    # ── Primary: build glib từ source thuần túy ─────────────────
    # Conda KHÔNG được dùng làm nguồn chính cho glib vì:
    #   conda glib-2.0.pc có Requires: libpcre2-8, nhưng libpcre2-8.pc
    #   không có trong conda → QEMU meson thất bại với "libpcre2-8 not found"
    # Conda chỉ là FALLBACK nếu source build thất bại hoàn toàn.


    # ── Helper: build pcre2 từ source nếu chưa có ───────────────
    _ensure_pcre2() {
        local _ppc="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
        # Kiểm tra pcre2 đã build chưa — dùng pkg-config nếu có, fallback kiểm tra file .pc trực tiếp
        if command -v pkg-config &>/dev/null; then
            PKG_CONFIG_PATH="$_ppc" pkg-config --exists libpcre2-8 2>/dev/null && return 0
        else
            [[ -f "$prefix/lib/pkgconfig/libpcre2-8.pc" || \
               -f "$prefix/lib64/pkgconfig/libpcre2-8.pc" ]] && return 0
        fi
        _rl_step "${_RL_N:-4}" "${_RL_T:-10}" "pcre2 10.42"
        local _p2dir="$build_dir/pcre2-src"
        mkdir -p "$_p2dir"; cd "$_p2dir"
        local _p2ok=0
        for _u in \
            "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.gz" \
            "https://sourceforge.net/projects/pcre/files/pcre2/10.42/pcre2-10.42.tar.gz/download"; do
            wget -q --no-check-certificate -O pcre2.tar.gz "$_u" 2>/dev/null \
                && tar xzf pcre2.tar.gz 2>/dev/null && { _p2ok=1; break; }
        done
        [[ $_p2ok -eq 0 ]] && { echo -e "${R}✘${W} Không tải được pcre2"; return 1; }
        cd pcre2-10.42
        ./configure --prefix="$prefix" --enable-static --disable-shared \
            --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 \
            --disable-jit > /tmp/pcre2-build.log 2>&1 \
            && make -j"$(nproc)" >> /tmp/pcre2-build.log 2>&1 \
            && make install   >> /tmp/pcre2-build.log 2>&1 \
            || { echo -e "${R}✘${W} pcre2 build thất bại — xem /tmp/pcre2-build.log"; return 1; }
        _rl_ok "pcre2 10.42 xong"
    }

    # ── Ưu tiên 2: build glib 2.76.6 từ source ──────────────────
    # Dùng 2.76.6 (không 2.78.x): glib 2.78+ có bug glib-enumtypes codegen
    # với meson 1.x khi python3 trong PATH là conda python — sinh lỗi:
    # "build/-c: not found" do meson pass PYTHON -c như single string.
    local GLIB_VER="2.76.6"
    local GLIB_MAJ="2.76"
    _rl_step "${_RL_N:-5}" "${_RL_T:-10}" "glib ${GLIB_VER}"

    # pcre2 là hard dep từ glib 2.73+ — đảm bảo có trước khi build
    _ensure_pcre2 || exit 1

    # ── Cache check: nếu glib đã build xong → skip ──────────────
    if [[ -f "$prefix/lib/libglib-2.0.a" || -f "$prefix/lib/libglib-2.0.so" \
       || -f "$prefix/lib64/libglib-2.0.a" ]]; then
        local _cached_ver
        _cached_ver=$(PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_PATH:-}" \
                      pkg-config --modversion glib-2.0 2>/dev/null || echo "?")
        echo -e "${G}✔${W} glib ${_cached_ver} đã có trong cache ($prefix) — bỏ qua build"
        export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
        return 0
    fi

    cd "$build_dir"
    rm -f glib.tar.xz
    local _glib_ok=0
    for _url in \
        "https://download.gnome.org/sources/glib/${GLIB_MAJ}/glib-${GLIB_VER}.tar.xz" \
        "https://ftp.gnome.org/pub/gnome/sources/glib/${GLIB_MAJ}/glib-${GLIB_VER}.tar.xz"; do
        wget -c -q --timeout=120 --tries=2 "$_url" -O glib.tar.xz 2>/dev/null \
            && python3 -c "import lzma; lzma.open('glib.tar.xz').read(1024)" 2>/dev/null \
            && _glib_ok=1 && break
        echo -e "${Y}⚠${W}  glib URL thất bại: $_url"
    done
    if [[ "$_glib_ok" == "0" ]]; then
        echo -e "${R}✘${W}  Không tải được glib ${GLIB_VER} từ source."
        echo -e "${Y}⚠${W}  Conda glib fallback bị loại bỏ: ABI mismatch với system gcc trên môi trường này."
        echo -e "${Y}⚠${W}  Kiểm tra kết nối internet hoặc thêm mirror URL cho glib tarball."
        exit 1
    fi
    python3 -c "
import lzma, tarfile
with lzma.open('glib.tar.xz') as f:
    with tarfile.open(fileobj=f) as t:
        t.extractall('.')
" || { echo -e "${R}✘${W} Giải nén glib thất bại"; exit 1; }
    cd "glib-${GLIB_VER}"
    mkdir -p build; cd build

    # ── Detect meson ──────────────────────────────────────────────
    local meson_cmd=""
    if   [[ -x "${PIP_TARGET:-}/bin/meson" ]];   then meson_cmd="${PIP_TARGET}/bin/meson"
    elif [[ -x "$py_prefix/bin/meson" ]];         then meson_cmd="$py_prefix/bin/meson"
    elif command -v meson &>/dev/null;             then meson_cmd="$(command -v meson)"
    elif python3 -c "import mesonbuild" &>/dev/null 2>&1; then
        # Tạo Python script thực — KHÔNG dùng shell -c vì meson dùng sys.argv[0]
        # để tìm binary path → "-c" gây ra "build/-c: not found".
        cat > /tmp/_meson_wrap.py <<'MESONPY'
#!/usr/bin/env python3
import sys
from mesonbuild.mesonmain import main
sys.exit(main())
MESONPY
        chmod +x /tmp/_meson_wrap.py
        meson_cmd="/tmp/_meson_wrap.py"
    else
        echo -e "${R}✘${W} meson không tìm thấy — không thể build glib"; exit 1
    fi
    # Nếu meson_cmd là shell script dùng python3 -c "..." → replace bằng Python wrapper
    # (conda meson hoặc pip wrapper cũ có cùng bug "build/-c: not found")
    if [[ -f "$meson_cmd" ]] && head -3 "$meson_cmd" 2>/dev/null | grep -q "python.*-c"; then
        python3 -c "import mesonbuild" &>/dev/null 2>&1 || \
            PYTHONPATH="${PIP_TARGET:-}:${PYTHONPATH:-}" python3 -c "import mesonbuild" &>/dev/null 2>&1
        if PYTHONPATH="${PIP_TARGET:-}:${PYTHONPATH:-}" python3 -c "import mesonbuild" &>/dev/null 2>&1; then
            cat > /tmp/_meson_wrap.py <<MESONPY2
#!/usr/bin/env python3
import sys, os
_pt = os.environ.get('PIP_TARGET', '${PIP_TARGET:-}')
if _pt: sys.path.insert(0, _pt)
from mesonbuild.mesonmain import main
sys.exit(main())
MESONPY2
            chmod +x /tmp/_meson_wrap.py
            :
            meson_cmd="/tmp/_meson_wrap.py"
        fi
    fi

    # ── Detect ninja ──────────────────────────────────────────────
    local ninja_cmd=""
    if   [[ -x "${PIP_TARGET:-}/bin/ninja" ]];   then ninja_cmd="${PIP_TARGET}/bin/ninja"
    elif command -v ninja &>/dev/null;             then ninja_cmd="$(command -v ninja)"
    elif command -v ninja-build &>/dev/null;       then ninja_cmd="$(command -v ninja-build)"
    else
        local _nj_bin
        _nj_bin=$(find "${PIP_TARGET:-/nonexistent}" -name "ninja" -type f \
            ! -name "*.py" ! -name "*.pyc" ! -path "*__pycache__*" 2>/dev/null | head -1 || true)
        if [[ -n "$_nj_bin" && -x "$_nj_bin" ]]; then ninja_cmd="$_nj_bin"
        else echo -e "${R}✘${W} ninja không tìm thấy"; exit 1; fi
    fi


    # Fix: khi build glib từ source, PHẢI isolate PKG_CONFIG_PATH khỏi conda.
    # Nếu để conda path lẫn vào, pkg-config trả về glib của conda → meson so sánh
    # sizeof(size_t) từ conda glib với system glib → mismatch → lỗi GLIB_SIZEOF_SIZE_T.
    # Chỉ trỏ vào $prefix (libs vừa build từ source: zlib, libffi, pcre2...).
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig"
    # PKG_CONFIG_LIBDIR override hoàn toàn mọi default path (bao gồm cả conda)
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig"

    # Đảm bảo $prefix/bin trong PATH và libs tìm được
    export PATH="$prefix/bin:${PATH}"
    # prefix lib trước conda lib để source-built .so được ưu tiên
    export LD_LIBRARY_PATH="$prefix/lib:$prefix/lib64:${CONDA_ROOT:-/opt/conda}/lib:${LD_LIBRARY_PATH:-}"

    # Tìm pkg-config: ưu tiên $prefix/bin (self-built), KHÔNG dùng conda pkg-config trực tiếp
    # vì conda pkg-config có hardcoded conda paths ignore PKG_CONFIG_LIBDIR.
    local _pc_bin=""
    if [[ -x "$prefix/bin/pkg-config" ]] && "$prefix/bin/pkg-config" --version &>/dev/null; then
        _pc_bin="$prefix/bin/pkg-config"
    elif [[ -x "$(command -v pkgconf 2>/dev/null || true)" ]]; then
        _pc_bin="$(command -v pkgconf)"
    fi
    # Nếu chỉ có conda pkg-config: tạo wrapper script tôn trọng PKG_CONFIG_LIBDIR
    if [[ -z "$_pc_bin" ]] && [[ -x "${CONDA_ROOT:-/opt/conda}/bin/pkg-config" ]]; then
        local _pc_wrapper="$prefix/bin/pkg-config"
        mkdir -p "$prefix/bin"
        cat > "$_pc_wrapper" <<PCWRAP
#!/bin/sh
exec env PKG_CONFIG_SYSTEM_LIBRARY_PATH="" \
     ${CONDA_ROOT:-/opt/conda}/bin/pkg-config "\$@"
PCWRAP
        chmod +x "$_pc_wrapper"
        _pc_bin="$_pc_wrapper"
        :
    fi
    local _no_pkgconfig=0
    if [[ -n "$_pc_bin" ]]; then
        export PKG_CONFIG="$_pc_bin"
        :
        :
    else
        echo -e "${Y}⚠${W}  Không tìm được pkg-config hoạt động — dùng pcre2=internal fallback"
        _no_pkgconfig=1
    fi

    # Helper: chỉ add option nếu glib version này có khai báo trong meson_options.txt
    _has_opt() { grep -qE "option\s*\(\s*'$1'" ../meson_options.txt 2>/dev/null; }

    # Flags luôn hợp lệ cho mọi glib version
    local _meson_flags=(
        --prefix="$prefix"
        --buildtype=plain
        -Dauto_features=disabled
        -Dlibdir="lib"
        -Dman=false
        -Dgtk_doc=false
        -Dlibmount=disabled
        -Dselinux=disabled
        -Ddtrace=false
        -Dsystemtap=false
        -Dlibelf=disabled
    )
    # Thêm options tuỳ theo glib version (tránh "Unknown option" với meson 1.11+)
    _has_opt tests            && _meson_flags+=(-Dtests=false)
    _has_opt installed_tests  && _meson_flags+=(-Dinstalled_tests=false)
    _has_opt xattr            && _meson_flags+=(-Dxattr=false)
    _has_opt nls              && _meson_flags+=(-Dnls=disabled)
    _has_opt introspection    && _meson_flags+=(-Dintrospection=disabled)

    # pcre2: nếu pkg-config hoạt động → glib tự detect qua PKG_CONFIG_PATH (pcre2 đã build từ source)
    # nếu pkg-config KHÔNG hoạt động → dùng -Dpcre2=internal để meson tự build pcre2 từ wrap
    if [[ "$_no_pkgconfig" == "1" ]]; then
        _has_opt pcre2 && _meson_flags+=(-Dpcre2=internal)
        # wrap-mode=nofallback: cho phép internal subproject nhưng không download wrap bên ngoài
        _meson_flags+=(--wrap-mode=nofallback)
        :
    else
        _has_opt pcre2 && _meson_flags+=(-Dpcre2=enabled)
        _meson_flags+=(--wrap-mode=nodownload)
    fi

    local _meson_exit=0
    : # meson setup
( _hb=0; while :; do sleep 30; _hb=$((_hb+1)); printf "[~] meson setup: %d min...
" "$((_hb/2))"; done ) &
_HB_MESON=$!
timeout 3600 "$meson_cmd" setup . .. "${_meson_flags[@]}" > /tmp/glib-meson.log 2>&1
kill "$_HB_MESON" 2>/dev/null; wait "$_HB_MESON" 2>/dev/null || true
_meson_exit=$?; :
    if [[ $_meson_exit -eq 124 ]]; then
        echo -e "${R}✘${W} meson setup glib TIMEOUT (>3600s) — xem /tmp/glib-meson.log"
        tail -30 /tmp/glib-meson.log; exit 1
    elif [[ $_meson_exit -ne 0 ]]; then
        echo -e "${R}✘${W}  meson glib thất bại (exit $_meson_exit) — xem /tmp/glib-meson.log"
        tail -30 /tmp/glib-meson.log
        echo -e "${Y}⚠${W}  Conda glib fallback bị loại bỏ (ABI mismatch với system gcc)."
        echo -e "${Y}⚠${W}  Xoá build cache và thử lại: rm -rf ~/qemu-static ~/qemu-build"
        exit 1
    fi
    local _ninja_exit=0
    :
( _hb=0; while :; do sleep 30; _hb=$((_hb+1)); printf "[~] glib build: %d min elapsed...\n" "$((_hb/2))"; done ) &
_HB_GLIB=$!
timeout 900 "$ninja_cmd" -j"$(nproc)" > /tmp/glib-build.log 2>&1 || _ninja_exit=$?
kill "$_HB_GLIB" 2>/dev/null; wait "$_HB_GLIB" 2>/dev/null || true
:
    if [[ $_ninja_exit -eq 124 ]]; then
        echo -e "${R}✘${W} ninja glib TIMEOUT (>900s)"; tail -20 /tmp/glib-build.log; exit 1
    elif [[ $_ninja_exit -ne 0 ]]; then
        echo -e "${R}✘${W}  ninja glib thất bại — xem /tmp/glib-build.log"
        tail -20 /tmp/glib-build.log
        echo -e "${Y}⚠${W}  Conda glib fallback bị loại bỏ (ABI mismatch với system gcc)."
        echo -e "${Y}⚠${W}  Xoá build cache và thử lại: rm -rf ~/qemu-static ~/qemu-build"
        exit 1
    fi
    timeout 120 "$ninja_cmd" install >> /tmp/glib-build.log 2>&1 \
        || {
            echo -e "${R}✘${W} glib install thất bại — xem /tmp/glib-build.log"; exit 1
        }
    _rl_ok "glib ${GLIB_VER} xong"
    echo "qemu" > "$BUILD/.rootless-resume"
}

# ════════════════════════════════════════════════════════════════
#  ROOTLESS BUILD
# ════════════════════════════════════════════════════════════════
_detect_cross_toolchain() {
    local _cc="${CC_PLAIN:-$(command -v gcc 2>/dev/null || command -v cc 2>/dev/null || echo "")}"
    [[ -z "$_cc" ]] && return

    local _cc_dir; _cc_dir="$(dirname "$_cc")"
    local _cc_bn;  _cc_bn="$(basename "$_cc")"

    # Add compiler bin dir to PATH so ar/ranlib/etc. can be found
    if [[ -d "$_cc_dir" ]] && [[ ":$PATH:" != *":$_cc_dir:"* ]]; then
        export PATH="$_cc_dir:$PATH"
        hash -r 2>/dev/null || true
    fi

    # Derive cross-prefix (e.g. x86_64-conda-linux-gnu from x86_64-conda-linux-gnu-gcc)
    local _cross_prefix=""
    if [[ "$_cc_bn" == *"-gcc" ]]; then
        _cross_prefix="${_cc_bn%-gcc}"
    elif [[ "$_cc_bn" == *"-cc" ]]; then
        _cross_prefix="${_cc_bn%-cc}"
    fi

    if [[ -n "$_cross_prefix" ]]; then
        for _tool in ar ranlib nm strip; do
            local _bin="$_cc_dir/${_cross_prefix}-${_tool}"
            if [[ -x "$_bin" ]]; then
                local _var="${_tool^^}"  # ar→AR, ranlib→RANLIB etc.
                export "${_var}=${_bin}"
                echo -e "${G}✔${W} Cross-toolchain ${_var}=${_bin}"
            fi
        done
    fi

    # Last-resort: if ar still not found, search conda envs
    if ! command -v "${AR:-ar}" &>/dev/null; then
        local _found_ar
        _found_ar=$(find /opt/conda/bin /opt/conda/envs/*/bin -maxdepth 1 \
            -name "*-ar" -o -name "ar" 2>/dev/null | head -1)
        if [[ -n "$_found_ar" ]]; then
            export AR="$_found_ar"
            echo -e "${G}✔${W} AR (fallback search): $AR"
        fi
    fi

    :
}

_qemu_build_tuning() {
    local _cc_hint="${CC_PLAIN:-${CC:-$(command -v gcc 2>/dev/null || command -v cc 2>/dev/null || echo "")}}"
    local _cc_ver=""
    local _is_clang=0
    local _lto_flags=""
    local _lto_ldflags=""
    local _lto_note=""

    if [[ -n "$_cc_hint" ]]; then
        if [[ "$_cc_hint" == *" "* ]]; then
            _cc_ver=$(bash -lc "set -o pipefail; $_cc_hint --version 2>/dev/null | head -1" 2>/dev/null || true)
        else
            _cc_ver=$("$_cc_hint" --version 2>/dev/null | head -1 || true)
        fi
    fi

    if [[ "$_cc_ver" == *clang* || "$_cc_ver" == *"Apple clang"* ]]; then
        _is_clang=1
    fi

    # -ffast-math: nới lỏng IEEE 754 để tối ưu FP ops trong TCG/FPU emulation
    # Đặt NO_FAST_MATH=1 để tắt nếu cần IEEE 754 chính xác tuyệt đối
    local _fast_math_flag=""
    if [[ "${NO_FAST_MATH:-0}" != "1" ]]; then
        _fast_math_flag=" -ffast-math"
    fi

    PGO_PROFILE_KIND="gcc"
    [[ "$_is_clang" == "1" ]] && PGO_PROFILE_KIND="clang"

    QEMU_BASE_CFLAGS="-O3 -march=native -mtune=native -pipe -fno-plt -fno-semantic-interposition -fomit-frame-pointer -fstack-protector-strong -ffunction-sections -fdata-sections -fipa-cp-clone -fgcse-after-reload -fweb -falign-functions=32 -falign-loops=32 -falign-jumps=32 -falign-labels=32 -fmerge-all-constants -fipa-pta${_fast_math_flag}"
    QEMU_BASE_CXXFLAGS="$QEMU_BASE_CFLAGS"
    QEMU_BASE_LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,--gc-sections"
    QEMU_CONFIGURE_LTO_OPT=""

    PGO_LAUNCH_ENV=""
    local _pgo_cflags="" _pgo_cxxflags="" _pgo_ldflags=""

    if [[ "${PGO_MODE:-0}" == "1" && "${PGO_PHASE:-normal}" != "normal" ]]; then
        case "${PGO_PHASE:-}" in
            generate)
                if [[ "$PGO_PROFILE_KIND" == "clang" ]]; then
                    _pgo_cflags="-fprofile-instr-generate=${PGO_PROFILE_DIR}"
                    _pgo_cxxflags="-fprofile-instr-generate=${PGO_PROFILE_DIR}"
                    _pgo_ldflags="-fprofile-instr-generate=${PGO_PROFILE_DIR}"
                    PGO_LAUNCH_ENV="env LLVM_PROFILE_FILE=${PGO_PROFILE_DIR}/%p-%m.profraw"
                else
                    # gcc: trailing slash bắt buộc — không có → tất cả .gcda ghi
                    # cùng một prefix thay vì vào thư mục, profile corrupt/trống
                    mkdir -p "${PGO_PROFILE_DIR}"
                    _pgo_cflags="-fprofile-generate=${PGO_PROFILE_DIR}/"
                    _pgo_cxxflags="-fprofile-generate=${PGO_PROFILE_DIR}/"
                    _pgo_ldflags="-fprofile-generate=${PGO_PROFILE_DIR}/"
                fi
                # Generate phase không có LTO → mất cross-unit inlining → TCG chậm hơn bình thường.
                # Bù lại bằng explicit inlining flags để giữ performance gần với normal build.
                if [[ "$PGO_PROFILE_KIND" == "gcc" ]]; then
                    _pgo_cflags+=" -finline-functions -finline-limit=1000 --param max-inline-insns-auto=200"
                    _pgo_cxxflags+=" -finline-functions -finline-limit=1000 --param max-inline-insns-auto=200"
                else
                    # clang: dùng -mllvm để pass inliner threshold
                    _pgo_cflags+=" -mllvm -inline-threshold=500"
                    _pgo_cxxflags+=" -mllvm -inline-threshold=500"
                fi
                ;;
            use)
                if [[ "$PGO_PROFILE_KIND" == "clang" ]]; then
                    _pgo_cflags="-fprofile-instr-use=${PGO_PROFILE_DIR}/default.profdata"
                    _pgo_cxxflags="-fprofile-instr-use=${PGO_PROFILE_DIR}/default.profdata"
                    _pgo_ldflags="-fprofile-instr-use=${PGO_PROFILE_DIR}/default.profdata"
                else
                    # -fprofile-correction: xử lý khi build dir use phase khác generate phase
                    # (GCC embed absolute path vào .gcda → path mismatch nếu build dir đổi)
                    # -Wno-missing-profile: suppress warning khi một số .gcda không tìm thấy
                    # (bình thường — không phải mọi TU đều được exercise trong generate phase)
                    # -Wno-error=coverage-mismatch: profile từ version QEMU khác → counter count
                    # không khớp, treat as warning thay vì error để build vẫn tiếp tục
                    _pgo_cflags="-fprofile-use=${PGO_PROFILE_DIR} -fprofile-correction -fprofile-partial-training -Wno-missing-profile -Wno-error=coverage-mismatch"
                    _pgo_cxxflags="-fprofile-use=${PGO_PROFILE_DIR} -fprofile-correction -fprofile-partial-training -Wno-missing-profile -Wno-error=coverage-mismatch"
                    _pgo_ldflags="-fprofile-use=${PGO_PROFILE_DIR}"
                fi
                ;;
        esac
        QEMU_BASE_CFLAGS+=" ${_pgo_cflags}"
        QEMU_BASE_CXXFLAGS+=" ${_pgo_cxxflags}"
        QEMU_BASE_LDFLAGS+=" ${_pgo_ldflags}"
    fi

    # PGO generate phase: tắt LTO bắt buộc.
    # -fprofile-generate + -flto không tương thích trong QEMU multi-target build:
    # mỗi TCG target là separate shared object, LTO IR không carry instrumentation
    # counters qua link boundary → .gcda/.profraw không được ghi → profile trống.
    # LTO chỉ bật ở phase 'use' (build cuối với profile đã có).
    local _pgo_is_generating=0
    if [[ "${PGO_MODE:-0}" == "1" && "${PGO_PHASE:-normal}" == "generate" ]]; then
        _pgo_is_generating=1
    fi

    if [[ "${NO_LTO:-0}" == "1" || "$_pgo_is_generating" == "1" ]]; then
        if [[ "$_pgo_is_generating" == "1" ]]; then
            _lto_note="LTO disabled (PGO generate phase — re-enabled in use phase)"
        else
            _lto_note="LTO disabled (NO_LTO=1)"
        fi
    elif [[ "$_is_clang" == "1" ]]; then
        _lto_flags="-flto"
        _lto_ldflags="-flto"
        if command -v ld.lld &>/dev/null; then
            _lto_ldflags="-flto -fuse-ld=lld"
        fi
        QEMU_CONFIGURE_LTO_OPT="--enable-lto"
        for _tool in ar ranlib nm; do
            local _cand
            _cand="$(command -v llvm-$_tool 2>/dev/null || true)"
            [[ -n "$_cand" ]] && export "${_tool^^}=$_cand"
        done
        _lto_note="Full LTO enabled (clang)"
    else
        _lto_flags="-flto"
        _lto_ldflags="-flto"
        QEMU_CONFIGURE_LTO_OPT="--enable-lto"

        local _tool_prefix=""
        if [[ "$_cc_hint" == *-gcc ]]; then
            _tool_prefix="${_cc_hint%-gcc}"
        fi

        if [[ -n "$_tool_prefix" ]]; then
            for _tool in ar ranlib nm; do
                local _cand=""
                for _name in "${_tool_prefix}-gcc-${_tool}" "gcc-${_tool}"; do
                    _cand="$(command -v "$_name" 2>/dev/null || true)"
                    [[ -n "$_cand" ]] && break
                done
                [[ -n "$_cand" ]] && export "${_tool^^}=$_cand"
            done
        else
            for _tool in ar ranlib nm; do
                local _cand=""
                _cand="$(command -v "gcc-${_tool}" 2>/dev/null || true)"
                [[ -n "$_cand" ]] && export "${_tool^^}=$_cand"
            done
        fi
        _lto_note="Full LTO enabled (gcc)"
    fi

    QEMU_BASE_CFLAGS+=" ${_lto_flags}"
    QEMU_BASE_CXXFLAGS+=" ${_lto_flags}"
    QEMU_BASE_LDFLAGS+=" ${_lto_ldflags}"

    export QEMU_BASE_CFLAGS QEMU_BASE_CXXFLAGS QEMU_BASE_LDFLAGS QEMU_CONFIGURE_LTO_OPT PGO_LAUNCH_ENV PGO_PROFILE_KIND
    if [[ "${NO_FAST_MATH:-0}" != "1" ]]; then
        _rl_ok "fast-math: BẬT (-ffast-math) [tắt: NO_FAST_MATH=1]"
    else
        _rl_warn "fast-math: TẮT (NO_FAST_MATH=1) — IEEE 754 chính xác"
    fi
    :
    :
    :
}


_rootless_build() {
    local ROOTLESS_PREFIX="$HOME/qemu-static"
    local ROOTLESS_BIN_DIR="$ROOTLESS_PREFIX/bin"
    local ROOTLESS_APPIMAGE_DIR="$ROOTLESS_PREFIX/share/qemu-appimage"
    local ROOTLESS_APPIMAGE="$ROOTLESS_APPIMAGE_DIR/QEMU-x86_64.AppImage"
    local ROOTLESS_QEMU="$ROOTLESS_BIN_DIR/qemu-system-x86_64"
    local ROOTLESS_LOG_DIR="$ROOTLESS_PREFIX/cache"

    _rootless_make_wrappers() {
        local _appimage="$1"
        local _bin_dir="$2"
        mkdir -p "$_bin_dir"
        local _cmd
        for _cmd in qemu-system-x86_64 qemu-img qemu-nbd qemu-io qemu-storage-daemon; do
            printf '#!/bin/sh\nexec "%s" --appimage-extract-and-run "%s" "$@"\n' \
                "$_appimage" "$_cmd" > "$_bin_dir/$_cmd"
            chmod +x "$_bin_dir/$_cmd"
        done
    }

    _rootless_download_appimage() {
        local _dest="$1"
        local _ok=0
        local _urls=(
            "https://github.com/pkgforge-dev/QEMU-AppImage/releases/download/11.0.0-1%402026-05-02_1777749420/QEMU-11.0.0-1-anylinux-x86_64.AppImage"
            "https://github.com/lucasmz1/Qemu-AppImage/releases/download/continuous-stable-jammy/QEMU-git-x86_64.AppImage"
        )
        mkdir -p "$ROOTLESS_APPIMAGE_DIR" "$ROOTLESS_LOG_DIR"
        for _url in "${_urls[@]}"; do
            echo -e "${B}ℹ${W}  Thử tải QEMU AppImage: $_url"
            rm -f "$_dest"
            if command -v aria2c &>/dev/null; then
                if aria2c --continue=true --file-allocation=none --check-certificate=false \
                    --max-tries=5 --retry-wait=3 -x16 -s16 -j1 \
                    -o "$(basename "$_dest")" -d "$(dirname "$_dest")" \
                    "$_url" > /tmp/qemu-appimage-download.log 2>&1; then
                    _ok=1
                fi
            elif command -v wget &>/dev/null; then
                if wget -c --progress=bar:force:noscroll -O "$_dest" "$_url" > /tmp/qemu-appimage-download.log 2>&1; then
                    _ok=1
                fi
            else
                if curl -fL --retry 5 --retry-delay 3 -o "$_dest" "$_url" > /tmp/qemu-appimage-download.log 2>&1; then
                    _ok=1
                fi
            fi
            if [[ "$_ok" == "1" ]] && [[ -s "$_dest" ]]; then
                chmod +x "$_dest" 2>/dev/null || true
                timeout 20 "$_dest" --appimage-extract-and-run qemu-system-x86_64 --version >/tmp/qemu-appimage-download.log 2>&1 && return 0
                rm -f "$_dest"
            fi
            rm -f "$_dest"
            echo -e "${Y}⚠${W}  AppImage tải thất bại: $_url"
        done
        return 1
    }

    mkdir -p "$ROOTLESS_PREFIX" "$ROOTLESS_APPIMAGE_DIR" "$ROOTLESS_LOG_DIR"

    if [[ -x "$ROOTLESS_QEMU" ]] && [[ -f "$ROOTLESS_APPIMAGE" ]]; then
        local rv
        rv=$("$ROOTLESS_QEMU" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU AppImage rootless v${rv} đã tồn tại — bỏ qua tải${W}"
        export QEMU_BIN="$ROOTLESS_QEMU"
        export PREFIX="$ROOTLESS_PREFIX"
        export PIP_TARGET="$PREFIX/pylib"
        export PYTHONPATH="$PIP_TARGET${PYTHONPATH:+:$PYTHONPATH}"
        export PATH="$ROOTLESS_BIN_DIR:$PIP_TARGET/bin:$HOME/.local/bin:$PATH"
        export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:${LD_LIBRARY_PATH:-}"
        return 0
    fi

    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔧 ROOTLESS APPIMAGE MODE${W}"
    echo -e "${C}════════════════════════════════════${W}"

    rm -rf "$HOME/python-local" "$HOME/qemu-static" "$HOME/qemu-build" "$HOME/certs"
    export PREFIX="$ROOTLESS_PREFIX"
    export BUILD="$HOME/qemu-build"
    mkdir -p "$PREFIX" "$BUILD" "$HOME/certs"

    CC_PLAIN="${CC_PLAIN:-$(command -v gcc || command -v cc || echo "gcc")}"
    CXX_PLAIN="${CXX_PLAIN:-$(command -v g++ || command -v c++ || echo "g++")}"
    export CC_PLAIN CXX_PLAIN

    export PIP_TARGET="$PREFIX/pylib"
    mkdir -p "$PIP_TARGET"
    export PYTHONPATH="$PIP_TARGET${PYTHONPATH:+:$PYTHONPATH}"
    export PATH="$ROOTLESS_BIN_DIR:$PIP_TARGET/bin:$HOME/.local/bin:$PATH"

    if ! _ensure_aria2; then
        echo -e "${Y}⚠${W}  aria2 không cài được — tải img sẽ dùng wget fallback"
    fi

    if ! _rootless_download_appimage "$ROOTLESS_APPIMAGE"; then
        echo -e "${R}✘${W}  Không tải được QEMU AppImage"
        echo -e "${Y}💡${W}  Hãy thử lại khi mạng ổn hơn, hoặc dùng --no-build để bỏ qua mode này"
        exit 1
    fi

    chmod +x "$ROOTLESS_APPIMAGE"
    _rootless_make_wrappers "$ROOTLESS_APPIMAGE" "$ROOTLESS_BIN_DIR"

    export QEMU_BIN="$ROOTLESS_QEMU"
    export LD_LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib64:${LD_LIBRARY_PATH:-}"

    if timeout 20 "$QEMU_BIN" --version >/tmp/qemu-appimage-version.log 2>&1; then
        local _rv
        _rv=$("$QEMU_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}✔${W} QEMU AppImage sẵn sàng: ${B}${_rv}${W}"
        echo -e "${G}✔${W} Wrapper: ${ROOTLESS_BIN_DIR}/{qemu-system-x86_64,qemu-img,qemu-nbd,qemu-io,qemu-storage-daemon}"
        echo -e "${G}✔${W} Rootless AppImage hoàn tất"
        echo -e "   QEMU  : $QEMU_BIN"
        echo -e "   Prefix: $PREFIX"
        echo -e "   Accel : ${KVM_MODE^^}"
        return 0
    fi

    echo -e "${R}✘${W}  QEMU AppImage không chạy được"
    tail -20 /tmp/qemu-appimage-version.log 2>/dev/null || true
    exit 1
}

# ════════════════════════════════════════════════════════════════
#  CROSS-TOOLCHAIN DETECTION
#  Detect AR/RANLIB/NM/STRIP from CC_PLAIN prefix
#  Fixes: conda cross-compiler (x86_64-conda-linux-gnu-gcc) needs
#         x86_64-conda-linux-gnu-ar instead of plain `ar`
# ════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════
#  MAIN — detect apt, detect KVM, detect QEMU
# ════════════════════════════════════════════════════════════════
QEMU_BIN="/usr/bin/qemu-system-x86_64"
ROOTLESS_QEMU="$HOME/qemu-static/bin/qemu-system-x86_64"
OPT_QEMU="/opt/qemu-optimized/bin/qemu-system-x86_64"
HOME_QEMU="$HOME/qemu-optimized/bin/qemu-system-x86_64"

_ask_win_image_early() {
    [[ -n "${win_choice:-}" ]] && return        # already set

    if [[ -n "${AUTO_WIN:-}" ]]; then
        win_choice="$AUTO_WIN"
    elif [[ "$AUTO_MODE" == "1" ]]; then
        win_choice="5"
        echo -e "${G}🤖 AUTO MODE — Windows preset: Win10 LTSC (5)${W}"
    else
        echo ""
        echo -e "${C}════════════════════════════════════${W}"
        echo -e "${C}🪟 CHỌN PHIÊN BẢN WINDOWS (trước build)${W}"
        echo -e "${C}════════════════════════════════════${W}"
        echo "1️⃣  Windows Server 2012 R2 x64"
        echo "2️⃣  Windows Server 2022 x64"
        echo "3️⃣  Windows 11 LTSB x64"
        echo "4️⃣  Windows 10 LTSB 2015 x64"
        echo "5️⃣  Windows 10 LTSC 2023 x64"
        if [[ -t 0 ]]; then
            read -rp "👉 Nhập số [1-5]: " win_choice
        else
            win_choice="5"
            echo -e "${Y}⚠${W}  stdin không tương tác — mặc định 5 (LTSC 2023)"
        fi
    fi
    case "${win_choice:-5}" in
        1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ; RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
        2) WIN_NAME="Windows Server 2022";    WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img";   USE_UEFI="no"  ; RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
        3) WIN_NAME="Windows 11 LTSB";        WIN_URL="https://archive.org/download/win_20260203/win.img";       USE_UEFI="yes" ; RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
        4) WIN_NAME="Windows 10 LTSB 2015";   WIN_URL="https://archive.org/download/win_20260208/win.img";       USE_UEFI="no"  ; RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
        5|*) WIN_NAME="Windows 10 LTSC 2023"; WIN_URL="https://archive.org/download/win_20260215/win.img";       USE_UEFI="no"  ; RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
    esac
    case "${win_choice:-5}" in
        3|4|5) RDP_USER="Admin"; RDP_PASS="Tam255Z" ;;
        *)     RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
    esac
    echo -e "${G}✔${W} Image đã chọn: ${C}${WIN_NAME}${W}"
}

# ── Start background download (parallel với build QEMU) ──────────
IMG_DL_PID=""
_IMG_DOWNLOAD_DONE=0   # set to 1 after parallel download confirms valid image
_img_valid() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    # QCOW2 check — dùng `file` command (đọc magic bytes, không cần network)
    if command -v file &>/dev/null && file "$f" 2>/dev/null | grep -qi "qcow"; then
        return 0
    fi
    # Fallback: od magic bytes
    local _magic
    _magic=$(od -An -N4 -tx1 "$f" 2>/dev/null | tr -d " \n" || echo "")
    [[ "$_magic" == "514649fb" ]] && return 0
    # Raw image: phải >= 2 GiB và header khác zero
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$sz" -lt 2147483648 ]] && return 1
    # Size check only — đủ vì UEFI/Win11 có thể có 512 bytes đầu toàn zero
    return 0
}

_start_parallel_download() {
    [[ "${USE_HTTP_BACKEND:-0}" == "1" ]] && return      # HTTP mode — no download
    [[ "${SAFE_DOWNLOAD:-0}"    == "1" ]] && return      # chunked mode — keep sequential
    [[ -z "${WIN_URL:-}"               ]] && return
    _img_valid "${WIN_IMG_PATH:-win.img}" && {
        echo -e "${G}✔${W} Image đã sẵn sàng — bỏ qua tải nền"; return; }
    echo -e "${B}ℹ${W}  🔄 Tải ${WIN_NAME} nền (song song với build QEMU)..."
    :
    if ! command -v aria2c &>/dev/null; then
        _ensure_aria2 || true
    fi
    if command -v aria2c &>/dev/null; then
        nohup aria2c "${ARIA2_OPTS[@]}" \
            --summary-interval=30 \
            "$WIN_URL" -d "$(dirname "${WIN_IMG_PATH:-win.img}")" -o "$(basename "${WIN_IMG_PATH:-win.img}")" \
            > /tmp/dl-parallel.log 2>&1 &
    else
        nohup wget --progress=dot:giga --continue             "$WIN_URL" -O "${WIN_IMG_PATH:-win.img}"             > /tmp/dl-parallel.log 2>&1 &
    fi
    IMG_DL_PID=$!
    disown "$IMG_DL_PID" 2>/dev/null || true
    echo -e "${G}✔${W} Download bắt đầu nền (PID: $IMG_DL_PID)"
}

# ── Đợi download nền nếu chưa xong ──────────────────────────────
_wait_parallel_download() {
    [[ -z "${IMG_DL_PID:-}" ]] && return
    if kill -0 "$IMG_DL_PID" 2>/dev/null; then
        echo ""
        echo -e "${B}ℹ${W}  ⏳ Build QEMU xong — đợi download ${WIN_NAME} hoàn tất..."
        :
        local _t=0
        while kill -0 "$IMG_DL_PID" 2>/dev/null; do
            _t=$(( _t + 5 ))
            local _sz; _sz=$(du -sh "${WIN_IMG_PATH:-win.img}" 2>/dev/null | cut -f1 || echo "?")
            printf "\r${B}◜${W} Đang tải... %-6s đã tải (%ss)" "$_sz" "$_t"
            sleep 5
        done
        printf "\r${G}✔${W} Download xong!%30s\n" ""
    fi
    wait "$IMG_DL_PID" 2>/dev/null || true
    IMG_DL_PID=""
    local _wimg="${WIN_IMG_PATH:-win.img}"
    if _img_valid "$_wimg" 2>/dev/null; then
        echo -e "${G}✔${W} ${WIN_NAME:-Windows image} tải thành công"
        _IMG_DOWNLOAD_DONE=1
    elif [[ -f "$_wimg" ]]; then
        SZ_BYTES=$(stat -c%s "$_wimg" 2>/dev/null || echo 0)
        if [[ "$SZ_BYTES" -ge 2147483648 ]]; then
            echo -e "${G}✔${W} ${WIN_NAME:-Windows image} tải thành công (${SZ_BYTES} bytes)"
            _IMG_DOWNLOAD_DONE=1
        else
            echo -e "${Y}⚠${W}  File nhỏ hơn 2GB (${SZ_BYTES} bytes) — có thể chưa xong: /tmp/dl-parallel.log"
        fi
    else
        echo -e "${Y}⚠${W}  Download chưa hoàn tất — kiểm tra /tmp/dl-parallel.log"
    fi
}

ORIGINAL_DIR="$(pwd)"
export ORIGINAL_DIR
# PREFIX fallback: nếu rootless build bị bỏ qua (QEMU đã tồn tại),
# PREFIX chưa được set bởi _rootless_build → đặt fallback $HOME/qemu-static
# để các hàm phụ (qemu-img lookup, aria2 path...) tìm được đúng đường
PREFIX="${PREFIX:-$HOME/qemu-static}"
export PREFIX
_detect_apt
_detect_kvm   # ← chạy KVM detection ngay sau apt detection

# ════════════════════════════════════════════════════════════════
#  ARIA2 — đảm bảo aria2c có sẵn
#  Thứ tự: static binary (~5s) → build from source (~5min) → apt → conda (20+min)
#  conda bị skip nếu env corrupt (broken symlinks / missing meta JSON)
# ════════════════════════════════════════════════════════════════

# Kiểm tra conda env có healthy không (không bị corrupt symlink/meta)
_conda_is_healthy() {
    command -v conda &>/dev/null || return 1
    # conda info --json trả lỗi nếu env hỏng nặng
    conda info --json > /tmp/_conda_health_$$.json 2>/dev/null || return 1
    local _base
    _base="$(python3 -c "import json; d=json.load(open('/tmp/_conda_health_$$.json')); print(d.get('root_prefix',''))" 2>/dev/null)"
    rm -f /tmp/_conda_health_$$.json
    [[ -z "$_base" ]] && return 1
    [[ -d "$_base/pkgs" ]] || return 1
    # Kiểm tra broken symlink trong conda-meta
    local _meta="$_base/conda-meta"
    [[ -d "$_meta" ]] || return 1
    # Nếu có file .json nào không đọc được → corrupt
    local _bad
    _bad=$(find "$_meta" -name "*.json" -maxdepth 1 2>/dev/null | while read -r f; do
        [[ -r "$f" ]] || echo "$f"
    done | wc -l)
    [[ "$_bad" -gt 0 ]] && return 1
    return 0
}

_ensure_aria2() {
    command -v aria2c &>/dev/null && return 0  # đã có rồi

    local _bin_dir="${PREFIX:-$HOME/qemu-static}/bin"
    mkdir -p "$_bin_dir"

    # ── Thử 1: static musl binary (nhanh nhất, ~5s, không cần root) ──
    spin_start "Tải aria2 static binary..."
    local _aria2_url="https://github.com/abcfy2/aria2-static-build/releases/latest/download/aria2-x86_64-linux-musl_static.zip"
    local _tmp_zip="/tmp/aria2-static-$$.zip"
    local _tmp_dir="/tmp/aria2-static-$$"

    if wget -q --no-check-certificate "$_aria2_url" -O "$_tmp_zip" 2>/dev/null \
        || curl -fsSL --insecure "$_aria2_url" -o "$_tmp_zip" 2>/dev/null; then
        mkdir -p "$_tmp_dir"
        if unzip -q "$_tmp_zip" -d "$_tmp_dir" 2>/dev/null; then
            local _aria2c
            _aria2c=$(find "$_tmp_dir" -name "aria2c" -type f | head -1)
            if [[ -n "$_aria2c" ]]; then
                install -m755 "$_aria2c" "$_bin_dir/aria2c"
                export PATH="$_bin_dir:$PATH"
                rm -rf "$_tmp_zip" "$_tmp_dir"
                spin_stop "aria2 static binary: $_bin_dir/aria2c"
                return 0
            fi
        fi
        rm -rf "$_tmp_zip" "$_tmp_dir"
    fi
    spin_fail "static binary thất bại — thử build from source..."

    # ── Thử 2: build from source (rootless, không cần root) ─────
    # Yêu cầu: gcc, make, pkg-config, libssl-dev, libxml2-dev, libsqlite3-dev
    # Trong HPC/conda env thường có đủ compiler nhưng thiếu dev libs → fallback tiếp
    if command -v gcc &>/dev/null && command -v make &>/dev/null; then
        spin_start "Build aria2 from source (~5 phút)..."
        local _src_ver="1.37.0"
        local _src_url="https://github.com/aria2/aria2/releases/download/release-${_src_ver}/aria2-${_src_ver}.tar.gz"
        local _src_dir="/tmp/aria2-src-$$"
        local _src_tar="/tmp/aria2-src-$$.tar.gz"
        mkdir -p "$_src_dir"

        if wget -q --no-check-certificate "$_src_url" -O "$_src_tar" 2>/dev/null \
            || curl -fsSL --insecure "$_src_url" -o "$_src_tar" 2>/dev/null; then
            tar -xf "$_src_tar" -C "$_src_dir" --strip-components=1 2>/dev/null
            rm -f "$_src_tar"

            # Tắt các feature cần lib ngoài để giảm dependency
            local _cfg_flags=(
                "--prefix=$_bin_dir/.."
                "--without-sqlite3"
                "--without-libexpat"
                "--without-libcares"
                "--disable-nls"
                "--disable-bittorrent"
                "--disable-metalink"
                "--with-pic"
            )
            # Dùng pkg-config từ conda nếu có (tránh system path)
            if command -v conda &>/dev/null; then
                local _conda_prefix
                _conda_prefix="$(conda info --base 2>/dev/null)/envs/$(conda info --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("active_prefix_name","base"))' 2>/dev/null || echo base)"
                [[ -d "$_conda_prefix/lib/pkgconfig" ]] && \
                    export PKG_CONFIG_PATH="$_conda_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            fi

            if (cd "$_src_dir" && \
                ./configure "${_cfg_flags[@]}" > /tmp/aria2-cfg-$$.log 2>&1 && \
                make -j"$(nproc)" > /tmp/aria2-make-$$.log 2>&1 && \
                make install > /dev/null 2>&1); then
                rm -rf "$_src_dir" /tmp/aria2-cfg-$$.log /tmp/aria2-make-$$.log
                export PATH="$_bin_dir:$PATH"
                if command -v aria2c &>/dev/null; then
                    spin_stop "aria2 build from source xong: $_bin_dir/aria2c"
                    return 0
                fi
            else
                echo -e "\n${Y}  configure log: $(tail -3 /tmp/aria2-cfg-$$.log 2>/dev/null)${W}" >&2
                rm -rf "$_src_dir" /tmp/aria2-cfg-$$.log /tmp/aria2-make-$$.log
            fi
        fi
        rm -rf "$_src_dir" "$_src_tar" 2>/dev/null
        spin_fail "build from source thất bại — thử apt..."
    else
        echo -e "${Y}⚠${W}  Thiếu gcc/make — bỏ qua build from source"
    fi

    # ── Thử 3: apt / apt-get (nếu root hoặc sudo) ───────────────
    local _apt=""
    command -v apt-get &>/dev/null && _apt="apt-get"
    command -v apt     &>/dev/null && _apt="apt"
    if [[ -n "$_apt" ]]; then
        spin_start "Cài aria2 qua $_apt..."
        if [[ "$(id -u)" == "0" ]]; then
            $_apt install -y -qq aria2 > /dev/null 2>&1 \
                && spin_stop "aria2 qua $_apt xong" \
                && return 0
        elif sudo -n true 2>/dev/null; then
            sudo $_apt install -y -qq aria2 > /dev/null 2>&1 \
                && spin_stop "aria2 qua sudo $_apt xong" \
                && return 0
        fi
        spin_fail "apt không cài được aria2 — thử conda (chậm)..."
    fi

    # ── Thử 4: conda (cuối cùng — chậm, 5-20 phút) ─────────────
    if command -v conda &>/dev/null; then
        if ! _conda_is_healthy; then
            echo -e "${Y}⚠${W}  conda env bị corrupt (broken symlinks / missing meta) — bỏ qua conda"
            echo -e "${B}ℹ${W}  Gợi ý: chạy ${C}conda clean --packages --tarballs${W} để thử phục hồi"
        else
            spin_start "Cài aria2 từ conda (chậm, vui lòng chờ)..."
            conda install -y -q -c conda-forge aria2 > /dev/null 2>&1 \
                || conda install -y -q aria2 > /dev/null 2>&1 || true
            if command -v aria2c &>/dev/null; then
                spin_stop "aria2 từ conda-forge xong"
                return 0
            fi
            spin_fail "aria2 conda thất bại"
        fi
    fi

    spin_fail "Không cài được aria2 — sẽ dùng wget/curl thay thế"
    return 1
}

# ════════════════════════════════════════════════════════════════
#  ISO MODE — boot từ Windows ISO (--iso=URL [--virtio=URL])
# ════════════════════════════════════════════════════════════════
_iso_mode_run() {
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}⬡  WINBOX — ISO Boot Mode${W}"
    echo -e "${C}════════════════════════════════════${W}"

    # ── Bước 1: Đảm bảo có QEMU ──────────────────────────────────
    spin_start "Kiểm tra QEMU..."
    AUTO_BUILD="${AUTO_BUILD:-}"
    local _qemu_ok=0
    for _q in "$HOME/qemu-static/bin/qemu-system-x86_64" \
              "$HOME/qemu-optimized/bin/qemu-system-x86_64" \
              "/opt/qemu-optimized/bin/qemu-system-x86_64" \
              "/usr/bin/qemu-system-x86_64" \
              "$(command -v qemu-system-x86_64 2>/dev/null || true)"; do
        [[ -x "$_q" ]] || continue
        if "$_q" --help 2>&1 | grep -q "\-display" && "$_q" --help 2>&1 | grep -qE "^-vnc "; then
            QEMU_BIN="$_q"; _qemu_ok=1; break
        fi
    done
    if [[ "$_qemu_ok" == "0" || "$AUTO_BUILD" == "yes" ]]; then
        spin_stop "QEMU chưa có — tiến hành build..."
        AUTO_BUILD="yes"
        # Luôn kiểm tra ROOTLESS trước để đảm bảo rootless mode hoạt động đúng trong ISO mode
        if [[ "$ROOTLESS" == "1" ]]; then
            spin_start "Build QEMU (rootless — ISO mode)..."
            _rootless_build 2>&1
            spin_stop "Build QEMU xong"
        elif [[ "$(id -u)" == "0" ]] && [[ "$APT_OK" == "1" ]]; then
            spin_start "Build QEMU (apt/root — ISO mode)..."
            _rootless_build 2>&1
            spin_stop "Build QEMU xong"
        else
            spin_start "Build QEMU (rootless fallback — ISO mode)..."
            _rootless_build 2>&1
            spin_stop "Build QEMU xong"
        fi
    else
        spin_stop "QEMU: $QEMU_BIN"
    fi

    # ── Resolve qemu-img ─────────────────────────────────────────
    local _qemu_bin_dir; _qemu_bin_dir="$(dirname "$QEMU_BIN")"
    QEMU_IMG=""
    for _qi in "$_qemu_bin_dir/qemu-img"                "$HOME/qemu-static/bin/qemu-img"                "$HOME/qemu-optimized/bin/qemu-img"                "/opt/qemu-optimized/bin/qemu-img"                "/usr/bin/qemu-img"                "/usr/local/bin/qemu-img"                "$(command -v qemu-img 2>/dev/null || true)"; do
        [[ -x "$_qi" ]] && { QEMU_IMG="$_qi"; break; }
    done
    if [[ -z "$QEMU_IMG" ]]; then
        # qemu-img không có → thử cài qua apt
        if [[ "$(id -u)" == "0" ]] && command -v apt-get &>/dev/null; then
            echo -e "${B}ℹ${W}  qemu-img không có — thử cài qemu-utils..."
            apt-get install -y -qq qemu-utils >/dev/null 2>&1 &&                 QEMU_IMG="$(command -v qemu-img 2>/dev/null || true)"
        elif sudo -n true 2>/dev/null && command -v apt-get &>/dev/null; then
            echo -e "${B}ℹ${W}  qemu-img không có — thử cài qemu-utils (sudo)..."
            sudo apt-get install -y -qq qemu-utils >/dev/null 2>&1 &&                 QEMU_IMG="$(command -v qemu-img 2>/dev/null || true)"
        fi
    fi
    if [[ -z "$QEMU_IMG" ]]; then
        # Fallback cuối: raw disk không cần qemu-img — dùng truncate/dd
        echo -e "${Y}⚠${W}  qemu-img không có — dùng truncate để tạo raw disk (không cần qemu-img)"
        QEMU_IMG="__truncate__"
    else
        echo -e "${G}✔${W}  qemu-img: $QEMU_IMG"
    fi

    # ── Helper: tạo raw disk ────────────────────────────────────
    _create_raw_disk() {
        local _path="$1" _gb="$2"
        if [[ "$QEMU_IMG" != "__truncate__" ]]; then
            "$QEMU_IMG" create -f raw "$_path" "${_gb}G" 2>&1
        else
            truncate -s "${_gb}G" "$_path" 2>&1
        fi
    }

    # ── Bước 2: Đảm bảo aria2c có sẵn ───────────────────────────
    _ensure_aria2 || true  # không fatal — fallback wget/curl trong _iso_download

    # ── Bước 3: Tải ISOs ─────────────────────────────────────────
    local _iso_dir="$HOME/.cache/winbox-iso"
    mkdir -p "$_iso_dir"
    cd "$_iso_dir"

    if [[ -z "$ISO_WIN_URL" ]]; then
        echo ""
        read -rp "$(echo -e "${B}📀${W} Nhập URL Windows ISO: ")" ISO_WIN_URL
        if [[ -z "$ISO_WIN_URL" ]]; then
            echo -e "${R}✘${W}  Cần URL Windows ISO. Dùng: bash winbox.sh --iso=URL"
            exit 1
        fi
    fi

    # ── Helper tải file với aria2 → wget → curl fallback ─────────
    _iso_download() {
        local _url="$1" _out="$2" _label="$3"
        local _full_path="$_iso_dir/$_out"
        spin_start "Kiểm tra ${_label}..."

        if [[ -f "$_full_path" ]]; then
            local _sz
            _sz=$(stat -c%s "$_full_path" 2>/dev/null || echo 0)
            if [[ "$_sz" -lt 104857600 ]]; then
                # < 100MB — rõ ràng incomplete/corrupt
                spin_stop "${Y}⚠${W}  ${_label} có nhưng < 100MB ($_sz bytes) — xóa và tải lại"
                rm -f "$_full_path" "$_full_path".aria2
            else
                spin_stop "${_label} đã có ($_sz bytes)"
                echo ""
                local _yn
                read -rp "$(echo -e "${Y}?${W}  Tải lại ${_label}? [y/N]: ")" _yn
                if [[ "${_yn,,}" == "y" ]]; then
                    rm -f "$_full_path" "$_full_path".aria2
                    echo -e "${B}ℹ${W}  Đã xóa — bắt đầu tải lại..."
                else
                    echo -e "${G}✔${W}  Dùng file cũ"
                    return 0
                fi
            fi
        fi

        # Thử aria2c trước — multi-connection, resume, progress
        if command -v aria2c &>/dev/null; then
            spin_stop "Tải ${_label} bằng aria2c..."
            aria2c "${ARIA2_OPTS[@]}" \
                --out="$_out" \
                --dir="$_iso_dir" \
                "$_url" \
            && { echo -e "${G}✔${W} ${_label} tải xong (aria2c)"; return 0; }
            echo -e "${Y}⚠${W}  aria2c thất bại — thử wget..."
        fi

        # Fallback wget
        if command -v wget &>/dev/null; then
            spin_stop "Tải ${_label} bằng wget..."
            wget --no-check-certificate --show-progress -O "$_iso_dir/$_out" "$_url" \
            && { echo -e "${G}✔${W} ${_label} tải xong (wget)"; return 0; }
            echo -e "${Y}⚠${W}  wget thất bại — thử curl..."
        fi

        # Fallback curl
        spin_stop "Tải ${_label} bằng curl..."
        curl -fL --insecure --progress-bar -o "$_iso_dir/$_out" "$_url" \
        && { echo -e "${G}✔${W} ${_label} tải xong (curl)"; return 0; }

        echo -e "${R}✘${W} Không tải được ${_label} từ: $_url"
        return 1
    }

    _iso_download "$ISO_WIN_URL" "win.iso" "Windows ISO" \
        || exit 1

    if [[ -n "$ISO_VIRTIO_URL" ]]; then
        _iso_download "$ISO_VIRTIO_URL" "virtio.iso" "VirtIO ISO" \
            || exit 1
    fi

    # ── Bước 3: Tạo disk ─────────────────────────────────────────
    local _disk_gb="60"
    local _cpu_cores="2"
    local _ram_gb="4"
    local _host_cores; _host_cores=$(nproc 2>/dev/null || echo 4)
    local _host_ram_gb; _host_ram_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)
    echo ""

    if [[ -f "$_iso_dir/win.img" ]]; then
        local _exist_sz
        if [[ "$QEMU_IMG" != "__truncate__" ]]; then
            _exist_sz=$("$QEMU_IMG" info "$_iso_dir/win.img" 2>/dev/null | awk '/virtual size/{print $3$4}' || echo "?")
        else
            _exist_sz=$(du -sh "$_iso_dir/win.img" 2>/dev/null | cut -f1 || echo "?")
        fi
        read -rp "$(echo -e "${Y}?${W}  win.img đã có (${_exist_sz}) — tạo lại không? [y/N]: ")" _yn
        if [[ "${_yn,,}" == "y" ]]; then
            read -rp "$(echo -e "${B}💾${W} Dung lượng disk mới (GB) [mặc định 60]: ")" _disk_raw
            _disk_raw=$(printf '%s' "${_disk_raw}" | tr -cd '0-9')
            [[ -n "$_disk_raw" ]] && _disk_gb="$_disk_raw"
            rm -f "$_iso_dir/win.img"
            spin_start "Tạo lại win.img raw (${_disk_gb}G)..."
            local _qimg_err2
            local _qimg_err2
            _qimg_err2=$(_create_raw_disk "$_iso_dir/win.img" "$_disk_gb" 2>&1) || {
                spin_stop ""
                echo -e "${R}✘${W}  Tạo disk thất bại: ${_qimg_err2}"
                echo -e "${B}ℹ${W}  Kiểm tra dung lượng trống: df -h ."
                return 1
            }
            spin_stop "Disk ${_disk_gb}G tạo xong"
        else
            echo -e "${G}✔${W}  Dùng disk cũ: $_iso_dir/win.img (${_exist_sz})"
        fi
    else
        read -rp "$(echo -e "${B}💾${W} Dung lượng disk (GB) [mặc định 60]: ")" _disk_raw
        _disk_raw=$(printf '%s' "${_disk_raw}" | tr -cd '0-9')
        [[ -n "$_disk_raw" ]] && _disk_gb="$_disk_raw"
        spin_start "Tạo win.img raw (${_disk_gb}G)..."
        local _qimg_err
        local _qimg_err
        _qimg_err=$(_create_raw_disk "$_iso_dir/win.img" "$_disk_gb" 2>&1) || {
            spin_stop ""
            echo -e "${R}✘${W}  Tạo disk thất bại: ${_qimg_err}"
            echo -e "${B}ℹ${W}  Kiểm tra dung lượng trống: df -h ."
            return 1
        }
        spin_stop "Disk ${_disk_gb}G tạo xong"
    fi

    read -rp "$(echo -e "${B}🖥️${W}  Số CPU cores [mặc định 2, host có ${_host_cores}]: ")" _cores_raw
    _cores_raw=$(printf '%s' "${_cores_raw}" | tr -cd '0-9')
    if [[ -n "$_cores_raw" && "$_cores_raw" -ge 1 ]]; then
        [[ "$_cores_raw" -gt "$_host_cores" ]] && \
            echo -e "${Y}⚠${W}  ${_cores_raw} cores > host (${_host_cores}) — có thể chậm" || true
        _cpu_cores="$_cores_raw"
    fi

    read -rp "$(echo -e "${B}🧠${W}  RAM (GB) [mặc định 4, host có ${_host_ram_gb}GB]: ")" _ram_raw
    _ram_raw=$(printf '%s' "${_ram_raw}" | tr -cd '0-9')
    if [[ -n "$_ram_raw" && "$_ram_raw" -ge 1 ]]; then
        _ram_gb="$_ram_raw"
    fi
    # Cap ISO mode RAM tối đa 50% host — Windows setup + download nền + JupyterHub
    # cùng lúc rất dễ OOM nếu cấp quá nhiều
    _iso_ram_cap=$(( _host_ram_gb * 50 / 100 ))
    [[ "$_iso_ram_cap" -lt 4 ]] && _iso_ram_cap=4
    if [[ "$_ram_gb" -gt "$_iso_ram_cap" ]]; then
        echo -e "${Y}⚠${W}  ISO mode: giới hạn RAM xuống ${_iso_ram_cap}GB (50% host) để tránh OOM khi setup"
        _ram_gb="$_iso_ram_cap"
    fi
    echo -e "${G}✔${W}  RAM ISO mode: ${_ram_gb}GB"

    # ── Bước 4: Khởi động VM ─────────────────────────────────────
    local _has_virtio_iso=0
    [[ -f "$_iso_dir/virtio.iso" && -n "$ISO_VIRTIO_URL" ]] && _has_virtio_iso=1

    # ── Detect KVM + CPU model (giống normal mode) ───────────────
    local _kvm_ok=0
    local _cpu_val
    local _machine_val="q35,vmport=off"
    local _kvm_accel_args
    local _tcg_tb_mb=4096

    if [[ -r /dev/kvm ]]; then
        _kvm_ok=1
        _kvm_accel_args=(-accel kvm)
        _cpu_val="host"
        _machine_val="q35"
        echo -e "${G}✔${W}  KVM phát hiện — dùng -cpu host -accel kvm"
    else
        echo -e "${Y}⚠${W}  KVM không có — dùng TCG software emulation"

        # ── TCG TB cache ──────────────────────────────────────────
        local _host_ram_iso; _host_ram_iso=$(awk '/MemTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo 2>/dev/null || echo 4)
        [[ "${_host_ram_iso:-0}" -lt 1 ]] && _host_ram_iso=4
        _tcg_tb_mb=$(( _host_ram_iso * 1024 * 6 / 100 ))
        [[ "$_tcg_tb_mb" -lt 4096   ]] && _tcg_tb_mb=4096
        [[ "$_tcg_tb_mb" -gt 8192 ]] && _tcg_tb_mb=8192
        _kvm_accel_args=(-accel "tcg,thread=multi,split-wx=off,one-insn-per-tb=off,tb-size=${_tcg_tb_mb}")
        echo -e "${G}⚡ TCG TB cache: ${_tcg_tb_mb}MB | multi-thread${W}"

        # ── CPU model-id (giống normal mode) ─────────────────────
        local _raw_cpu_name _cpu_vendor _cpu_name_useful _stripped
        _raw_cpu_name=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/^.*: //' || echo "")
        _cpu_vendor=$(grep -m1 "vendor_id"  /proc/cpuinfo 2>/dev/null | awk '{print $NF}' || echo "")
        _cpu_name_useful=0
        _stripped=$(printf '%s' "$_raw_cpu_name" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [[ -n "$_stripped" && "$_stripped" != "unknown" && ${#_stripped} -ge 4 ]]; then
            printf '%s' "$_stripped" | grep -q '[a-z]' && _cpu_name_useful=1
        fi

        local _cpu_host _cpu_model_id _cpu_extra
        if [[ "$_cpu_name_useful" == "1" ]]; then
            _cpu_host="$_raw_cpu_name"
            _cpu_model_id=$(printf '%s' "$_cpu_host"                 | tr ',' ' '                 | tr -d '"\@#$%^&*|<>'                 | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//'                 | cut -c1-48)
        else
            case "$_cpu_vendor" in
                GenuineIntel) _cpu_host="Intel Xeon Gold 6254" ;;
                AuthenticAMD) _cpu_host="AMD EPYC 7763" ;;
                HygonGenuine) _cpu_host="Hygon C86 7185" ;;
                CentaurHauls) _cpu_host="VIA Nano" ;;
                *)            _cpu_host="Generic x86_64" ;;
            esac
            _cpu_model_id="${_cpu_host} Processor"
            echo -e "${Y}⚠${W}  CPU name không đọc được — dùng fallback: ${_cpu_model_id}"
        fi
        _cpu_extra=
        grep -q ssse3  /proc/cpuinfo && _cpu_extra="${_cpu_extra},+ssse3"
        grep -q sse4_1 /proc/cpuinfo && _cpu_extra="${_cpu_extra},+sse4.1"
        grep -q sse4_2 /proc/cpuinfo && _cpu_extra="${_cpu_extra},+sse4.2"
        grep -q rdtscp /proc/cpuinfo && _cpu_extra="${_cpu_extra},+rdtscp"
        grep -q ' avx ' /proc/cpuinfo && _cpu_extra="${_cpu_extra},+avx"
        grep -q avx2   /proc/cpuinfo && _cpu_extra="${_cpu_extra},+avx2"
        _cpu_val="qemu64,hypervisor=off,tsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+cx16,+x2apic,+sep,+pat,+pse,+aes,+popcnt,-tsc-deadline${_cpu_extra},model-id=${_cpu_model_id}"
        echo -e "${G}✔${W}  CPU model: ${_cpu_host}  |  flags:${_cpu_extra:-none}"
    fi

    local _launch_cmd=(
        "$QEMU_BIN"
        -machine "${_machine_val}"
        -cpu "${_cpu_val}"
        -smp "${_cpu_cores},sockets=1,cores=${_cpu_cores},threads=1"
        -m "${_ram_gb}G"
        "${_kvm_accel_args[@]}"
        -object iothread,id=io1
        -drive file="$_iso_dir/win.img",if=none,id=disk0,format=raw,cache=unsafe,aio=threads,discard=on
        -device virtio-blk-pci,drive=disk0,iothread=io1,num-queues=1,queue-size=128
        -cdrom "$_iso_dir/win.iso"
    )
    if [[ "$_has_virtio_iso" == "1" ]]; then
        _launch_cmd+=(
            -drive file="$_iso_dir/virtio.iso",media=cdrom,if=none,id=cdvirtio
            -device ide-cd,drive=cdvirtio
        )
    fi

    _launch_cmd+=(
        -device virtio-gpu-pci
        -device qemu-xhci,id=xhci
        -device usb-tablet,bus=xhci.0
        -device usb-kbd,bus=xhci.0
        -netdev user,id=n0,hostfwd=tcp::3389-:3389
        -device virtio-net-pci,netdev=n0
        -vnc :0
        -boot order=c,menu=on
        -daemonize
    )

    spin_start "Khởi động ISO VM..."
    # Giảm OOM priority trước khi launch — Windows setup spike RAM rất cao
    [[ -w /proc/self/oom_score_adj ]] && echo -500 > /proc/self/oom_score_adj 2>/dev/null || true
    export QEMU_AUDIO_DRV=none
    "${_launch_cmd[@]}"
    spin_stop "ISO VM đã khởi động"

    # ── Summary ───────────────────────────────────────────────────
    echo ""
    echo -e "${C}════════════════════════════════════════════${W}"
    echo -e "${C}⬡  WINBOX — ISO Boot${W}"
    echo -e "${C}════════════════════════════════════════════${W}"
    echo -e "📀 ISO Boot   : ${G}VM đang chạy${W}"
    if [[ "$_kvm_ok" == "1" ]]; then
        echo -e "⚡ Accel      : ${G}KVM + -cpu host${W}"
    else
        echo -e "⚡ Accel      : ${Y}TCG | TB: ${_tcg_tb_mb}MB${W}"
        echo -e "🧠 CPU Model  : ${B}${_cpu_host:-qemu64}${W}"
    fi
    echo -e "🖥  VNC        : ${G}localhost:5900${W}"
    echo -e "              → vncviewer localhost:5900"
    echo -e "              → TigerVNC / RealVNC / any VNC client"
    echo -e "🌐 RDP port   : ${G}localhost:3389${W}  (sau khi cài Windows)"
    echo -e "💾 Disk       : ${B}${_iso_dir}/win.img${W}  (${_disk_gb}G, raw)"
    if [[ "$_has_virtio_iso" == "1" ]]; then
        echo -e "📦 VirtIO     : ${B}${_iso_dir}/virtio.iso${W}"
    fi
    echo -e "${C}════════════════════════════════════════════${W}"
}

# ── ISO mode early exit ────────────────────────────────────────
if [[ "$ISO_MODE" == "1" ]]; then
    _iso_mode_run
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
#  MENU CHÍNH — phải hiện trước khi hỏi bất cứ gì
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}⬡  WINBOX${W}"
if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "${C}⚡ Acceleration: ${G}KVM (hardware)${C}${W}"
else
    echo -e "${C}⚡ Acceleration: ${Y}TCG (software)${C}${W}"
fi
echo -e "${C}════════════════════════════════════${W}"

if [[ "$AUTO_MODE" == "1" ]]; then
    echo -e "${G}🤖 AUTO MODE — bỏ qua menu, tiến hành tạo VM${W}"
    main_choice="1"
else
    echo "1️⃣  Tạo Windows VM"
    echo "2️⃣  Quản Lý Windows VM"
    echo "3️⃣  Xoá VM (xoá tiến trình + img)"
    echo -e "${C}════════════════════════════════════${W}"
    read -rp "👉 Nhập lựa chọn [1-3]: " main_choice
fi
# ── Early exit cho case 2 & 3 (tránh build QEMU / cài aria2 không cần thiết) ──
case "$main_choice" in
2)
    echo ""
    echo -e "${C}🚀 ===== MANAGE RUNNING VM =====${W}"
    if pgrep -f 'qemu-system-x86_64' > /dev/null; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
            vcpu=$(sed -n 's/.*-smp \([^ ,]*\).*/\1/p' <<< "$cmd")
            ram=$(sed -n  's/.*-m \([^ ]*\).*/\1/p'    <<< "$cmd")
            cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo "?")
            mem=$(ps -p "$pid" -o %mem= 2>/dev/null || echo "?")
            echo -e "🆔 PID: ${Y}${pid}${W}  |  vCPU: ${B}${vcpu}${W}  |  RAM: ${B}${ram}${W}  |  CPU: ${G}${cpu}%${W}  |  MEM: ${R}${mem}%${W}"
        done < <(pgrep -f 'qemu-system-x86_64')
    else
        echo -e "${R}❌ Không có VM nào đang chạy${W}"
    fi
    echo -e "${C}==================================${W}"
    read -rp "🆔 Nhập PID VM muốn tắt (hoặc Enter để bỏ qua): " kill_pid
    if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
        kill "$kill_pid" 2>/dev/null || true
        echo -e "${G}✅ Đã gửi tín hiệu tắt VM PID $kill_pid${W}"
    fi
    exit 0
    ;;

3)
    echo ""
    echo -e "${C}🗑️  ===== XOÁ VM =====${W}"
    BUILD="${BUILD:-/tmp/qemu-build}"
    IMG_LIST=(); IMG_LABEL=()
    for _p in \
        "$BUILD/win.img" "/tmp/qemu-build/win.img" "$HOME/win.img" \
        "/content/win.img" "$(pwd)/win.img" \
        "$BUILD/2012.img" "$BUILD/2022.img" \
        "/tmp/qemu-build/2012.img" "/tmp/qemu-build/2022.img"; do
        if [[ -f "$_p" ]]; then
            SIZE=$(du -sh "$_p" 2>/dev/null | cut -f1 || echo "?")
            IMG_LIST+=("$_p"); IMG_LABEL+=("$_p  [${SIZE}]")
        fi
    done
    RUNNING_PIDS=()
    while IFS= read -r pid; do
        [[ -n "$pid" ]] && RUNNING_PIDS+=("$pid")
    done < <(pgrep -f 'qemu-system-x86_64' 2>/dev/null || true)
    echo -e "${C}── VM đang chạy: ──────────────────────${W}"
    if [[ "${#RUNNING_PIDS[@]}" -gt 0 ]]; then
        for pid in "${RUNNING_PIDS[@]}"; do
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
            img=$(grep -oE -- '-drive file=[^ ,]+' <<< "$cmd" | cut -d= -f3 | head -1)
            echo -e "  🆔 PID ${Y}${pid}${W}  |  img: ${B}${img:-unknown}${W}"
        done
    else
        echo -e "  ${B}(không có VM nào đang chạy)${W}"
    fi
    echo -e "${C}── Image files tìm thấy: ───────────────${W}"
    if [[ "${#IMG_LIST[@]}" -gt 0 ]]; then
        for i in "${!IMG_LIST[@]}"; do
            echo -e "  $((i+1)). ${IMG_LABEL[$i]}"
        done
    else
        echo -e "  ${B}(không tìm thấy img nào)${W}"
    fi
    echo -e "${C}═══════════════════════════════════════${W}"
    echo -e "${R}⚠️  Xoá VM sẽ:${W}"
    echo -e "   1. Kill tất cả tiến trình qemu-system-x86_64"
    echo -e "   2. Dừng QEMU processes"
    echo -e "   3. Xoá các img file được chọn"
    echo -e "${C}═══════════════════════════════════════${W}"
    read -rp "❓ Bạn có chắc muốn xoá VM không? (yes/n): " confirm_delete
    confirm_delete=$(echo "${confirm_delete:-n}" | tr -cd 'a-zA-Z')
    if [[ "$confirm_delete" != "yes" ]]; then
        echo -e "${Y}⚠️  Huỷ — không xoá gì cả${W}"
        exit 0
    fi
    if [[ "${#RUNNING_PIDS[@]}" -gt 0 ]]; then
        echo -e "${B}ℹ${W}  Kill VM processes..."
        for pid in "${RUNNING_PIDS[@]}"; do
            kill -SIGTERM "$pid" 2>/dev/null || true
        done
        sleep 2
        for pid in "${RUNNING_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && kill -SIGKILL "$pid" 2>/dev/null || true
        done
        echo -e "${G}✔${W} Đã kill tất cả QEMU processes"
    else
        echo -e "${B}ℹ${W}  Không có QEMU process nào"
    fi
    rm -f /tmp/frpc-rdp.* /tmp/frpc-watchdog.pid 2>/dev/null || true
    if [[ "${#IMG_LIST[@]}" -gt 0 ]]; then
        if [[ "${#IMG_LIST[@]}" -eq 1 ]]; then
            del_choice="1"
        else
            echo ""; echo "Chọn img muốn xoá:"
            for i in "${!IMG_LIST[@]}"; do echo "  $((i+1)). ${IMG_LABEL[$i]}"; done
            echo "  a. Xoá tất cả"; echo "  0. Không xoá img nào"
            read -rp "👉 Nhập số (hoặc 'a' cho tất cả): " del_choice
            del_choice=$(echo "${del_choice:-0}" | tr -cd '0-9a')
        fi
        if [[ "$del_choice" == "a" ]]; then
            for p in "${IMG_LIST[@]}"; do rm -f "$p" && echo -e "${G}✔${W} Đã xoá: $p" || echo -e "${R}✘${W} Không xoá được: $p"; done
        elif [[ "$del_choice" =~ ^[0-9]+$ && "$del_choice" -ge 1 && "$del_choice" -le "${#IMG_LIST[@]}" ]]; then
            idx=$(( del_choice - 1 ))
            rm -f "${IMG_LIST[$idx]}" && echo -e "${G}✔${W} Đã xoá: ${IMG_LIST[$idx]}" || echo -e "${R}✘${W} Không xoá được: ${IMG_LIST[$idx]}"
        else
            echo -e "${B}ℹ${W}  Bỏ qua xoá img"
        fi
    fi
    rm -f /tmp/qemu-launch.log /tmp/frpc-rdp.* /tmp/frpc-watchdog.pid 2>/dev/null || true
    echo ""; echo -e "${G}✅ Xoá VM hoàn tất${W}"
    exit 0
    ;;
esac

# Case 1 falls through — tiếp tục build/download
_ask_win_image_early
WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/win.img"
export WIN_IMG_PATH

# ── Auto PGO use phase cho Windows 11 (choice=3), không cần --pgo flag ──────
# Tự động tải profile từ archive.org và build use phase. Nếu tải thất bại →
# tiếp tục bình thường (non-PGO), không block.
# NGOẠI LỆ: KVM available → bỏ qua PGO + build hoàn toàn, dùng AppImage
if [[ "${win_choice:-}" == "3" && "${PGO_MODE:-0}" == "0" && "${KVM_AVAILABLE:-0}" == "0" ]]; then
    _AUTO_PGO_KEY="win11pgo"
    _AUTO_PGO_ROOT="${WINBOX_PGO_DIR:-$ORIGINAL_PWD}"
    _AUTO_PGO_ARCHIVE="$_AUTO_PGO_ROOT/${_AUTO_PGO_KEY}.tar.gz"
    _AUTO_PGO_DIR="$_AUTO_PGO_ROOT/$_AUTO_PGO_KEY"
    _AUTO_PGO_URL="https://archive.org/download/win11pgo.tar/win11pgo.tar.gz"
    _auto_pgo_ok=0

    # Dùng archive local nếu đã có sẵn
    if [[ -f "$_AUTO_PGO_ARCHIVE" ]] \
        && [[ $(stat -c%s "$_AUTO_PGO_ARCHIVE" 2>/dev/null || echo 0) -gt 1024 ]] \
        && tar -tzf "$_AUTO_PGO_ARCHIVE" >/dev/null 2>&1; then
        echo -e "${G}✔${W}  PGO profile Win11 đã có local: $_AUTO_PGO_ARCHIVE"
        _auto_pgo_ok=1
    else
        echo -e "${B}ℹ${W}  Tải PGO profile Win11 từ: $_AUTO_PGO_URL"
        _dl_ok=0
        if command -v aria2c &>/dev/null; then
            aria2c "${ARIA2_OPTS[@]}" \
                "$_AUTO_PGO_URL" -d "$_AUTO_PGO_ROOT" -o "${_AUTO_PGO_KEY}.tar.gz" && _dl_ok=1
        elif command -v wget &>/dev/null; then
            wget -q --show-progress --continue "$_AUTO_PGO_URL" -O "$_AUTO_PGO_ARCHIVE" && _dl_ok=1
        elif command -v curl &>/dev/null; then
            curl -fL --progress-bar "$_AUTO_PGO_URL" -o "$_AUTO_PGO_ARCHIVE" && _dl_ok=1
        fi
        if [[ "$_dl_ok" == "1" ]] \
            && [[ -f "$_AUTO_PGO_ARCHIVE" ]] \
            && [[ $(stat -c%s "$_AUTO_PGO_ARCHIVE" 2>/dev/null || echo 0) -gt 1024 ]] \
            && tar -tzf "$_AUTO_PGO_ARCHIVE" >/dev/null 2>&1; then
            echo -e "${G}✔${W}  PGO profile Win11 tải xong"
            _auto_pgo_ok=1
        else
            echo -e "${Y}⚠${W}  Tải PGO profile thất bại — chạy QEMU không PGO"
            rm -f "$_AUTO_PGO_ARCHIVE" 2>/dev/null || true
        fi
    fi

    if [[ "$_auto_pgo_ok" == "1" ]]; then
        rm -rf "$_AUTO_PGO_DIR"
        if tar -xzf "$_AUTO_PGO_ARCHIVE" -C "$_AUTO_PGO_ROOT" >/dev/null 2>&1; then
            echo -e "${G}✔${W}  PGO profile giải nén xong → build use phase"
            PGO_MODE=1
            PGO_PHASE="use"
            PGO_PROFILE_READY=1
            PGO_PROFILE_KEY="$_AUTO_PGO_KEY"
            PGO_PROFILE_ROOT="$_AUTO_PGO_ROOT"
            PGO_PROFILE_DIR="$_AUTO_PGO_DIR"
            PGO_PROFILE_ARCHIVE="$_AUTO_PGO_ARCHIVE"
            PGO_PROFILE_KIND="gcc"
            PGO_LAUNCH_ENV=""
            export PGO_MODE PGO_PHASE PGO_PROFILE_READY PGO_PROFILE_KEY \
                   PGO_PROFILE_ROOT PGO_PROFILE_DIR PGO_PROFILE_ARCHIVE \
                   PGO_PROFILE_KIND PGO_LAUNCH_ENV
            # Chỉ force rebuild nếu chưa có QEMU nào
            _pgo_qemu_exists=0
            for _pq in "$OPT_QEMU" "$HOME_QEMU" "$ROOTLESS_QEMU" \
                       "$(command -v qemu-system-x86_64 2>/dev/null)"; do
                [[ -n "$_pq" && -x "$_pq" ]] && { _pgo_qemu_exists=1; break; }
            done
            if [[ "$_pgo_qemu_exists" == "0" ]]; then
                AUTO_BUILD="yes"
                echo -e "${B}ℹ${W}  PGO use phase: chưa có QEMU → sẽ build với Win11 profile"
            else
                echo -e "${G}✔${W}  PGO use phase: QEMU đã có → bỏ qua rebuild"
            fi
        else
            echo -e "${Y}⚠${W}  Giải nén PGO profile thất bại — chạy không PGO"
        fi
    fi
fi
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$PGO_MODE" == "1" ]]; then
    _pgo_prepare_context "${win_choice:-5}"
    if [[ "$PGO_PROFILE_READY" == "1" ]]; then
        PGO_PHASE="use"
        echo -e "${G}✔${W} PGO profile đã có cho ${PGO_PROFILE_KEY}: ${PGO_PROFILE_ARCHIVE}"
        echo -e "${B}ℹ${W}  Sẽ build QEMU với profile này, không generate lại."
    else
        PGO_PHASE="generate"
        mkdir -p "$PGO_PROFILE_DIR"
        echo -e "${B}ℹ${W}  PGO profile chưa có cho ${PGO_PROFILE_KEY}."
        echo -e "${B}ℹ${W}  File sẽ được lưu tại: ${PGO_PROFILE_ARCHIVE}"
    fi
    export PGO_PHASE PGO_PROFILE_ROOT PGO_PROFILE_KEY PGO_PROFILE_DIR PGO_PROFILE_ARCHIVE PGO_PROFILE_READY PGO_PROFILE_KIND PGO_LAUNCH_ENV
fi

# PGO use phase: chỉ rebuild nếu chưa có QEMU
if [[ "${PGO_MODE:-0}" == "1" && "${PGO_PHASE:-}" == "use" && "$AUTO_BUILD" != "yes" ]]; then
    _pgo_qemu_exists=0
    for _pq in "$OPT_QEMU" "$HOME_QEMU" "$ROOTLESS_QEMU" \
               "$(command -v qemu-system-x86_64 2>/dev/null)"; do
        [[ -n "$_pq" && -x "$_pq" ]] && { _pgo_qemu_exists=1; break; }
    done
    if [[ "$_pgo_qemu_exists" == "0" ]]; then
        AUTO_BUILD="yes"
        echo -e "${B}ℹ${W}  PGO use phase: chưa có QEMU → sẽ build với profile đã lưu"
    fi
fi

_detect_existing_qemu() {
    for q in "$OPT_QEMU" "$HOME_QEMU" "$ROOTLESS_QEMU" "$QEMU_BIN" \
              "$(command -v qemu-system-x86_64 2>/dev/null)"; do
        if [[ -n "$q" && -x "$q" ]]; then
            local qv
            qv=$("$q" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
            echo -e "${G}⚡ Tìm thấy QEMU v${qv} tại: $q${W}"
            export QEMU_BIN="$q"
            export PATH="$(dirname "$q"):$PATH"
            [[ "$q" == "$OPT_QEMU" || "$q" == "$HOME_QEMU" ]] && export QEMU_BUILT_BIN="$q"
            return 0
        fi
    done
    return 1
}

# ── KVM FAST PATH: có KVM → bỏ qua build/PGO, dùng AppImage ─────────────────
# Lý do: KVM cho tốc độ hardware virtualization, PGO TCG optimization không cần thiết.
# AppImage nhanh hơn nhiều so với build from source (tải ~150MB vs build 10-20 phút).
if [[ "${KVM_AVAILABLE:-0}" == "1" && "$AUTO_BUILD" != "yes" ]]; then
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}⚡ KVM DETECTED — AppImage fast path${W}"
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${G}✔${W}  KVM có sẵn → không cần build QEMU từ source hay PGO"
    echo -e "${B}ℹ${W}  Dùng QEMU AppImage prebuilt (nhanh hơn, KVM hardware acceleration)"

    # Cancel PGO nếu đã được set bởi auto-PGO Win11
    if [[ "${PGO_MODE:-0}" == "1" ]]; then
        PGO_MODE=0
        PGO_PHASE=""
        AUTO_BUILD="no"
        export PGO_MODE PGO_PHASE
        echo -e "${B}ℹ${W}  PGO bị hủy — KVM không cần TCG optimization"
    fi

    # Kiểm tra AppImage đã có chưa
    _KVM_ROOTLESS_QEMU="$HOME/qemu-static/bin/qemu-system-x86_64"
    _KVM_APPIMAGE="$HOME/qemu-static/share/qemu-appimage/QEMU-x86_64.AppImage"

    if [[ -x "$_KVM_ROOTLESS_QEMU" ]] && [[ -f "$_KVM_APPIMAGE" ]]; then
        _rv=$("$_KVM_ROOTLESS_QEMU" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}✔${W}  QEMU AppImage v${_rv} đã có — bỏ qua tải"
        export QEMU_BIN="$_KVM_ROOTLESS_QEMU"
        export PATH="$HOME/qemu-static/bin:$PATH"
        export LD_LIBRARY_PATH="$HOME/qemu-static/lib:$HOME/qemu-static/lib64:${LD_LIBRARY_PATH:-}"
        export PREFIX="$HOME/qemu-static"
    else
        echo -e "${B}ℹ${W}  Tải QEMU AppImage..."
        WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/win.img"
        _start_parallel_download
        [[ -n "$IMG_DL_PID" ]] && echo -e "${B}ℹ${W}  🔀 Tải Windows image song song với AppImage (PID: $IMG_DL_PID)"
        _rootless_build
    fi

    _wait_parallel_download
    choice="n"   # skip build block hoàn toàn
    echo -e "${G}✔${W}  QEMU AppImage sẵn sàng với KVM acceleration"
    echo -e "${C}════════════════════════════════════${W}"
    echo ""
fi
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${choice:-}" != "n" ]]; then

if _detect_existing_qemu; then
    QEMU_VER=$("$QEMU_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
    if [[ "$AUTO_BUILD" == "yes" ]]; then
        choice="y"
        echo -e "${Y}⚠${W}  --rebuild: build lại QEMU v${QEMU_VER}"
    elif [[ "$AUTO_BUILD" == "no" || "$AUTO_MODE" == "1" ]]; then
        choice="n"
        echo -e "${G}✔${W} QEMU v${QEMU_VER} đã có — bỏ qua build (dùng --rebuild để build lại)"
    else
        echo -e "${G}✔${W} QEMU v${QEMU_VER} đã có — bỏ qua build"
        echo -e "${B}ℹ${W}  Dùng --rebuild nếu muốn build lại"
        choice="n"
    fi
else
    if [[ "$AUTO_BUILD" == "no" ]]; then
        choice="n"
        echo -e "${Y}⚠${W}  --no-build: bỏ qua build (QEMU chưa có, có thể lỗi)"
    elif [[ "$AUTO_MODE" == "1" || "$AUTO_BUILD" == "yes" ]]; then
        choice="y"
        echo -e "${G}🤖 Chưa có QEMU — tiến hành build${W}"
    else
        choice=$(ask "👉 Chưa tìm thấy QEMU. Build ngay không? (y/n): " "y")
    fi
fi

fi  # end if choice != n

if [[ "$choice" == "y" ]]; then

    if [[ "$ROOTLESS" == "1" ]]; then
        # Bắt đầu tải image nền TRƯỚC khi build để tối đa hoá parallelism
        # (rootless mode dùng AppImage, thường nhanh hơn source build)
        WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/win.img"
        _start_parallel_download
        [[ -n "$IMG_DL_PID" ]] && echo -e "${B}ℹ${W}  🔀 Tải image song song với rootless AppImage (PID: $IMG_DL_PID)"
        _rootless_build
    elif [[ -x "/opt/qemu-optimized/bin/qemu-system-x86_64" && "$AUTO_BUILD" != "yes" ]]; then
        BUILT_VER=$("/opt/qemu-optimized/bin/qemu-system-x86_64" --version 2>/dev/null \
            | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU v${BUILT_VER} đã có tại /opt/qemu-optimized — bỏ qua build${W}"
        echo -e "${B}ℹ${W}  Dùng --rebuild để build lại"
        export QEMU_BIN="/opt/qemu-optimized/bin/qemu-system-x86_64"
        export PATH="/opt/qemu-optimized/bin:$PATH"
        export LD_LIBRARY_PATH="/opt/qemu-optimized/lib:${LD_LIBRARY_PATH:-}"
    elif [[ -x "$HOME/qemu-optimized/bin/qemu-system-x86_64" && "$AUTO_BUILD" != "yes" ]]; then
        BUILT_VER=$("$HOME/qemu-optimized/bin/qemu-system-x86_64" --version 2>/dev/null \
            | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU v${BUILT_VER} đã có tại ~/qemu-optimized — bỏ qua build${W}"
        export QEMU_BIN="$HOME/qemu-optimized/bin/qemu-system-x86_64"
        export PATH="$HOME/qemu-optimized/bin:$PATH"
    elif [[ -x "$QEMU_BIN" && "$AUTO_BUILD" != "yes" ]]; then
        BUILT_VER=$("$QEMU_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU v${BUILT_VER} đã tồn tại — bỏ qua build${W}"
        export PATH="/opt/qemu-optimized/bin:$PATH"
    else
        echo ""
        $APT_CMD update -qq > /dev/null 2>&1

        DEPS=(
            "lsb-release|lsb-release|lsb_release"
            "wget|wget|wget"
            "gnupg|gnupg|gpg"
            "build-essential|build-essential|gcc"
            "ninja-build|ninja-build|ninja"
            "git|git|git"
            "python3-venv|python3-venv|python3"
            "python3-pip|python3-pip|pip3"
            "pkg-config|pkg-config|pkg-config"
            "aria2|aria2|aria2c"
            "ovmf|ovmf|"
            "libglib2.0-dev|libglib2.0-dev|"
            "libpixman-1-dev|libpixman-1-dev|"
            "zlib1g-dev|zlib1g-dev|"
            "libslirp-dev|libslirp-dev|"
            "meson|meson|meson"
            "software-properties-common|software-properties-common|"
            "genisoimage|genisoimage|genisoimage"
        )

        TOTAL=${#DEPS[@]}; IDX=0
        for entry in "${DEPS[@]}"; do
            IFS='|' read -r label pkg chk <<< "$entry"
            IDX=$(( IDX + 1 ))
            if [[ -n "$chk" ]] && command -v "$chk" &>/dev/null; then continue; fi
            if dpkg -s "$pkg" &>/dev/null 2>&1; then continue; fi
            _rl_step "$IDX" "$TOTAL"
            apt_install "$pkg" || true
        done
        _rl_ok "apt deps xong"

        export CC="${CC:-gcc}"
        export CXX="${CXX:-g++}"
        LLD_AVAILABLE=0

        GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")
        if ver_lt "$GLIB_VER" "2.66"; then
            _rl_warn "glib cũ — build 2.76.6"
            :
            silent sudo apt-get install -y libffi-dev gettext
            cd /tmp; silent wget -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz
            :
            :
            if command -v xz &>/dev/null; then
                silent tar -xf /tmp/glib-2.76.6.tar.xz -C /tmp
            else
                python3 -c "
import lzma, tarfile, os
os.chdir('/tmp')
with lzma.open('glib-2.76.6.tar.xz') as f:
    with tarfile.open(fileobj=f) as t:
        t.extractall('.')
" 2>/dev/null
            fi
            :
            :
            cd glib-2.76.6; silent meson setup build --prefix=/usr/local
            silent ninja -C build; silent sudo ninja -C build install
            _rl_ok "glib 2.76.6 xong"
            export PKG_CONFIG_PATH="/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
            export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:${LD_LIBRARY_PATH:-}"
        else
            echo -e "${G}✔ glib đủ yêu cầu: $GLIB_VER${W}"
        fi

        PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        :
        # Ưu tiên gói versioned (python3.X-venv) — bắt buộc với Python 3.12+ trên Ubuntu 24.04
        VENV_PKG_VER="python${PY_VER}-venv"
        VENV_PKG_GEN="python3-venv"
        _venv_pkg_ok=0
        dpkg -s "$VENV_PKG_VER" &>/dev/null 2>&1 && _venv_pkg_ok=1
        dpkg -s "$VENV_PKG_GEN" &>/dev/null 2>&1 && _venv_pkg_ok=1
        if [[ "$_venv_pkg_ok" == "0" ]]; then
            echo -ne "${B}◜${W} Cài ${VENV_PKG_VER}..."
            # Dùng $APT_CMD thay vì sudo apt-get (tránh sudo khi đã là root)
            $APT_CMD install -y -qq "$VENV_PKG_VER" > /dev/null 2>&1 \
                || $APT_CMD install -y -qq "$VENV_PKG_GEN" > /dev/null 2>&1 \
                || true   # || true: không để set -e thoát nếu cả hai fail
            echo -e "\r${G}✔${W} python venv packages cài xong          "
        else
            echo -e "${G}✔${W} python venv pkg đã có (${VENV_PKG_VER} hoặc ${VENV_PKG_GEN})"
        fi

        if [[ -d ~/qemu-env ]] && [[ -f ~/qemu-env/bin/activate ]]; then
            echo -e "${G}✔${W} Python venv đã tồn tại — sử dụng lại"
            _USE_VENV=1
        else
            echo -e "${Y}⚠${W} Không tạo venv trong rootless mode — dùng no-venv mode"
            _USE_VENV=0
        fi

        # Fix: PREFIX và PIP_TARGET chỉ được set trong _rootless_build.
        # Trong root/apt mode các biến này chưa khai báo → set -u crash.
        # Đặt fallback an toàn để PATH export không bị lỗi.
        PREFIX="${PREFIX:-$HOME/qemu-static}"
        PIP_TARGET="${PIP_TARGET:-$HOME/.local/lib/python-packages}"

        if [[ "${_USE_VENV:-0}" == "1" ]]; then
            source ~/qemu-env/bin/activate
        else
            export PATH="$PIP_TARGET/bin:$HOME/.local/bin:$PREFIX/bin:$PATH"
            export PYTHONPATH="$PIP_TARGET${PYTHONPATH:+:$PYTHONPATH}"
        fi

        :
        :
        {
            pip_install --upgrade pip tomli packaging
            pip_install meson ninja
            sudo apt-get remove -y meson 2>/dev/null || true
            hash -r
        } > /tmp/pip-install.log 2>&1
        _rl_ok "meson / ninja sẵn sàng"
        _qemu_build_tuning
        EXTRA_CFLAGS="$QEMU_BASE_CFLAGS"
        EXTRA_CXXFLAGS="$QEMU_BASE_CXXFLAGS"
        EXTRA_LDFLAGS="$QEMU_BASE_LDFLAGS"
        export CFLAGS="$EXTRA_CFLAGS"
        export CXXFLAGS="$EXTRA_CXXFLAGS"
        export LDFLAGS="$EXTRA_LDFLAGS"

        # ── LLVM Hybrid: cài dev trước khi clone QEMU ────────
        _llvm_hybrid_install_dev || true  # fallback silently
        
        if [[ ! -d /tmp/qemu-src ]]; then
            spin_start "Tải source QEMU v11.0.0..."
            silent git clone --depth 1 --branch v11.0.0 \
                https://gitlab.com/qemu-project/qemu.git /tmp/qemu-src
            spin_stop "Tải source QEMU xong"
        else
            echo -e "${G}✔ Source QEMU đã có tại /tmp/qemu-src — bỏ qua clone${W}"
        fi
        
        # ── LLVM Hybrid: extract source files vào QEMU tree ───
        _llvm_hybrid_extract_sources /tmp/qemu-src || LLVM_BUILD_OK=0

        rm -rf /tmp/qemu-build
        mkdir -p /tmp/qemu-build
        cd /tmp/qemu-build

        TCG_TB_COMPILE=$(( 256 * 1024 * 1024 ))

        export CFLAGS="$EXTRA_CFLAGS"
        export CXXFLAGS="$EXTRA_CXXFLAGS"
        export LDFLAGS="$EXTRA_LDFLAGS"

        # ── KVM flag cho configure apt-mode ──────────────────────
        if [[ "$KVM_AVAILABLE" == "1" ]]; then
            QEMU_KVM_FLAG="--enable-kvm"
            echo -e "${G}⚡ QEMU apt-build: --enable-kvm${W}"
        else
            QEMU_KVM_FLAG="--disable-kvm"
            echo -e "${B}ℹ${W}  QEMU apt-build: --disable-kvm (TCG mode)"
        fi

        # ── LLVM Hybrid flag cho configure ───────────────────
        # LLVM detection via meson dependency() in tcg/llvm/meson.build
        if [[ "$LLVM_BUILD_OK" == "1" && "$LLVM_ENABLED" == "1" ]]; then
            QEMU_LLVM_FLAG=""
            echo -e "${C}⬡ QEMU apt-build: LLVM Hybrid ORC JIT (auto-detected via meson)${W}"
        else
            QEMU_LLVM_FLAG=""
            [[ "$LLVM_ENABLED" == "1" ]] && echo -e "${Y}⚠${W}  LLVM không khả dụng — build QEMU TCG-only"
        fi

        # Bắt đầu tải image SONG SONG từ bước configure để tối đa hoá thời gian chạy song song
        WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/${WIN_IMG_PATH_BASE:-win.img}"
        _start_parallel_download
        [[ -n "$IMG_DL_PID" ]] && echo -e "${B}ℹ${W}  🔀 Tải image đang chạy nền (PID: $IMG_DL_PID) trong khi configure + compile..."
        _rl_step 1 2 && :

        if ../qemu-src/configure \
            --prefix=/opt/qemu-optimized \
            --target-list=x86_64-softmmu \
            --enable-tcg \
            $QEMU_KVM_FLAG \
            --enable-slirp \
            --enable-coroutine-pool \
            --enable-vnc \
            --disable-mshv \
            --disable-xen \
            --disable-gtk \
            --disable-sdl \
            --disable-spice \
            --disable-plugins \
            --disable-debug-info \
            --disable-docs \
            --disable-werror \
            --disable-fdt \
            --disable-vdi \
            --disable-vvfat \
            --disable-cloop \
            --disable-dmg \
            --disable-pa \
            --disable-alsa \
            --disable-oss \
            --disable-jack \
            --disable-gnutls \
            --disable-smartcard \
            --disable-libusb \
            --disable-seccomp \
            --disable-modules \
            -Dguest_agent=disabled \
            -Dguest_agent_msi=disabled \
            -Dtools=enabled \
            --extra-cflags="$QEMU_BASE_CFLAGS" \
            --extra-cxxflags="$QEMU_BASE_CXXFLAGS" \
            --extra-ldflags="$QEMU_BASE_LDFLAGS" \
            > /tmp/qemu-configure.log 2>&1; then
            spin_stop "Configure xong"
        else
            spin_fail "Configure thất bại — xem /tmp/qemu-configure.log"
            tail -30 /tmp/qemu-configure.log >&2
            exit 1
        fi

        ulimit -n 84857 2>/dev/null || true
        NCPU=$(nproc)

        # ── Compile QEMU ─────────────────────────────────────
        spin_start "Compile QEMU với ${NCPU} cores (mất 5-20 phút)..."
        printf "[*] QEMU (system) compile started at %s
" "$(date +%H:%M:%S)"
( _hb=0; while :; do sleep 30; _hb=$((_hb+1)); printf "[~] QEMU compile: %d min...
" "$((_hb/2))"; done ) & _HB_QSYS=$!
if ninja -j"$NCPU" >> /tmp/qemu-build.log 2>&1; then
  kill "$_HB_QSYS" 2>/dev/null; wait "$_HB_QSYS" 2>/dev/null || true; printf "[+] QEMU compile done
"
            spin_stop "Compile QEMU xong"
        else
            spin_fail "Compile QEMU thất bại — xem /tmp/qemu-build.log"
            tail -30 /tmp/qemu-build.log >&2
            exit 1
        fi
        echo -e "${G}🔥 Build hoàn tất: safe fast build${W}"

        echo -e "${B}ℹ${W}  Cài đặt QEMU vào /opt/qemu-optimized..."
        # Kiểm tra sudo trước để không bị treo chờ password
        if [[ $EUID -eq 0 ]]; then
            # Đang là root — cài thẳng
            ninja install > /tmp/qemu-install.log 2>&1 \
                && echo -e "${G}✔${W} Cài đặt QEMU xong (root)" \
                || { echo -e "${R}✘${W} ninja install thất bại:"; tail -20 /tmp/qemu-install.log; exit 1; }
        elif sudo -n true 2>/dev/null; then
            # sudo không cần password
            sudo ninja install > /tmp/qemu-install.log 2>&1 \
                && echo -e "${G}✔${W} Cài đặt QEMU xong (sudo)" \
                || { echo -e "${R}✘${W} ninja install thất bại:"; tail -20 /tmp/qemu-install.log; exit 1; }
        else
            # sudo cần password hoặc không có — cài vào $HOME thay thế
            echo -e "${Y}⚠${W}  sudo không có hoặc cần password — cài vào ~/qemu-optimized thay thế"
            mkdir -p ~/qemu-optimized
            DESTDIR="" ninja install --destdir="" 2>/dev/null \
                || MESON_INSTALL_DESTDIR_PREFIX="$HOME/qemu-optimized" ninja install \
                    > /tmp/qemu-install.log 2>&1 \
                || { echo -e "${R}✘${W} ninja install thất bại:"; tail -20 /tmp/qemu-install.log; exit 1; }
            export PATH="$HOME/qemu-optimized/bin:$PATH"
            export QEMU_BIN="$HOME/qemu-optimized/bin/qemu-system-x86_64"
            echo -e "${G}✔${W} Cài đặt QEMU xong → ~/qemu-optimized"
        fi

        # Cập nhật QEMU_BIN sau khi cài xong (tránh trỏ vào path không tồn tại)
        # Ưu tiên rootless path ($PREFIX, ~/qemu-static) trước opt/usr
        for _qp in \
            "${PREFIX:-}/bin/qemu-system-x86_64" \
            "$HOME/qemu-static/bin/qemu-system-x86_64" \
            "/opt/qemu-optimized/bin/qemu-system-x86_64" \
            "$HOME/qemu-optimized/bin/qemu-system-x86_64" \
            "/usr/bin/qemu-system-x86_64"; do
            [[ -x "$_qp" ]] && { export QEMU_BIN="$_qp"; break; }
        done
        # Thêm bin dir của QEMU_BIN vào PATH (hoạt động đúng cả root lẫn rootless)
        [[ -n "${QEMU_BIN:-}" ]] && export PATH="$(dirname "$QEMU_BIN"):$PATH"
        echo -e "${G}🔥 QEMU build xong! $("$QEMU_BIN" --version 2>/dev/null | head -1 || echo '(ok)')${W}"
        echo -e "   Accel: ${KVM_MODE^^}"
    fi
    # Đợi download nền (nếu đang chạy)
    _wait_parallel_download
else
    echo -e "${Y}⚡ Bỏ qua build QEMU.${W}"
    # Với --no-build, cần đảm bảo image sẵn sàng (download nếu cần)
    _start_parallel_download
    _wait_parallel_download
fi

# Đảm bảo bin dir của QEMU_BIN luôn có trong PATH (đúng cả root lẫn rootless)
[[ -x "${QEMU_BIN:-}" ]] && export PATH="$(dirname "$QEMU_BIN"):$PATH"

# ════════════════════════════════════════════════════════════════
#  CHỌN PHIÊN BẢN WINDOWS
# ════════════════════════════════════════════════════════════════
echo ""
if [[ -n "${win_choice:-}" ]]; then
    echo -e "${G}🤖 Dùng image đã chọn trước: ${WIN_NAME:-Windows image}${W}"
elif [[ "$AUTO_MODE" == "1" && -n "$AUTO_WIN" ]]; then
    win_choice="$AUTO_WIN"
    echo -e "${G}🤖 AUTO MODE — Windows preset: ${AUTO_WIN}${W}"
else
    echo "🪟 Chọn phiên bản Windows muốn tải:"
    echo "1️⃣  Windows Server 2012 R2 x64"
    echo "2️⃣  Windows Server 2022 x64"
    echo "3️⃣  Windows 11 LTSB x64"
    echo "4️⃣  Windows 10 LTSB 2015 x64"
    echo "5️⃣  Windows 10 LTSC 2023 x64"
    if [[ -t 0 ]]; then
        read -rp "👉 Nhập số [1-5]: " win_choice
    else
        win_choice="5"
        echo -e "${Y}⚠${W}  stdin không tương tác — mặc định chọn 5 (LTSC 2023)"
    fi
fi

case "$win_choice" in
1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ;;
2) WIN_NAME="Windows Server 2022";    WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img";   USE_UEFI="no"  ;;
3) WIN_NAME="Windows 11 LTSB";        WIN_URL="https://archive.org/download/win_20260203/win.img";       USE_UEFI="yes" ;;
4) WIN_NAME="Windows 10 LTSB 2015";   WIN_URL="https://archive.org/download/win_20260208/win.img";       USE_UEFI="no"  ;;
5) WIN_NAME="Windows 10 LTSC 2023";   WIN_URL="https://archive.org/download/win_20260215/win.img";       USE_UEFI="no"  ;;
*) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ;;
esac

case "$win_choice" in
3|4|5) RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
*)     RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
esac

# Kiểm tra win.img hợp lệ (tồn tại + không phải file rỗng/zero + >= 2GB)

# VNC boot verification - HTTP backend an toàn với VNC
# Không cần tắt HTTP backend, VNC hoạt động độc lập

# ── HTTP backend mode: tạo QCOW2 backing file thay vì tải toàn bộ image ──
if [[ "${USE_HTTP_BACKEND:-0}" == "1" ]]; then
    if [[ ! -f win.img ]] || ! _img_valid win.img; then
        echo -e "${C}════════════════════════════════════${W}"
        echo -e "${C}🌐 HTTP-BACKEND MODE — không tải file${W}"
        echo -e "${C}════════════════════════════════════${W}"
        echo -e "${B}ℹ${W}  Tạo QCOW2 backing → $WIN_URL"
        echo -e "${B}ℹ${W}  QEMU sẽ fetch block on-demand (tiết kiệm disk, cần mạng tốt)"
        # Dùng /usr/bin/qemu-img trực tiếp (tránh wrapper cũ trong /opt)
        _REAL_QEMU_IMG=$(for _q in /usr/bin/qemu-img /usr/local/bin/qemu-img; do
            [[ -x "$_q" ]] && grep -qv "touch" "$_q" 2>/dev/null && echo "$_q" && break
        done)
        [[ -z "$_REAL_QEMU_IMG" ]] && _REAL_QEMU_IMG=$(PATH=/usr/bin:/bin which qemu-img 2>/dev/null || echo "")
        if [[ -n "$_REAL_QEMU_IMG" && -x "$_REAL_QEMU_IMG" ]]; then
            "$_REAL_QEMU_IMG" create -f qcow2 -F raw -b "$WIN_URL" win.img 2>/dev/null                 && { echo -e "${G}✔${W} QCOW2 backing file tạo xong: win.img (HTTP-backed, ~200KB local)"; _HTTP_BACKED=1; }                 || {
                    echo -e "${Y}⚠${W}  qemu-img create failed — fallback tải thường"
                    USE_HTTP_BACKEND=0
                }
        else
            echo -e "${Y}⚠${W}  qemu-img thật không tìm thấy — fallback tải thường"
            USE_HTTP_BACKEND=0
        fi
    else
        echo -e "${G}✔${W} win.img đã tồn tại và hợp lệ — bỏ qua tạo backing"
        _HTTP_BACKED=1
    fi
fi

# Đảm bảo WIN_IMG_PATH tuyệt đối + quay về thư mục gốc
WIN_IMG_PATH="${WIN_IMG_PATH:-${ORIGINAL_DIR:-$(pwd)}/win.img}"
cd "${ORIGINAL_DIR:-$(pwd)}" 2>/dev/null || true

_HTTP_BACKED="${_HTTP_BACKED:-0}"
if [[ "$_HTTP_BACKED" == "1" ]] || [[ "${_IMG_DOWNLOAD_DONE:-0}" == "1" ]] || _img_valid "$WIN_IMG_PATH"; then
    echo -e "${G}✔ win.img sẵn sàng ($(du -sh "$WIN_IMG_PATH" 2>/dev/null | cut -f1 || echo "HTTP-backed")) — bỏ qua tải${W}"
else
    [[ -f "$WIN_IMG_PATH" ]] &&         echo -e "${Y}⚠${W}  win.img tồn tại nhưng không hợp lệ (rỗng/nhỏ quá) — tải lại"
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}⬇  Đang tải: ${Y}$WIN_NAME${W}"
    echo -e "${C}════════════════════════════════════${W}"
    if command -v aria2c &>/dev/null; then
        aria2c "${ARIA2_OPTS[@]}" \
            "$WIN_URL" -d "$(dirname "$WIN_IMG_PATH")" -o "$(basename "$WIN_IMG_PATH")"
    else
        echo -e "${Y}⚠${W}  aria2c không có — dùng wget..."
        wget --progress=bar:force --continue "$WIN_URL" -O "$WIN_IMG_PATH"
    fi
    echo -e "${G}✔ Tải $WIN_NAME xong${W}"
fi

# ── Hỏi đổi password (root mode, interactive) ─────────────────────

# ── Thực thi reset password nếu user đã xác nhận ──────────────────

if [[ "$AUTO_MODE" == "1" ]]; then
    extra_gb=0
    echo -e "${G}🤖 AUTO MODE — disk extend: 0GB (bỏ qua resize)${W}"
else
    extra_gb=""
    read -rp "📦 Mở rộng đĩa thêm bao nhiêu GB (default 20)? " extra_gb
    # Lọc bỏ escape codes/ký tự lạ từ terminal (tmux, SSH)
    extra_gb=$(echo "${extra_gb:-20}" | tr -cd '0-9')
    extra_gb="${extra_gb:-20}"
fi

if [[ "$extra_gb" -gt 0 ]]; then
    spin_start "Resize disk +${extra_gb}GB..."
    # Rootless: dùng qemu-img cùng thư mục với QEMU_BIN thay vì bare command
    _QEMU_IMG_BIN=""
    for _qi in \
        "$(dirname "${QEMU_BIN:-/nonexistent}")/qemu-img" \
        "${PREFIX:-}/bin/qemu-img" \
        "$HOME/qemu-static/bin/qemu-img" \
        "/opt/qemu-optimized/bin/qemu-img" \
        "/usr/bin/qemu-img" \
        "$(command -v qemu-img 2>/dev/null || true)"; do
        [[ -x "$_qi" ]] && { _QEMU_IMG_BIN="$_qi"; break; }
    done
    if [[ -n "$_QEMU_IMG_BIN" ]]; then
        silent "$_QEMU_IMG_BIN" resize "$WIN_IMG_PATH" "+${extra_gb}G"
    else
        echo -e "${Y}⚠${W}  qemu-img không tìm thấy — bỏ qua resize"
    fi
    spin_stop "Resize disk xong"
else
    echo -e "${B}ℹ${W}  Bỏ qua resize disk (extra_gb=0)"
fi

# ════════════════════════════════════════════════════════════════
#  CẤU HÌNH VM
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}⚙  CHỌN CHẾ ĐỘ CẤU HÌNH VM${W}"
echo -e "${C}════════════════════════════════════${W}"

if [[ "$AUTO_MODE" == "1" ]]; then
    cfg_mode="1"
    echo -e "${G}🤖 AUTO MODE — tự động chọn cấu hình tài nguyên${W}"
else
    echo "1️⃣  Auto cấu hình (khuyên dùng)"
    echo "2️⃣  Tự chọn thủ công"
    echo -e "${C}════════════════════════════════════${W}"
    if [[ -t 0 ]]; then
        read -rp "👉 Nhập lựa chọn [1-2]: " cfg_mode
    else
        cfg_mode="1"
        echo -e "${Y}⚠${W}  stdin không tương tác — mặc định chọn 1 (auto cấu hình)"
    fi
fi

if [[ "$cfg_mode" == "1" ]]; then
    spin_start "Auto detect tài nguyên host..."
    cpu_v=$(nproc 2>/dev/null); cpu_u=$cpu_v

    if [[ -f /sys/fs/cgroup/cpu.max ]]; then
        IFS=" " read -r cq cp < /sys/fs/cgroup/cpu.max
        [[ "$cq" != "max" ]] && cpu_u=$(awk "BEGIN{printf \"%.0f\",$cq/$cp}")
    elif [[ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then
        cq=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        cp=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
        [[ "$cq" != "-1" ]] && cpu_u=$(awk "BEGIN{printf \"%.0f\",$cq/$cp}")
    fi
    [[ "$cpu_u" -lt 1 ]] && cpu_u=1

    mem_total_gb=$(awk '/MemTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo)
    mem_auto_gb=$(awk "BEGIN{printf \"%d\", ($mem_total_gb*0.70)+0.5}")
    [[ "$mem_auto_gb" -lt 2 ]] && mem_auto_gb=2
    max_ram=$(( mem_total_gb - 1 ))
    [[ "$mem_auto_gb" -gt "$max_ram" ]] && mem_auto_gb=$max_ram
    cpu_core=$cpu_u; ram_size=$mem_auto_gb
    spin_stop "Auto detect xong"
    echo "   🖥️  CPU : ${cpu_v} cores (usable: ${cpu_core})"
    echo "   💾 RAM : ${mem_total_gb}GB total → VM ${ram_size}GB"
else
    cpu_core=""; ram_size=""
    read -rp "⚙  CPU core (default 4): " cpu_core
    read -rp "💾 RAM GB   (default 4): " ram_size
    cpu_core=$(echo "${cpu_core:-4}" | tr -cd '0-9'); cpu_core="${cpu_core:-4}"
    ram_size=$(echo "${ram_size:-4}" | tr -cd '0-9'); ram_size="${ram_size:-4}"
    # Đảm bảo cpu_u có giá trị hợp lệ khi manual mode
    cpu_u="${cpu_core}"
fi

# ════════════════════════════════════════════════════════════════
#  TCG PERFORMANCE TUNING
#  _tcg_tune_common  — chạy trên cả root lẫn rootless
#  _tcg_tune_root    — chỉ chạy khi có root (thêm mọi thứ còn lại)
#  _tcg_tune         — dispatcher tự chọn đúng phiên bản
# ════════════════════════════════════════════════════════════════

# ── Shared: detect physical cores, numactl, chrt, env vars ──────
_tcg_tune_common() {
    # MALLOC_ARENA_MAX=4: TCG multi-thread JIT với 4 arenas giảm lock contention
    export MALLOC_ARENA_MAX=4
    export MALLOC_MMAP_THRESHOLD_=131072
    export MALLOC_TRIM_THRESHOLD_=131072
    export JIT_SERIALIZE_OBJECT=1
    # Tắt QEMU audio — headless/RDP không cần, tránh tốn thread
    export QEMU_AUDIO_DRV=none
    echo -e "${G}✔${W} JIT env vars set (MALLOC_ARENA_MAX=4, QEMU_AUDIO_DRV=none)"

    # oom_score_adj: giảm OOM priority cho QEMU (không cần root)
    if [[ -w /proc/self/oom_score_adj ]]; then
        echo -500 > /proc/self/oom_score_adj 2>/dev/null \
            && echo -e "${G}✔${W} oom_score_adj=-500 (QEMU ít bị OOM kill hơn)" \
            || echo -e "${Y}⚠${W}  oom_score_adj: không ghi được"
    fi

    # taskset: pin QEMU vào số core được cấp phép theo cgroup quota
    # Không dùng physical core detection (nguy hiểm trong container/vCPU)
    _TASKSET_PREFIX=""
    if command -v taskset &>/dev/null; then
        # cpu_u đã được detect từ cgroup quota ở bước auto-config trước
        _pin_cores="${cpu_u:-${cpu_core:-$(nproc)}}"
        [[ "$_pin_cores" -lt 1 ]] && _pin_cores=1
        # Pin vào 0..(N-1) — đúng với cả bare-metal lẫn container vCPU
        _pin_range="0-$(( _pin_cores - 1 ))"
        [[ "$_pin_cores" -eq 1 ]] && _pin_range="0"
        _TASKSET_PREFIX="taskset -c $_pin_range"
        echo -e "${G}✔${W} taskset: pin vào ${_pin_cores} vCPU [${_pin_range}] (từ cgroup quota)"
    else
        echo -e "${Y}⚠${W}  taskset không có — bỏ qua CPU pinning"
    fi
    export _TASKSET_PREFIX

    # detect numactl
    if command -v numactl &>/dev/null \
        && numactl --hardware 2>/dev/null | grep -q 'node 0'; then
        TCG_NUMACTL_PREFIX="numactl --membind=0 --cpunodebind=0"
        echo -e "${G}✔${W} numactl: membind=0 (NUMA node 0)"
    else
        TCG_NUMACTL_PREFIX=""
    fi
    export TCG_NUMACTL_PREFIX

    # detect chrt realtime
    if command -v chrt &>/dev/null && chrt -f 99 true 2>/dev/null; then
        TCG_CHRT_PREFIX="chrt -f 99"
        echo -e "${G}✔${W} chrt -f 99 (FIFO RT)"
    elif command -v chrt &>/dev/null && chrt -r 1 true 2>/dev/null; then
        TCG_CHRT_PREFIX="chrt -r 1"
        echo -e "${G}✔${W} chrt -r 1 (RR RT)"
    else
        TCG_CHRT_PREFIX=""
        echo -e "${Y}⚠${W}  chrt: không có quyền realtime"
    fi
    export TCG_CHRT_PREFIX
    QEMU_HUGEPAGES_DIR=""; export QEMU_HUGEPAGES_DIR
}

# ── Root-only extras ─────────────────────────────────────────────
_tcg_tune_root() {
    echo -e "${B}ℹ${W}  Root TCG tuning..."

    # 1. renice
    renice -n -20 $$ 2>/dev/null \
        && echo -e "${G}✔${W} renice -20" \
        || echo -e "${Y}⚠${W}  renice thất bại"

    # 2. ionice
    ionice -c 1 -n 0 $$ 2>/dev/null \
        && echo -e "${G}✔${W} ionice: RT class" \
        || echo -e "${Y}⚠${W}  ionice thất bại"

    # 3. CPU governor → performance
    for _gf in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$_gf" ]] && echo performance > "$_gf" 2>/dev/null || true
    done
    local _gov; _gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a")
    echo -e "${G}✔${W} CPU governor: ${_gov}"

    # 4. Hugepages (2MB)
    local _pages_needed=$(( ${ram_size:-2} * 512 ))
    local _hr="/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
    if [[ -w "$_hr" ]]; then
        echo "$_pages_needed" > "$_hr" 2>/dev/null || true
        local _after; _after=$(cat "$_hr" 2>/dev/null || echo 0)
        if [[ "$_after" -ge "$_pages_needed" ]]; then
            QEMU_HUGEPAGES_DIR="/dev/hugepages"
            export QEMU_HUGEPAGES_DIR
            echo -e "${G}✔${W} Hugepages: ${_after} × 2MB"
        else
            echo -e "${Y}⚠${W}  Hugepages: chỉ có ${_after}/${_pages_needed} — bỏ qua"
        fi
    else
        echo -e "${Y}⚠${W}  Hugepages sysfs: không ghi được — bỏ qua"
    fi

    # 5. Disk scheduler → mq-deadline (skip loop devices, suppress EROFS)
    local _sched_ok=0
    for _sched in /sys/block/*/queue/scheduler; do
        [[ -f "$_sched" ]] || continue
        [[ "$_sched" == */loop* ]] && continue  # skip loop devices
        { echo mq-deadline > "$_sched"; } 2>/dev/null             && _sched_ok=$((_sched_ok+1)) || true
    done
    if [[ $_sched_ok -gt 0 ]]; then
        echo -e "${G}✔${W} Disk scheduler → mq-deadline ($_sched_ok)"
    else
        echo -e "${Y}⚠${W}  Disk scheduler: read-only/no permission — bỏ qua"
    fi
    # dummy-to-keep-indentation for Disk scheduler → mq-deadline"
}

# ── stress-ng warmup — chạy được cả root lẫn rootless ───────────
_stress_warmup() {
    local _ncpu="${1:-$(nproc)}"
    local _dur=8
    if command -v stress-ng &>/dev/null; then
        echo -e "${B}ℹ${W}  stress-ng warmup: ${_ncpu} CPU × ${_dur}s..."
        timeout $(( _dur + 2 )) stress-ng --cpu "$_ncpu" --cpu-method matrixprod \
            -t "${_dur}s" --metrics-brief 2>/dev/null || true
        echo -e "${G}✔${W} Warmup xong — CPU đang ở peak frequency"
    else
        apt_install stress-ng > /dev/null 2>&1 || true
        if command -v stress-ng &>/dev/null; then
            timeout $(( _dur + 2 )) stress-ng --cpu "$_ncpu" -t "${_dur}s" 2>/dev/null || true
            echo -e "${G}✔${W} Warmup xong"
        else
            echo -e "${Y}⚠${W}  stress-ng không có — bỏ qua warmup"
        fi
    fi
}

# ── Dispatcher ───────────────────────────────────────────────────
_tcg_tune() {
    if [[ "${NO_TUNING:-0}" == "1" ]]; then
        echo -e "${Y}⚠${W}  Bỏ qua toàn bộ TCG tuning"
        LAUNCH_PREFIX=""
        TCG_TB_MB=512
        return
    fi
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔧 TCG PERFORMANCE TUNING${W}"
    echo -e "${C}════════════════════════════════════${W}"
    _tcg_tune_common
    if [[ $EUID -eq 0 ]]; then
        _tcg_tune_root
    fi
    _stress_warmup "${cpu_core:-$(nproc)}"
    LAUNCH_PREFIX="${_TASKSET_PREFIX:+${_TASKSET_PREFIX} }${TCG_NUMACTL_PREFIX:+${TCG_NUMACTL_PREFIX} }${TCG_CHRT_PREFIX:-}"
    LAUNCH_PREFIX="${LAUNCH_PREFIX# }"
    export LAUNCH_PREFIX
    echo -e "${G}🔥 TCG tuning xong — full TCG optimizations on${W}"
    echo ""
}

if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "${G}⚡ VM sẽ chạy với KVM acceleration + CPU host passthrough${W}"
    ACCEL_OPT="-accel kvm"
    CPU_OPT="-cpu host"
    LAUNCH_PREFIX=""   # KVM không cần numactl/chrt prefix

    # Network
    [[ "$win_choice" == "4" ]] \
        && NET_DEVICE="-device e1000e,netdev=n0" \
        || NET_DEVICE="-device virtio-net-pci,netdev=n0"

    # BIOS/UEFI
    [[ "$USE_UEFI" == "yes" ]] \
        && {
            # Detect OVMF across common paths (rootless may not have apt-installed ovmf)
            _OVMF=""
            for _ovmf in                 /usr/share/qemu/OVMF.fd                 /usr/share/ovmf/OVMF.fd                 /usr/share/ovmf/x64/OVMF.fd                 /usr/share/OVMF/OVMF_CODE.fd                 "${PREFIX:-}/share/qemu/OVMF.fd"                 "$HOME/qemu-static/share/qemu/OVMF.fd"; do
                [[ -f "$_ovmf" ]] && { _OVMF="$_ovmf"; break; }
            done
            if [[ -n "$_OVMF" ]]; then
                OVMF_PATH="$_OVMF"
                echo -e "${G}✔${W} OVMF firmware: $_OVMF"
            else
                echo -e "${Y}⚠${W}  OVMF.fd không tìm thấy — thử tải..."
                _OVMF_TMP="${PREFIX:-$HOME/qemu-static}/share/qemu"
                mkdir -p "$_OVMF_TMP"
                _OVMF_OK=0
                for _ovmf_url in \
                    "https://github.com/nicowillis/ovmf-prebuilt/raw/main/OVMF.fd" \
                    "https://github.com/clearlinux/common/raw/master/OVMF.fd" \
                    "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd"; do
                    if wget -q --timeout=30 --tries=2 "$_ovmf_url" -O "$_OVMF_TMP/OVMF.fd" 2>/dev/null; then
                        # Sanity check: OVMF.fd should be >= 1MB and start with known magic
                        _sz=$(stat -c%s "$_OVMF_TMP/OVMF.fd" 2>/dev/null || echo 0)
                        if [[ "$_sz" -ge 1048576 ]]; then
                            _OVMF_OK=1; break
                        else
                            echo -e "${Y}⚠${W}  OVMF từ $_ovmf_url quá nhỏ ($_sz bytes) — thử nguồn khác"
                            rm -f "$_OVMF_TMP/OVMF.fd"
                        fi
                    fi
                done
                if [[ "$_OVMF_OK" == "1" ]]; then
                    OVMF_PATH="$_OVMF_TMP/OVMF.fd"
                    echo -e "${G}✔${W} OVMF tải xong → $_OVMF_TMP/OVMF.fd"
                else
                    OVMF_PATH=""
                    echo -e "${R}✘${W}  Không tải được OVMF — dùng SeaBIOS legacy BIOS"
                    echo -e "${Y}   Windows 10/11 có thể báo lỗi 0xc0000225 với SeaBIOS."
                    echo -e "${Y}   Fix: cài gói 'ovmf' (apt install ovmf) hoặc đặt WINBOX_DISK_BUS=ide${W}"
                fi
            fi
        } \
        || OVMF_PATH=""

    QEMU_CMD=(
        ${QEMU_BIN:-qemu-system-x86_64}
        -machine q35,hpet=off
        $CPU_OPT
        -smp "$cpu_core"
        -m "${ram_size}G"
        $ACCEL_OPT
        -rtc base=localtime,clock=host
    )

else
    # ── TCG MODE ─────────────────────────────────────────────────
    echo -e "${Y}⚡ VM sẽ chạy với TCG (software emulation)${W}"

    # Chạy tất cả TCG tuning
    _tcg_tune

    # TCG TB cache — size theo host RAM, tối đa 16384MB (giới hạn QEMU)
    _host_ram_gb="${mem_total_gb:-$(awk '/MemTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo)}"
    [[ "${_host_ram_gb:-0}" -lt 1 ]] && _host_ram_gb=4
    # Dùng 12% host RAM cho TB cache, floor 4096MB, cap 16384MB
    TCG_TB_MB=$(( _host_ram_gb * 1024 * 6 / 100 ))
    [[ "$TCG_TB_MB" -lt 4096  ]] && TCG_TB_MB=4096
    [[ "$TCG_TB_MB" -gt 8192 ]] && TCG_TB_MB=8192
    # PGO generate phase: giảm tb-size xuống 256MB.
    # Binary instrumented nặng hơn bình thường → TB cache lớn gây QEMU
    # spend quá nhiều thời gian compile TB ở boot → treo/chậm cực đoan.
    # 256MB đủ để boot + profile mà không bị stall.
    if [[ "${PGO_MODE:-0}" == "1" && "${PGO_PHASE:-}" == "generate" ]]; then
        TCG_TB_MB=256
        echo -e "${Y}⚡ PGO generate: tb-size giảm xuống 256MB (tránh boot stall)${W}"
        echo -e "${Y}⚠  Boot sẽ chậm hơn bình thường do PGO instrumentation — bình thường!${W}"
    fi
    TCG_ACCEL_OPTS="thread=multi,split-wx=off,one-insn-per-tb=off,tb-size=$TCG_TB_MB"
    # ── LLVM Hybrid Backend: integrated as compile-time feature ───
    if [[ "$LLVM_ENABLED" == "1" ]]; then
        if [[ "$LLVM_BUILD_OK" == "1" ]]; then
            echo -e "${C}⬡ LLVM Hybrid: compiled into QEMU (hot blocks → ORC JIT)${W}"
        else
            echo -e "${Y}⚠${W}  LLVM build failed — TCG-only (VM still works)"
        fi
    fi
    echo -e "${G}⚡ TCG TB cache: ${TCG_TB_MB}MB${W}"
    echo -e "${G}⚡ TCG accel: multi-thread + split-wx=off + one-insn-per-tb=off${W}"

    # CPU flags
    # model-id = tên CPU hiển thị trong Windows Device Manager (text thuần)
    # KHÔNG ảnh hưởng performance — feature flags bên dưới mới quan trọng
    #
    # Thứ tự ưu tiên lấy tên CPU:
    #   1. model name từ /proc/cpuinfo (nếu không phải "unknown"/rỗng)
    #   2. vendor_id + family/model number → tên hợp lý
    #   3. Hardcode fallback theo vendor
    _raw_cpu_name=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/^.*: //' || echo "")
    _cpu_vendor=$(grep -m1 "vendor_id"  /proc/cpuinfo 2>/dev/null | awk '{print $NF}' || echo "")

    # Kiểm tra tên có thực sự hữu ích không
    # Các giá trị vô nghĩa thường gặp trên container/VPS: "unknown", trống, chỉ toàn số/ký tự đặc biệt
    _cpu_name_useful=0
    _stripped=$(printf '%s' "$_raw_cpu_name" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [[ -n "$_stripped" && "$_stripped" != "unknown" && ${#_stripped} -ge 4 ]]; then
        # Phải có ít nhất 1 chữ cái (không phải toàn số/ký hiệu)
        if printf '%s' "$_stripped" | grep -q '[a-z]'; then
            _cpu_name_useful=1
        fi
    fi

    if [[ "$_cpu_name_useful" == "1" ]]; then
        # Dùng tên thật — sanitize để QEMU chấp nhận
        cpu_host="$_raw_cpu_name"
        cpu_model_id=$(printf '%s' "$cpu_host" \
            | tr ',' ' ' \
            | tr -d '"\\@#$%^&*|<>' \
            | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//' \
            | cut -c1-48)
    else
        # Tên không dùng được — fallback theo vendor_id
        case "$_cpu_vendor" in
            GenuineIntel) cpu_host="Intel Xeon Gold 6254" ;;
            AuthenticAMD) cpu_host="AMD EPYC 7763" ;;
            HygonGenuine) cpu_host="Hygon C86 7185" ;;
            CentaurHauls) cpu_host="VIA Nano" ;;
            *)            cpu_host="Generic x86_64" ;;
        esac
        cpu_model_id="${cpu_host} Processor"
        echo -e "${Y}⚠${W}  CPU name không đọc được ('${_raw_cpu_name:-empty}') — dùng fallback: ${cpu_model_id}"
    fi
    CPU_EXTRA=
    grep -q ssse3  /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+ssse3"
    grep -q sse4_1 /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.1"
    grep -q sse4_2 /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.2"
    grep -q rdtscp /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+rdtscp"
    grep -q ' avx ' /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx"
    grep -q avx2   /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx2"
    # qemu64: baseline an toàn, chỉ expose đúng flags host có — tránh emulate thừa
    # -tsc-deadline: tắt TSC-deadline timer trap overhead trong TCG
    cpu_model="qemu64,hypervisor=off,tsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+cx16,+x2apic,+sep,+pat,+pse,+aes,+popcnt,-tsc-deadline${CPU_EXTRA},model-id=${cpu_model_id}"

    # Network
    [[ "$win_choice" == "4" ]] \
        && NET_DEVICE="-device e1000e,netdev=n0" \
        || NET_DEVICE="-device virtio-net-pci,netdev=n0"

    # BIOS/UEFI
    [[ "$USE_UEFI" == "yes" ]] \
        && {
            # Detect OVMF across common paths (rootless may not have apt-installed ovmf)
            _OVMF=""
            for _ovmf in                 /usr/share/qemu/OVMF.fd                 /usr/share/ovmf/OVMF.fd                 /usr/share/ovmf/x64/OVMF.fd                 /usr/share/OVMF/OVMF_CODE.fd                 "${PREFIX:-}/share/qemu/OVMF.fd"                 "$HOME/qemu-static/share/qemu/OVMF.fd"; do
                [[ -f "$_ovmf" ]] && { _OVMF="$_ovmf"; break; }
            done
            if [[ -n "$_OVMF" ]]; then
                OVMF_PATH="$_OVMF"
                echo -e "${G}✔${W} OVMF firmware: $_OVMF"
            else
                echo -e "${Y}⚠${W}  OVMF.fd không tìm thấy — thử tải..."
                _OVMF_TMP="${PREFIX:-$HOME/qemu-static}/share/qemu"
                mkdir -p "$_OVMF_TMP"
                _OVMF_OK=0
                for _ovmf_url in \
                    "https://github.com/nicowillis/ovmf-prebuilt/raw/main/OVMF.fd" \
                    "https://github.com/clearlinux/common/raw/master/OVMF.fd" \
                    "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd"; do
                    if wget -q --timeout=30 --tries=2 "$_ovmf_url" -O "$_OVMF_TMP/OVMF.fd" 2>/dev/null; then
                        # Sanity check: OVMF.fd should be >= 1MB and start with known magic
                        _sz=$(stat -c%s "$_OVMF_TMP/OVMF.fd" 2>/dev/null || echo 0)
                        if [[ "$_sz" -ge 1048576 ]]; then
                            _OVMF_OK=1; break
                        else
                            echo -e "${Y}⚠${W}  OVMF từ $_ovmf_url quá nhỏ ($_sz bytes) — thử nguồn khác"
                            rm -f "$_OVMF_TMP/OVMF.fd"
                        fi
                    fi
                done
                if [[ "$_OVMF_OK" == "1" ]]; then
                    OVMF_PATH="$_OVMF_TMP/OVMF.fd"
                    echo -e "${G}✔${W} OVMF tải xong → $_OVMF_TMP/OVMF.fd"
                else
                    OVMF_PATH=""
                    echo -e "${R}✘${W}  Không tải được OVMF — dùng SeaBIOS legacy BIOS"
                    echo -e "${Y}   Windows 10/11 có thể báo lỗi 0xc0000225 với SeaBIOS."
                    echo -e "${Y}   Fix: cài gói 'ovmf' (apt install ovmf) hoặc đặt WINBOX_DISK_BUS=ide${W}"
                fi
            fi
        } \
        || OVMF_PATH=""

    # "pc" (i440fx): ít overhead hơn q35 trong TCG — interrupt routing đơn giản hơn
    _machine_type="${WINBOX_MACHINE_TYPE:-q35}"
    echo -e "${G}✔${W} Machine type: ${B}${_machine_type}${W} [override: WINBOX_MACHINE_TYPE=pc|q35]"

    QEMU_CMD=(
        ${QEMU_BIN:-qemu-system-x86_64}
        -machine ${_machine_type},hpet=off,vmport=off,mem-merge=off
        -cpu "$cpu_model"
        -smp "$cpu_core,cores=$cpu_core,threads=1,sockets=1"
        -m "${ram_size}G"
        -accel tcg,${TCG_ACCEL_OPTS}
        -rtc base=localtime
        -overcommit cpu-pm=on
        -boot order=c,strict=on
        -no-shutdown
        -device virtio-mouse-pci
        -device virtio-keyboard-pci
        -nodefaults
        # ICH9-LPC globals added conditionally below (q35 only)
        # (moved outside array to avoid syntax issues with pc machine)
        -smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640"
        -no-user-config
    )

    # kvm-pit chỉ hợp lệ khi có KVM — TCG không có pit device này
    [[ "${KVM_AVAILABLE:-0}" == "1" ]] && QEMU_CMD+=(-global kvm-pit.lost_tick_policy=discard)

    # ICH9-LPC globals only valid for q35 machine type
    [[ "${_machine_type}" == "q35" ]] && QEMU_CMD+=(-global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1)

    # Hugepages mem-path nếu detect được
    if [[ -n "${QEMU_HUGEPAGES_DIR:-}" && -d "$QEMU_HUGEPAGES_DIR" ]]; then
        QEMU_CMD+=(-mem-path "$QEMU_HUGEPAGES_DIR" -mem-prealloc)
        echo -e "${G}✔${W} Hugepages: -mem-path $QEMU_HUGEPAGES_DIR -mem-prealloc"
    fi
fi

# ── Thêm BIOS/UEFI ───────────────────────────────────────────
# shellcheck disable=SC2206 — BIOS_OPT is intentionally split into two words (-bios PATH)
[[ -n "${OVMF_PATH:-}" ]] && QEMU_CMD+=(-bios "${OVMF_PATH}")

# ── Disk ─────────────────────────────────────────────────────
WIN_IMG_PATH="${WIN_IMG_PATH:-win.img}"
# Detect image format: HTTP-backed = qcow2, else try file command
_QEMU_IMG_FMT="raw"
if [[ "${_HTTP_BACKED:-0}" == "1" ]]; then
    _QEMU_IMG_FMT="qcow2"
elif command -v qemu-img &>/dev/null; then
    _detected_fmt=$(qemu-img info --output=json "$WIN_IMG_PATH" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('format','raw'))" 2>/dev/null || echo "raw")
    [[ -n "$_detected_fmt" ]] && _QEMU_IMG_FMT="$_detected_fmt"
elif command -v file &>/dev/null && file "$WIN_IMG_PATH" 2>/dev/null | grep -qi "qcow"; then
    _QEMU_IMG_FMT="qcow2"
fi
# Disk interface: virtio
# io_uring: không dùng cho AppImage/rootless (seccomp block trong container/JupyterHub)
# Chỉ probe khi dùng system QEMU (build từ source hoặc apt)
_DISK_AIO="threads"

_is_appimage=0
[[ "${QEMU_BIN:-}" == *"qemu-static"* ]] && _is_appimage=1

if [[ "$_is_appimage" == "0" ]]; then
    # Bước 1: kiểm tra kernel có io_uring không
    _io_uring_kernel=0
    if [[ -e /proc/sys/kernel/io_uring_disabled ]]; then
        _disabled=$(cat /proc/sys/kernel/io_uring_disabled 2>/dev/null || echo 2)
        [[ "$_disabled" == "0" ]] && _io_uring_kernel=1
    elif python3 -c "
import ctypes, sys
NR_io_uring_setup = 425
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall(NR_io_uring_setup, 1, ctypes.c_void_p(0))
sys.exit(0 if ctypes.get_errno() != 38 else 1)
" 2>/dev/null; then
        _io_uring_kernel=1
    fi

    # Bước 2: probe QEMU chỉ khi kernel ok
    if [[ "$_io_uring_kernel" == "1" ]]; then
        _qemu_bin_probe="${QEMU_BIN:-qemu-system-x86_64}"
        if [[ -x "$_qemu_bin_probe" ]] || command -v "$_qemu_bin_probe" &>/dev/null; then
            _probe_out=$("$_qemu_bin_probe" \
                -drive file=/dev/null,if=none,id=x,aio=io_uring,format=raw \
                -machine none -nographic 2>&1 || true)
            if ! echo "$_probe_out" | grep -qi "invalid aio\|not support\|Operation not permitted\|seccomp"; then
                _DISK_AIO="io_uring"
            fi
        fi
    fi
fi

if [[ "$_DISK_AIO" == "io_uring" ]]; then
    echo -e "${G}✔${W}  Disk bus: ${B}virtio${W} + aio=${B}io_uring${W}"
else
    echo -e "${G}✔${W}  Disk bus: ${B}virtio${W} + aio=threads${_is_appimage:+ (AppImage — io_uring disabled)}"
fi
QEMU_CMD+=(
    -drive file="$WIN_IMG_PATH",if=none,id=disk0,cache=unsafe,aio=${_DISK_AIO},format="$_QEMU_IMG_FMT"
    -device virtio-blk-pci,drive=disk0,iothread=io1,num-queues=4,queue-size=256
    -object iothread,id=io1
)

if [[ "${WINBOX_NET_DEVICE}" == "e1000e" ]]; then
    NET_DEVICE="-device e1000e,netdev=n0"
elif [[ "${WINBOX_NET_DEVICE}" == "virtio" ]]; then
    NET_DEVICE="-device virtio-net-pci,netdev=n0"
elif [[ "${WINBOX_NET_DEVICE}" == "auto" ]]; then
    [[ "$win_choice" == "4" ]] \
        && NET_DEVICE="-device e1000e,netdev=n0" \
        || NET_DEVICE="-device virtio-net-pci,netdev=n0"
fi
QEMU_CMD+=(
    -netdev user,id=n0,hostfwd=tcp::${WINVM_RDP_PORT}-:${WINVM_RDP_PORT}${_EXTRA_FWDS_STR}
    $NET_DEVICE
)
if [[ "${WINBOX_VNC:-0}" == "1" ]]; then
    QEMU_CMD+=(-device nec-usb-xhci -device usb-tablet)
fi

# ── Input ────────────────────────────────────────────────────

# ── Display ──────────────────────────────────────────────────
# VNC luôn bật mặc định (có thể tắt bằng WINBOX_VNC=0)
if [[ "${WINBOX_VNC:-1}" == "1" ]]; then
    if "$QEMU_BIN" -help 2>&1 | grep -qE "^-vnc "; then
        QEMU_CMD+=(-vga virtio -vnc :0)
        echo -e "${G}✔${W} VNC enabled on :5900 (-vnc :0)"
    else
        QEMU_CMD+=(-vga virtio -display none)
        echo -e "${Y}⚠${W} QEMU build này không hỗ trợ -vnc, dùng RDP only (-display none)"
    fi
else
    QEMU_CMD+=(-vga virtio -display none)
fi

# ── SMBIOS/config đã được thêm vào QEMU_CMD bên trên ─────────
# -nodefaults already disables serial/monitor; removed redundant -serial none -monitor none

# ════════════════════════════════════════════════════════════════
#  KHỞI ĐỘNG VM
# ════════════════════════════════════════════════════════════════
echo -e "${B}ℹ${W}  Khởi động VM ${WIN_NAME}..."

QEMU_LOG="/tmp/qemu-launch-$$.log"
rm -f /tmp/qemu-launch.log 2>/dev/null || true
ln -sf "$QEMU_LOG" /tmp/qemu-launch.log 2>/dev/null || true

# ── Validate QEMU_BIN trước khi launch ──────────────────────────
# Resolve lại QEMU_BIN theo thứ tự ưu tiên
_resolve_qemu_bin() {
    for q in \
        "${QEMU_BIN:-}" \
        "$HOME/qemu-static/bin/qemu-system-x86_64" \
        "$HOME/qemu-optimized/bin/qemu-system-x86_64" \
        "/opt/qemu-optimized/bin/qemu-system-x86_64" \
        "$(command -v qemu-system-x86_64 2>/dev/null)"; do
        [[ -n "$q" && -x "$q" ]] && { echo "$q"; return 0; }
    done
    return 1
}

RESOLVED_QEMU=$(_resolve_qemu_bin) || {
    echo -e "${R}✘ Không tìm thấy qemu-system-x86_64!${W}"
    echo -e "${Y}   Đảm bảo đã build QEMU trước khi chạy VM.${W}"
    exit 1
}
export QEMU_BIN="$RESOLVED_QEMU"
QEMU_CMD[0]="$QEMU_BIN"
echo -e "${G}✔${W} QEMU binary: $QEMU_BIN"

# Build extra port forward string
for _fwd in "${EXTRA_FWDS[@]+"${EXTRA_FWDS[@]}"}"; do
    [[ -z "$_fwd" ]] && continue
    _h="${_fwd%%:*}"; _g="${_fwd##*:}"
    _EXTRA_FWDS_STR+=",hostfwd=tcp::${_h}-:${_g}"
done
# Add QMP socket to QEMU command
QEMU_CMD+=(-qmp unix:"$WINVM_QMP_SOCK",server,nowait)

echo "QEMU CMD: ${QEMU_CMD[*]}" > "$QEMU_LOG"

# LAUNCH_PREFIX giữ nguyên giá trị từ _tcg_tune()


# Rootless QEMU: đảm bảo LD_LIBRARY_PATH có lib path TRƯỚC khi fork
if [[ "$QEMU_BIN" == *"qemu-static"* ]]; then
    _QEMU_PREFIX="$(dirname "$(dirname "$QEMU_BIN")")"
    export LD_LIBRARY_PATH="$_QEMU_PREFIX/lib:$_QEMU_PREFIX/lib64:$_QEMU_PREFIX/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
    :
fi

_RUN_PREFIX=""
if [[ -n "${PGO_LAUNCH_ENV:-}" ]]; then
    _RUN_PREFIX="$PGO_LAUNCH_ENV"
fi
if [[ -n "${LAUNCH_PREFIX:-}" ]]; then
    _RUN_PREFIX="${_RUN_PREFIX:+${_RUN_PREFIX} }${LAUNCH_PREFIX}"
fi

if [[ -n "$_RUN_PREFIX" ]]; then
    echo -e "${G}🔥 Launch prefix: ${_RUN_PREFIX}${W}"
    # Dùng read -ra để split _RUN_PREFIX an toàn (không dùng eval)
    read -ra _launch_prefix_arr <<< "$_RUN_PREFIX"
    nohup "${_launch_prefix_arr[@]}" "${QEMU_CMD[@]}" >> "$QEMU_LOG" 2>&1 &
else
    nohup "${QEMU_CMD[@]}" >> "$QEMU_LOG" 2>&1 &
fi
QEMU_PID=$!
echo "$QEMU_PID" > "$WINVM_PID_FILE"
# Write state file for --status
python3 -c "
import json,sys
json.dump({\"pid\":int(sys.argv[1]),\"instance\":int(sys.argv[2]),\"rdp_port\":int(sys.argv[3]),\"rdp_user\":sys.argv[4],\"win_name\":sys.argv[5]},
    open(sys.argv[6],\"w\"), indent=2)
" "$QEMU_PID" "$INSTANCE_ID" "$WINVM_RDP_PORT" "$RDP_USER" "$WIN_NAME" "$WINVM_STATE_FILE" 2>/dev/null || true
disown "$QEMU_PID"

sleep 4
if kill -0 "$QEMU_PID" 2>/dev/null; then
    echo -e "${G}✔${W} VM đã khởi động (PID: $QEMU_PID)"
else
    echo -e "${R}✘ VM KHÔNG khởi động được!${W}"
    echo -e "${R}═══ QEMU ERROR LOG ═══${W}"
    cat "$QEMU_LOG"
    echo -e "${R}═══════════════════════${W}"
    echo -e "${Y}Tip: Xem log đầy đủ tại $QEMU_LOG${W}"
    exit 1
fi


PUBLIC=""

if [[ "${PGO_MODE:-0}" == "1" && "${PGO_PROFILE_READY:-0}" != "1" ]]; then
    echo ""
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "${C}🧪 PGO TRAINING MODE${W}"
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "${B}ℹ${W}  Hãy vào VM và chạy vài workload nhẹ để QEMU học trước."
    echo -e "${B}ℹ${W}  Profile sẽ được lưu tại: ${PGO_PROFILE_ARCHIVE}"
    echo -e "${B}ℹ${W}  Khi xong, gõ ${G}continue${W} để dừng VM, lưu profile và build lại."
    while true; do
        read -rp "continue> " _pgo_reply || true  # || true tránh set -e kill script khi stdin là EOF/non-interactive
        [[ "${_pgo_reply,,}" == "continue" ]] && break
    done
    echo -e "${B}ℹ${W}  Đang dừng VM để flush PGO profile..."
    _pgo_stop_vm
    if _pgo_finalize_profile; then
        if [[ -f "$PGO_PROFILE_ARCHIVE" ]]; then
            echo -e "${G}✔${W} PGO profile đã lưu: ${PGO_PROFILE_ARCHIVE}"
            echo -e "${B}ℹ${W}  Đang build lại QEMU với profile vừa lưu..."
            PGO_PROFILE_READY=1
            PGO_PHASE="use"
            PGO_MODE=1
            export PGO_PROFILE_READY PGO_PHASE PGO_MODE
            exec bash "$0" "${ORIGINAL_ARGS[@]}"
        else
            echo -e "${R}✘${W}  Không tạo được PGO archive: ${PGO_PROFILE_ARCHIVE}"
            exit 1
        fi
    else
        echo -e "${R}✘${W}  Finalize PGO profile thất bại — không build lại${W}"
        exit 1
    fi
fi

# ── SUMMARY ───────────────────────────────────────────────────────
echo ""
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${C}🚀 WINBOX DEPLOYED SUCCESSFULLY${W}"
[[ "$AUTO_MODE" == "1" ]] && \
    echo -e "${C}🤖 Launched via: --auto${AUTO_WIN:+ --win$AUTO_WIN}${W}"
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "🪟 OS           : ${Y}$WIN_NAME${W}"
echo -e "⚙  CPU Cores    : ${B}$cpu_core${W}"
echo -e "💾 RAM          : ${B}${ram_size} GB${W}"
if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "⚡ Acceleration : ${G}KVM (hardware) + CPU host${W}"
else
    echo -e "⚡ Acceleration : ${Y}TCG (software) | TB cache: ${TCG_TB_MB:-?}MB${W}"
    echo -e "🧠 CPU Model    : ${B}${cpu_host:-unknown}${W}"
fi
echo -e "${C}──────────────────────────────────────────────${W}"
if [[ -n "$PUBLIC" ]]; then
    echo -e "📡 RDP Address  : ${G}${PUBLIC}${W}"

else
    echo -e "📡 RDP (local)  : ${G}localhost:${WINVM_RDP_PORT}${W}"
    [[ "${use_rdp:-n}" == "y" ]] && \
        echo -e "${Y}   ⚠  Tunnel chưa lấy được endpoint — xem log ở trên${W}"
fi
echo -e "👤 Username     : ${Y}$RDP_USER${W}"
echo -e "🔑 Password     : ${Y}$RDP_PASS${W}"
echo -e "${C}══════════════════════════════════════════════${W}"
echo "🖥  VNC Server   : ${G}:5900${W} (share=force-shared)"
echo "   → vncviewer localhost:5900"
echo "   → noVNC: http://localhost:6080 (nếu có websockify)"
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${G}🟢 Status       : RUNNING (PID: $QEMU_PID)${W}"
echo    "⏱  GUI Mode     : VNC + RDP"
echo -e "${C}══════════════════════════════════════════════${W}"
