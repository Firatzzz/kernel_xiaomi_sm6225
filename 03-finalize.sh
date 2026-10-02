#!/usr/bin/env bash
# =============================================================================
#  03-finalize.sh
#  Langkah 3: Finalisasi setelah semua cherry-pick selesai
#  - Update localversion
#  - Tampilkan laporan lengkap
#  - Cek build readiness
#
#  Usage: bash 03-finalize.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   STEP 3: Finalize Upstream                         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

CURRENT=$(git rev-parse --abbrev-ref HEAD)
log "Branch: $CURRENT"
[[ -n "$(git status --porcelain)" ]] && err "Working tree kotor! Selesaikan conflict dulu."

# ── Update localversion ───────────────────────────────────────────────────────
echo ""
log "Update localversion files..."

echo "-cip136" > localversion-cip
ok "localversion-cip → '-cip136'"

echo "-rt50" > localversion-rt
ok "localversion-rt  → '-rt50' (file baru)"

# Hapus localversion-st jika ada (tidak relevan di RT branch)
if [[ -f localversion-st ]]; then
    warn "Menghapus localversion-st (tidak relevan di RT branch)"
    git rm localversion-st 2>/dev/null || rm localversion-st
fi

git add localversion-cip localversion-rt 2>/dev/null || true
git commit -m "localversion: update to v4.19.325-cip136-rt50" --allow-empty
ok "localversion committed"

# ── Verifikasi versi ──────────────────────────────────────────────────────────
echo ""
log "Verifikasi kernel version..."
KERNEL_VER=$(make kernelversion 2>/dev/null || echo "unknown")
echo -e "  Kernel version: ${BOLD}$KERNEL_VER${NC}"

HEAD_COUNT=$(git rev-list "v4.19.325-cip136-rt50..HEAD" --count 2>/dev/null || echo "?")
echo -e "  Commit di atas RT tag: ${BOLD}$HEAD_COUNT${NC}"

# ── Laporan cherry-pick ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ LAPORAN CHERRY-PICK PER KATEGORI ═══${NC}"
echo ""
LOG_DIR=".cherry-logs"
if [[ -d "$LOG_DIR" ]]; then
    TOTAL_SUCCESS=0; TOTAL_FAIL=0
    for progress_file in "$LOG_DIR/"*.progress; do
        [[ -f "$progress_file" ]] || continue
        cat_name=$(basename "$progress_file" .progress)
        count=$(wc -l < "$progress_file")
        failed_file="$LOG_DIR/${cat_name}.failed"
        failed_count=0
        [[ -f "$failed_file" ]] && failed_count=$(wc -l < "$failed_file")
        echo -e "  ${CYAN}$cat_name${NC}: ${GREEN}$count picked${NC}, ${RED}$failed_count failed/skipped${NC}"
        ((TOTAL_SUCCESS += count)) || true
        ((TOTAL_FAIL += failed_count)) || true
    done
    echo ""
    echo -e "  ${BOLD}Total berhasil: ${GREEN}$TOTAL_SUCCESS${NC}"
    echo -e "  ${BOLD}Total gagal:    ${RED}$TOTAL_FAIL${NC}"
fi

# ── Tampilkan semua yang gagal ────────────────────────────────────────────────
echo ""
if ls "$LOG_DIR/"*.failed &>/dev/null 2>&1; then
    TOTAL_FAILED_LINES=$(cat "$LOG_DIR/"*.failed 2>/dev/null | wc -l)
    if [[ "$TOTAL_FAILED_LINES" -gt 0 ]]; then
        warn "Commit yang gagal/skip (perlu review manual):"
        cat "$LOG_DIR/"*.failed 2>/dev/null | head -30
        echo ""
        echo -e "  File lengkap: ${CYAN}$LOG_DIR/*.failed${NC}"
    fi
fi

# ── Checklist akhir ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ CHECKLIST SEBELUM BUILD ═══${NC}"
echo ""
echo -e "  ${BOLD}1. Update defconfig untuk RT:${NC}"
echo "     Edit: arch/arm64/configs/vendor/xiaomi/fog.config"
echo "     Tambahkan:"
echo "       CONFIG_PREEMPT_RT=y      # aktifkan RT scheduler"
echo "       CONFIG_HZ_1000=y         # timing RT lebih presisi"
echo ""
echo -e "  ${BOLD}2. KNOWN-BUGS yang perlu diperhatikan:${NC}"
echo -e "  ${YELLOW}⚠ CVE-2025-39953${NC} — cgroup fix di-revert oleh CIP"
echo "     File: kernel/cgroup/cgroup.c"
echo "     Ini adalah known issue dari CIP sendiri (documented di KNOWN-BUGS)"
echo ""
echo -e "  ${BOLD}3. Build test:${NC}"
echo "     export ARCH=arm64"
echo "     export CROSS_COMPILE=aarch64-linux-gnu-"
echo "     make fog_defconfig          # atau defconfig device kamu"
echo "     make -j\$(nproc) 2>&1 | tee build.log"
echo "     grep -c 'error:' build.log  # harus 0"
echo ""
echo -e "  ${BOLD}4. Jika ada build error di sched/:${NC}"
echo "     Patch sched/CASS kamu mungkin tidak kompatibel dengan RT."
echo "     Solusi: revert cat-D-sched patches dan gunakan RT scheduler bawaan."
echo ""
echo -e "  ${BOLD}5. Push ke GitHub:${NC}"
echo "     git push origin upstream-v4.19.325-cip136-rt50"
echo ""
ok "Finalisasi selesai! Branch: $CURRENT"
