#!/bin/bash

# Default parameters: SM-A346E (INS) Stock & SM-S711B (INS) Target
export STOCK_DEVICE="${1:-SM-A346E}"
export TARGET_DEVICE="${2:-SM-S711B}"
export USE_UI_8_TETHERING_APEX="${3:-False}"
export OUTPUT_FILESYSTEM="${4:-erofs}"
export STOCK_CSC="${5:-INS}"
export TARGET_CSC="${6:-INS}"

VERSION="1"

# Directories
export STOCK_FIRM_DIR="$(pwd)/FW/$STOCK_DEVICE"
export FIRM_DIR="$(pwd)/FW/$TARGET_DEVICE"
export OUT_DIR="$(pwd)/OUT"
export WORK_DIR="$(pwd)/WORK"
export APKTOOL="$(pwd)/bin/java/apktool.jar"
export DEVICES_DIR="$(pwd)/QuantumROM/Devices"
export VNDKS_COLLECTION="$(pwd)/QuantumROM/vndks"

mkdir -p "$STOCK_FIRM_DIR" "$FIRM_DIR" "$OUT_DIR" "$WORK_DIR"

# Source
source "$(pwd)/scripts/debloat.sh"
source "$(pwd)/scripts/git_utils.sh"
source "$(pwd)/scripts/QuantumRom.sh"

REPO="SN-Abdullah-Al-Noman/QuantumROM"
BRANCH="Devices"

if [ "$STOCK_DEVICE" != "None" ]; then
    if curl -fsSL -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/contents/$STOCK_DEVICE?ref=$BRANCH" >/dev/null 2>&1; then
        echo "✅ Device supported in remote repo: $STOCK_DEVICE"
        GIT_SPARSE_DOWNLOAD "SN-Abdullah-Al-Noman/QuantumROM" "Devices" "$STOCK_DEVICE" "$(pwd)/QuantumROM/Devices/$STOCK_DEVICE"
    else
        echo "ℹ️ Device '$STOCK_DEVICE' not in remote $REPO/$BRANCH; using extracted $STOCK_DEVICE firmware directly."
    fi
else
    echo "ℹ️ STOCK_DEVICE is set to None."
fi

# 1. Download & Extract Stock Firmware (SM-A346E INS)
if [ "$STOCK_DEVICE" != "None" ]; then
    if [ ! -d "$STOCK_FIRM_DIR/system/system" ]; then
        if ! ls "$STOCK_FIRM_DIR"/*.zip >/dev/null 2>&1 && ! ls "$STOCK_FIRM_DIR"/*.tar* >/dev/null 2>&1 && ! ls "$STOCK_FIRM_DIR"/*.img >/dev/null 2>&1; then
            DOWNLOAD_FIRMWARE "$STOCK_DEVICE" "$STOCK_CSC" "$STOCK_FIRM_DIR"
        fi
        EXTRACT_FIRMWARE "$STOCK_FIRM_DIR"
        EXTRACT_SUPER_IMG "$STOCK_FIRM_DIR"
        EXTRACT_FIRMWARE_IMG "$STOCK_FIRM_DIR" "all"
    fi
fi

# 2. Download & Extract Target Firmware (SM-S711B INS)
if [ ! -d "$FIRM_DIR/system/system" ]; then
    if ! ls "$FIRM_DIR"/*.zip >/dev/null 2>&1 && ! ls "$FIRM_DIR"/*.tar* >/dev/null 2>&1 && ! ls "$FIRM_DIR"/*.img >/dev/null 2>&1; then
        DOWNLOAD_FIRMWARE "$TARGET_DEVICE" "$TARGET_CSC" "$FIRM_DIR"
    fi
    EXTRACT_FIRMWARE "$FIRM_DIR"
    EXTRACT_SUPER_IMG "$FIRM_DIR"
    EXTRACT_FIRMWARE_IMG "$FIRM_DIR" "all"
fi

# 3. CSC Decode & Debloat
DECODE_CSC "$FIRM_DIR" "$WORK_DIR"
DEBLOAT "$FIRM_DIR"
DEBLOAT_SAMSUNG_BIXBY_APPS "$FIRM_DIR"
DEBLOAT_SAMSUNG_DEX_APPS "$FIRM_DIR"

# 4. Stock Config, MediaTek Port Sync (SM-A346E -> SM-S711B), SELinux & Security
APPLY_STOCK_CONFIG "$STOCK_DEVICE" "$FIRM_DIR" "$STOCK_FIRM_DIR"
PATCH_SELINUX "$FIRM_DIR"
DISABLE_SECURITY "$FIRM_DIR"
ADD_CHINA_SMART_MANAGER "$FIRM_DIR"
ADD_SAMSUNG_FLAGSHIP_APPS "$FIRM_DIR"
APPLY_CUSTOM_FEATURES "$FIRM_DIR"

# 5. Framework, Services, SSRM & SecSettings Smali Patching
INSTALL_FRAMEWORK "$APKTOOL" "$FIRM_DIR/system/system/framework/framework-res.apk"

DECOMPILE "$APKTOOL" "$FIRM_DIR/system/system/framework" "$FIRM_DIR/system/system/framework/ssrm.jar" "$WORK_DIR"
DECOMPILE "$APKTOOL" "$FIRM_DIR/system/system/framework" "$FIRM_DIR/system/system/framework/services.jar" "$WORK_DIR"
DECOMPILE "$APKTOOL" "$FIRM_DIR/system/system/framework" "$FIRM_DIR/system/system/framework/framework.jar" "$WORK_DIR"

PATCH_SSRM "$WORK_DIR/ssrm"
PATCH_FLAG_SECURE "$FIRM_DIR" "$WORK_DIR/services"
PATCH_SECURE_FOLDER "$FIRM_DIR" "$WORK_DIR/services"
PATCH_PRIVATE_SHARE "$WORK_DIR/services"
DISABLE_SIGNATURE_VERIFICATION "$WORK_DIR/services"
PATCH_KNOX_GUARD "$WORK_DIR/services"
PATCH_CUSTOM_PLATFORM_SIGNATURE "$WORK_DIR/services"
PATCH_MTK_PICTURE_QUALITY "$WORK_DIR/framework" "$WORK_DIR/services"

RECOMPILE "$APKTOOL" "$FIRM_DIR/system/system/framework" "$WORK_DIR/ssrm" "$WORK_DIR"
RECOMPILE "$APKTOOL" "$FIRM_DIR/system/system/framework" "$WORK_DIR/services" "$WORK_DIR"
RECOMPILE "$APKTOOL" "$FIRM_DIR/system/system/framework" "$WORK_DIR/framework" "$WORK_DIR"
mv -f "$WORK_DIR"/*.jar "$FIRM_DIR/system/system/framework/"

PATCH_SECSETTINGS_OUTDOOR_MODE "$APKTOOL" "$FIRM_DIR" "$WORK_DIR"

# 6. Bluetooth Library Patch
PATCH_BT_LIB "$FIRM_DIR" "$WORK_DIR"

# 7. Final Build Properties
B_ID="$(grep -m1 '^ro.system.build.id=' "$FIRM_DIR/system/system/build.prop" | cut -d= -f2 | tr -d '\r')"
B_V="$(grep -m1 '^ro.system.build.version.incremental=' "$FIRM_DIR/system/system/build.prop" | cut -d= -f2 | tr -d '\r')"
BUILD_PROP "$FIRM_DIR" "system" "ro.build.display.id" "${B_ID} ${B_V} V-${VERSION}: Built with Quantum Tools"
BUILD_PROP "$FIRM_DIR" "product" "ro.build.display.id" "${B_ID} ${B_V} V-${VERSION}: Built with Quantum Tools"

# 8. Build Output Images
BUILD_IMG "$FIRM_DIR" "all" "$OUTPUT_FILESYSTEM" "$OUT_DIR"
