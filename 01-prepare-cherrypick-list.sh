#!/usr/bin/env bash
# =============================================================================
#  01-prepare-cherrypick-list.sh
#  Langkah 1: Generate daftar cherry-pick yang diprioritaskan
#  Jalankan SEKALI dari branch upstream-v4.19.325-cip136-rt50
#
#  Usage: bash 01-prepare-cherrypick-list.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

# ── Konfigurasi ─────────────────────────────────────────────────────────────
SOURCE_BRANCH="motregen"          # Branch asal (yang berisi patch kamu)
BASE_COMMIT="d4d8446893fd"        # Titik pisah: Merge tag v4.19.325-cip136
RT_TAG="v4.19.325-cip136-rt50"
LISTS_DIR=".cherry-lists"
PATCHES_DIR=".cherry-patches"

mkdir -p "$LISTS_DIR" "$PATCHES_DIR"

echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   STEP 1: Generate Cherry-Pick Lists                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Validasi ─────────────────────────────────────────────────────────────────
CURRENT=$(git rev-parse --abbrev-ref HEAD)
log "Branch saat ini: $CURRENT"
[[ -n "$(git status --porcelain)" ]] && err "Working tree kotor! Commit atau stash dulu."
git rev-parse "$RT_TAG" &>/dev/null || err "Tag $RT_TAG tidak ditemukan. Jalankan git fetch cip tag $RT_TAG --no-tags dulu."
git rev-parse "$SOURCE_BRANCH" &>/dev/null || err "Branch $SOURCE_BRANCH tidak ditemukan."

# ── Export semua patch dari motregen sebagai backup ───────────────────────────
log "Export patch dari $SOURCE_BRANCH ke $PATCHES_DIR/ ..."
git format-patch "${BASE_COMMIT}..${SOURCE_BRANCH}" \
    --no-merges \
    --output-directory "$PATCHES_DIR/" \
    --quiet
PATCH_COUNT=$(ls "$PATCHES_DIR/"*.patch 2>/dev/null | wc -l)
ok "Exported $PATCH_COUNT patch files → $PATCHES_DIR/"

# ── Generate list semua commit (oldest→newest) ────────────────────────────────
log "Generating commit lists..."

git log --format="%H %s" --no-merges --reverse \
    "${BASE_COMMIT}..${SOURCE_BRANCH}" \
    > "$LISTS_DIR/00-all-commits.txt"

TOTAL=$(wc -l < "$LISTS_DIR/00-all-commits.txt")
log "Total commit custom: $TOTAL"

# ── Kategori A: SKIP — Sudah pasti ada di RT tag ─────────────────────────────
# Deteksi dengan git cherry: '-' berarti equivalent patch sudah ada upstream
log "Deteksi commit duplikat dengan git cherry (bisa lambat ~2 menit)..."
> "$LISTS_DIR/01-skip-duplicates.txt"
> "$LISTS_DIR/02-cherrypick-all.txt"

SKIP_COUNT=0
PICK_COUNT=0

while IFS=' ' read -r hash subject; do
    result=$(git cherry "$RT_TAG" "$hash" 2>/dev/null | head -1 | cut -c1)
    if [[ "$result" == "-" ]]; then
        echo "$hash $subject" >> "$LISTS_DIR/01-skip-duplicates.txt"
        ((SKIP_COUNT++)) || true
    else
        echo "$hash" >> "$LISTS_DIR/02-cherrypick-all.txt"
        ((PICK_COUNT++)) || true
    fi
done < "$LISTS_DIR/00-all-commits.txt"

ok "Duplikat (akan di-skip): $SKIP_COUNT"
ok "Perlu cherry-pick:        $PICK_COUNT"

# ── Kategori berdasarkan prefix ───────────────────────────────────────────────
log "Kategorisasi commit yang akan di-cherry-pick..."

# Ambil hash+subject dari yang akan di-cherry-pick
while IFS= read -r hash; do
    subject=$(git log -1 --format="%s" "$hash")
    echo "$hash $subject"
done < "$LISTS_DIR/02-cherrypick-all.txt" \
    > "$LISTS_DIR/02-cherrypick-all-with-subject.txt"

# Kategori per tipe (hanya yang akan di-cherry-pick):
# Techpack / Display (KONFLIK TINGGI - techpack tidak ada di RT)
grep -iE " techpack:" "$LISTS_DIR/02-cherrypick-all-with-subject.txt" \
    | awk '{print $1}' > "$LISTS_DIR/cat-A-techpack.txt" 2>/dev/null || true

# DTS / arm64 device tree
grep -iE " (arm64: dts|dts:|ARM64: dts)" "$LISTS_DIR/02-cherrypick-all-with-subject.txt" \
    | awk '{print $1}' > "$LISTS_DIR/cat-B-dts.txt" 2>/dev/null || true

# KernelSU
grep -iE " KernelSU:" "$LISTS_DIR/02-cherrypick-all-with-subject.txt" \
    | awk '{print $1}' > "$LISTS_DIR/cat-C-kernelsu.txt" 2>/dev/null || true

# Sched patches (KONFLIK - RT ganti scheduler)
grep -iE " sched" "$LISTS_DIR/02-cherrypick-all-with-subject.txt" \
    | awk '{print $1}' > "$LISTS_DIR/cat-D-sched.txt" 2>/dev/null || true

# Binder
grep -iE " binder" "$LISTS_DIR/02-cherrypick-all-with-subject.txt" \
    | awk '{print $1}' > "$LISTS_DIR/cat-E-binder.txt" 2>/dev/null || true

# ZSTD / lib
grep -iE " (zstd|lib: zstd)" "$LISTS_DIR/02-cherrypick-all-with-subject.txt" \
    | awk '{print $1}' > "$LISTS_DIR/cat-F-zstd.txt" 2>/dev/null || true

# Fog / device config
grep -iE " fog" "$LISTS_DIR/02-cherrypick-all-with-subject.txt" \
    | awk '{print $1}' > "$LISTS_DIR/cat-G-fog-config.txt" 2>/dev/null || true

# cpufreq / cpuidle / power
grep -iE " (cpufreq|cpuidle|power:)" "$LISTS_DIR/02-cherrypick-all-with-subject.txt" \
    | awk '{print $1}' > "$LISTS_DIR/cat-H-power.txt" 2>/dev/null || true

# simple_lmk
grep -iE " simple_lmk" "$LISTS_DIR/02-cherrypick-all-with-subject.txt" \
    | awk '{print $1}' > "$LISTS_DIR/cat-I-lmk.txt" 2>/dev/null || true

# Sisanya (uncategorized)
ALL_CATEGORIZED=$(cat "$LISTS_DIR/cat-"*.txt 2>/dev/null | sort -u)
while IFS= read -r hash; do
    if ! echo "$ALL_CATEGORIZED" | grep -q "^$hash$"; then
        echo "$hash" >> "$LISTS_DIR/cat-Z-other.txt"
    fi
done < "$LISTS_DIR/02-cherrypick-all.txt"

echo ""
echo -e "${BOLD}═══ RINGKASAN KATEGORI (dari yang perlu di-cherry-pick) ═══${NC}"
echo ""
printf "  %-4s %-35s %s\n" "Jml" "Kategori" "File list"
printf "  %-4s %-35s %s\n" "---" "---------" "---------"
for f in "$LISTS_DIR/cat-"*.txt; do
    count=$(wc -l < "$f" 2>/dev/null || echo 0)
    name=$(basename "$f" .txt | sed 's/cat-[A-Z]-//')
    printf "  %-4s %-35s %s\n" "$count" "$name" "$(basename $f)"
done

echo ""
echo -e "${BOLD}═══ TOTAL ═══${NC}"
echo "  Skip (duplikat di RT): $SKIP_COUNT"
echo "  Cherry-pick:           $PICK_COUNT"
echo "  Total dari motregen:   $TOTAL"
echo ""
ok "List tersimpan di: $LISTS_DIR/"
echo ""
echo -e "${BOLD}Langkah selanjutnya:${NC}"
echo "  bash 02-cherrypick-run.sh [kategori]"
echo ""
echo "  Contoh urutan yang disarankan:"
echo "    bash 02-cherrypick-run.sh cat-G-fog-config.txt    # config device dulu"
echo "    bash 02-cherrypick-run.sh cat-B-dts.txt           # device tree"
echo "    bash 02-cherrypick-run.sh cat-F-zstd.txt          # lib zstd"
echo "    bash 02-cherrypick-run.sh cat-H-power.txt         # cpufreq/power"
echo "    bash 02-cherrypick-run.sh cat-I-lmk.txt           # simple_lmk"
echo "    bash 02-cherrypick-run.sh cat-C-kernelsu.txt      # KernelSU"
echo "    bash 02-cherrypick-run.sh cat-E-binder.txt        # binder"
echo "    bash 02-cherrypick-run.sh cat-Z-other.txt         # sisanya"
echo "    bash 02-cherrypick-run.sh cat-A-techpack.txt      # techpack (paling banyak conflict)"
echo "    bash 02-cherrypick-run.sh cat-D-sched.txt         # sched (review manual dulu!)"
