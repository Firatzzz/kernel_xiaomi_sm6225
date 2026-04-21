set -e
set -o pipefail

export TZ='Asia/Jakarta'
BUILDDATE=$(date +%Y%m%d)
BUILDTIME=$(date +%H%M%S)
BASE_DIR=$(pwd)
KERNEL_DIR="$BASE_DIR/kernel_xiaomi_sm6225"
OUTPUT_DIR="$BASE_DIR/Ouput Kernel"
ANYKERNEL_DIR="$BASE_DIR/AnyKernel3"
LOG_FILE="$BASE_DIR/build.log"

PIXELDRAIN_API_KEY=''

# KernelSU
KERNELSU=1

if [ $KERNELSU = 1 ]; then
  KERNEL_NAME='Invicible-KSU'
  KERNEL_BRANCH='motregen'
else
  KERNEL_NAME='Invicible'
  KERNEL_BRANCH='motregen'
fi

# Cleanup
echo "--- Cleaning up previous builds ---"
rm -rf "$KERNEL_DIR/out"
rm -f "$LOG_FILE"
mkdir -p "$OUTPUT_DIR"

# Check Dependencies
echo "--- Checking Dependencies ---"
MISSING_DEPS=0
for cmd in make clang gcc aarch64-linux-gnu-gcc zip git; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "ERROR: command '$cmd' not found!"
        MISSING_DEPS=1
    fi
done

if [ $MISSING_DEPS -eq 1 ]; then
    echo "--------------------------------------------------------"
    echo "CRITICAL ERROR: Some build tools are missing."
    echo "Please run the following command to install them:"
    echo "sudo apt update && sudo apt install -y build-essential clang gcc-aarch64-linux-gnu git bc bison flex libssl-dev"
    echo "--------------------------------------------------------"
    exit 1
fi

# Download and Setup Clang
if [ ! -d "clang-llvm" ]; then
    echo "--- Downloading AOSP Clang ---"
    wget https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android14-release/clang-r487747c.tar.gz -O "clang-r487747c.tar.gz"
    mkdir -p clang-llvm
    tar -xf clang-r487747c.tar.gz -C clang-llvm
    rm -f clang-r487747c.tar.gz
fi

export PATH="$BASE_DIR/clang-llvm/bin:${PATH}"

# Build
echo "--- Starting Build Process ---"
cd "$KERNEL_DIR"

# Ensure repo is up to date and branches are known
echo "--- Fetching latest data from Git ---"
git fetch origin

# Branch checkout
echo "--- Checking out branch: $KERNEL_BRANCH ---"
if git checkout "$KERNEL_BRANCH"; then
    echo "--- Successfully checked out $KERNEL_BRANCH ---"
else
    echo "ERROR: Branch '$KERNEL_BRANCH' not found!"
    echo "Available local branches:"
    git branch
    echo "Available remote branches:"
    git branch -r
    exit 1
fi

# Prepare Config
echo "--- Configuring Kernel ---"
MAKE_ARGS=(
    -j$(nproc --all)
    O=out
    ARCH=arm64
    CC=clang
    LLVM=1
    LLVM_IAS=1
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE=aarch64-linux-gnu-
)

# Step 1: Base defconfig
echo "--- Applying base defconfig: vendor/bengal-perf_defconfig ---"
make "${MAKE_ARGS[@]}" vendor/bengal-perf_defconfig 2>&1 | tee -a "$LOG_FILE"

# Step 2: Merge fragments
echo "--- Merging device configuration: vendor/xiaomi/fog.config ---"
fragments=(arch/arm64/configs/vendor/xiaomi/fog.config)
if [ $KERNELSU = 1 ]; then
    echo "--- Merging KernelSU configuration: vendor/ksu.config ---"
    fragments+=(arch/arm64/configs/vendor/ksu.config)
fi

# Ensure merge_config.sh is executable
chmod +x scripts/kconfig/merge_config.sh
ARCH=arm64 ./scripts/kconfig/merge_config.sh -O out/ out/.config "${fragments[@]}" 2>&1 | tee -a "$LOG_FILE"

# Auto-fill new config options with defaults to avoid interactive prompts
echo "--- Auto-filling new configuration options ---"
make "${MAKE_ARGS[@]}" olddefconfig 2>&1 | tee -a "$LOG_FILE"

# Execute Build
echo "--- Compiling Kernel (this may take a while) ---"
if make "${MAKE_ARGS[@]}" Image.gz dtbo.img dtb.img 2>&1 | tee -a "$LOG_FILE"; then
    echo "--- Build command finished successfully ---"
else
    echo "--- Build FAILED! Check build.log for details ---"
    exit 1
fi

# Locate output files
KERNEL_IMAGE="$KERNEL_DIR/out/arch/arm64/boot/Image.gz"
DTBO_IMAGE="$KERNEL_DIR/out/arch/arm64/boot/dtbo.img"
DTB_IMAGE="$KERNEL_DIR/out/arch/arm64/boot/dtb.img"

if [ ! -f "$KERNEL_IMAGE" ] || [ ! -f "$DTBO_IMAGE" ]; then
    echo "ERROR: Kernel image or DTBO image not found in 'out' folder!"
    echo "Check if the build actually produced these files."
    exit 1
fi

# Package
echo "--- Packaging with AnyKernel3 ---"
cd "$BASE_DIR"
if [ ! -d "AnyKernel3" ]; then
    echo "--- Cloning AnyKernel3 ---"
    git clone --depth=1 https://github.com/alternoegraha/AnyKernel3-680 -b master AnyKernel3
else
    echo "--- Restoring AnyKernel3 folders ---"
    cd AnyKernel3 && git checkout -- . && cd ..
fi

# Clear AnyKernel3 folder from old files
rm -f AnyKernel3/Image.gz AnyKernel3/dtbo.img AnyKernel3/dtb.img

cp "$KERNEL_IMAGE" "$DTBO_IMAGE" AnyKernel3/
[ -f "$DTB_IMAGE" ] && cp "$DTB_IMAGE" AnyKernel3/ || echo "Note: dtb.img not found, skipping..."

# Zip it
cd AnyKernel3
ZIP_NAME="${KERNEL_NAME}-${BUILDDATE}-${BUILDTIME}.zip"
echo "--- Creating ZIP: $ZIP_NAME ---"
zip -r9 "$ZIP_NAME" . -x ".git*" -x "README.md" -x "*.zip"
mv "$ZIP_NAME" "$OUTPUT_DIR/"

# Cleanup AnyKernel3 files
rm -f Image.gz dtbo.img dtb.img

echo "-------------------------------------------"
echo "Build finished! SUCCESS!"
echo "Result located at: $OUTPUT_DIR/$ZIP_NAME"
echo "Check build.log for compilation details."
echo "-------------------------------------------"
