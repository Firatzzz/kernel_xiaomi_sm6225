#!/usr/bin/env bash
# =============================================================================
#  02-cherrypick-run.sh
#  Langkah 2: Jalankan cherry-pick per kategori secara interaktif
#
#  Usage: bash 02-cherrypick-run.sh <file-list>
#  Contoh: bash 02-cherrypick-run.sh .cherry-lists/cat-C-kernelsu.txt
#
#  Saat conflict:
#    - Script PAUSE dan tunjukkan file yang conflict
#    - Kamu resolve manual, lalu tekan ENTER untuk lanjut
#    - Atau ketik 's' untuk SKIP commit ini
#    - Atau ketik 'q' untuk QUIT (simpan progress)
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }
conflict(){ echo -e "${RED}[CONFLICT]${NC} $*"; }
skip()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }

LISTS_DIR=".cherry-lists"
LOG_DIR=".cherry-logs"
mkdir -p "$LOG_DIR"

# ── Validasi argument ─────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && err "Usage: bash $0 <file-list>\nContoh: bash $0 $LISTS_DIR/cat-C-kernelsu.txt"

LIST_FILE="$1"
[[ ! -f "$LIST_FILE" ]] && err "File tidak ditemukan: $LIST_FILE"

CATEGORY=$(basename "$LIST_FILE" .txt)
PROGRESS_FILE="$LOG_DIR/${CATEGORY}.progress"
FAILED_FILE="$LOG_DIR/${CATEGORY}.failed"
SESSION_LOG="$LOG_DIR/${CATEGORY}.log"

echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   STEP 2: Cherry-Pick — $CATEGORY${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Cek kondisi ──────────────────────────────────────────────────────────────
CURRENT=$(git rev-parse --abbrev-ref HEAD)
log "Branch: $CURRENT"
[[ "$CURRENT" != "upstream-v4.19.325-cip136-rt50" ]] && \
    warn "Kamu tidak di branch upstream-v4.19.325-cip136-rt50! Lanjut? (y/N)" && \
    read -r ans && [[ "$ans" != "y" ]] && exit 0

# ── Load progress jika ada ────────────────────────────────────────────────────
DONE_COMMITS=()
if [[ -f "$PROGRESS_FILE" ]]; then
    warn "Progress sebelumnya ditemukan ($PROGRESS_FILE)"
    echo -ne "  Lanjut dari progress sebelumnya? [Y/n]: "
    read -r ans
    if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
        mapfile -t DONE_COMMITS < "$PROGRESS_FILE"
        ok "Melanjutkan dari ${#DONE_COMMITS[@]} commit yang sudah diproses."
    else
        > "$PROGRESS_FILE"
        > "$FAILED_FILE"
        warn "Progress direset."
    fi
fi

# ── Baca daftar commit ────────────────────────────────────────────────────────
mapfile -t COMMITS < "$LIST_FILE"
TOTAL=${#COMMITS[@]}
DONE=0; SUCCESS=0; SKIPPED=0; FAILED=0
IDX=0

echo ""
log "Total commit dalam kategori ini: $TOTAL"
echo ""

# ── Loop cherry-pick ──────────────────────────────────────────────────────────
for hash in "${COMMITS[@]}"; do
    ((IDX++)) || true
    [[ -z "$hash" ]] && continue

    # Skip yang sudah diproses sebelumnya
    if printf '%s\n' "${DONE_COMMITS[@]}" | grep -q "^${hash}$"; then
        ((DONE++)) || true
        continue
    fi

    SUBJECT=$(git log -1 --format="%s" "$hash" 2>/dev/null || echo "(unknown)")
    PROGRESS_BAR="[$IDX/$TOTAL]"

    echo -ne "${DIM}$PROGRESS_BAR${NC} "

    # ── Coba cherry-pick ──────────────────────────────────────────────────────
    if git cherry-pick "$hash" \
        --no-edit \
        --allow-empty \
        --allow-empty-message \
        >> "$SESSION_LOG" 2>&1; then

        ok "$PROGRESS_BAR ${hash:0:10} — $SUBJECT"
        echo "$hash" >> "$PROGRESS_FILE"
        ((SUCCESS++)) || true

    else
        # ── Ada conflict ──────────────────────────────────────────────────────
        echo ""
        conflict "$PROGRESS_BAR ${hash:0:10} — $SUBJECT"
        echo ""

        # Tampilkan file yang conflict
        CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null)
        if [[ -n "$CONFLICTED" ]]; then
            echo -e "  ${YELLOW}File yang conflict:${NC}"
            echo "$CONFLICTED" | while read -r f; do
                echo -e "    ${RED}↳${NC} $f"
            done
        fi

        # Cek apakah ini conflict "modify/delete" (techpack di RT tidak ada)
        MODIFY_DELETE=$(git status --short 2>/dev/null | grep -c "^DU\|^UD" || true)
        if [[ "$MODIFY_DELETE" -gt 0 ]]; then
            echo ""
            warn "Tipe conflict: file di motregen tidak ada di RT tag (modify/delete)"
            warn "Ini terjadi karena RT tidak punya direktori tersebut (misal techpack/)"
            echo ""
            echo -e "  Pilihan:"
            echo -e "  ${GREEN}[a]${NC} Accept ours — ambil file dari motregen (REKOMENDASI untuk techpack)"
            echo -e "  ${YELLOW}[s]${NC} Skip commit ini"
            echo -e "  ${RED}[q]${NC} Quit & simpan progress"
            echo -ne "  Pilihan [a/s/q]: "
            read -r choice

            case "${choice:-a}" in
                a|A)
                    # Accept semua file "ours" (dari commit yang sedang di-cherry-pick)
                    git checkout --theirs . 2>/dev/null || true
                    git add -A
                    git cherry-pick --continue --no-edit >> "$SESSION_LOG" 2>&1 || \
                        git commit --no-edit --allow-empty >> "$SESSION_LOG" 2>&1 || true
                    ok "Accepted (ours): $hash"
                    echo "$hash" >> "$PROGRESS_FILE"
                    ((SUCCESS++)) || true
                    ;;
                s|S)
                    git cherry-pick --abort >> "$SESSION_LOG" 2>&1 || true
                    skip "Skipped: $hash"
                    echo "SKIP:$hash $SUBJECT" >> "$FAILED_FILE"
                    echo "$hash" >> "$PROGRESS_FILE"
                    ((SKIPPED++)) || true
                    ;;
                q|Q)
                    git cherry-pick --abort >> "$SESSION_LOG" 2>&1 || true
                    echo ""
                    warn "Quit — progress disimpan. Jalankan ulang script untuk lanjut."
                    break
                    ;;
            esac

        else
            # Conflict biasa — pause untuk resolve manual
            echo ""
            warn "Conflict biasa — silakan resolve manual:"
            echo ""
            echo -e "  ${BOLD}Cara resolve:${NC}"
            echo -e "  1. Buka file yang conflict di editor"
            echo -e "  2. Cari marker ${RED}<<<<<<< HEAD${NC} / ${YELLOW}=======}${NC} / ${GREEN}>>>>>>> commit${NC}"
            echo -e "  3. Edit sesuai keinginan"
            echo -e "  4. ${CYAN}git add <file-yang-sudah-difix>${NC}"
            echo -e "  5. Tekan ENTER di sini untuk lanjut"
            echo ""
            echo -e "  Atau:"
            echo -e "  ${YELLOW}[s]${NC} Skip commit ini"
            echo -e "  ${RED}[q]${NC} Quit & simpan progress"
            echo -ne "  [ENTER untuk lanjut / s / q]: "
            read -r choice

            case "${choice:-}" in
                s|S)
                    git cherry-pick --abort >> "$SESSION_LOG" 2>&1 || true
                    skip "Skipped: $hash"
                    echo "SKIP:$hash $SUBJECT" >> "$FAILED_FILE"
                    echo "$hash" >> "$PROGRESS_FILE"
                    ((SKIPPED++)) || true
                    ;;
                q|Q)
                    git cherry-pick --abort >> "$SESSION_LOG" 2>&1 || true
                    warn "Quit — progress disimpan."
                    break
                    ;;
                *)
                    # Lanjut setelah resolve manual
                    git cherry-pick --continue --no-edit >> "$SESSION_LOG" 2>&1 || \
                    git commit --no-edit --allow-empty >> "$SESSION_LOG" 2>&1 || {
                        warn "cherry-pick --continue gagal. Skip commit ini."
                        git cherry-pick --abort 2>/dev/null || true
                        echo "FAIL:$hash $SUBJECT" >> "$FAILED_FILE"
                        echo "$hash" >> "$PROGRESS_FILE"
                        ((FAILED++)) || true
                        continue
                    }
                    ok "Resolved & continue: $hash"
                    echo "$hash" >> "$PROGRESS_FILE"
                    ((SUCCESS++)) || true
                    ;;
            esac
        fi
    fi

    ((DONE++)) || true
done

# ── Laporan akhir ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ LAPORAN: $CATEGORY ═══${NC}"
echo ""
echo -e "  ${GREEN}✓ Berhasil:${NC}  $SUCCESS"
echo -e "  ${YELLOW}→ Di-skip:${NC}   $SKIPPED"
echo -e "  ${RED}✗ Gagal:${NC}     $FAILED"
echo -e "  Total:       $TOTAL"
echo ""

if [[ -s "$FAILED_FILE" ]]; then
    warn "Commit yang gagal/skip tersimpan di: $FAILED_FILE"
fi

ok "Log tersimpan di: $SESSION_LOG"
echo ""
echo -e "${BOLD}Setelah semua kategori selesai, jalankan:${NC}"
echo "  bash 03-finalize.sh"
