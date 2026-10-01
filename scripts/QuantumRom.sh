#!/bin/bash

###################################################################################################
# PART 1: ENVIRONMENT, DOWNLOADERS, EXTRACTORS & ENCRYPTION DISABLERS
###################################################################################################

# QT DIR
QT_DIR="$(pwd)"

# Binary
export lpmake="$QT_DIR/bin/lp/lpmake"
export lpunpack="$QT_DIR/bin/lp/lpunpack"
export make_ext4fs="$QT_DIR/bin/ext4/make_ext4fs"
export samloader="$QT_DIR/bin/samloader/samloader"
export make_f2fs="$QT_DIR/bin/f2fs-tools/mkfs.f2fs"
export sload_f2fs="$QT_DIR/bin/f2fs-tools/sload.f2fs"
export omc_decoder="$QT_DIR/bin/java/omc-decoder.jar"
export mkfs_erofs="$QT_DIR/bin/erofs-utils/mkfs.erofs"
export extract_erofs="$QT_DIR/bin/erofs-utils/extract.erofs"
export imgextractor_py="$QT_DIR/bin/py_scripts/imgextractor.py"

chmod +x "$lpmake"
chmod +x "$lpunpack"
chmod +x "$samloader"
chmod +x "$make_f2fs"
chmod +x "$sload_f2fs"
chmod +x "$mkfs_erofs"
chmod +x "$make_ext4fs"
chmod +x "$extract_erofs"


WGET_DOWNLOAD() {
    local URL="$1"
    local OUT_DIR="$2"

    if [ -z "$URL" ] || [ -z "$OUT_DIR" ]; then
        echo "Usage: WGET_DOWNLOAD <URL> <OUTPUT_DIRECTORY>"
        return 1
    fi

    mkdir -p "$OUT_DIR" || {
        echo "- Failed to create output directory:"
        echo "    $OUT_DIR"
        exit 1
    }

    local FILE=$(basename "${URL%%\?*}")
    local OUT="$OUT_DIR/$FILE"

    if ! wget --spider -q "$URL"; then
        echo "- File is not downloadable:"
        echo "    $URL"
        exit 1
    fi

    echo "- Downloading: $FILE"

    wget --no-check-certificate -q -O "$OUT" "$URL" &
    local PID=$!

    local SPINNER='|/-\'
    local i=0

    while kill -0 "$PID" 2>/dev/null; do
        printf '\r- Downloading... %s' "${SPINNER:i++%4:1}"
        sleep 0.2
    done

    wait "$PID"
    local STATUS=$?

    if [ "$STATUS" -ne 0 ]; then
        echo
        echo "- Download failed"
        rm -f "$OUT"
        exit 1
    fi

    printf '\r- Download completed: %s\n' "$OUT"
}


DOWNLOAD_FIRMWARE() {
    echo " "

    if [ "$#" -lt 3 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <MODEL> <CSC> <DOWNLOAD_DIRECTORY> [VERSION]"
        return 1
    fi

    local MODEL="$1"
    local CSC="$2"
    local DOWN_DIR="$3"
    local VERSION="${4:-}"

    rm -rf "$DOWN_DIR"
    mkdir -p "$DOWN_DIR"

    if [ "${#CSC}" -ne 3 ]; then
        echo "- CSC is not 3 characters"
        echo "- Treating CSC as download URL"
        if [[ "$CSC" =~ gofile\.io/d/([^/?]+) ]]; then
            echo "GoFile link detected"
            echo "Directory: ${BASH_REMATCH[1]}"
            python3 "${QT_DIR}/GoFileDownloader/downloader.py" "$CSC"
            mv "${QT_DIR}/Downloads/${BASH_REMATCH[1]}"/* "$DOWN_DIR"/
            return 0
        else
            WGET_DOWNLOAD "$CSC" "$DOWN_DIR"
            return 0
        fi
    fi

    echo -e "======================================"
    echo -e "  Samsung FW Downloader   "
    echo -e "======================================"
    echo -e "MODEL: $MODEL | CSC: $CSC"
    echo -e "DOWNLOAD DIR: $DOWN_DIR"

    # Check version
    if [ -z "$VERSION" ]; then
        VERSION=$($samloader check-update --model "$MODEL" --region "$CSC")

        if [ $? -ne 0 ] || [ -z "$VERSION" ]; then
            echo "⛔️ MODEL/CSC not valid or no update found."
            exit 1
        fi
    fi

    if [ -n "$GITHUB_ENV" ]; then
        echo "VERSION=$VERSION" >> "$GITHUB_ENV"
    fi

    # Download Firmware
    local VERSION_FILE="${VERSION//\//_}"
    $samloader download --model "$MODEL" --region "$CSC" --version "$VERSION" --out-file "$DOWN_DIR/${VERSION_FILE}.zip"
    if [ $? -ne 0 ]; then
        echo -e "⛔️ Download failed. Check MODEL/CSC."
        exit 1
    fi

    find "$DOWN_DIR" -type f -name "*.zip.enc*" -delete

    # Show Firmware Info
    local file_size=$(du -m "${DOWN_DIR}/${VERSION_FILE}.zip" 2>/dev/null | awk '{print $1}')
    echo -e "Firmware Size: ${file_size} MB"
}


CHECK_FILE() {
    if [ ! -f "$1" ]; then
        echo -e "[!] File not found: $1"
        echo -e "- Skipping..."
        return 1
    fi
    return 0
}


REMOVE_LINE() {
    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <TARGET_LINE> <TARGET_FILE>"
        return 1
    fi

    local LINE="$1"
    local FILE="$2"

    [ -f "$FILE" ] || return 0
    echo -e "- Deleting $LINE from $FILE"
    grep -vxF "$LINE" "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE" || rm -f "$FILE.tmp"
    return 0
}


GET_PROP() {
    if [ "$#" -ne 3 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> <PARTITION> <PROP>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local PARTITION="$2"
    local PROP="$3"

    case "$PARTITION" in
        system)
            FILE="${EXTRACTED_FIRM_DIR}/system/system/build.prop"
            ;;
        vendor)
            FILE="${EXTRACTED_FIRM_DIR}/vendor/build.prop"
            ;;
        product)
            FILE="${EXTRACTED_FIRM_DIR}/product/etc/build.prop"
            ;;
        system_ext)
            FILE="${EXTRACTED_FIRM_DIR}/system_ext/etc/build.prop"
            ;;
        odm)
            FILE="${EXTRACTED_FIRM_DIR}/odm/etc/build.prop"
            ;;
        *)
            echo -e "Unknown partition: $PARTITION"
            return 0
            ;;
    esac

    if [ ! -f "$FILE" ]; then
        return 0
    fi

    local VALUE=$(grep -m1 "^${PROP}=" "$FILE" | cut -d'=' -f2- | tr -d '\r')

    if [ -z "$VALUE" ]; then
        return 0
    fi

    echo -e "$VALUE"
}

GET_FF_VALUE() {
    local KEY="$1"
    local FILE="$2"

    awk -F'[<>]' -v key="$KEY" '
        $2 == key { print $3; exit }
    ' "$FILE"
}


DETECT_FILESYSTEM() {
    local imgfile="$1"

    [ ! -f "$imgfile" ] && {
        echo "unknown"
        return 1
    }

    local fstype=$(blkid -o value -s TYPE "$imgfile" 2>/dev/null)
    [ -z "$fstype" ] && fstype=$(file -b "$imgfile" 2>/dev/null)

    case "$fstype" in
        *"Android sparse image"*)
            echo "sparse"
            ;;
        *"ext2"*)
            echo "ext2"
            ;;
        *"ext3"*)
            echo "ext3"
            ;;
        *"ext4"*)
            echo "ext4"
            ;;
        *"f2fs"*|*"F2FS"*)
            echo "f2fs"
            ;;
        *"erofs"*|*"EROFS"*)
            echo "erofs"
            ;;
        *"squashfs"*|*"Squashfs"*)
            echo "squashfs"
            ;;
        *"LZ4 compressed"*)
            echo "lz4"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}


EXTRACT_FIRMWARE() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <FIRMWARE_DIRECTORY>"
        return 1
    fi

    local FIRM_DIR="$1"

    echo -e "Extracting downloaded firmware."

    if [ ! -d "$FIRM_DIR" ]; then
        echo -e "- Directory not found: $FIRM_DIR"
        exit
    fi

    # For extension less file
    for file in "$FIRM_DIR"/*; do
        [ -f "$file" ] || continue

        case "$(basename "$file")" in
            *.*) continue ;;
        esac

        7z x -y -bd -bsp1 -o"$FIRM_DIR" "$file"
    done

    # ---- ZIP ----
    for file in "$FIRM_DIR"/*.zip; do
        [ -e "$file" ] || continue

        echo -e "Extracting zip: $(basename "$file")"
        7z x -y -bd -bsp1 -o"$FIRM_DIR" "$file"

        rm -f "$file"
    done

    # remove unwanted archives before extraction
    rm -f "$FIRM_DIR"/BL_*.tar.md5
    rm -f "$FIRM_DIR"/CP_*.tar.md5
    rm -f "$FIRM_DIR"/HOME_CSC_*.tar.md5
    rm -f "$FIRM_DIR"/USERDATA_*.tar.md5

    # ---- XZ ----
    for file in "$FIRM_DIR"/*.xz; do
        [ -e "$file" ] || continue

        echo -e "Extracting xz: $(basename "$file")"
        7z x -y -bd -bsp1 -o"$FIRM_DIR" "$file"

        rm -f "$file"
    done

    # ---- RENAME .MD5 -> .TAR ----
    for file in "$FIRM_DIR"/*.md5; do
        [ -e "$file" ] || continue

        mv -- "$file" "${file%.md5}"
    done

    # ---- TAR ----
    for file in "$FIRM_DIR"/*.tar; do
        [ -e "$file" ] || continue

        echo -e "Extracting tar: $(basename "$file")"

        tar -xf "$file" -C "$FIRM_DIR"

        # remove only samsung firmware tar archives
        case "$(basename "$file")" in
            AP_*|BL_*|CP_*|CSC_*|HOME_CSC_*)
                rm -f "$file"
                ;;
        esac
    done

    # ---- REMOVE UNWANTED LZ4 FILES ----
    rm -rf \
        "$FIRM_DIR/meta-data" \
        "$FIRM_DIR"/*.txt \
        "$FIRM_DIR"/*.pit \
        "$FIRM_DIR"/*.bin \
        "$FIRM_DIR"/cache.img.lz4 \
        "$FIRM_DIR"/dtbo.img.lz4 \
        "$FIRM_DIR"/efuse.img.lz4 \
        "$FIRM_DIR"/gz-verified.img.lz4 \
        "$FIRM_DIR"/lk-verified.img.lz4 \
        "$FIRM_DIR"/md1img.img.lz4 \
        "$FIRM_DIR"/md_udc.img.lz4 \
        "$FIRM_DIR"/misc.bin.lz4 \
        "$FIRM_DIR"/omr.img.lz4 \
        "$FIRM_DIR"/param.bin.lz4 \
        "$FIRM_DIR"/preloader.img.lz4 \
        "$FIRM_DIR"/recovery.img.lz4 \
        "$FIRM_DIR"/scp-verified.img.lz4 \
        "$FIRM_DIR"/spmfw-verified.img.lz4 \
        "$FIRM_DIR"/sspm-verified.img.lz4 \
        "$FIRM_DIR"/tee-verified.img.lz4 \
        "$FIRM_DIR"/tzar.img.lz4 \
        "$FIRM_DIR"/up_param.bin.lz4 \
        "$FIRM_DIR"/userdata.img.lz4 \
        "$FIRM_DIR"/vbmeta.img.lz4 \
        "$FIRM_DIR"/vbmeta_system.img.lz4 \
        "$FIRM_DIR"/audio_dsp-verified.img.lz4 \
        "$FIRM_DIR"/cam_vpu1-verified.img.lz4 \
        "$FIRM_DIR"/cam_vpu2-verified.img.lz4 \
        "$FIRM_DIR"/cam_vpu3-verified.img.lz4 \
        "$FIRM_DIR"/dpm-verified.img.lz4 \
        "$FIRM_DIR"/init_boot.img.lz4 \
        "$FIRM_DIR"/mcupm-verified.img.lz4 \
        "$FIRM_DIR"/pi_img-verified.img.lz4 \
        "$FIRM_DIR"/uh.bin.lz4 \
        "$FIRM_DIR"/vendor_boot.img.lz4 \
        "$FIRM_DIR"/ssu.img.lz4

    # ---- LZ4 ----
    for file in "$FIRM_DIR"/*.lz4; do
        [ -e "$file" ] || continue

        echo -e "Extracting lz4: $(basename "$file")"

        lz4 -d "$file" "${file%.lz4}"

        rm -f "$file"
    done

    echo -e "Firmware Extraction complete."
}


EXTRACT_SUPER_IMG() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <FIRMWARE_DIRECTORY>"
        return 1
    fi

    local FIRM_DIR="$1"

    if [ -f "$FIRM_DIR/super.img" ]; then
        echo -e "Extracting super.img"
        if [ "$(DETECT_FILESYSTEM "$FIRM_DIR/super.img")" = "sparse" ]; then
            echo -e "Converting to raw super.img"
            simg2img "$FIRM_DIR/super.img" "$FIRM_DIR/super_raw.img"
            rm -f "$FIRM_DIR/super.img"
            mv -f "$FIRM_DIR/super_raw.img" "$FIRM_DIR/super.img"
        fi

        echo "- Extracting partitions from super.img"
        "$lpunpack" "$FIRM_DIR/super.img" "$FIRM_DIR" || return 1
        rm -f "$FIRM_DIR/super.img"

        echo -e "- super.img extraction complete"

    else
        echo -e "No super.img found."
    fi
}


PREPARE_PARTITIONS() {
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo -e "Preparing partitions."
    
    if [ ! -d "$EXTRACTED_FIRM_DIR" ]; then
        echo -e "- Directory not found: $EXTRACTED_FIRM_DIR"
        return 1
    fi

    # Delete empty b slot images
    rm -rf "$EXTRACTED_FIRM_DIR"/*_b.img

    for img in "$EXTRACTED_FIRM_DIR"/*_a.img; do
        [ -f "$img" ] || continue

        new="${img%_a.img}.img"
        mv -f "$img" "$new"
    done
}


EXTRACT_FIRMWARE_IMG() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> all|img_name"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local MODE="$2"

    if ! ls "$EXTRACTED_FIRM_DIR"/*.img >/dev/null 2>&1; then
        echo -e "No .img files found in: $EXTRACTED_FIRM_DIR"
        return 0
    fi

    echo -e "Extracting images from: $EXTRACTED_FIRM_DIR"

    extract_img() {
        local imgfile="$1"

        [ -e "$imgfile" ] || return

        local img_name="$(basename "$imgfile")"

        if [[ "$img_name" == "boot.img" || "$img_name" == "recovery.img" ]]; then
            echo -e "- Skipping $img_name"
            return
        fi

        local partition="$(basename "${imgfile%.img}")"
        local ORG_IMG_SIZE=$(stat -c%s -- "$imgfile")

        local fstype=$(DETECT_FILESYSTEM "$imgfile")
        if [ "$fstype" = "sparse" ]; then
            echo -e "$partition.img is SPARSE. Converting to raw img."

            local tmp_raw="${imgfile}.raw"

            if ! simg2img "$imgfile" "$tmp_raw" >/dev/null 2>&1; then
                echo -e "Failed to convert sparse image: $img_name"
                return
            fi

            if [ ! -f "$tmp_raw" ]; then
                echo -e "- Sparse conversion output missing: $tmp_raw"
                return
            fi

            rm -f "$imgfile"
            mv "$tmp_raw" "$imgfile"
        fi

        local fstype=$(DETECT_FILESYSTEM "$imgfile")

        case "$fstype" in
            ext4)
                echo " "
                echo -e "$partition.img Detected ext4. Size: $ORG_IMG_SIZE bytes. Extracting..."
                rm -rf "${EXTRACTED_FIRM_DIR}/$partition"
                python3 "$imgextractor_py" "$imgfile" "$EXTRACTED_FIRM_DIR"
                ;;

            erofs)
                echo " "
                echo -e "$partition.img Detected erofs. Size: $ORG_IMG_SIZE bytes. Extracting..."
                rm -rf "${EXTRACTED_FIRM_DIR}/$partition"
                "$extract_erofs" -i "$imgfile" -x -f -o "$EXTRACTED_FIRM_DIR" >/dev/null 2>&1
                ;;

            f2fs)
                echo " "
                echo -e "$partition.img Detected f2fs. Size: $ORG_IMG_SIZE bytes. Extracting..."
                bash "$QT_DIR/scripts/extract_img.sh" "$imgfile" "$EXTRACTED_FIRM_DIR"
                ;;

            *)
                echo -e "- $img_name unsupported filesystem type: ($fstype), skipping"
                ;;
        esac
    }

    if [ "$MODE" = "all" ]; then
        PREPARE_PARTITIONS "$EXTRACTED_FIRM_DIR"
        for imgfile in "$EXTRACTED_FIRM_DIR"/*.img; do
            [ -e "$imgfile" ] || continue
            extract_img "$imgfile"
        done
    else
        local TARGET_IMG="${EXTRACTED_FIRM_DIR}/$MODE"

        if [ ! -f "$TARGET_IMG" ]; then
            echo -e "- Image not found: $TARGET_IMG"
            return 0
        fi

        extract_img "$TARGET_IMG"
    fi
}


DISABLE_FBE() {
    local EXTRACTED_FIRM_DIR="$1"

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIRECTORY>"
        return 1
    fi

    if [ ! -d "${EXTRACTED_FIRM_DIR}/vendor/etc" ]; then
        return 0
    fi

    local fstab_files=$(grep -lr 'fileencryption' "${EXTRACTED_FIRM_DIR}/vendor/etc" 2>/dev/null)

    for i in $fstab_files; do
        if [ -f "$i" ]; then
            echo -e "- Disabling file-based encryption (FBE) for /data."
            echo -e "- Found $i."
            sed -i -e 's/^\([^#].*\)fileencryption=[^,]*\(.*\)$/# &\n\1encryptable\2/g' "$i"
        fi
    done
}


DISABLE_FDE() {
    local EXTRACTED_FIRM_DIR="$1"

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIRECTORY>"
        return 1
    fi

    if [ ! -d "${EXTRACTED_FIRM_DIR}/vendor/etc" ]; then
        return 0
    fi

    local fstab_files=$(grep -lr 'forceencrypt' "${EXTRACTED_FIRM_DIR}/vendor/etc" 2>/dev/null)

    for i in $fstab_files; do
        if [ -f "$i" ]; then
            echo -e "- Disabling full-disk encryption (FDE) for /data..."
            echo -e "- Found $i."
            sed -i -e 's/^\([^#].*\)forceencrypt=[^,]*\(.*\)$/# &\n\1encryptable\2/g' "$i"
        fi
    done
}


###################################################################################################
# PART 2: APKTOOL, SMALI PATCHING, MTK PICTURE QUALITY, CUSTOM SIGNATURES & BLUETOOTH
###################################################################################################

INSTALL_FRAMEWORK() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <APKTOOL_JAR_DIR> <framework-res.apk>"
        return 1
    fi

    local APKTOOL="$1"
    local framework_apk="$2"
    local FRAME_CACHE_DIR="${WORK_DIR:-$QT_DIR/WORK}/framework_cache"

    echo -e "Installing: $framework_apk"

    if [ ! -f "$framework_apk" ]; then
        echo -e "- File not found: $framework_apk"
        return 0
    fi

    mkdir -p "$FRAME_CACHE_DIR"
    java -jar "$APKTOOL" install-framework --frame-path "$FRAME_CACHE_DIR" "$framework_apk"
}


DECOMPILE() {
    echo " "

    if [ "$#" -lt 4 ]; then
        echo -e "Usage: DECOMPILE <APKTOOL_JAR_DIR> <FRAMEWORK_DIR> <FILE> <DECOMPILE_DIR> [EXTRA_ARGS]"
        return 1
    fi

    local APKTOOL="$1"
    local FRAMEWORK_DIR="$2"
    local FILE="$3"
    local DECOMPILE_DIR="$4"
    local EXTRA_ARGS="${5:-}"
    local BASENAME="$(basename "${FILE%.*}")"
    local OUT="$DECOMPILE_DIR/$BASENAME"
    local FRAME_CACHE_DIR="${WORK_DIR:-$QT_DIR/WORK}/framework_cache"

    echo -e "Decompiling: $FILE in: $DECOMPILE_DIR"

    if [ ! -f "$FILE" ]; then
        echo -e "- File not found: $FILE"
        return 1
    fi

    mkdir -p "$FRAME_CACHE_DIR"
    rm -rf "$OUT"
    java -jar "$APKTOOL" d --force --frame-path "$FRAME_CACHE_DIR" --match-original $EXTRA_ARGS "$FILE" -o "$OUT"
}


RECOMPILE() {
    echo " "

    if [ "$#" -ne 4 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <APKTOOL_JAR_DIR> <FRAMEWORK_DIR> <DECOMPILED_DIR> <RECOMPILE_DIR>"
        return 1
    fi

    local APKTOOL="$1"
    local FRAMEWORK_DIR="$2"
    local DECOMPILED_DIR="$3"
    local RECOMPILE_DIR="$4"
    local FRAME_CACHE_DIR="${WORK_DIR:-$QT_DIR/WORK}/framework_cache"
    
    echo -e "Recompiling: $DECOMPILED_DIR"

    if [ ! -d "$DECOMPILED_DIR" ]; then
        echo "- Directory not found: $DECOMPILED_DIR"
        return 0
    fi

    local org_file_name=$(awk '/^apkFileName:/ {print $2}' "$DECOMPILED_DIR/apktool.yml")
    local name="${org_file_name%.*}"
    local ext="${org_file_name##*.}"
    local built_file="$RECOMPILE_DIR/${name}.$ext"

    java -jar "$APKTOOL" b "$DECOMPILED_DIR" --copy-original --frame-path "$FRAME_CACHE_DIR" -o "$built_file"
    rm -rf "$DECOMPILED_DIR"
    rm -f "$FRAMEWORK_DIR/1.apk"
}


REPLACE_SMALI_METHOD() {
    local FILE="$1"
    local METHOD_NAME="$2"
    local NEW_BODY=$(echo -e "$3" | tail -n +2)

    echo -e "Patching: $FILE"
    echo -e "- Method: $METHOD_NAME"

    if [ ! -f "$FILE" ]; then
        echo -e "- Warning: File not found: $FILE"
        return 0
    fi

    # Extract method signature (e.g. isAvailable()Z) so it matches with or without 'final'/'blacklist'
    local METHOD_SIG=$(echo "$METHOD_NAME" | awk '{print $NF}')
    local ESCAPED_SIG=$(printf '%s' "$METHOD_SIG" | sed 's/[][()\.^$*+?]/\\&/g')

    if ! grep -Eq "^[[:space:]]*\.method.* ${ESCAPED_SIG}" "$FILE"; then
        echo -e "- Warning- Method: $METHOD_SIG not found in: $FILE"
        return 0
    fi

    sed -i "
/^[[:space:]]*\.method.* ${ESCAPED_SIG}/,/^[[:space:]]*\.end method/{
    /^[[:space:]]*\.method/{
        p
        r /dev/stdin
        d
    }
    /^[[:space:]]*\.end method/p
    d
}" "$FILE" <<< "$NEW_BODY"
}


HEX_PATCH() {
    echo " "

    if [ "$#" -ne 3 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <FILE> <TARGET_VALUE> <REPLACE_VALUE>"
        return 1
    fi

    local FILE="$1"
    local FROM="$(echo -e "$2" | tr '[:upper:]' '[:lower:]')"
    local TO="$(echo -e "$3" | tr '[:upper:]' '[:lower:]')"

    [ ! -f "$FILE" ] && { echo -e "- File not found: $FILE"; return 0; }

    xxd -p -c 0 "$FILE" | grep -q "$FROM" || {
        echo -e "- Pattern not found: $FROM"
        return 0
    }

    echo -e "- Patching: $FILE"
    echo -e "- From $FROM to $TO"
    [ -f "$FILE.bak" ] || cp "$FILE" "$FILE.bak"

    xxd -p -c 0 "$FILE" | sed "s/$FROM/$TO/" | xxd -r -p > "$FILE.tmp" &&
    mv "$FILE.tmp" "$FILE"

    xxd -p -c 0 "$FILE" | grep -q "$TO" && {
        echo -e "- Patch success"
        rm -rf "$FILE.bak"        
        return 0
    }

    echo -e "- Patch failed, restoring backup"
    mv "$FILE.bak" "$FILE"
    return 0
}


PATCH_FLAG_SECURE() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRMWARE_DIRECTORY> <EXTRACTED_SERVICES_DIRECTORY>"
        return 1
    fi

    local FILE_1 FILE_2 FILE_3

    local REPLACE_BODY_1='
    .locals 1

    const/4 v0, 0x0

    return v0
    '

    local REPLACE_BODY_2='
    .locals 1

    invoke-static {}, Ljava/util/Collections;->emptyList()Ljava/util/List;
    move-result-object v0
    return-object v0
    '

    echo -e "Patching flag secure."

    local EXTRACTED_FIRM_DIR="$1"
    local WORK_DIR="$2"

    if [ ! -d "$WORK_DIR" ]; then
        echo "- Directory not found: $WORK_DIR"
        return 1
    fi

    local ANDROID_VERSION=$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.system.build.version.release")
    echo "Android version: $ANDROID_VERSION"

    FILE_1=$(find "$WORK_DIR" -type f -name "WindowState.smali" | head -n 1)
    FILE_2=$(find "$WORK_DIR" -type f -name "WindowManagerService.smali" | head -n 1)
    FILE_3=$(find "$WORK_DIR" -type f -name "DevicePolicyManagerService.smali" | head -n 1)

    [ -n "$FILE_1" ] && REPLACE_SMALI_METHOD "$FILE_1" "isSecureLocked()Z" "$REPLACE_BODY_1"
    [ -n "$FILE_2" ] && REPLACE_SMALI_METHOD "$FILE_2" "notifyScreenshotListeners(I)Ljava/util/List;" "$REPLACE_BODY_2"
    [ -n "$FILE_3" ] && REPLACE_SMALI_METHOD "$FILE_3" "getScreenCaptureDisabled(Landroid/content/ComponentName;IZ)Z" "$REPLACE_BODY_1"
    return 0
}


PATCH_SECURE_FOLDER() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRMWARE_DIRECTORY> <EXTRACTED_SERVICES_DIRECTORY>"
        return 1
    fi

    local REPLACE_BODY_1='
    .locals 1
 
    const/4 v0, 0x0
 
    return v0
    '

    echo -e "Patching secure folder."

    local EXTRACTED_FIRM_DIR="$1"
    local WORK_DIR="$2"
    local FILE_1=$(find "$WORK_DIR" -type f -name "DarManagerService.smali" | head -n 1)

    if [ -n "$FILE_1" ]; then
        REPLACE_SMALI_METHOD "$FILE_1" "isDeviceRootKeyInstalled()Z" "$REPLACE_BODY_1"
        REPLACE_SMALI_METHOD "$FILE_1" "isKnoxKeyInstallable()Z" "$REPLACE_BODY_1"
    fi
    return 0
}


PATCH_PRIVATE_SHARE() {
    echo " "

    if [ "$#" -lt 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_SERVICES_OR_WORK_DIRECTORY>"
        return 1
    fi

    echo -e "Patching private share."
    local SEARCH_DIR="$(dirname "$1")"
    local FILE=$(find "$SEARCH_DIR" -type f -name "AttestParameterSpec.smali" | head -n 1)

    if [ -n "$FILE" ]; then
        local REPLACE_BODY='
    .locals 1
 
    const/4 v0, 0x1
 
    return v0
    '
        REPLACE_SMALI_METHOD "$FILE" "isVerifiableIntegrity()Z" "$REPLACE_BODY"
    fi
    return 0
}


DISABLE_SIGNATURE_VERIFICATION() {
    echo " "

    if [ "$#" -lt 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_SERVICES_OR_WORK_DIRECTORY>"
        return 1
    fi

    echo -e "Disabling signature verification."
    local SEARCH_DIR="$(dirname "$1")"
    local FILE=$(find "$SEARCH_DIR" -type f -name "ApkSignatureVerifier.smali" | head -n 1)

    if [ -n "$FILE" ]; then
        local REPLACE_BODY='
    .locals 1

    const/4 v0, 0x1
 
    return v0
    '
        REPLACE_SMALI_METHOD "$FILE" "getMinimumSignatureSchemeVersionForTargetSdk(I)I" "$REPLACE_BODY"
    fi
    return 0
}


PATCH_KNOX_GUARD() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_SERVICES_DIRECTORY>"
        return 1
    fi

    echo -e "Patching knox guard."
    local FILE=$(find "$1" -type f -name "KnoxGuardSeService.smali" | head -n 1)
    local METHOD_NAME_1=".method public constructor <init>(Landroid/content/Context;)V"
    local REPLACE_BODY_1='
    .locals 0
 
    invoke-direct {p0}, Lcom/samsung/android/knoxguard/IKnoxGuardManager$Stub;-><init>()V
 
    const/4 p1, 0x0
 
    iput-object p1, p0, Lcom/samsung/android/knoxguard/service/KnoxGuardSeService;->mConnectivityManagerService:Landroid/net/ConnectivityManager;
 
    new-instance p0, Ljava/lang/UnsupportedOperationException;
 
    const-string p1, "KnoxGuard is disabled"
 
    invoke-direct {p0, p1}, Ljava/lang/UnsupportedOperationException;-><init>(Ljava/lang/String;)V

    throw p0
    '
    [ -n "$FILE" ] && REPLACE_SMALI_METHOD "$FILE" "$METHOD_NAME_1" "$REPLACE_BODY_1"
    rm -rf "$FIRM_DIR/system/system/priv-app/KnoxGuard"
    return 0
}


PATCH_MTK_PICTURE_QUALITY() {
    echo " "
    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <DECOMPILED_FRAMEWORK_DIR> <DECOMPILED_SERVICES_DIR>"
        return 1
    fi

    local FW_WORK_DIR="$1"
    local SERVICES_WORK_DIR="$2"

    echo -e "Applying MediaTek PictureQuality patches to framework.jar and services.jar..."

    # 1. Patch framework.jar (SemDisplayQualityFeature.smali)
    local DQ_FEAT_SMALI=$(find "$FW_WORK_DIR" -type f -name "SemDisplayQualityFeature.smali" | head -n 1)

    if [ -n "$DQ_FEAT_SMALI" ] && [ -f "$DQ_FEAT_SMALI" ]; then
        echo "- Updating $DQ_FEAT_SMALI to MTK platform..."
        cat << 'EOF' > "$DQ_FEAT_SMALI"
.class public Lcom/samsung/android/displayquality/SemDisplayQualityFeature;
.super Ljava/lang/Object;
.source "SemDisplayQualityFeature.java"

# static fields
.field public static final blacklist ADAPTIVE_SYNC_SUPPORT:Z
.field public static final blacklist DP_BACKOFF_SUPPORT:Z
.field public static final blacklist DP_DEBUG_SUPPORT:Z
.field public static final blacklist DP_RATIO_SUPPORT:Z
.field private static final blacklist DQ_SVC_FEATURE:Ljava/lang/String; = "MTK"
.field public static final blacklist ENABLED:Z = true
.field public static final blacklist HAL_SUPPORT:Z = false
.field private static final blacklist HAS_OPTION:Z
.field public static final blacklist LTM_SUPPORT:Z
.field public static final blacklist OUTDOOR_VISIBILITY_SUPPORT:Z
.field public static final blacklist PLATFORM:Ljava/lang/String;
.field public static final blacklist SVI_SUPPORT:Z
.field public static final blacklist VIVID_PLUS_SUPPORT:Z

# direct methods
.method static constructor blacklist <clinit>()V
    .locals 4

    const-string v0, "MTK"
    sput-object v0, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->PLATFORM:Ljava/lang/String;

    const-string v1, ","
    invoke-virtual {v0, v1}, Ljava/lang/String;->split(Ljava/lang/String;)[Ljava/lang/String;
    move-result-object v1

    const/4 v2, 0x1
    const/4 v3, 0x0
    array-length v1, v1
    if-le v1, v2, :cond_0
    move v1, v2
    goto :goto_0
    :cond_0
    move v1, v3
    :goto_0
    sput-boolean v1, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->HAS_OPTION:Z

    invoke-virtual {v0, v0}, Ljava/lang/String;->contains(Ljava/lang/CharSequence;)Z
    move-result v0
    if-nez v0, :cond_1
    if-nez v1, :cond_1
    goto :goto_1
    :cond_1
    move v2, v3
    :goto_1
    sput-boolean v2, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->OUTDOOR_VISIBILITY_SUPPORT:Z
    sput-boolean v3, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->ADAPTIVE_SYNC_SUPPORT:Z
    sput-boolean v3, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->LTM_SUPPORT:Z
    sput-boolean v3, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->SVI_SUPPORT:Z
    sput-boolean v3, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->VIVID_PLUS_SUPPORT:Z
    sput-boolean v3, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->DP_RATIO_SUPPORT:Z
    sput-boolean v3, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->DP_DEBUG_SUPPORT:Z
    sput-boolean v3, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->DP_BACKOFF_SUPPORT:Z
    return-void
.end method

.method public constructor blacklist <init>()V
    .locals 0
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    return-void
.end method
EOF
    fi

    # 2. Patch services.jar (PictureQualityHelper.smali & SemDisplayQuality.smali)
    local SEM_DQ_SMALI=$(find "$SERVICES_WORK_DIR" -type f -name "SemDisplayQuality.smali" | head -n 1)

    if [ -n "$SEM_DQ_SMALI" ] && [ -f "$SEM_DQ_SMALI" ]; then
        local DQ_DIR="$(dirname "$SEM_DQ_SMALI")"
        echo "- Injecting PictureQualityHelper.smali and updating SemDisplayQuality.smali in $DQ_DIR..."
        cat << 'EOF' > "$DQ_DIR/PictureQualityHelper.smali"
.class public Lcom/samsung/android/displayquality/PictureQualityHelper;
.super Ljava/lang/Object;
.source "PictureQualityHelper.java"

# static fields
.field private static final TAG:Ljava/lang/String; = "SemDisplayQualityMtk"

# instance fields
.field private DEBUG:Z
.field private final PQ_CLASS:Ljava/lang/String;
.field private mPQClass:Ljava/lang/Class;
.field private mPQGetAALMethod:Ljava/lang/reflect/Method;
.field private mPQSetAALMethod:Ljava/lang/reflect/Method;
.field private mPQSetPicutreMode:Ljava/lang/reflect/Method;

# direct methods
.method public constructor <init>()V
    .locals 7
    const-string/jumbo v0, "com.mediatek.pq.PictureQuality"
    const-string/jumbo v1, "SemDisplayQualityMtk"
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    sget-object v2, Landroid/os/Build;->TYPE:Ljava/lang/String;
    const-string/jumbo v3, "eng"
    invoke-virtual {v3, v2}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
    move-result v3
    const/4 v4, 0x1
    const/4 v5, 0x0
    if-nez v3, :cond_1
    const-string/jumbo v3, "userdebug"
    invoke-virtual {v3, v2}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
    move-result v2
    if-eqz v2, :cond_0
    goto :goto_0
    :cond_0
    move v2, v5
    goto :goto_1
    :cond_1
    :goto_0
    move v2, v4
    :goto_1
    iput-boolean v2, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->DEBUG:Z
    iput-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->PQ_CLASS:Ljava/lang/String;
    const/4 v2, 0x0
    iput-object v2, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQClass:Ljava/lang/Class;
    iput-object v2, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQGetAALMethod:Ljava/lang/reflect/Method;
    iput-object v2, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQSetAALMethod:Ljava/lang/reflect/Method;
    iput-object v2, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQSetPicutreMode:Ljava/lang/reflect/Method;
    :try_start_0
    invoke-static {v0}, Ljava/lang/Class;->forName(Ljava/lang/String;)Ljava/lang/Class;
    move-result-object v0
    iput-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQClass:Ljava/lang/Class;
    const-string/jumbo v3, "getAALFunction"
    new-array v6, v5, [Ljava/lang/Class;
    invoke-virtual {v0, v3, v2}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;
    move-result-object v0
    iput-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQGetAALMethod:Ljava/lang/reflect/Method;
    iget-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQClass:Ljava/lang/Class;
    const-string/jumbo v2, "setAALFunctionProperty"
    new-array v3, v4, [Ljava/lang/Class;
    sget-object v6, Ljava/lang/Integer;->TYPE:Ljava/lang/Class;
    aput-object v6, v3, v5
    invoke-virtual {v0, v2, v3}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;
    move-result-object v0
    iput-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQSetAALMethod:Ljava/lang/reflect/Method;
    iget-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQClass:Ljava/lang/Class;
    const-string/jumbo v2, "setPictureMode"
    new-array v3, v4, [Ljava/lang/Class;
    aput-object v6, v3, v5
    invoke-virtual {v0, v2, v3}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;
    move-result-object v0
    iput-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQSetPicutreMode:Ljava/lang/reflect/Method;
    :try_end_0
    .catch Ljava/lang/ClassNotFoundException; {:try_start_0 .. :try_end_0} :catch_1
    .catch Ljava/lang/NoSuchMethodException; {:try_start_0 .. :try_end_0} :catch_0
    return-void
    :catch_0
    const-string/jumbo p0, "PQ Method not found"
    invoke-static {v1, p0}, Landroid/util/Slog;->d(Ljava/lang/String;Ljava/lang/String;)I
    goto :goto_2
    :catch_1
    const-string/jumbo p0, "PQ Class not found"
    invoke-static {v1, p0}, Landroid/util/Slog;->d(Ljava/lang/String;Ljava/lang/String;)I
    :goto_2
    return-void
.end method

# virtual methods
.method public getPQtAALFunction()I
    .locals 3
    iget-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQGetAALMethod:Ljava/lang/reflect/Method;
    const/4 v1, 0x0
    const-string/jumbo v2, "SemDisplayQualityMtk"
    if-nez v0, :cond_0
    const-string/jumbo p0, "mPQGetAALMethod not ready"
    invoke-static {v2, p0}, Landroid/util/Slog;->d(Ljava/lang/String;Ljava/lang/String;)I
    return v1
    :cond_0
    :try_start_0
    iget-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQGetAALMethod:Ljava/lang/reflect/Method;
    iget-object p0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQClass:Ljava/lang/Class;
    const/4 v2, 0x0
    invoke-virtual {v0, p0, v2}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;
    move-result-object p0
    check-cast p0, Ljava/lang/Integer;
    invoke-virtual {p0}, Ljava/lang/Integer;->intValue()I
    move-result p0
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0
    return p0
    :catch_0
    move-exception p0
    invoke-virtual {p0}, Ljava/lang/Exception;->printStackTrace()V
    return v1
.end method

.method public setPQAALFunctionProperty(I)V
    .locals 2
    iget-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQSetAALMethod:Ljava/lang/reflect/Method;
    const-string/jumbo v1, "SemDisplayQualityMtk"
    if-nez v0, :cond_0
    return-void
    :cond_0
    :try_start_0
    iget-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQSetAALMethod:Ljava/lang/reflect/Method;
    iget-object p0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQClass:Ljava/lang/Class;
    invoke-static {p1}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;
    move-result-object p1
    filled-new-array {p1}, [Ljava/lang/Object;
    move-result-object p1
    invoke-virtual {v0, p0, p1}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0
    return-void
    :catch_0
    move-exception p0
    invoke-virtual {p0}, Ljava/lang/Exception;->printStackTrace()V
    return-void
.end method

.method public setPQSetPictureMode(I)V
    .locals 2
    iget-object v0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQSetPicutreMode:Ljava/lang/reflect/Method;
    if-nez v0, :cond_0
    return-void
    :cond_0
    :try_start_0
    iget-object p0, p0, Lcom/samsung/android/displayquality/PictureQualityHelper;->mPQClass:Ljava/lang/Class;
    invoke-static {p1}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;
    move-result-object p1
    filled-new-array {p1}, [Ljava/lang/Object;
    move-result-object p1
    invoke-virtual {v0, p0, p1}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0
    return-void
    :catch_0
    move-exception p0
    invoke-virtual {p0}, Ljava/lang/Exception;->printStackTrace()V
    return-void
.end method
EOF

        cat << 'EOF' > "$SEM_DQ_SMALI"
.class public Lcom/samsung/android/displayquality/SemDisplayQuality;
.super Lcom/samsung/android/displayquality/SemDisplayQualityAP;
.source "SemDisplayQuality.java"

# static fields
.field private static final AAL_DRE_ON:I = 0x4
.field private static final AAL_ESS_DRE_ON:I = 0x6
.field private static final AAL_ESS_ON:I = 0x2
.field private static final AAL_OFF:I = 0x0
.field private static final PICTURE_MODE_NATURAL:I = 0x0
.field private static final PICTURE_MODE_VIVID:I = 0x1
.field private static final PROP_AAL_SUPPORT:Ljava/lang/String; = "ro.vendor.mtk_aal_support"
.field private static final PROP_PQ_SUPPORT:Ljava/lang/String; = "ro.vendor.mtk_pq_support"
.field private static final SUPPORTED:Ljava/lang/String; = "1"
.field private static final TAG:Ljava/lang/String; = "SemDisplayQualityMtk"
.field private static final mSupportDPDebug:Z
.field private static final mSupportDpBackOff:Z
.field private static final mSupportDpRatio:Z
.field private static final mSupportOutdoor:Z
.field private static final mSupportVividPlus:Z

# instance fields
.field private dpHelper:Lcom/samsung/android/displayport/DisplayportHelper;
.field private mCurAALMode:I
.field private mPQHelper:Lcom/samsung/android/displayquality/PictureQualityHelper;

# direct methods
.method static constructor <clinit>()V
    .locals 1
    sget-boolean v0, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->OUTDOOR_VISIBILITY_SUPPORT:Z
    sput-boolean v0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mSupportOutdoor:Z
    sget-boolean v0, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->VIVID_PLUS_SUPPORT:Z
    sput-boolean v0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mSupportVividPlus:Z
    sget-boolean v0, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->DP_BACKOFF_SUPPORT:Z
    sput-boolean v0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mSupportDpBackOff:Z
    sget-boolean v0, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->DP_RATIO_SUPPORT:Z
    sput-boolean v0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mSupportDpRatio:Z
    sget-boolean v0, Lcom/samsung/android/displayquality/SemDisplayQualityFeature;->DP_DEBUG_SUPPORT:Z
    sput-boolean v0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mSupportDPDebug:Z
    return-void
.end method

.method public constructor <init>(Landroid/content/Context;)V
    .locals 6
    invoke-direct {p0, p1}, Lcom/samsung/android/displayquality/SemDisplayQualityAP;-><init>(Landroid/content/Context;)V
    const/4 v0, 0x0
    iput-object v0, p0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mPQHelper:Lcom/samsung/android/displayquality/PictureQualityHelper;
    iput-object v0, p0, Lcom/samsung/android/displayquality/SemDisplayQuality;->dpHelper:Lcom/samsung/android/displayport/DisplayportHelper;
    sget-boolean v1, Lcom/samsung/android/displayquality/SemDisplayQuality;->mSupportOutdoor:Z
    sget-boolean v2, Lcom/samsung/android/displayquality/SemDisplayQuality;->mSupportVividPlus:Z
    const-string/jumbo v3, "SemDisplayQualityMtk"
    if-nez v1, :cond_4
    const-string/jumbo p0, "OUTDOOR_VISIBILITY not support"
    invoke-static {v3, p0}, Landroid/util/Slog;->i(Ljava/lang/String;Ljava/lang/String;)I
    return-void
    :cond_4
    invoke-direct {p0}, Lcom/samsung/android/displayquality/SemDisplayQuality;->isDRESupport()Z
    move-result p1
    if-nez p1, :cond_5
    const-string p0, "AAL DRE not support"
    invoke-static {v3, p0}, Landroid/util/Slog;->i(Ljava/lang/String;Ljava/lang/String;)I
    return-void
    :cond_5
    new-instance p1, Lcom/samsung/android/displayquality/PictureQualityHelper;
    invoke-direct {p1}, Lcom/samsung/android/displayquality/PictureQualityHelper;-><init>()V
    iput-object p1, p0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mPQHelper:Lcom/samsung/android/displayquality/PictureQualityHelper;
    invoke-virtual {p1}, Lcom/samsung/android/displayquality/PictureQualityHelper;->getPQtAALFunction()I
    move-result p1
    iput p1, p0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mCurAALMode:I
    if-eqz v1, :cond_6
    invoke-direct {p0}, Lcom/samsung/android/displayquality/SemDisplayQuality;->checkBrightnessModeAndRunDRE()V
    const/4 p1, 0x1
    iput-boolean p1, p0, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->mUseScreenStatusAsyncHandle:Z
    invoke-virtual {p0}, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->startScreenStatusReceiver()V
    sget-object p1, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->SCREEN_BRIGHTNESS_MODE_URI:Landroid/net/Uri;
    invoke-virtual {p0, p1}, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->startSettingObserver(Landroid/net/Uri;)V
    :cond_6
    if-eqz v2, :cond_7
    invoke-direct {p0}, Lcom/samsung/android/displayquality/SemDisplayQuality;->checkScreenModeAndSetPictureMode()V
    sget-object p1, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->SCREEN_MODE_SETTING_URI:Landroid/net/Uri;
    invoke-virtual {p0, p1}, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->startSettingObserver(Landroid/net/Uri;)V
    :cond_7
    return-void
.end method

.method private checkBrightnessModeAndRunDRE()V
    .locals 2
    iget-object v0, p0, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->mBrightnessModeLock:Ljava/lang/Object;
    monitor-enter v0
    :try_start_0
    iget-object v1, p0, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->mContentResolver:Landroid/content/ContentResolver;
    invoke-virtual {p0, v1}, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->isBrightnessModeAuto(Landroid/content/ContentResolver;)Z
    move-result v1
    iput-boolean v1, p0, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->mIsBrightnessModeAuto:Z
    if-eqz v1, :cond_0
    invoke-direct {p0}, Lcom/samsung/android/displayquality/SemDisplayQuality;->enableDRE()V
    goto :goto_0
    :catchall_0
    move-exception p0
    goto :goto_1
    :cond_0
    invoke-direct {p0}, Lcom/samsung/android/displayquality/SemDisplayQuality;->disableDRE()V
    :goto_0
    monitor-exit v0
    return-void
    :goto_1
    monitor-exit v0
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0
    throw p0
.end method

.method private checkScreenModeAndSetPictureMode()V
    .locals 1
    invoke-virtual {p0}, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->getScreenModeSetting()I
    move-result v0
    invoke-virtual {p0, v0}, Lcom/samsung/android/displayquality/SemDisplayQuality;->handleScreenModeChanged(I)V
    return-void
.end method

.method private disableDRE()V
    .locals 1
    iget-object p0, p0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mPQHelper:Lcom/samsung/android/displayquality/PictureQualityHelper;
    if-eqz p0, :cond_0
    const/4 v0, 0x0
    invoke-virtual {p0, v0}, Lcom/samsung/android/displayquality/PictureQualityHelper;->setPQAALFunctionProperty(I)V
    :cond_0
    return-void
.end method

.method private enableDRE()V
    .locals 1
    iget-object p0, p0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mPQHelper:Lcom/samsung/android/displayquality/PictureQualityHelper;
    if-eqz p0, :cond_0
    const/4 v0, 0x4
    invoke-virtual {p0, v0}, Lcom/samsung/android/displayquality/PictureQualityHelper;->setPQAALFunctionProperty(I)V
    :cond_0
    return-void
.end method

.method private isDRESupport()Z
    .locals 2
    const-string/jumbo p0, "ro.vendor.mtk_aal_support"
    invoke-static {p0}, Landroid/os/SystemProperties;->get(Ljava/lang/String;)Ljava/lang/String;
    move-result-object p0
    const-string v0, "1"
    invoke-virtual {v0, p0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
    move-result p0
    const/4 v0, 0x0
    if-nez p0, :cond_0
    return v0
    :cond_0
    const-string/jumbo p0, "ro.vendor.mtk_pq_support"
    invoke-static {p0}, Landroid/os/SystemProperties;->get(Ljava/lang/String;)Ljava/lang/String;
    move-result-object p0
    :try_start_0
    invoke-static {p0}, Ljava/lang/Integer;->parseInt(Ljava/lang/String;)I
    move-result p0
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0
    if-lez p0, :cond_1
    const/4 p0, 0x1
    return p0
    :catch_0
    :cond_1
    return v0
.end method

# virtual methods
.method public enhanceOutdoorVisibilityByLux(I)V
    .locals 0
    return-void
.end method

.method public handleAutoBrightnessModeOff()V
    .locals 0
    invoke-direct {p0}, Lcom/samsung/android/displayquality/SemDisplayQuality;->disableDRE()V
    return-void
.end method

.method public handleAutoBrightnessModeOn()V
    .locals 0
    invoke-direct {p0}, Lcom/samsung/android/displayquality/SemDisplayQuality;->enableDRE()V
    return-void
.end method

.method public handleScreenModeChanged(I)V
    .locals 1
    const/4 v0, 0x2
    if-ne p1, v0, :cond_0
    iget-object p0, p0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mPQHelper:Lcom/samsung/android/displayquality/PictureQualityHelper;
    if-eqz p0, :cond_1
    const/4 p1, 0x0
    invoke-virtual {p0, p1}, Lcom/samsung/android/displayquality/PictureQualityHelper;->setPQSetPictureMode(I)V
    return-void
    :cond_0
    const/4 v0, 0x4
    if-ne p1, v0, :cond_1
    iget-object p0, p0, Lcom/samsung/android/displayquality/SemDisplayQuality;->mPQHelper:Lcom/samsung/android/displayquality/PictureQualityHelper;
    if-eqz p0, :cond_1
    const/4 p1, 0x1
    invoke-virtual {p0, p1}, Lcom/samsung/android/displayquality/PictureQualityHelper;->setPQSetPictureMode(I)V
    :cond_1
    return-void
.end method

.method public handleScreenOff()V
    .locals 0
    return-void
.end method

.method public handleScreenOffAsync()V
    .locals 0
    invoke-direct {p0}, Lcom/samsung/android/displayquality/SemDisplayQuality;->disableDRE()V
    return-void
.end method

.method public handleScreenOn()V
    .locals 0
    return-void
.end method

.method public handleScreenOnAsync()V
    .locals 2
    iget-object v0, p0, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->mBrightnessModeLock:Ljava/lang/Object;
    monitor-enter v0
    :try_start_0
    iget-boolean v1, p0, Lcom/samsung/android/displayquality/SemDisplayQualityAP;->mIsBrightnessModeAuto:Z
    if-eqz v1, :cond_0
    invoke-direct {p0}, Lcom/samsung/android/displayquality/SemDisplayQuality;->enableDRE()V
    :cond_0
    monitor-exit v0
    return-void
    :catchall_0
    move-exception p0
    monitor-exit v0
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0
    throw p0
.end method
EOF
    fi
}


PATCH_CUSTOM_PLATFORM_SIGNATURE() {
    echo " "
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <DECOMPILED_SERVICES_DIR>"
        return 1
    fi

    local SERVICES_WORK_DIR="$1"
    local SIG_PATCH_FILE="${QT_DIR}/patches/services.jar/0001-Allow-custom-platform-signature.patch"

    echo -e "Patching Custom Platform Signature in services.jar..."
    if [ -f "$SIG_PATCH_FILE" ]; then
        patch -p1 -d "$SERVICES_WORK_DIR" < "$SIG_PATCH_FILE" || true
    fi
    return 0
}


PATCH_SECSETTINGS_OUTDOOR_MODE() {
    echo " "
    if [ "$#" -ne 3 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <APKTOOL> <EXTRACTED_FIRM_DIR> <WORK_DIR>"
        return 1
    fi

    local APKTOOL="$1"
    local EXTRACTED_FIRM_DIR="$2"
    local WORK_DIR="$3"
    local FRAMEWORK_DIR="$EXTRACTED_FIRM_DIR/system/system/framework"
    local SEC_SETTINGS="$EXTRACTED_FIRM_DIR/system/system/priv-app/SecSettings/SecSettings.apk"

    if [ ! -f "$SEC_SETTINGS" ]; then
        echo "- SecSettings.apk not found, skipping outdoor mode patch."
        return 0
    fi

    echo "- Decompiling SecSettings.apk (smali only, --no-res) for Outdoor Mode patch..."
    DECOMPILE "$APKTOOL" "$FRAMEWORK_DIR" "$SEC_SETTINGS" "$WORK_DIR" "--no-res"

    local OUTDOOR_CONTROLLER=$(find "$WORK_DIR/SecSettings" -type f -path '*/com/samsung/android/settings/display/controller/SecOutDoorModePreferenceController.smali' -print -quit)

    if [ -n "$OUTDOOR_CONTROLLER" ] && [ -f "$OUTDOOR_CONTROLLER" ]; then
        local BODY_TRUE='
    .locals 1

    const/4 v0, 0x1

    return v0
    '
        REPLACE_SMALI_METHOD "$OUTDOOR_CONTROLLER" "isAvailable()Z" "$BODY_TRUE"
    else
        echo "- Warning: SecOutDoorModePreferenceController.smali not found!"
    fi

    RECOMPILE "$APKTOOL" "$FRAMEWORK_DIR" "$WORK_DIR/SecSettings" "$WORK_DIR"
    if [ -f "$WORK_DIR/SecSettings.apk" ]; then
        mv -f "$WORK_DIR/SecSettings.apk" "$SEC_SETTINGS"
        echo "- SecSettings.apk patched and restored."
    fi
}


UPDATE_SDHMS() {
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIRECTORY>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo "- Adding alternative SDHMS app."
    local SDK="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.build.version.sdk_full")"
    local ANDROID_VERSION="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.system.build.version.release")"
    
    if [ -d "${QT_DIR}/QuantumROM/Mods/Apps/SDHMS/${ANDROID_VERSION}/priv-app/SamsungDeviceHealthManagerService" ]; then
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/priv-app/SamsungDeviceHealthManagerService"
        cp -a "${QT_DIR}/QuantumROM/Mods/Apps/SDHMS/${ANDROID_VERSION}/." "${EXTRACTED_FIRM_DIR}/system/system/"
    else
        echo "- Alternative SDHMS app for $ANDROID_VERSION not found."
    fi
}


PATCH_SSRM() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_SSRM_DIRECTORY>"
        return 1
    fi

    local SSRM_DIR="$1"
    local FILE="$SSRM_DIR/smali/com/android/server/ssrm/Feature.smali"

    echo -e "Patching SSRM."
    echo -e "- Patching: $FILE"

    if [ ! -f "$FILE" ]; then
        echo "- File name not found: $FILE"
        return 1
    fi

    if FOUND=$(grep -E 'const-string [vp][0-9]+, "dvfs_policy_[^"]*"' "$FILE" | sed -n '2p'); then
        if [ -n "$FOUND" ]; then
            echo "- Found DVFS policy: $FOUND"

            if [ -n "$STOCK_DVFS_FILENAME" ]; then
                sed -i -E \
                    '0,/dvfs_policy_[^"]*/!{
                        s|(const-string [vp][0-9]+, ")dvfs_policy_[^"]*(")|\1'"$STOCK_DVFS_FILENAME"'\2|
                    }' \
                    "$FILE"

                echo "- DVFS policy file name replaced to: ${STOCK_DVFS_FILENAME}"
            else
                echo "- STOCK_DVFS_FILENAME is empty. Skipping replacement."
            fi
        else
            echo "- DVFS policy file name not found."
        fi
    else
        echo "- DVFS policy file name not found."
    fi

    if FOUND=$(grep -E 'const-string [vp][0-9]+, "siop_[^"]*_[^"]*"' "$FILE"); then
        if [ -n "$FOUND" ]; then
            echo "- Found SIOP policy: $FOUND"

            if [ -n "$STOCK_SIOP_POLICY_FILENAME" ]; then
                sed -i -E \
                    's|(const-string [vp][0-9]+, ")siop_[^"]*_[^"]*(")|\1'"$STOCK_SIOP_POLICY_FILENAME"'\2|' \
                    "$FILE"

                echo "- SIOP policy file name replaced to: ${STOCK_SIOP_POLICY_FILENAME}"
            else
                echo "- STOCK_SIOP_POLICY_FILENAME is empty. Skipping replacement."
            fi
        else
            echo "- SIOP policy file name not found."
        fi
    else
        echo "- SIOP policy file name not found."
    fi
}


PATCH_BT_LIB() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIRECTORY> <WORK_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local WORK_DIR="$2"
    local BT_LIB_FILE="$WORK_DIR/libbluetooth_jni.so"

    echo -e "Patching Bluetooth library."
    if ! ls "$EXTRACTED_FIRM_DIR"/system/system/apex/com.android.bt*.apex >/dev/null 2>&1; then
        echo -e "- No bluetooth apex file found."
        return 0
    fi

    7z e "${EXTRACTED_FIRM_DIR}/system/system/apex/com.android.bt"*.apex \
        "apex_payload.img" -o"$WORK_DIR" -y >/dev/null 2>&1 || true

    if [ -f "$WORK_DIR/apex_payload.img" ]; then
        debugfs -R "dump /lib64/libbluetooth_jni.so $WORK_DIR/libbluetooth_jni.so" \
            "$WORK_DIR/apex_payload.img" >/dev/null 2>&1 || true
        rm -rf "$WORK_DIR/apex_payload.img"
    fi

    if [ ! -f "$BT_LIB_FILE" ] || [ ! -s "$BT_LIB_FILE" ]; then
        echo -e "- libbluetooth_jni.so not present in APEX (Android 15/16+ Bluetooth stack); skipping legacyjni hex patch."
        rm -f "$BT_LIB_FILE"
        return 0
    fi

    declare -A hex=(
        [136]=00122a0140395f01086b00020054 [1136]=00122a0140395f01086bde030014
        [135]=480500352800805228 [1135]=530100142800805228
        [134]=6804003528008052 [1134]=2b00001428008052
        [133]=6804003528008052 [1133]=2a00001428008052
        [132]=........f9031f2af3031f2a41 [1132]=1f2003d5f9031f2af3031f2a48
        [131]=........f9031f2af3031f2a41 [1131]=1f2003d5f9031f2af3031f2a48
        [130]=........f3031f2af4031f2a3e [1130]=1f2003d5f3031f2af4031f2a3e
        [129]=........f4031f2af3031f2ae8030032 [1129]=1f2003d5f4031f2af3031f2ae8031f2a
        [128]=88000034e8030032 [1128]=1f2003d5e8031f2a
        [127]=88000034e8030032 [1127]=1f2003d5e8031f2a
        [126]=88000034e8030032 [1126]=1f2003d5e8031f2a
        [234]=4e7e4448bb [1234]=4e7e4437e0
        [233]=4e7e4440bb [1233]=4e7e4432e0
        [231]=20b14ff000084ff000095ae0 [1231]=00bf4ff000084ff0000964e0
        [230]=18b14ff0000b00254a [1230]=00204ff0000b002554
        [229]=..b100250120 [1229]=00bf00250020
        [228]=..b101200028 [1228]=00bf00200028
        [227]=09b1012032e0 [1227]=00bf002032e0
        [226]=08b1012031e0 [1226]=00bf002031e0
        [225]=087850bbb548 [1225]=08785ae1b548
        [224]=007840bb6a48 [1224]=0078c4e06a48
        [330]=88000054691180522925c81a69000037 [1330]=1f2003d5691180522925c81a1f2003d5
        [329]=88000054691180522925c81a69000037 [1329]=1f2003d5691180522925c81a1f2003d5
        [328]=7f1d0071e91700f9e83c0054 [1328]=7f1d0071e91700f9e7010014
        [429]=....0034f3031f2af4031f2a....0014 [1429]=1f2003d5f3031f2af4031f2a47000014
        [531]=10b1002500244ce0 [1531]=00bf0025002456e0
        [530]=18b100244ff0000b4d [1530]=002000244ff0000b57
        [529]=44387810b1002400254a [1529]=44387800200024002556
        [629]=90387810b1002400254a [1629]=90387800200024002558
    )

    local PATCHED=0

    for idx in "${!hex[@]}"; do
        (( idx >= 1000 )) && continue

        local from="${hex[$idx]}"
        local to="${hex[$((idx + 1000))]}"

        [ -z "$to" ] && continue

        local from_regex="$(echo "$from" | sed -E 's/\.\./[0-9a-f]{2}/g')"
        if perl -e '
            $/ = undef;
            open(F, shift) or exit 1;
            $_ = <F>;
            my $hex = unpack("H*", $_);
            exit ($hex =~ /'"$from_regex"'/i ? 0 : 1);
        ' "$BT_LIB_FILE"; then

            echo -e "- Found Bluetooth patch pattern [$idx]"

            HEX_PATCH "$BT_LIB_FILE" "$from" "$to" || return 1

            PATCHED=1
            mv -f "$BT_LIB_FILE" "${EXTRACTED_FIRM_DIR}/system/system/lib64/"
            break
        fi
    done

    if [ "$PATCHED" -eq 0 ]; then
        echo -e "- No known Bluetooth patch pattern matched."
        rm -rf "$BT_LIB_FILE"
        return 0
    fi

    return 0
}


###################################################################################################
# PART 3: VNDK, SYSTEM_EXT, SELINUX (ORIGINAL) & FLOATING FEATURES
###################################################################################################

FIX_VNDK() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIRECTORY>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local TARGET_ROM_SYSTEM_EXT_DIR="$(GET_SYSTEM_EXT_DIR "$EXTRACTED_FIRM_DIR")"

    echo "Checking $STOCK_DEVICE and $TARGET_DEVICE VNDK version."

    local SDK="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.build.version.sdk_full")"
    local ANDROID_VERSION="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.system.build.version.release")"

    if [[ -z "$SDK" ]]; then
        SDK="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.build.version.sdk")"
    fi

    echo "- Target rom Android version: $ANDROID_VERSION - SDK version: $SDK"

    if [[ "$STOCK_DUAL_VNDKS" != "30_31" && -f "${TARGET_ROM_SYSTEM_EXT_DIR}/apex/com.android.vndk.v${STOCK_VNDK_VERSION}.apex" ]]; then
        echo "- VNDK matched: ${TARGET_ROM_SYSTEM_EXT_DIR}/apex/com.android.vndk.v${STOCK_VNDK_VERSION}.apex"
        return 0
    fi

    echo "- VNDK mismatch. Adding SDK $SDK com.android.vndk.v${STOCK_VNDK_VERSION}.apex"

    if [[ "$STOCK_DUAL_VNDKS" == "30_31" || ! -f "${TARGET_ROM_SYSTEM_EXT_DIR}/apex/com.android.vndk.v${STOCK_VNDK_VERSION}.apex" ]]; then
        rm -rf "${TARGET_ROM_SYSTEM_EXT_DIR}/apex/"com.android.vndk.v*.apex

        local VNDK_ZIP="Android-${ANDROID_VERSION}_SDK-${SDK}.zip"
        local VNDK_URL="https://github.com/SN-Abdullah-Al-Noman/QuantumROM/releases/download/VNDKS/${VNDK_ZIP}"
        local VNDK_EXTRACT_DIR="${QT_DIR}/QuantumROM/vndks/Android-${ANDROID_VERSION}_SDK-${SDK}"

        mkdir -p "${QT_DIR}/QuantumROM/vndks"

        if curl -fsSL \
            "https://api.github.com/repos/SN-Abdullah-Al-Noman/QuantumROM/releases/tags/VNDKS" |
            jq -e --arg dev "$VNDK_ZIP" '.assets[].name == $dev' |
            grep -q true; then
            echo "- $VNDK_ZIP found"
        else
            echo "- $VNDK_ZIP not found"
            exit 1
        fi

        if curl -fsSL --connect-timeout 5 https://www.google.com >/dev/null; then
            echo "- Downloading $VNDK_ZIP"
            if wget -q --no-check-certificate -O "${QT_DIR}/QuantumROM/vndks/${VNDK_ZIP}" "$VNDK_URL"; then
                if 7z x -aoa -y -bd -bso0 -bse0 -bsp1 "${QT_DIR}/QuantumROM/vndks/${VNDK_ZIP}" -o"$VNDK_EXTRACT_DIR"; then
                    if [ -d "${VNDK_EXTRACT_DIR}/${STOCK_VNDK_VERSION}" ]; then
                        cp -a "${VNDK_EXTRACT_DIR}/${STOCK_VNDK_VERSION}/." "$TARGET_ROM_SYSTEM_EXT_DIR/"
                        echo "- VNDK $STOCK_VNDK_VERSION copied successfully"
                        if [[ "$STOCK_DUAL_VNDKS" == "30_31" ]]; then
                            cp -a "${VNDK_EXTRACT_DIR}/30/." "$TARGET_ROM_SYSTEM_EXT_DIR/"
                            cp -a "${VNDK_EXTRACT_DIR}/31/." "$TARGET_ROM_SYSTEM_EXT_DIR/"
                            cp -a "${VNDK_EXTRACT_DIR}/dual_vndks/30_31/." "$TARGET_ROM_SYSTEM_EXT_DIR/etc/vintf/"
                            echo "- Dual vndk 30 and 31 copied successfully"
                        fi
                    else
                        echo "- ERROR: Extracted VNDK directory not found:"
                        echo "  ${VNDK_EXTRACT_DIR}/${STOCK_VNDK_VERSION}"
                        return 1
                    fi
                else
                    echo "- ERROR: Failed to extract $VNDK_ZIP"
                    exit 1
                fi
            else
                echo "- ERROR: Failed to download $VNDK_ZIP"
                exit 1
            fi
        else
            echo "- ERROR: Internet connection unavailable"
            exit 1
        fi
    fi
}


ADD_SYSTEM_EXT_IN_SYSTEM_ROOT() {
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo -e "- Copying system_ext content into system root"
    rm -rf "${EXTRACTED_FIRM_DIR}/system/system_ext"
    mv "${EXTRACTED_FIRM_DIR}/system_ext" "${EXTRACTED_FIRM_DIR}/system"

    echo -e "- Cleaning and merging system_ext file contexts and configs"
    SYSTEM_EXT_CONFIG_FILE="${EXTRACTED_FIRM_DIR}/config/system_ext_fs_config"
    SYSTEM_EXT_CONTEXTS_FILE="${EXTRACTED_FIRM_DIR}/config/system_ext_file_contexts"

    SYSTEM_CONFIG_FILE="${EXTRACTED_FIRM_DIR}/config/system_fs_config"
    SYSTEM_CONTEXTS_FILE="${EXTRACTED_FIRM_DIR}/config/system_file_contexts"

    SYSTEM_EXT_TEMP_CONFIG="${SYSTEM_EXT_CONFIG_FILE}.tmp"
    SYSTEM_EXT_TEMP_CONTEXTS="${SYSTEM_EXT_CONTEXTS_FILE}.tmp"

    # Clean system_ext contexts
    grep -v '^/ u:object_r:system_file:s0$' "$SYSTEM_EXT_CONTEXTS_FILE" \
    | grep -v '^/system_ext u:object_r:system_file:s0$' \
    | grep -v '^/system_ext(.*)? u:object_r:system_file:s0$' \
    | grep -v '^/system_ext/ u:object_r:system_file:s0$' \
    > "$SYSTEM_EXT_TEMP_CONTEXTS" && mv "$SYSTEM_EXT_TEMP_CONTEXTS" "$SYSTEM_EXT_CONTEXTS_FILE"

    # Clean system_ext config
    grep -v '^/ 0 0 0755$' "$SYSTEM_EXT_CONFIG_FILE" \
    | grep -v '^system_ext/ 0 0 0755$' \
    > "$SYSTEM_EXT_TEMP_CONFIG" && mv "$SYSTEM_EXT_TEMP_CONFIG" "$SYSTEM_EXT_CONFIG_FILE"

    # Fix system_ext config
    awk '{print "system/" $0}' "$SYSTEM_EXT_CONFIG_FILE" \
    > "$SYSTEM_EXT_TEMP_CONFIG" && mv "$SYSTEM_EXT_TEMP_CONFIG" "$SYSTEM_EXT_CONFIG_FILE"

    # Fix system_ext contexts
    awk '{print "/system" $0}' "$SYSTEM_EXT_CONTEXTS_FILE" \
    > "$SYSTEM_EXT_TEMP_CONTEXTS" && mv "$SYSTEM_EXT_TEMP_CONTEXTS" "$SYSTEM_EXT_CONTEXTS_FILE"

    # Append cleaned system_ext config into system config
    cat "$SYSTEM_EXT_CONFIG_FILE" >> "$SYSTEM_CONFIG_FILE"

    # Append cleaned system_ext contexts into system contexts
    cat "$SYSTEM_EXT_CONTEXTS_FILE" >> "$SYSTEM_CONTEXTS_FILE"

    rm -rf "$EXTRACTED_FIRM_DIR"/config/system_ext*
    local TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system/system_ext"
}


SEPARATE_SYSTEM_EXT() {
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo "- Separating system_ext"
    mv "${EXTRACTED_FIRM_DIR}/system/system/system_ext" "${EXTRACTED_FIRM_DIR}/"
    ln -s /system_ext ${EXTRACTED_FIRM_DIR}/system/system/system_ext
    rm -rf "${EXTRACTED_FIRM_DIR}/system/system_ext"
    mkdir "${EXTRACTED_FIRM_DIR}/system/system_ext"

    SYSTEM_FS_CONFIG="${EXTRACTED_FIRM_DIR}/config/system_fs_config"
    SYSTEM_FILE_CONTEXTS="${EXTRACTED_FIRM_DIR}/config/system_file_contexts"
    
    SYSTEM_EXT_FS_CONFIG="${EXTRACTED_FIRM_DIR}/config/system_ext_fs_config"
    SYSTEM_EXT_FILE_CONTEXTS="${EXTRACTED_FIRM_DIR}/config/system_ext_file_contexts"

    # Process system_ext_file_contexts
    if grep -q '^/system/system/system_ext' "$SYSTEM_FILE_CONTEXTS"; then
        grep '^/system/system/system_ext' "$SYSTEM_FILE_CONTEXTS" > "$SYSTEM_EXT_FILE_CONTEXTS"
        sed -i '\|^/system/system/system_ext|d' "$SYSTEM_FILE_CONTEXTS"
        awk '{sub(/^\/system\/system\/system_ext/, "/system_ext"); print}' "$SYSTEM_EXT_FILE_CONTEXTS" > "$SYSTEM_EXT_FILE_CONTEXTS.tmp"  && \
        mv "$SYSTEM_EXT_FILE_CONTEXTS.tmp" "$SYSTEM_EXT_FILE_CONTEXTS"

        # Add object context line if missing
        grep -qxF '/system/system_ext u:object_r:system_file:s0' "$SYSTEM_FILE_CONTEXTS" || echo '/system/system_ext u:object_r:system_file:s0' >> "$SYSTEM_FILE_CONTEXTS"
        grep -qxF '/system/system/system_ext u:object_r:system_file:s0' "$SYSTEM_EXT_FILE_CONTEXTS" || echo '/system/system/system_ext u:object_r:system_file:s0' >> "$SYSTEM_EXT_FILE_CONTEXTS"

        grep -qxF '/ u:object_r:system_file:s0' "$SYSTEM_EXT_FILE_CONTEXTS" || echo '/ u:object_r:system_file:s0' >> "$SYSTEM_EXT_FILE_CONTEXTS"
        sort -u "$SYSTEM_EXT_FILE_CONTEXTS" -o "$SYSTEM_EXT_FILE_CONTEXTS"
    fi

    # Process system_ext_fs_config
    if grep -q '^system/system/system_ext' "$SYSTEM_FS_CONFIG"; then
        grep '^system/system/system_ext' "$SYSTEM_FS_CONFIG" > "$SYSTEM_EXT_FS_CONFIG"
        sed -i '\|^system/system/system_ext|d' "$SYSTEM_FS_CONFIG"
        awk '{sub(/^system\/system\/system_ext/, "system_ext"); print}' "$SYSTEM_EXT_FS_CONFIG" > "$SYSTEM_EXT_FS_CONFIG.tmp" &&  \
        mv "$SYSTEM_EXT_FS_CONFIG.tmp" "$SYSTEM_EXT_FS_CONFIG"

        # Add default fs permissions if missing
        grep -qxF 'system/system_ext 0 0 0755' "$SYSTEM_FS_CONFIG" || echo 'system/system_ext 0 0 0755' >> "$SYSTEM_FS_CONFIG"
        grep -qxF 'system/system/system_ext 0 0 0644' "$SYSTEM_FS_CONFIG" || echo 'system/system/system_ext 0 0 0644' >> "$SYSTEM_FS_CONFIG"

        grep -qxF '/ 0 0 0755' "$SYSTEM_EXT_FS_CONFIG" || echo '/ 0 0 0755' >> "$SYSTEM_EXT_FS_CONFIG"
        grep -qxF 'system_ext/ 0 0 0755' "$SYSTEM_EXT_FS_CONFIG" || echo 'system_ext/ 0 0 0755' >> "$SYSTEM_EXT_FS_CONFIG"
        sort -u "$SYSTEM_EXT_FS_CONFIG" -o "$SYSTEM_EXT_FS_CONFIG"
    fi

    local TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system_ext"
}


ADJUST_SYSTEM_EXT() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    if [ "$STOCK_HAS_SEPARATE_SYSTEM_EXT" = "FALSE" ]; then
        echo "- STOCK_HAS_SEPARATE_SYSTEM_EXT: $STOCK_HAS_SEPARATE_SYSTEM_EXT"

        if [ -d "${EXTRACTED_FIRM_DIR}/system/system/system_ext/etc" ]; then
            local TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system/system/system_ext"

        elif [ -d "${EXTRACTED_FIRM_DIR}/system/system_ext/etc" ]; then
            local TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system/system_ext"
            
        elif [ -d "${EXTRACTED_FIRM_DIR}/system_ext/etc" ]; then
            ADD_SYSTEM_EXT_IN_SYSTEM_ROOT "$EXTRACTED_FIRM_DIR"
        fi

    elif [ "$STOCK_HAS_SEPARATE_SYSTEM_EXT" = "TRUE" ]; then
        echo "STOCK_HAS_SEPARATE_SYSTEM_EXT: $STOCK_HAS_SEPARATE_SYSTEM_EXT"

        if [ -d "${EXTRACTED_FIRM_DIR}/system/system/system_ext/etc" ]; then
            SEPARATE_SYSTEM_EXT "$EXTRACTED_FIRM_DIR"
        fi
    fi

    echo "- TARGET_ROM_SYSTEM_EXT_DIR set to: $(GET_SYSTEM_EXT_DIR "$EXTRACTED_FIRM_DIR")"
}


GET_SYSTEM_EXT_DIR() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    if [ ! -L "${EXTRACTED_FIRM_DIR}/system_ext" ] && [ -d "${EXTRACTED_FIRM_DIR}/system_ext/etc" ]; then
        local TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system_ext"
    elif [ ! -L "${EXTRACTED_FIRM_DIR}/system/system_ext" ] && [ -d "${EXTRACTED_FIRM_DIR}/system/system_ext/etc" ]; then
        local TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system/system_ext"
    elif [ ! -L "${EXTRACTED_FIRM_DIR}/system/system/system_ext" ] && [ -d "${EXTRACTED_FIRM_DIR}/system/system/system_ext/etc" ]; then
        local TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system/system/system_ext"
    else
        return 0
    fi

    echo "$TARGET_ROM_SYSTEM_EXT_DIR"
}


PATCH_SELINUX() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local TARGET_ROM_SYSTEM_EXT_DIR="$(GET_SYSTEM_EXT_DIR "$EXTRACTED_FIRM_DIR")"

    echo -e "Patching selinux."

    UNSUPPORTED_SELINUX=("audiomirroring" "fabriccrypto" "hal_dsms_default" "qb_id_prop" "hal_dsms_service" "proc_compaction_proactiveness" "sbauth" "ker_app" "kpp_app" "kpp_data" "attiqi_app" "kpoc_charger" "sec_diag" "mosey_app" "vendor_smcinvoke_device" "perf_prop" "uwb_regulation_skip_prop")

    if [ -d "${EXTRACTED_FIRM_DIR}/system" ]; then
        echo "- Patching selinux for system"

        REMOVE_LINE '(genfscon sysfs "/bus/usb/devices" (u object_r sysfs_usb ((s0) (s0))))' \
            "${EXTRACTED_FIRM_DIR}/system/system/etc/selinux/plat_sepolicy.cil" >/dev/null 2>&1
        REMOVE_LINE '(genfscon proc "/sys/vm/compaction_proactiveness" (u object_r proc_compaction_proactiveness ((s0) (s0))))' \
            "${EXTRACTED_FIRM_DIR}/system/system/etc/selinux/plat_sepolicy.cil" >/dev/null 2>&1
    else
        echo -e "- No system directory found."
    fi

    if [ -d "$TARGET_ROM_SYSTEM_EXT_DIR" ]; then
        echo -e "- Patching selinux for system_ext"

        find "${TARGET_ROM_SYSTEM_EXT_DIR}/etc/selinux/mapping/" -type f -name "*.0.cil" | while read -r SELINUX_FILE; do
            for keyword in "${UNSUPPORTED_SELINUX[@]}"; do
                if grep -qF "$keyword" "$SELINUX_FILE"; then
                    sed -i "/$keyword/d" "$SELINUX_FILE"
                fi
            done
        done

        REMOVE_LINE '(genfscon proc "/sys/kernel/firmware_config" (u object_r proc_fmw ((s0) (s0))))' \
            "${TARGET_ROM_SYSTEM_EXT_DIR}/etc/selinux/system_ext_sepolicy.cil" >/dev/null 2>&1
        REMOVE_LINE '(genfscon proc "/sys/vm/compaction_proactiveness" (u object_r proc_compaction_proactiveness ((s0) (s0))))' \
            "${TARGET_ROM_SYSTEM_EXT_DIR}/etc/selinux/system_ext_sepolicy.cil" >/dev/null 2>&1
        REMOVE_LINE 'init.svc.vendor.wvkprov_server_hal                           u:object_r:wvkprov_prop:s0' \
            "${TARGET_ROM_SYSTEM_EXT_DIR}/etc/selinux/system_ext_property_contexts" >/dev/null 2>&1
    else
        echo -e "- No system_ext directory found."
    fi
}


UPDATE_FLOATING_FEATURE() {
    if [ "$#" -ne 3 ]; then
        echo "Usage: ${FUNCNAME[0]} <TARGET_ROM_FLOATING_FEATURE> <FLOATING_FEATURE_LINE> <VALUE>"
        return 1
    fi

    local TARGET_ROM_FLOATING_FEATURE="$1"
    local key="$2"
    local value="$3"

    value=$(printf '%s' "$value" | tr -d '\r' | xargs)

    [ -z "$value" ] && {
        echo "- Skipping $key — no value found."
        return
    }

    local escaped_value
    escaped_value=$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')

    if grep -Fq "<${key}>" "$TARGET_ROM_FLOATING_FEATURE"; then

        local current_value
        current_value=$(
            sed -n "s|.*<${key}>\\(.*\\)</${key}>.*|\\1|p" \
            "$TARGET_ROM_FLOATING_FEATURE" | head -n1 | xargs
        )

        if [ "$current_value" = "$value" ]; then
            return
        fi

        sed -i \
            "/<${key}>.*<\/${key}>/c\\    <${key}>${escaped_value}</${key}>" \
            "$TARGET_ROM_FLOATING_FEATURE"
    else
        sed -i \
            "3i\\    <${key}>${escaped_value}</${key}>" \
            "$TARGET_ROM_FLOATING_FEATURE"
    fi
}


APPLY_CUSTOM_FLOATING_FEATURE() {
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo -e "- Applying Custom Floating Feature."

    if [ -f "${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml" ]; then
        local TARGET_ROM_FLOATING_FEATURE="${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml"
    elif [ -f "${EXTRACTED_FIRM_DIR}/vendor/etc/floating_feature.xml" ]; then
        local TARGET_ROM_FLOATING_FEATURE="${EXTRACTED_FIRM_DIR}/vendor/etc/floating_feature.xml"
    else
        echo "- Error: floating_feature.xml not found!"
        return 0
    fi

    #========== COMMON ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_CONFIG_SEP_CATEGORY" "sep_basic"

    #============= AI ==========#
    sed -i '/SEC_FLOATING_FEATURE_COMMON_DISABLE_NATIVE_AI/d' "$TARGET_ROM_FLOATING_FEATURE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_VISION_SUPPORT_AI_MY_FAVORITE_CONTENTS" "TRUE"

    #========== EDGE ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_CONFIG_EDGE" "panel"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_SUPPORT_BRIEF_NOTIFICATION" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_CONFIG_EDGELIGHTING_FRAME_EFFECT" "frame_effect"

    #========== SCREEN RECORDER ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_SCREEN_RECORDER" "TRUE"

    #========== AUDIO ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_BT_RECORDING" "TRUE"

    #========== BATTERY ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_BATTERY_SUPPORT_BSOH_GALAXYDIAGNOSTICS" "TRUE"

    #========== SETTINGS ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SETTINGS_SUPPORT_DEFAULT_DOUBLE_TAP_TO_WAKE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SETTINGS_SUPPORT_FUNCTION_KEY_MENU" "TRUE"

    #========== SYSTEM ============#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEM_SUPPORT_ENHANCED_CPU_RESPONSIVENESS" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEM_SUPPORT_ENHANCED_PROCESSING" "TRUE"

    #========== LAUNCHER ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LAUNCHER_SUPPORT_CLOCK_LIVE_ICON" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LAUNCHER_CONFIG_ANIMATION_TYPE" "HighEnd"

    #========== CAMERA ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_SUPPORT_PRIVACY_TOGGLE" "TRUE"

    #========== MEDIATEK / EXTRA FLOATING FEATURES ==========#
    sed -i '/SEC_FLOATING_FEATURE_GRAPHICS_SUPPORT_3D_SURFACE_TRANSITION_FLAG/d' "$TARGET_ROM_FLOATING_FEATURE"
    sed -i '/SEC_FLOATING_FEATURE_GRAPHICS_SUPPORT_RELUMINO_EFFECT_FLAG/d' "$TARGET_ROM_FLOATING_FEATURE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_MODE" "1"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LCD_SUPPORT_EXTRA_BRIGHTNESS" "TRUE"
}


APPLY_STOCK_ROM_FLOATING_FEATURE() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <STOCK_ROM_FLOATING_FEATURE> <TARGET_ROM_FLOATING_FEATURE>"
        return 1
    fi

    local STOCK_ROM_FLOATING_FEATURE="$1"
    local TARGET_ROM_FLOATING_FEATURE="$2"

    echo "Applying Stock Floating Feature."

    #========== AUDIO ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_AUDIO_CONFIG_VOLUMEMONITOR_STAGE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_AUDIO_CONFIG_VOLUMEMONITOR_STAGE" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_VOLUME_MONITOR" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_VOLUME_MONITOR" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_AUDIO_CONFIG_REMOTE_MIC" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_AUDIO_CONFIG_REMOTE_MIC" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_AUDIO_CONFIG_SOUNDALIVE_VERSION" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_AUDIO_CONFIG_SOUNDALIVE_VERSION" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_AUDIO_CONFIG_VOLUMEMONITOR_GAIN" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_AUDIO_CONFIG_VOLUMEMONITOR_GAIN" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_DUAL_SPEAKER" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_DUAL_SPEAKER" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_AUDIO_NUMBER_OF_SPEAKER" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_AUDIO_NUMBER_OF_SPEAKER" "$STOCK_ROM_FLOATING_FEATURE")"

    #========== SETTINGS ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_SETTINGS_CONFIG_ELECTRIC_RATED_VALUE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_SETTINGS_CONFIG_ELECTRIC_RATED_VALUE" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_SETTINGS_CONFIG_BRAND_NAME" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_SETTINGS_CONFIG_BRAND_NAME" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_SETTINGS_CONFIG_DEFAULT_FONT_SIZE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_SETTINGS_CONFIG_DEFAULT_FONT_SIZE" "$STOCK_ROM_FLOATING_FEATURE")"

    #========== REFRESH RATE ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_MODE" "1"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_DEFAULT_REFRESH_RATE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_DEFAULT_REFRESH_RATE" "$STOCK_ROM_FLOATING_FEATURE")"

    #========== SYSTEM ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_SYSTEM_CONFIG_SIOP_POLICY_FILENAME" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_SYSTEM_CONFIG_SIOP_POLICY_FILENAME" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_COMMON_CONFIG_DEVICE_MANUFACTURING_TYPE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_COMMON_CONFIG_DEVICE_MANUFACTURING_TYPE" "$STOCK_ROM_FLOATING_FEATURE")"

    #========== LAUNCHER ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_LAUNCHER_CONFIG_ANIMATION_TYPE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_LAUNCHER_CONFIG_ANIMATION_TYPE" "$STOCK_ROM_FLOATING_FEATURE")"

    #========== DISPLAY ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_LCD_CONFIG_CONTROL_AUTO_BRIGHTNESS" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_LCD_CONFIG_CONTROL_AUTO_BRIGHTNESS" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_LCD_CONFIG_DEFAULT_SCREEN_MODE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_LCD_CONFIG_DEFAULT_SCREEN_MODE" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_LCD_SUPPORT_NATURAL_SCREEN_MODE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_LCD_SUPPORT_NATURAL_SCREEN_MODE" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_LCD_SUPPORT_SCREEN_MODE_TYPE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_LCD_SUPPORT_SCREEN_MODE_TYPE" "$STOCK_ROM_FLOATING_FEATURE")"

    #========== CAMERA ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_CAMERA_CONFIG_CAMID_TELE_BINNING" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_CAMERA_CONFIG_CAMID_TELE_BINNING" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_CAMERA_CONFIG_MEMORY_USAGE_LEVEL" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_CAMERA_CONFIG_MEMORY_USAGE_LEVEL" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_CAMERA_CONFIG_QRCODE_INTERVAL" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_CAMERA_CONFIG_QRCODE_INTERVAL" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_CAMERA_CONFIG_UW_DISTORTION_CORRECTION" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_CAMERA_CONFIG_UW_DISTORTION_CORRECTION" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_CAMERA_CONFIG_AVATAR_MAX_FACE_NUM" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_CAMERA_CONFIG_AVATAR_MAX_FACE_NUM" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_CAMERA_CONFIG_CAMID_TELE_STANDARD_CROP" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_CAMERA_CONFIG_CAMID_TELE_STANDARD_CROP" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE" "$STOCK_ROM_FLOATING_FEATURE")"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_CAMERA_CONFIG_NIGHT_FRONT_DISPLAY_FLASH_TRANSPARENT" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_CAMERA_CONFIG_NIGHT_FRONT_DISPLAY_FLASH_TRANSPARENT" "$STOCK_ROM_FLOATING_FEATURE")"

    #========== BIOAUTH ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_BIOAUTH_CONFIG_FINGERPRINT_FEATURES" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_BIOAUTH_CONFIG_FINGERPRINT_FEATURES" "$STOCK_ROM_FLOATING_FEATURE")"

    #========== LOCKSCREEN ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_LOCKSCREEN_CONFIG_PUNCHHOLE_VI" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_LOCKSCREEN_CONFIG_PUNCHHOLE_VI" "$STOCK_ROM_FLOATING_FEATURE")"

    #========== VIDEO EDITOR ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_COMMON_CONFIG_MULTIMEDIA_EDITOR_PLUGIN_PACKAGES" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_COMMON_CONFIG_MULTIMEDIA_EDITOR_PLUGIN_PACKAGES" "$STOCK_ROM_FLOATING_FEATURE")"

    #============= PHOTO REMASTER FIX ==========#
    if grep -q "<SEC_FLOATING_FEATURE_SAIV_CONFIG_MIDAS>" "$STOCK_ROM_FLOATING_FEATURE"; then
        UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_CONFIG_MULTIMEDIA_EDITOR_PLUGIN_PACKAGES" \
        "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_COMMON_CONFIG_MULTIMEDIA_EDITOR_PLUGIN_PACKAGES" "$STOCK_ROM_FLOATING_FEATURE")"
    else
        sed -i '/<SEC_FLOATING_FEATURE_SAIV_CONFIG_MIDAS>/d' "$TARGET_ROM_FLOATING_FEATURE"
    fi
    
    #========== SIM RELATED ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
    "SEC_FLOATING_FEATURE_COMMON_CONFIG_EMBEDDED_SIM_SLOTSWITCH" \
    "$(GET_FF_VALUE "SEC_FLOATING_FEATURE_COMMON_CONFIG_EMBEDDED_SIM_SLOTSWITCH" "$STOCK_ROM_FLOATING_FEATURE")"

    #========== COMMON ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_CONFIG_SEP_CATEGORY" "sep_basic"

    #============= AI ==========#
    sed -i '/SEC_FLOATING_FEATURE_COMMON_DISABLE_NATIVE_AI/d' "$TARGET_ROM_FLOATING_FEATURE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_VISION_SUPPORT_AI_MY_FAVORITE_CONTENTS" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_NOTE_ASSIST" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_SMART_CAPTURE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_SUPPORT_SCREENSHOT_NOTIFICATION" "TRUE"

    #============= OCR ==========#
    sed -i '/SEC_FLOATING_FEATURE_CAMERA_CONFIG_OCR_ENGINE_UNSUPPORT /d' "$TARGET_ROM_FLOATING_FEATURE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_CONFIG_STRIDE_OCR_VERSION" "V2"

    #========== EDGE ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_CONFIG_EDGE" "panel"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_SUPPORT_BRIEF_NOTIFICATION" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_CONFIG_EDGELIGHTING_FRAME_EFFECT" "frame_effect"

    #========== SCREEN RECORDER ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_SCREEN_RECORDER" "TRUE"

    #========== VOICE RECORDER ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_VOICERECORDER_CONFIG_DEF_MODE" "normal,interview,voicememo"

    #========== AUDIO ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_BT_RECORDING" "TRUE"

    #========== BATTERY ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_BATTERY_SUPPORT_BSOH_GALAXYDIAGNOSTICS" "TRUE"

    #========== SETTINGS ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SETTINGS_SUPPORT_DEFAULT_DOUBLE_TAP_TO_WAKE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SETTINGS_SUPPORT_FUNCTION_KEY_MENU" "TRUE"

    #========== SYSTEM ============#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEM_SUPPORT_ENHANCED_CPU_RESPONSIVENESS" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEM_SUPPORT_ENHANCED_PROCESSING" "TRUE"

    #========== LAUNCHER ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LAUNCHER_SUPPORT_CLOCK_LIVE_ICON" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LAUNCHER_CONFIG_ANIMATION_TYPE" "HighEnd"

    #========== DISPLAY ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LCD_SUPPORT_EXTRA_BRIGHTNESS" "TRUE"

    #========== AOD ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_FRAMEWORK_CONFIG_AOD_ITEM" "aodversion=7,clocktransition,coverboldfont"

    #========== CAMERA ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_SUPPORT_PRIVACY_TOGGLE" "TRUE"

    #========== GENAI ==========#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_IMAGE_CLIPPER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_OBJECT_ERASER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_REFLECTION_ERASER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_SHADOW_ERASER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_SMART_LASSO" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_SPOT_FIXER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_STYLE_TRANSFER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_TIME_WEATHER_WALLPAPER" "TRUE"

    #======= Extra Features ======#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_MULTIWINDOW" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_MULTIWINDOW_SMART_POPUP_VIEW" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LAUNCHER_SUPPORT_SMART_WIDGET" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GALLERY_SUPPORT_PHOTO_REMASTER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_ADAPT_SOUND" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GAMING_SUPPORT_GAMEBOOSTER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GAMING_SUPPORT_PRIORITY_MODE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LCD_SUPPORT_VISION_BOOSTER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_MEMORY_SUPPORT_RAM_PLUS" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_SUPPORT_QRCODE_SCANNER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_SUPPORT_DOCUMENT_SCAN" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_SCREEN_CAPTURE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_AOD_DOZE_SERVICE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LAUNCHER_SUPPORT_CALENDAR_LIVE_ICON" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_SECURE_WIFI" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_AI_WALLPAPER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_CLIPBOARD_EDGE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_SUPPORT_NOTIFICATION_HISTORY" "TRUE"

    #===================================================================#
    #                   ENABLE NOW BRIEF                                #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_CONFIG_AWESOME_INTELLIGENCE" "202501"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_CONFIG_AI_VERSION" "20263"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_AI_AGENT" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_CONFIG_SMART_SUGGESTION" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_PERSONALIZED_DATA_CORE" "TRUE"

    #===================================================================#
    #                   ONE UI 7 NOW BAR & LIVE NOTIFS                  #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_SUPPORT_NOW_BAR" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_SUPPORT_LIVE_NOTIFICATIONS" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_CONFIG_NOW_BRIEF" "TRUE"

    #===================================================================#
    #                 ADVANCED GALAXY AI & STUDIO EDITING               #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_DRAWING_ASSIST" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GALLERY_SUPPORT_AUDIO_ERASER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GALLERY_SUPPORT_PORTRAIT_STUDIO" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SIP_SUPPORT_WRITING_ASSIST" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SAMSUNGNOTES_SUPPORT_AI_FORMAT" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SIP_SUPPORT_LIVE_TRANSLATE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_CIRCLE_TO_SEARCH" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_VOICERECORDER_SUPPORT_SUMMARY" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_VOICERECORDER_SUPPORT_SPEAKER_DETERMINATION" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_INTERPRETER" "TRUE"

    #===================================================================#
    #                  LOCK SCREEN DEPTH & REAL-TIME BLUR               #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LOCKSCREEN_SUPPORT_WALLPAPER_DEPTH_EFFECT" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LOCKSCREEN_CONFIG_WALLPAPER_FRAME_EFFECT" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GRAPHICS_SUPPORT_REALTIME_BLUR" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GRAPHICS_SUPPORT_AOD_FULL_SCREEN" "TRUE"

    #===================================================================#
    #                OUTDOOR MODE & DISPLAY ENHANCEMENTS                #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LCD_SUPPORT_OUTDOOR_MODE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LCD_CONFIG_NATURAL_SCREEN_MODE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LCD_SUPPORT_WIDE_COLOR_GAMUT" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SETTINGS_SUPPORT_SCREEN_MODE_ADVANCED" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GALLERY_SUPPORT_SUPER_HDR" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SETTINGS_CONFIG_EXTRA_DIM" "TRUE"

    #===================================================================#
    #                      APP LOCK & SECURITY                          #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SETTINGS_SUPPORT_APP_LOCK" "TRUE"

    #===================================================================#
    #                   DEX, ECOSYSTEM & CONNECTIVITY                   #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_DEX" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_WIRELESS_DEX" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_CONTINUITY" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_QUICKSHARE_SUPPORT_UWB" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEM_SUPPORT_REALTIME_NETWORK_SPEED" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_WLAN_SUPPORT_WIFI_7" "TRUE"

    #===================================================================#
    #                     AUDIO & CALL ENHANCEMENTS                     #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_VOICE_FOCUS" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_DOLBY_ATMOS" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_DOLBY_GAME" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_AUDIO_SUPPORT_VOLUME_MONITOR" "TRUE"

    #===================================================================#
    #                 BATTERY, CHARGING & HARDWARE                      #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GAMING_SUPPORT_PAUSE_USB_POWER_DELIVERY" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_BATTERY_SUPPORT_PROTECT_BATTERY" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SETTINGS_SUPPORT_BATTERY_PROTECTION_MODES" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_AUTONOMIC_POWER_SAVING" "TRUE"

    #===================================================================#
    #                       CAMERA FLAGSHIP MODES                       #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_SUPPORT_PRO_VIDEO" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_SUPPORT_SINGLE_TAKE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_SUPPORT_SCENE_OPTIMIZER" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_SUPPORT_DIRECTOR_VIEW" "TRUE"

    #===================================================================#
    #                     GALAXY AI CORE & FRAMEWORK                    #
    #===================================================================#
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_COMMON_SUPPORT_GALAXY_AI" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_INTELLIGENCE_SUPPORT_AI" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_HONOR_SUPPORT_AI" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_INTELLIGENCE_SUPPORT_NOW_NUDGE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_INTELLIGENCE_SUPPORT_CONTEXTUAL_NUDGE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_INTELLIGENCE_SUPPORT_SMART_SUGGESTION" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_INTELLIGENCE_SUPPORT_PERSONAL_DATA" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_INTELLIGENCE_SUPPORT_SCREEN_ANALYSIS" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_INTELLIGENCE_SUPPORT_AUTOFILL_NUDGE" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_SUPPORT_FLOATING_NUDGE_BUTTON" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_SUPPORT_CONTEXT_SHORTCUT" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_MESSAGING_SUPPORT_CONTEXTUAL_REPLY" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_NOTIFICATION_SUPPORT_AI_NUDGE" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_VOICE_SUPPORT_LIVE_TRANSLATE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CALL_SUPPORT_VOICE_TRANSLATION" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SIP_SUPPORT_AI_TRANSLATION" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SIP_SUPPORT_AI_GRAMMAR" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SIP_SUPPORT_AI_TONE" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GALLERY_SUPPORT_GENERATIVE_EDIT" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GALLERY_SUPPORT_SKETCH_TO_IMAGE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_SUPPORT_AI_OBJECT_ERASER" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SNOTE_SUPPORT_INTELLIGENCE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SBROWSER_SUPPORT_AI_SUMMARIZE" "TRUE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SBROWSER_SUPPORT_AI_TRANSLATION" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_VOICERECORDER_SUPPORT_STT_SUMMARY" "TRUE"

    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_SYSTEMUI_SUPPORT_CIRCLE_TO_SEARCH" "TRUE"

    #========== MEDIATEK / EXTRA FLOATING FEATURES ==========#
    sed -i '/SEC_FLOATING_FEATURE_GRAPHICS_SUPPORT_3D_SURFACE_TRANSITION_FLAG/d' "$TARGET_ROM_FLOATING_FEATURE"
    sed -i '/SEC_FLOATING_FEATURE_GRAPHICS_SUPPORT_RELUMINO_EFFECT_FLAG/d' "$TARGET_ROM_FLOATING_FEATURE"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_MODE" "1"
    UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_LCD_SUPPORT_EXTRA_BRIGHTNESS" "TRUE"
}

###################################################################################################
# PART 4: CAMERA, BLUETOOTH, MEDIATEK PORTING, STOCK CONFIG, SECURITY & FLAGSHIP APPS
###################################################################################################

REMOVE_CAMERA_FILES() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local LIB_DIRS=(
        "${EXTRACTED_FIRM_DIR}/system/system/lib"
        "${EXTRACTED_FIRM_DIR}/system/system/lib64"
    )

    local ARCSOFT_LIBS_LIST="${EXTRACTED_FIRM_DIR}/system/system/etc/public.libraries-arcsoft.txt"
    local CAMERA_LIBS_LIST="${EXTRACTED_FIRM_DIR}/system/system/etc/public.libraries-camera.samsung.txt"

    echo "- Removing camera files."

    local arcsoft_files=()
    local camera_files=()

    [ -f "$ARCSOFT_LIBS_LIST" ] && mapfile -t arcsoft_files < "$ARCSOFT_LIBS_LIST"
    [ -f "$CAMERA_LIBS_LIST" ] && mapfile -t camera_files < "$CAMERA_LIBS_LIST"

    local LIB_FILES=("${arcsoft_files[@]}" "${camera_files[@]}")

    for folder in "${LIB_DIRS[@]}"; do
        for file_name in "${LIB_FILES[@]}"; do
            local target="$folder/$file_name"

            if [ -f "$target" ]; then
                rm -f "$target"
            fi
        done
    done

    rm -f "$ARCSOFT_LIBS_LIST"
    rm -f "$CAMERA_LIBS_LIST"

    rm -rf "${EXTRACTED_FIRM_DIR}/system/system/priv-app/SamsungCamera"
    rm -rf "${EXTRACTED_FIRM_DIR}/system/system/cameradata"
}


FIX_BLUETOOTH() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local BUILD_BRAND=$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "Build.BRAND")
    local ANDROID_VERSION=$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.system.build.version.release")
    local SDK="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.build.version.sdk_full")"

    if [[ -z "$SDK" ]]; then
        local SDK="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" ro.build.version.sdk)"
    fi

    if [ "$STOCK_DEVICE_CHIPSET" = "MediaTek" ] && [ "$BUILD_BRAND" != "MTK" ]; then
        echo "- Adding mediatek bluetooth apex."
        if [ -d "${QT_DIR}/QuantumROM/MTK_SPECIAL/${SDK}/BT_APEX/system/apex" ]; then
            rm -rf "${EXTRACTED_FIRM_DIR}"/system/system/apex/com.android.bt*.apex
            cp -rfa "${QT_DIR}/QuantumROM/MTK_SPECIAL/${SDK}/BT_APEX/system/." \
                "${EXTRACTED_FIRM_DIR}/system/system"
        fi
    fi
}


FIX_CAMERA() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local BUILD_BRAND=$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "Build.BRAND")
    local ANDROID_VERSION=$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.system.build.version.release")

    if [ "$STOCK_DEVICE_CHIPSET" = "MediaTek" ] && [ "$BUILD_BRAND" != "MTK" ]; then
        echo "- Adding mediatek camera related files."

        if [ ! -f "${QT_DIR}/QuantumROM/Mods/Apps/MTK_Camera_Files_Android_${ANDROID_VERSION}.zip" ]; then
            if curl -fsSL --connect-timeout 5 https://www.google.com >/dev/null; then
                if ! wget --no-check-certificate \
                    "https://github.com/SN-Abdullah-Al-Noman/Samsung_Special/releases/download/Android_${ANDROID_VERSION}/MTK_Camera_Files_Android_${ANDROID_VERSION}.zip" \
                    -O "${QT_DIR}/QuantumROM/Mods/Apps/MTK_Camera_Files_Android_${ANDROID_VERSION}.zip"; then
                    echo "Unable to download MTK_Camera_Files_Android_${ANDROID_VERSION}.zip. Skipping adding camera files."
                    return 0
                fi
            else
                echo "No internet connection available. Unable to download MTK_Camera_Files_Android_${ANDROID_VERSION}.zip."
                return 0
            fi
        fi

        if [ -s "${QT_DIR}/QuantumROM/Mods/Apps/MTK_Camera_Files_Android_${ANDROID_VERSION}.zip" ]; then
            rm -rf "${QT_DIR}/QuantumROM/Mods/Apps/MTK_Camera_Files_Android_${ANDROID_VERSION}"
            REMOVE_CAMERA_FILES "$EXTRACTED_FIRM_DIR"

            unzip -o \
                "${QT_DIR}/QuantumROM/Mods/Apps/MTK_Camera_Files_Android_${ANDROID_VERSION}.zip" \
                -d "${QT_DIR}/QuantumROM/Mods/Apps/MTK_Camera_Files_Android_${ANDROID_VERSION}" \
                >/dev/null 2>&1

            local FIRST_CAM_LINE="$(grep -n '^    <SEC_FLOATING_FEATURE_CAMERA' "${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml" | head -n 1 | cut -d: -f1)"
            sed -i '/^    <SEC_FLOATING_FEATURE_CAMERA/d' "${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml"
            sed -i "$((FIRST_CAM_LINE-1))r ${QT_DIR}/QuantumROM/Mods/Apps/MTK_Camera_Files_Android_${ANDROID_VERSION}/system/etc/floating_feature.xml" "${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml"
            rm -rf "${QT_DIR}/QuantumROM/Mods/Apps/MTK_Camera_Files_Android_${ANDROID_VERSION}/system/etc/floating_feature.xml"

            echo "- Copying A34 mediatek camera related files."
            cp -rfa "${QT_DIR}/QuantumROM/Mods/Apps/MTK_Camera_Files_Android_${ANDROID_VERSION}/system/." "${EXTRACTED_FIRM_DIR}/system/system"
        fi
    fi
}


ADD_JAR_TO_CLASSPATH() {
    local TARGET_FIRM_DIR="$1"
    local FILE_TYPE="$2"
    local SCOPE="$3"
    local JAR_PATH="$4"
    local MIN_API="${5:-}"
    local MAX_API="${6:-}"

    local PROTO_FILE="$QT_DIR/WORK/classpaths.proto"
    mkdir -p "$QT_DIR/WORK"

    cat << 'EOF' > "$PROTO_FILE"
syntax = "proto3";

enum Classpath {
  UNKNOWN = 0;
  BOOTCLASSPATH = 1;
  SYSTEMSERVERCLASSPATH = 2;
  DEX2OATBOOTCLASSPATH = 3;
  STANDALONE_SYSTEMSERVER_JARS = 4;
}

message Jar {
  string path = 1;
  Classpath classpath = 2;
  string min_sdk_version = 3;
  string max_sdk_version = 4;
}

message ExportedClasspathsJars {
  repeated Jar jars = 1;
}
EOF

    local FILE=""
    if [[ "$FILE_TYPE" == "bootclasspath" ]]; then
        FILE="$TARGET_FIRM_DIR/system/system/etc/classpaths/bootclasspath.pb"
    elif [[ "$FILE_TYPE" == "systemserverclasspath" ]]; then
        FILE="$TARGET_FIRM_DIR/system/system/etc/classpaths/systemserverclasspath.pb"
    else
        FILE="$FILE_TYPE"
    fi

    if [ ! -f "$FILE" ]; then
        echo "- Classpath pb file not found: $FILE"
        return 0
    fi

    if ! command -v protoc >/dev/null 2>&1; then
        echo "- Warning: protoc not installed, skipping $JAR_PATH injection"
        return 0
    fi

    local PB_DIR="$(dirname "$FILE")"
    local PB_NAME="$(basename "$FILE")"

    (
        cd "$PB_DIR"
        protoc --decode=ExportedClasspathsJars --proto_path="$(dirname "$PROTO_FILE")" "$(basename "$PROTO_FILE")" < "$PB_NAME" > "${PB_NAME}.txt"
        {
            echo "jars {"
            echo "  path: \"$JAR_PATH\""
            echo "  classpath: $SCOPE"
            [ -n "$MIN_API" ] && echo "  min_sdk_version: \"$MIN_API\""
            [ -n "$MAX_API" ] && echo "  max_sdk_version: \"$MAX_API\""
            echo "}"
        } >> "${PB_NAME}.txt"
        protoc --encode=ExportedClasspathsJars --proto_path="$(dirname "$PROTO_FILE")" "$(basename "$PROTO_FILE")" < "${PB_NAME}.txt" > "$PB_NAME"
        rm -f "${PB_NAME}.txt"
    )
}


APPLY_MEDIATEK_PORT_FILES() {
    echo " "
    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <STOCK_EXTRACTED_FIRM_DIR> <TARGET_EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local STOCK_DIR="$1"
    local TARGET_DIR="$2"

    if [ ! -d "$STOCK_DIR/system/system" ] || [ ! -d "$TARGET_DIR/system/system" ]; then
        echo "- Stock or Target firmware directory not extracted properly. Skipping direct MTK port sync."
        return 0
    fi

    echo "=========================================================="
    echo "  Porting MediaTek (SM-A346E) Blobs & Props to Target ROM"
    echo "=========================================================="

    local TARGET_SYS_EXT="$(GET_SYSTEM_EXT_DIR "$TARGET_DIR")"
    local STOCK_SYS_EXT="$(GET_SYSTEM_EXT_DIR "$STOCK_DIR")"

    # 1. Backup Target (S711B) VEX & Camera Libraries before replacing system/lib*
    local BACKUP_LIBS_DIR="$QT_DIR/WORK/target_camera_vex_backup"
    rm -rf "$BACKUP_LIBS_DIR"
    mkdir -p "$BACKUP_LIBS_DIR"

    local VEX_AND_CAM_LIBS=(
        "system/lib64/libandroid.vexfwk.samsung.so"
        "system/lib64/libcommon-jni.vexfwk.samsung.so"
        "system/lib64/libimgproc.vexfwk.samsung.so"
        "system/lib64/libmetadata.vexfwk.samsung.so"
        "system/lib64/libndk.vexfwk.samsung.so"
        "system/lib64/libruntime.vexfwk.samsung.so"
        "system/lib64/libsdk-v2-jni.vexfwk.samsung.so"
        "system/lib64/vexfwk_service_aidl-ndk.so"
        "system/lib/libandroid.vexfwk.samsung.so"
        "system/lib/libcommon-jni.vexfwk.samsung.so"
        "system/lib/libimgproc.vexfwk.samsung.so"
        "system/lib/libmetadata.vexfwk.samsung.so"
        "system/lib/libndk.vexfwk.samsung.so"
        "system/lib/libruntime.vexfwk.samsung.so"
        "system/lib/libsdk-v2-jni.vexfwk.samsung.so"
        "system/lib/vexfwk_service_aidl-ndk.so"
        "system/lib64/libsec_camerax_util_jni.camera.samsung.so"
        "system/lib/libsec_camerax_util_jni.camera.samsung.so"
        "system/lib64/libVideoClassifier.camera.samsung.so"
        "system/lib64/libImageTagger.camera.samsung.so"
        "system/lib64/libsaiv_HprFace_cmh_support_jni.camera.samsung.so"
        "system/lib64/libFace_Landmark_Engine.camera.samsung.so"
        "system/lib64/libHpr_RecFace_dl_v1.0.camera.samsung.so"
        "system/lib64/libStride.camera.samsung.so"
        "system/lib64/libStrideTensorflowLite.camera.samsung.so"
        "system/lib64/extractors/libsapeextractor.so"
        "system/lib64/extractors/libsdffextractor.so"
        "system/lib64/extractors/libsdsfextractor.so"
        "system/lib64/libscalenetpkg.so"
        "system/lib64/libSceneDetector_v1.camera.samsung.so"
        "system/lib64/libimage_enhancement.arcsoft.so"
        "system/lib64/libdualcam_portraitlighting_gallery_360.so"
        "system/lib64/libtensorflowLite.camera.samsung.so"
        "system/lib64/libMyFilter.camera.samsung.so"
        "system/lib64/libtensorflowlite_inference_api.camera.samsung.so"
        "system/lib64/libtensorflowLite2_11_0_dynamic_camera.so"
        "system/lib64/libLttEngine.camera.samsung.so"
        "system/lib64/libAuraRenderer.graphics.samsung.so"
        "system/lib64/libDocShadowRemoval.arcsoft.so"
        "system/lib64/libDeepDocRectify.camera.samsung.so"
        "system/lib64/libImageSegmenter_v1.camera.samsung.so"
        "system/lib64/libstartrail.camera.samsung.so"
        "system/lib64/libdvs.camera.samsung.so"
        "system/lib64/libPetClustering.camera.samsung.so"
        "system/lib64/lib_pet_detection.arcsoft.so"
        "system/lib64/libRelighting_API.camera.samsung.so"
        "system/lib64/libBestPhoto.camera.samsung.so"
        "system/lib64/libae_bracket_hdr.arcsoft.so"
        "system/lib64/libAEBHDR_wrapper.camera.samsung.so"
        "system/lib64/libDualCamBokehCapture.camera.samsung.so"
        "system/lib64/libarcsoft_dualcam_portraitlighting.so"
        "system/lib64/libarcsoft_single_cam_glasses_seg.so"
        "system/lib64/libarcsoft_superresolution_bokeh.so"
        "system/lib64/libdualcam_refocus_image.so"
        "system/lib64/libhigh_dynamic_range_bokeh.so"
        "system/lib64/libhighres_enhancement.arcsoft.so"
        "system/lib64/libHREnhancementAPI.camera.samsung.so"
        "system/lib64/libFaceRecognition.arcsoft.so"
        "system/lib64/libfrtracking_engine.arcsoft.so"
        "system/lib64/libMPISingleRGB40.camera.samsung.so"
        "system/lib64/libMPISingleRGB40Tuning.camera.samsung.so"
        "system/lib64/libAIQSolution_MPISingleRGB40.camera.samsung.so"
        "system/lib64/libAIQSolution_MPI.camera.samsung.so"
        "system/lib64/libLocalTM_pcc.camera.samsung.so"
        "system/lib64/libObjectDetector_v1.camera.samsung.so"
        "system/lib64/libsuperresolution_raw.arcsoft.so"
        "system/lib64/libsuperresolutionraw_wrapper_v2.camera.samsung.so"
    )

    for rel_lib in "${VEX_AND_CAM_LIBS[@]}"; do
        if [ -f "$TARGET_DIR/system/$rel_lib" ]; then
            mkdir -p "$(dirname "$BACKUP_LIBS_DIR/$rel_lib")"
            cp -af "$TARGET_DIR/system/$rel_lib" "$BACKUP_LIBS_DIR/$rel_lib"
        fi
    done

    # 2. Patch system_ext from Stock (SM-A346E)
    if [ -n "$STOCK_SYS_EXT" ] && [ -n "$TARGET_SYS_EXT" ]; then
        echo "- Patching system_ext with SM-A346E binaries, frameworks, and configs..."
        for sub in bin lib lib64 etc/init etc/selinux; do
            rm -rf "$TARGET_SYS_EXT/$sub"
            [ -d "$STOCK_SYS_EXT/$sub" ] && cp -a "$STOCK_SYS_EXT/$sub" "$TARGET_SYS_EXT/$sub"
        done

        [ -d "$STOCK_SYS_EXT/usp" ] && cp -a "$STOCK_SYS_EXT/usp" "$TARGET_SYS_EXT/"

        mkdir -p "$TARGET_SYS_EXT/framework"
        for jar in mediatek-common.jar mediatek-ims-base.jar mediatek-framework.jar CustomPropInterface.jar DataChannelApi.jar duraspeed.jar log-handler.jar; do
            [ -f "$STOCK_SYS_EXT/framework/$jar" ] && cp -af "$STOCK_SYS_EXT/framework/$jar" "$TARGET_SYS_EXT/framework/"
        done

        local FTP_SYS_EXT=(
            "a2dp_audio_policy_configuration.xml" "a2dp_in_audio_policy_configuration.xml"
            "aee-commit" "aee-config" "audio_policy_configuration_bluetooth_legacy_hal.xml"
            "audio_policy_configuration_stub.xml" "audio_policy_configuration.xml"
            "audio_policy_engine_configuration.xml" "audio_policy_engine_default_stream_volumes.xml"
            "audio_policy_engine_product_strategies.xml" "audio_policy_engine_stream_volumes.xml"
            "audio_policy_volumes.xml" "bluetooth_audio_policy_configuration.xml" "custom.conf"
            "default_volume_tables.xml" "hearing_aid_audio_policy_configuration.xml"
            "mtklog-config.prop" "nr-city.xml" "r_submix_audio_policy_configuration.xml"
            "spn-conf.xml" "usb_audio_policy_configuration.xml"
        )
        for f in "${FTP_SYS_EXT[@]}"; do
            [ -f "$STOCK_SYS_EXT/etc/$f" ] && cp -af "$STOCK_SYS_EXT/etc/$f" "$TARGET_SYS_EXT/etc/"
        done
    fi

    # 3. Add MediaTek Jars to bootclasspath.pb
    echo "- Adding MediaTek jars to bootclasspath.pb..."
    ADD_JAR_TO_CLASSPATH "$TARGET_DIR" "bootclasspath" "BOOTCLASSPATH" "/system_ext/framework/mediatek-common.jar"
    ADD_JAR_TO_CLASSPATH "$TARGET_DIR" "bootclasspath" "DEX2OATBOOTCLASSPATH" "/system_ext/framework/mediatek-common.jar"
    ADD_JAR_TO_CLASSPATH "$TARGET_DIR" "bootclasspath" "BOOTCLASSPATH" "/system_ext/framework/mediatek-framework.jar"
    ADD_JAR_TO_CLASSPATH "$TARGET_DIR" "bootclasspath" "DEX2OATBOOTCLASSPATH" "/system_ext/framework/mediatek-framework.jar"
    ADD_JAR_TO_CLASSPATH "$TARGET_DIR" "bootclasspath" "BOOTCLASSPATH" "/system_ext/framework/mediatek-ims-base.jar"
    ADD_JAR_TO_CLASSPATH "$TARGET_DIR" "bootclasspath" "DEX2OATBOOTCLASSPATH" "/system_ext/framework/mediatek-ims-base.jar"

    # 4. Patch system from Stock (SM-A346E)
    echo "- Patching system with SM-A346E bin, lib, lib64, init, vintf, and configs..."
    for sub in etc/init etc/vintf bin lib lib64; do
        rm -rf "$TARGET_DIR/system/system/$sub"
        [ -d "$STOCK_DIR/system/system/$sub" ] && cp -a "$STOCK_DIR/system/system/$sub" "$TARGET_DIR/system/system/$sub"
    done

    local SYS_ETC_FILES=(
        "public.libraries-mtk.txt" "public.libraries-trustonic.txt"
        "public.libraries-camera.samsung.txt" "public.libraries-arcsoft.txt"
        "permissions/verizon_net_sip_library.xml" "resolution_tuner_app_list.xml"
        "open_msync_app_list.xml" "msync_ctrl_table.xml" "audio_effects.conf"
        "ams_aal_config.xml" "TelephonyLog_dynamic.ds"
    )
    for f in "${SYS_ETC_FILES[@]}"; do
        if [ -f "$STOCK_DIR/system/system/etc/$f" ]; then
            mkdir -p "$(dirname "$TARGET_DIR/system/system/etc/$f")"
            cp -af "$STOCK_DIR/system/system/etc/$f" "$TARGET_DIR/system/system/etc/$f"
        fi
    done

    for jar in verizon.net.sip.jar msync-lib.jar; do
        [ -f "$STOCK_DIR/system/system/framework/$jar" ] && cp -af "$STOCK_DIR/system/system/framework/$jar" "$TARGET_DIR/system/system/framework/"
    done

    # 5. Restore Target VEX & Camera libs and update public.libraries*.txt
    cp -rfa "$BACKUP_LIBS_DIR/." "$TARGET_DIR/system/"
    rm -rf "$BACKUP_LIBS_DIR"

    rm -f "$TARGET_DIR/system/system/lib64/libtensorflowLite.myfilter.camera.samsung.so" \
          "$TARGET_DIR/system/system/lib64/libtensorflowlite_inference_api.myfilter.camera.samsung.so" \
          "$TARGET_DIR/system/system/lib64/libdualcam_portraitlighting_gallery_360_lite.so" \
          "$TARGET_DIR/system/system/etc/public.libraries-edensdk.samsung.txt"
    rm -rf "$TARGET_DIR/system/system/app/WifiRROverlayAppLls"

    {
        echo "libsec_camerax_util_jni.camera.samsung.so"
        echo "libtensorflowLite.camera.samsung.so"
        echo "libtensorflowlite_inference_api.camera.samsung.so"
        echo "libLttEngine.camera.samsung.so"
        echo "libBestPhoto.camera.samsung.so"
        echo "libVideoClassifier.camera.samsung.so"
        echo "libstartrail.camera.samsung.so"
        echo "libObjectDetector_v1.camera.samsung.so"
        echo "libPetClustering.camera.samsung.so"
        echo "libImageSegmenter_v1.camera.samsung.so"
        echo "libSceneDetector_v1.camera.samsung.so"
        echo "libAEBHDR_wrapper.camera.samsung.so"
        echo "libDualCamBokehCapture.camera.samsung.so"
        echo "libHREnhancementAPI.camera.samsung.so"
        echo "libhybridHDR_wrapper.camera.samsung.so"
        echo "libAIQSolution_MPISingleRGB40.camera.samsung.so"
        echo "libMPISingleRGB40.camera.samsung.so"
        echo "libAIQSolution_MPI.camera.samsung.so"
        echo "libSwIsp_wrapper_v1.camera.samsung.so"
        echo "libMultiFrameProcessing30.camera.samsung.so"
        echo "libLocalTM_pcc.camera.samsung.so"
        echo "libsuperresolutionraw_wrapper_v2.camera.samsung.so"
        echo "libdvs.camera.samsung.so"
        echo "libsaiv_HprFace_cmh_support_jni.camera.samsung.so"
        echo "libHpr_RecFace_dl_v1.0.camera.samsung.so"
        echo "libFace_Landmark_Engine.camera.samsung.so"
    } >> "$TARGET_DIR/system/system/etc/public.libraries-camera.samsung.txt"
    sort -u "$TARGET_DIR/system/system/etc/public.libraries-camera.samsung.txt" -o "$TARGET_DIR/system/system/etc/public.libraries-camera.samsung.txt"

    {
        echo "lib_pet_detection.arcsoft.so"
        echo "libae_bracket_hdr.arcsoft.so"
        echo "libhybrid_high_dynamic_range.arcsoft.so"
        echo "libimage_enhancement.arcsoft.so"
        echo "libfrtracking_engine.arcsoft.so"
        echo "libFaceRecognition.arcsoft.so"
        echo "libsuperresolution_raw.arcsoft.so"
    } >> "$TARGET_DIR/system/system/etc/public.libraries-arcsoft.txt"
    sort -u "$TARGET_DIR/system/system/etc/public.libraries-arcsoft.txt" -o "$TARGET_DIR/system/system/etc/public.libraries-arcsoft.txt"

    # 6. Replace Google Hotword CORTEXM55 blobs with RISCV blobs from Stock A346E
    rm -rf "$TARGET_DIR/product/priv-app/HotwordEnrollmentOKGoogleEx4CORTEXM55" \
           "$TARGET_DIR/product/priv-app/HotwordEnrollmentXGoogleEx4CORTEXM55"
    if [ -d "$STOCK_DIR/product/priv-app/HotwordEnrollmentOKGoogleEx4RISCV" ]; then
        cp -a "$STOCK_DIR/product/priv-app/HotwordEnrollmentOKGoogleEx4RISCV" "$TARGET_DIR/product/priv-app/"
    fi
    if [ -d "$STOCK_DIR/product/priv-app/HotwordEnrollmentXGoogleEx4RISCV" ]; then
        cp -a "$STOCK_DIR/product/priv-app/HotwordEnrollmentXGoogleEx4RISCV" "$TARGET_DIR/product/priv-app/"
    fi

    # 7. Apply MediaTek, Audio, RIL, SurfaceFlinger & Photo Remaster Properties
    sed -i '/^media.extractor.sec.pcm-32bit=/d' "$TARGET_DIR/system/system/build.prop" 2>/dev/null || true

    local DOLBY_VER="$(GET_PROP "$STOCK_DIR" "system" "media.extractor.sec.dolby-lib-version")"
    local MTK_BRANCH="$(GET_PROP "$STOCK_DIR" "system" "ro.mediatek.version.branch")"
    local MTK_RELEASE="$(GET_PROP "$STOCK_DIR" "system" "ro.mediatek.version.release")"

    [ -n "$DOLBY_VER" ] && BUILD_PROP "$TARGET_DIR" "system" "media.extractor.sec.dolby-lib-version" "$DOLBY_VER"
    [ -n "$MTK_BRANCH" ] && BUILD_PROP "$TARGET_DIR" "system" "ro.mediatek.version.branch" "$MTK_BRANCH"
    [ -n "$MTK_RELEASE" ] && BUILD_PROP "$TARGET_DIR" "system" "ro.mediatek.version.release" "$MTK_RELEASE"

    # Photo Remaster Fix for Galaxy A34 5G (a34x)
    BUILD_PROP "$TARGET_DIR" "system" "ro.midas.device" "a34x"

    # system_ext.prop & system.prop MediaTek entries
    BUILD_PROP "$TARGET_DIR" "system_ext" "ro.audio.ihaladaptervendorextension_enabled" "true"
    BUILD_PROP "$TARGET_DIR" "system" "Build.BRAND" "MTK"
    BUILD_PROP "$TARGET_DIR" "system" "ro.base_build" "noah"
    BUILD_PROP "$TARGET_DIR" "system" "ro.audio.ihaladaptervendorextension_enabled" "true"
    BUILD_PROP "$TARGET_DIR" "system" "ro.audio.usb.period_us" "16000"
    BUILD_PROP "$TARGET_DIR" "system" "vendor.af.threshold.src_and_effect_count" "5"
    BUILD_PROP "$TARGET_DIR" "system" "vendor.af.pausewait.enable" "false"
    BUILD_PROP "$TARGET_DIR" "system" "vendor.af.dynamic.sleeptime.enable" "true"
    BUILD_PROP "$TARGET_DIR" "system" "ro.audio.flinger_standbytime_ms" "1000"
    BUILD_PROP "$TARGET_DIR" "system" "persist.audio.deepbuffer_delay" "0"
    BUILD_PROP "$TARGET_DIR" "system" "ro.camera.sound.forced" "0"
    BUILD_PROP "$TARGET_DIR" "system" "ro.audio.silent" "0"
    BUILD_PROP "$TARGET_DIR" "system" "debug.sf.enable_gl_backpressure" "0"
    BUILD_PROP "$TARGET_DIR" "system" "debug.sf.treat_170m_as_sRGB" "1"
    BUILD_PROP "$TARGET_DIR" "system" "debug.sf.predict_hwc_composition_strategy" "0"
    BUILD_PROP "$TARGET_DIR" "system" "debug.sf.enable_transaction_tracing" "false"
    BUILD_PROP "$TARGET_DIR" "system" "ro.vendor.have_aee_feature" "1"
    BUILD_PROP "$TARGET_DIR" "system" "vendor.rild.libpath" "mtk-ril.so"
    BUILD_PROP "$TARGET_DIR" "system" "vendor.rild.libargs" "-d /dev/ttyC0"
    BUILD_PROP "$TARGET_DIR" "system" "wifi.interface" "wlan0"
    BUILD_PROP "$TARGET_DIR" "system" "ro.mediatek.wlan.wsc" "1"
    BUILD_PROP "$TARGET_DIR" "system" "ro.mediatek.wlan.p2p" "1"
    BUILD_PROP "$TARGET_DIR" "system" "mediatek.wlan.ctia" "0"
    BUILD_PROP "$TARGET_DIR" "system" "persist.mtk_telecom_max_ringingcall_number" "1"
    BUILD_PROP "$TARGET_DIR" "system" "persist.vendor.pco5.radio.ctrl" "0"
    BUILD_PROP "$TARGET_DIR" "system" "wifi.direct.interface" "p2p0"
    BUILD_PROP "$TARGET_DIR" "system" "ro.vendor.mtk_telephony_add_on_policy" "0"
    BUILD_PROP "$TARGET_DIR" "system" "persist.vendor.wfc.sys_wfc_support" "1"
    BUILD_PROP "$TARGET_DIR" "system" "ro.vendor.customer_logpath" "/data"
    BUILD_PROP "$TARGET_DIR" "system" "wifi.tethering.interface" "ap0"
    BUILD_PROP "$TARGET_DIR" "system" "persist.vendor.vzw_device_type" "0"
    BUILD_PROP "$TARGET_DIR" "system" "ro.vendor.mtk_omacp_support" "1"
    BUILD_PROP "$TARGET_DIR" "system" "persist.vendor.mtk.vilte.enable" "1"
    BUILD_PROP "$TARGET_DIR" "system" "persist.vendor.vilte_support" "1"
    BUILD_PROP "$TARGET_DIR" "system" "persist.vendor.pms_removable" "1"
    BUILD_PROP "$TARGET_DIR" "system" "media.stagefright.thumbnail.prefer_hw_codecs" "true"
    BUILD_PROP "$TARGET_DIR" "system" "vendor.mtk_thumbnail_optimization" "true"
    BUILD_PROP "$TARGET_DIR" "system" "ro.vendor.mtk_flv_playback_support" "1"
    BUILD_PROP "$TARGET_DIR" "system" "debug.stagefright.c2inputsurface" "-1"
    BUILD_PROP "$TARGET_DIR" "system" "ro.mtk_perf_simple_start_win" "1"
    BUILD_PROP "$TARGET_DIR" "system" "ro.mtk_perf_fast_start_win" "1"
    BUILD_PROP "$TARGET_DIR" "system" "ro.mtk_perf_response_time" "1"
    BUILD_PROP "$TARGET_DIR" "system" "ro.sys.usb.mtp.whql.enable" "0"
    BUILD_PROP "$TARGET_DIR" "system" "ro.sys.usb.storage.type" "mtp"
    BUILD_PROP "$TARGET_DIR" "system" "ro.sys.usb.bicr" "no"
    BUILD_PROP "$TARGET_DIR" "system" "ro.sys.usb.charging.only" "yes"
    BUILD_PROP "$TARGET_DIR" "system" "persist.sys.fuse.passthrough.enable" "true"
    BUILD_PROP "$TARGET_DIR" "system" "ro.iorapd.enable" "false"
    BUILD_PROP "$TARGET_DIR" "system" "ro.property_service.async_persist_writes" "true"
    BUILD_PROP "$TARGET_DIR" "system" "persist.vendor.mdlog.flush_log_ratio" "0"
    BUILD_PROP "$TARGET_DIR" "system" "ro.opengles.version" "196610"
    BUILD_PROP "$TARGET_DIR" "system" "ro.zygote.preload.enable" "0"
    BUILD_PROP "$TARGET_DIR" "system" "qemu.hw.mainkeys" "0"
    BUILD_PROP "$TARGET_DIR" "system" "ro.kernel.zio" "38,108,105,16"
    BUILD_PROP "$TARGET_DIR" "system" "sys.ipo.pwrdncap" "2"
    BUILD_PROP "$TARGET_DIR" "system" "sys.ipo.disable" "1"
    BUILD_PROP "$TARGET_DIR" "system" "ro.surface_flinger.use_content_detection_for_refresh_rate" "false"
    BUILD_PROP "$TARGET_DIR" "system" "ro.surface_flinger.enable_frame_rate_override" "false"

    # (Add inside APPLY_MEDIATEK_PORT_FILES right after step 6 Hotword blobs):

    # 6b. Copy Stock MediaTek Bluetooth APEX from SM-A346E
    if ls "$STOCK_DIR"/system/system/apex/com.android.bt*.apex >/dev/null 2>&1; then
        echo "- Copying SM-A346E MediaTek Bluetooth APEX..."
        rm -rf "$TARGET_DIR"/system/system/apex/com.android.bt*.apex
        cp -af "$STOCK_DIR"/system/system/apex/com.android.bt*.apex "$TARGET_DIR/system/system/apex/"
    fi

    # 6c. Merge SM-A346E fs_config and file_contexts for system and system_ext
    mkdir -p "$TARGET_DIR/config"
    for cfg in system_fs_config system_file_contexts system_ext_fs_config system_ext_file_contexts; do
        if [ -f "$STOCK_DIR/config/$cfg" ]; then
            cat "$STOCK_DIR/config/$cfg" >> "$TARGET_DIR/config/$cfg"
            sort -u "$TARGET_DIR/config/$cfg" -o "$TARGET_DIR/config/$cfg"
        fi
    done
}


APPLY_STOCK_CONFIG() {
    echo " "
    if [ "$#" -lt 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <STOCK_DEVICE> <EXTRACTED_FIRM_DIR> [STOCK_EXTRACTED_FIRM_DIR]"
        return 1
    fi

    local STOCK_DEVICE="$1"
    local EXTRACTED_FIRM_DIR="$2"
    local STOCK_EXTRACTED_DIR="${3:-$STOCK_FIRM_DIR}"

    echo -e "Applying $STOCK_DEVICE device config."

    local SDK="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.build.version.sdk_full")"

    if [[ -z "$SDK" ]]; then
        local SDK="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" ro.build.version.sdk)"
    fi

    if [ -f "${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml" ]; then
        local TARGET_ROM_FLOATING_FEATURE="${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml"
    elif [ -f "${EXTRACTED_FIRM_DIR}/vendor/etc/floating_feature.xml" ]; then
        local TARGET_ROM_FLOATING_FEATURE="${EXTRACTED_FIRM_DIR}/vendor/etc/floating_feature.xml"
    else
        echo "- Error: floating_feature.xml not found!"
        return 1
    fi

    if GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.system.product.cpu.abilist" >/dev/null 2>&1; then
        local TARGET_ROM_CPU_ABILIST="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.system.product.cpu.abilist")"
    elif GET_PROP "$EXTRACTED_FIRM_DIR" "product" "ro.product.cpu.abilist" >/dev/null 2>&1; then
        local TARGET_ROM_CPU_ABILIST="$(GET_PROP "$EXTRACTED_FIRM_DIR" "product" "ro.product.cpu.abilist")"
    else
        echo "- CPU abilist property not found!"
        return 1
    fi

    if [ -z "$STOCK_DEVICE" ] || [ "$STOCK_DEVICE" = "None" ]; then
        echo -e "- No target device is set. Just modifying ROM without any device config."
        return 0
    fi

    if [ ! -d "${EXTRACTED_FIRM_DIR}/system/system" ]; then
        echo -e "- No usable extracted firmware found"
        return 1
    fi

    if [ -f "${DEVICES_DIR}/$STOCK_DEVICE/config" ]; then
        echo -e "$STOCK_DEVICE config found."
        export STOCK_VNDK_VERSION="$(grep -m1 '^STOCK_VNDK_VERSION=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
        export STOCK_DUAL_VNDKS="$(grep -m1 '^STOCK_DUAL_VNDKS=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
        export STOCK_HAS_SEPARATE_SYSTEM_EXT="$(grep -m1 '^STOCK_HAS_SEPARATE_SYSTEM_EXT=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
        export STOCK_DEVICE_CPU_ABILIST="$(grep -m1 '^STOCK_DEVICE_CPU_ABILIST=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
        export STOCK_DEVICE_CHIPSET="$(grep -m1 '^STOCK_DEVICE_CHIPSET=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
        export USE_ALT_SDHMS_APP="$(grep -m1 '^USE_ALT_SDHMS_APP=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
        export STOCK_HAS_ESIM_SUPPORT="$(grep -m1 '^STOCK_HAS_ESIM_SUPPORT=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
        export SDHMS_MAX_SUPPORTED_OS_SDK="$(grep -m1 '^SDHMS_MAX_SUPPORTED_OS_SDK=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
        export STOCK_DVFS_FILENAME="$(grep -m1 '^STOCK_DVFS_FILENAME=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
        export STOCK_SIOP_POLICY_FILENAME="$(grep -m1 '^STOCK_SIOP_POLICY_FILENAME=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
    else
        echo -e "- Using default SM-A346E MediaTek config fallback."
        export STOCK_VNDK_VERSION="33"
        export STOCK_HAS_SEPARATE_SYSTEM_EXT="TRUE"
        export STOCK_DEVICE_CHIPSET="MediaTek"
        export STOCK_HAS_ESIM_SUPPORT="FALSE"
        export STOCK_DVFS_FILENAME="dvfs_policy_mt6877_xx"
        export STOCK_SIOP_POLICY_FILENAME="siop_a34x_mt6877"
    fi

    echo "Stock device vndk version: $STOCK_VNDK_VERSION"
    if [ -f "${DEVICES_DIR}/$STOCK_DEVICE/floating_feature.xml" ]; then
        export STOCK_ROM_FLOATING_FEATURE="${DEVICES_DIR}/$STOCK_DEVICE/floating_feature.xml"
    elif [ -n "$STOCK_EXTRACTED_DIR" ] && [ -f "$STOCK_EXTRACTED_DIR/system/system/etc/floating_feature.xml" ]; then
        export STOCK_ROM_FLOATING_FEATURE="$STOCK_EXTRACTED_DIR/system/system/etc/floating_feature.xml"
    fi

    # Remove ESIM files if stock device does not support.
    if [ "$STOCK_HAS_ESIM_SUPPORT" = "FALSE" ]; then
        REMOVE_ESIM_FILES "$EXTRACTED_FIRM_DIR"
    fi

    # ADJUST SYSTEM_EXT PARTITION.
    ADJUST_SYSTEM_EXT "$EXTRACTED_FIRM_DIR"

    # If extracted Stock Firmware (SM-A346E) exists, sync MediaTek port files directly
    if [ -n "$STOCK_EXTRACTED_DIR" ] && [ -d "$STOCK_EXTRACTED_DIR/system/system" ]; then
        APPLY_MEDIATEK_PORT_FILES "$STOCK_EXTRACTED_DIR" "$EXTRACTED_FIRM_DIR"
    fi

    # FIX VNDK.
    FIX_VNDK "$EXTRACTED_FIRM_DIR"

    # FIX CAMERA & BLUETOOTH IF NEEDED
    FIX_CAMERA "$EXTRACTED_FIRM_DIR"
    FIX_BLUETOOTH "$EXTRACTED_FIRM_DIR"

    # Fix samsung device health manager service
    if [ "$USE_ALT_SDHMS_APP" = "TRUE" ]; then
        if [ -n "$SDHMS_MAX_SUPPORTED_OS_SDK" ] && [ "$(echo "$SDK > $SDHMS_MAX_SUPPORTED_OS_SDK" | bc -l)" -eq 1 ]; then
            UPDATE_SDHMS "$EXTRACTED_FIRM_DIR"
        fi
    fi

    # Apply stock floating feature.
    if [ -f "$STOCK_ROM_FLOATING_FEATURE" ]; then
        APPLY_STOCK_ROM_FLOATING_FEATURE "$STOCK_ROM_FLOATING_FEATURE" "$TARGET_ROM_FLOATING_FEATURE"
    fi

    # Fix unsupported BPF error for kernels lower than 5.10.
    if [ "$USE_UI_8_TETHERING_APEX" = "True" ]; then
        cp -rfa "${QT_DIR}/QuantumROM/Mods/Tethering_Apex/UI-8/." "${EXTRACTED_FIRM_DIR}/"
    fi

    if [ "$STOCK_DEVICE_TYPE" = "jdm" ]; then
        APPLY_JDM_SPECIAL "$EXTRACTED_FIRM_DIR"
    else
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/cameradata/portrait_data"
    fi

    rm -rf "${EXTRACTED_FIRM_DIR}/system/system/etc/init"/rscmgr*.rc
    find "${EXTRACTED_FIRM_DIR}/system/system/media" -maxdepth 1 -type f \( -iname "*.spi" -o -iname "*.qmg" -o -iname "*.txt" \) -delete
    rm -rf "$EXTRACTED_FIRM_DIR"/product/overlay/framework-res*auto_generated_rro_product.apk
    rm -rf "${EXTRACTED_FIRM_DIR}"/product/overlay/SystemUI*auto_generated_rro_product.apk
    rm -rf "${EXTRACTED_FIRM_DIR}"/product/overlay/TeleService*auto_generated_rro_product.apk

    if [ -d "${DEVICES_DIR}/$STOCK_DEVICE/Stock" ]; then
        cp -a "${DEVICES_DIR}/$STOCK_DEVICE/Stock/." "${EXTRACTED_FIRM_DIR}/"
    fi

    if [ -d "${DEVICES_DIR}/${STOCK_DEVICE}/extra" ]; then
        cp -af "${DEVICES_DIR}/${STOCK_DEVICE}/extra/." "${QT_DIR}/OUT"
    fi

    BUILD_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.product.system.model" "$STOCK_DEVICE"
}


BUILD_PROP() {
    if [ "$#" -lt 3 ]; then
        echo -e "Usage: BUILD_PROP <EXTRACTED_FIRM_DIR> <PARTITION> <KEY> [VALUE]"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local PARTITION="$2"
    local KEY="$3"
    local VALUE="${4-}"

    local FILE=""

    case "$PARTITION" in
        system)
            local FILE="${EXTRACTED_FIRM_DIR}/system/system/build.prop"
            ;;
        vendor)
            local FILE="${EXTRACTED_FIRM_DIR}/vendor/build.prop"
            ;;
        product)
            local FILE="${EXTRACTED_FIRM_DIR}/product/etc/build.prop"
            ;;
        system_ext)
            local TARGET_SYS_EXT="$(GET_SYSTEM_EXT_DIR "$EXTRACTED_FIRM_DIR")"
            local FILE="${TARGET_SYS_EXT}/etc/build.prop"
            ;;
        odm)
            local FILE="${EXTRACTED_FIRM_DIR}/odm/etc/build.prop"
            ;;
        *)
            echo -e "Unknown partition: $PARTITION"
            return 0
            ;;
    esac

    if [ ! -f "$FILE" ]; then
        echo -e "- File not found: $FILE"
        return 0
    fi

    if grep -q "^${KEY}=" "$FILE"; then
        if [ -z "$VALUE" ]; then
            sed -i "s|^${KEY}=.*|${KEY}=|" "$FILE"
        else
            sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" "$FILE"
        fi
    else
        if [ -z "$VALUE" ]; then
            echo -e "${KEY}=" >> "$FILE"
        else
            echo -e "${KEY}=${VALUE}" >> "$FILE"
        fi
    fi
}


REMOVE_TLC_ICC() {
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    if [ -d "${EXTRACTED_FIRM_DIR}/vendor" ]; then
        rm -f \
        "${EXTRACTED_FIRM_DIR}/vendor/bin/hw/vendor.samsung.hardware.tlc.iccc@1.0-service" \
        "${EXTRACTED_FIRM_DIR}/vendor/etc/init/vendor.samsung.hardware.tlc.iccc@1.0-service.rc" \
        "${EXTRACTED_FIRM_DIR}/vendor/etc/vintf/manifest/vendor.samsung.hardware.tlc.iccc@1.0-manifest.xml" \
        "${EXTRACTED_FIRM_DIR}/vendor/lib64/vendor.samsung.hardware.tlc.iccc@1.0-impl.so" \
        "${EXTRACTED_FIRM_DIR}/vendor/lib64/vendor.samsung.hardware.tlc.iccc@1.0.so"
    fi
}


DISABLE_SECURITY() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo -e "Disabling security related things."

    if [ -f "${EXTRACTED_FIRM_DIR}/product/etc/build.prop" ]; then
        echo "- Disabling factory reset protection from product."
        BUILD_PROP "$EXTRACTED_FIRM_DIR" "product" "ro.frp.pst" ""
    fi

    if [ -f "${EXTRACTED_FIRM_DIR}/vendor/build.prop" ]; then
        echo "- Disabling factory reset protection from vendor."
        BUILD_PROP "$EXTRACTED_FIRM_DIR" "vendor" "ro.frp.pst" ""
    fi

    if [ -f "${EXTRACTED_FIRM_DIR}/vendor/recovery-from-boot.p" ]; then
        echo "- Disabling stock recovery restoration."
        rm -rf "${EXTRACTED_FIRM_DIR}/vendor/recovery-from-boot.p"
    fi

    DISABLE_FBE "$EXTRACTED_FIRM_DIR"
    DISABLE_FDE "$EXTRACTED_FIRM_DIR"
    REMOVE_TLC_ICC "$EXTRACTED_FIRM_DIR"
}


APPLY_JDM_SPECIAL() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    echo -e "Applying jdm device feature."

    local EXTRACTED_FIRM_DIR="$1"
    local ANDROID_VERSION=$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.system.build.version.release")

    rm -rf "${EXTRACTED_FIRM_DIR}/system/system/priv-app/SamsungCamera"

    if [ ! -f "${QT_DIR}/QuantumROM/Mods/Apps/JDM_Camera_Files_Android_${ANDROID_VERSION}.zip" ]; then
        if curl -fsSL --connect-timeout 5 https://www.google.com >/dev/null; then
            wget -q --no-check-certificate \
                "https://github.com/SN-Abdullah-Al-Noman/Samsung_Special/releases/download/Android_${ANDROID_VERSION}/JDM_Camera_Files_Android_${ANDROID_VERSION}.zip" \
                -O "${QT_DIR}/QuantumROM/Mods/Apps/JDM_Camera_Files_Android_${ANDROID_VERSION}.zip"
        else
            echo "- No internet connection available. Unable to download: JDM_Camera_Files_Android_${ANDROID_VERSION}.zip"
            return 0
        fi
    fi

    if [ -f "${QT_DIR}/QuantumROM/Mods/Apps/JDM_Camera_Files_Android_${ANDROID_VERSION}.zip" ]; then
        rm -rf "${QT_DIR}/QuantumROM/Mods/Apps/JDM_Camera_Files_Android_${ANDROID_VERSION}"
        unzip -o "${QT_DIR}/QuantumROM/Mods/Apps/JDM_Camera_Files_Android_${ANDROID_VERSION}.zip" \
            -d "${QT_DIR}/QuantumROM/Mods/Apps/JDM_Camera_Files_Android_${ANDROID_VERSION}" >/dev/null 2>&1

        cp -rfa "${QT_DIR}/QuantumROM/Mods/Apps/JDM_Camera_Files_Android_${ANDROID_VERSION}/." "${EXTRACTED_FIRM_DIR}/"
    fi
}


ADD_CHINA_SMART_MANAGER() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo "Adding China smart manager."

    if [ ! -d "${EXTRACTED_FIRM_DIR}/system" ]; then
        echo "No extracted firmware found."
        return 1
    fi

    local PRODUCT_BRAND=$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.product.system.brand")
    local ANDROID_VERSION=$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.system.build.version.release")
    
    if [ "$PRODUCT_BRAND" != "samsung" ]; then
        echo "- Unsupported Android product: $PRODUCT_BRAND"
        return 0
    fi

    if [[ ! "$ANDROID_VERSION" =~ ^(14|15|16)$ ]]; then
        echo "- Unsupported Android version: $ANDROID_VERSION"
        return 0
    fi

    if [ -f "${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml" ]; then
        local TARGET_ROM_FLOATING_FEATURE="${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml"
    elif [ -f "${EXTRACTED_FIRM_DIR}/vendor/etc/floating_feature.xml" ]; then
        local TARGET_ROM_FLOATING_FEATURE="${EXTRACTED_FIRM_DIR}/vendor/etc/floating_feature.xml"
    else
        echo "- Error: floating_feature.xml not found!"
        return 0
    fi

    # ================= SMART MANAGER =================
    if [ ! -d "${EXTRACTED_FIRM_DIR}/system/system/priv-app/SmartManagerCN" ] && \
        [ ! -f "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_SmartManagerCN_Android_${ANDROID_VERSION}.zip" ]; then

        if curl -fsSL --connect-timeout 5 https://www.google.com >/dev/null; then
            wget -q --no-check-certificate \
                "https://github.com/SN-Abdullah-Al-Noman/Samsung_Special/releases/download/Android_${ANDROID_VERSION}/Samsung_SmartManagerCN_Android_${ANDROID_VERSION}.zip" \
                -O "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_SmartManagerCN_Android_${ANDROID_VERSION}.zip"
        else
            echo "- No internet connection available. Unable to download: Samsung_SmartManagerCN_Android_${ANDROID_VERSION}.zip"
            return 0
        fi
    fi

    if [ ! -d "${EXTRACTED_FIRM_DIR}/system/system/priv-app/SmartManagerCN" ] && \
        [ -f "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_SmartManagerCN_Android_${ANDROID_VERSION}.zip" ]; then

        rm -rf "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_SmartManagerCN_Android_${ANDROID_VERSION}"
        unzip -o "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_SmartManagerCN_Android_${ANDROID_VERSION}.zip" \
            -d "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_SmartManagerCN_Android_${ANDROID_VERSION}" >/dev/null 2>&1

        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/priv-app/AppLock"
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/priv-app/Firewall"
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/priv-app/SmartManager_v5"
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/priv-app/SmartManagerCN"

        cp -rfa "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_SmartManagerCN_Android_${ANDROID_VERSION}/." "${EXTRACTED_FIRM_DIR}/"

        UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" \
            "SEC_FLOATING_FEATURE_SMARTMANAGER_CONFIG_PACKAGE_NAME" \
            "com.samsung.android.sm_cn"
    fi

    chmod -R u+rwX "$EXTRACTED_FIRM_DIR"
}


ADD_SAMSUNG_FLAGSHIP_APPS() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo -e "Adding samsung full ONEUI apps."

    if [ ! -d "${EXTRACTED_FIRM_DIR}/system" ]; then
        echo "No extracted firmware found."
        return 1
    fi

    local PRODUCT_BRAND=$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.product.system.brand")
    local ANDROID_VERSION=$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.system.build.version.release")

    if [ "$PRODUCT_BRAND" != "samsung" ]; then
        return 1
    fi

    if [[ ! "$ANDROID_VERSION" =~ ^(14|15|16)$ ]]; then
        echo "- Unsupported Android version: $ANDROID_VERSION"
        return 0
    fi

    if [ -f "${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml" ]; then
        local TARGET_ROM_FLOATING_FEATURE="${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml"
    elif [ -f "${EXTRACTED_FIRM_DIR}/vendor/etc/floating_feature.xml" ]; then
        local TARGET_ROM_FLOATING_FEATURE="${EXTRACTED_FIRM_DIR}/vendor/etc/floating_feature.xml"
    else
        echo "- Error: floating_feature.xml not found!"
        return 1
    fi

    # ================= PHOTO EDITOR AI FULL =================
    echo "- Adding Photo editor ai full."
    
    if [ ! -d "${EXTRACTED_FIRM_DIR}/system/system/priv-app/PhotoEditor_AIFull" ] && \
        [ ! -f "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_PhotoEditor_AIFull_Android_${ANDROID_VERSION}.zip" ]; then

        if curl -fsSL --connect-timeout 5 https://www.google.com >/dev/null; then
            wget -q --no-check-certificate \
                "https://github.com/SN-Abdullah-Al-Noman/Samsung_Special/releases/download/Android_${ANDROID_VERSION}/Samsung_PhotoEditor_AIFull_Android_${ANDROID_VERSION}.zip" \
                -O "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_PhotoEditor_AIFull_Android_${ANDROID_VERSION}.zip"
        else
            echo "- No internet connection available. Unable to download: Samsung_PhotoEditor_AIFull_Android_${ANDROID_VERSION}.zip"
            return 0
        fi
    fi

    if [ ! -d "${EXTRACTED_FIRM_DIR}/system/system/priv-app/PhotoEditor_AIFull" ] && \
        [ -f "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_PhotoEditor_AIFull_Android_${ANDROID_VERSION}.zip" ]; then

        rm -rf "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_PhotoEditor_AIFull_Android_${ANDROID_VERSION}"

        unzip -o "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_PhotoEditor_AIFull_Android_${ANDROID_VERSION}.zip" \
            -d "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_PhotoEditor_AIFull_Android_${ANDROID_VERSION}" >/dev/null 2>&1

        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/etc/ailasso"
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/etc/ailassomatting"
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/etc/inpainting"
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/etc/objectremoval"
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/etc/reflectionremoval"
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/etc/shadowremoval"
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/etc/style_transfer"
        rm -rf "${EXTRACTED_FIRM_DIR}/system/system/priv-app"/PhotoEditor_*

        #========== GENAI ==========#
        if [ -f "$TARGET_ROM_FLOATING_FEATURE" ]; then
            UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_IMAGE_CLIPPER" "TRUE"
            UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_OBJECT_ERASER" "TRUE"
            UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_REFLECTION_ERASER" "TRUE"
            UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_SHADOW_ERASER" "TRUE"
            UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_SMART_LASSO" "TRUE"
            UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_SPOT_FIXER" "TRUE"
            UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_GENAI_SUPPORT_STYLE_TRANSFER" "TRUE"
        fi

        cp -rfa "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_PhotoEditor_AIFull_Android_${ANDROID_VERSION}/." "${EXTRACTED_FIRM_DIR}/"
    fi

    # Fix Samsung AI Photo Editor app Crash.
    if [ -f "${EXTRACTED_FIRM_DIR}/system/system/cameradata/portrait_data/single_bokeh_feature.json" ]; then
        sed -i '0,/"ModelType": "MODEL_TYPE_INSTANCE_CAPTURE"/s//"ModelType": "MODEL_TYPE_OBJ_INSTANCE_CAPTURE"/' \
        "${EXTRACTED_FIRM_DIR}/system/system/cameradata/portrait_data/single_bokeh_feature.json"
    fi

    # ================= OCR DATA PROVIDER =================
    echo "- Adding Samsung OCR Data Provider."

    if [ ! -d "${EXTRACTED_FIRM_DIR}/system/system/app/OCRDataProvider" ] && \
        [ ! -f "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_OCRDataProvider_Android_${ANDROID_VERSION}.zip" ]; then

        if curl -fsSL --connect-timeout 5 https://www.google.com >/dev/null; then
            wget -q --no-check-certificate \
                "https://github.com/SN-Abdullah-Al-Noman/Samsung_Special/releases/download/Android_${ANDROID_VERSION}/Samsung_OCRDataProvider_Android_${ANDROID_VERSION}.zip" \
                -O "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_OCRDataProvider_Android_${ANDROID_VERSION}.zip"
        else
            echo "- No internet connection available. Unable to download: Samsung_OCRDataProvider_Android_${ANDROID_VERSION}.zip"
            return 0
        fi
    fi

    if [ ! -d "${EXTRACTED_FIRM_DIR}/system/system/app/OCRDataProvider" ] && \
        [ -f "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_OCRDataProvider_Android_${ANDROID_VERSION}.zip" ]; then

        rm -rf "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_OCRDataProvider_Android_${ANDROID_VERSION}"
        unzip -o "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_OCRDataProvider_Android_${ANDROID_VERSION}.zip" \
            -d "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_OCRDataProvider_Android_${ANDROID_VERSION}" >/dev/null 2>&1

        #============= OCR ==========#
        sed -i '/SEC_FLOATING_FEATURE_CAMERA_CONFIG_OCR_ENGINE_UNSUPPORT /d' "$TARGET_ROM_FLOATING_FEATURE"
        UPDATE_FLOATING_FEATURE "$TARGET_ROM_FLOATING_FEATURE" "SEC_FLOATING_FEATURE_CAMERA_CONFIG_STRIDE_OCR_VERSION" "V2"

        cp -rfa "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_OCRDataProvider_Android_${ANDROID_VERSION}/." "${EXTRACTED_FIRM_DIR}/"

        if [ ! -d "${EXTRACTED_FIRM_DIR}/system/system/app/OCRDataProvider" ]; then
            cp -rfa "${QT_DIR}/QuantumROM/Mods/Apps/OCR/." "${EXTRACTED_FIRM_DIR}/"
        fi
    fi

    # ================= IMPORTANT APPS =================
    echo "- Adding Samsung Important Apps."

    if [ ! -f "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_Important_Apps_Android_${ANDROID_VERSION}.zip" ]; then
        if curl -fsSL --connect-timeout 5 https://www.google.com >/dev/null; then
            wget -q --no-check-certificate \
                "https://github.com/SN-Abdullah-Al-Noman/Samsung_Special/releases/download/Android_${ANDROID_VERSION}/Samsung_Important_Apps_Android_${ANDROID_VERSION}.zip" \
               -O "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_Important_Apps_Android_${ANDROID_VERSION}.zip"
        else
            echo "No internet connection available. Unable to download: Samsung_Important_Apps_Android_${ANDROID_VERSION}.zip"
            return 0
        fi
    fi

    if [ -s "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_Important_Apps_Android_${ANDROID_VERSION}.zip" ]; then
        rm -rf "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_Important_Apps_Android_${ANDROID_VERSION}"
        unzip -o "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_Important_Apps_Android_${ANDROID_VERSION}.zip" \
            -d "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_Important_Apps_Android_${ANDROID_VERSION}" >/dev/null 2>&1

        cp -rfa "${QT_DIR}/QuantumROM/Mods/Apps/Samsung_Important_Apps_Android_${ANDROID_VERSION}/." "${EXTRACTED_FIRM_DIR}/"
    fi

    chmod -R u+rwX "$EXTRACTED_FIRM_DIR"
}


APPLY_CUSTOM_FEATURES() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo -e "Applying usefull features."

    if [ -d "${QT_DIR}/QuantumROM/usefull_things" ]; then
        cp -a "${QT_DIR}/QuantumROM/usefull_things/." "${QT_DIR}/OUT"
    fi

    if [ ! -d "${EXTRACTED_FIRM_DIR}/system" ]; then
        echo "- No extracted firmware found."
        return 1
    fi

    echo -e "- Adding build prop tweak."
    BUILD_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.product.locale" "en-US"
    BUILD_PROP "$EXTRACTED_FIRM_DIR" "system" "fw.max_users" "5"
    BUILD_PROP "$EXTRACTED_FIRM_DIR" "system" "fw.show_multiuserui" "1"
    BUILD_PROP "$EXTRACTED_FIRM_DIR" "system" "wifi.interface" "wlan0"
    BUILD_PROP "$EXTRACTED_FIRM_DIR" "system" "wlan.wfd.hdcp" "disable"
    BUILD_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.telephony.sim_slots.count" "2"
    BUILD_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.surface_flinger.protected_contents" "true"
    BUILD_PROP "$EXTRACTED_FIRM_DIR" "product" "ro.product.locale" "en-US"

    # Apply custom floating feature.
    APPLY_CUSTOM_FLOATING_FEATURE "$EXTRACTED_FIRM_DIR"

    chmod -R u+rwX "$EXTRACTED_FIRM_DIR"
}


###################################################################################################
# PART 5: CSC DECODER, FS_CONFIG / FILE_CONTEXTS GENERATORS & IMAGE BUILDERS
###################################################################################################

DECODE_CSC() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> <OUT_DIR>"
        return 1
    fi

    echo -e "-Decoding CSC - odm,optics."

    if ! command -v java >/dev/null 2>&1; then
        echo -e "- Java is not installed."
        return 1
    fi

    local FW_DIR="$1"
    local OUT_DIR="$2"

    if [ -d "${FW_DIR}/odm/etc/omc" ]; then
        rm -rf "${OUT_DIR}/odm_decoded"

        echo "- Decoding odm/etc/omc in ${OUT_DIR}"

        java -jar "$omc_decoder" \
            -i "${FW_DIR}/odm/etc/omc" \
            -o "${OUT_DIR}/odm_decoded" \
            >/dev/null 2>&1 || {
                echo -e "- Failed decoding odm/etc/omc."
            }
    else
         echo "- No odm found."
    fi

    if [ -d "${FW_DIR}/optics" ]; then
        rm -rf "${OUT_DIR}/optics_decoded"

        echo "- Decoding optics in ${OUT_DIR}"

        java -jar "$omc_decoder" \
            -i "${FW_DIR}/optics" \
            -o "${OUT_DIR}/optics_decoded" \
            >/dev/null 2>&1 || {
                echo -e "- Failed decoding optics."
            }
    else
         echo "- No optics found."
    fi
}


GEN_FS_CONFIG() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> <PARTITION_FOLDER_NAME>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local PARTITION="$2"

    [ ! -d "${EXTRACTED_FIRM_DIR}/$PARTITION" ] && {
        echo -e "- Partition not found: $PARTITION"
        return 1
    }

    [ "$PARTITION" = "config" ] && return 0

    mkdir -p "${EXTRACTED_FIRM_DIR}/config"
    local FS_CONFIG="${EXTRACTED_FIRM_DIR}/config/${PARTITION}_fs_config"

    touch "$FS_CONFIG"
    sed -i 's/\r$//' "$FS_CONFIG"

    echo -e "Generating fs_config for partition: $PARTITION"

    if [ "$PARTITION" = "product" ]; then
        sed -i '/HotwordEnrollmentOKGoogleEx4CORTEXM55/d' "$FS_CONFIG" 2>/dev/null || true
        sed -i '/HotwordEnrollmentXGoogleEx4CORTEXM55/d' "$FS_CONFIG" 2>/dev/null || true
    fi

    # Deduplicate existing entries by path (first column)
    awk '!seen[$1]++' "$FS_CONFIG" > "${FS_CONFIG}.tmp" && mv "${FS_CONFIG}.tmp" "$FS_CONFIG"

    declare -A EXISTING_FS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [ -z "$line" ] && continue
        local p_only="${line%% *}"
        EXISTING_FS["$p_only"]=1
    done < "$FS_CONFIG"

    find "${EXTRACTED_FIRM_DIR}/$PARTITION" -mindepth 1 \( -type f -o -type d -o -type l \) | while IFS= read -r item; do
        REL_PATH="${item#${EXTRACTED_FIRM_DIR}/$PARTITION/}"
        PATH_ENTRY="$PARTITION/$REL_PATH"

        [[ -n "${EXISTING_FS[$PATH_ENTRY]-}" ]] && continue

        if [ -d "$item" ]; then
            printf "%s 0 0 0755\n" "$PATH_ENTRY" >> "$FS_CONFIG"
        else
            if [[ "$REL_PATH" == */bin/* ]]; then
                printf "%s 0 2000 0755\n" "$PATH_ENTRY" >> "$FS_CONFIG"
            else
                printf "%s 0 0 0644\n" "$PATH_ENTRY" >> "$FS_CONFIG"
            fi
        fi
    done

    unset EXISTING_FS
    echo -e "- $PARTITION fs_config generated"
}


GEN_FILE_CONTEXTS() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> <PARTITION_FOLDER_NAME>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local PARTITION="$2"

    local CONTEXT="u:object_r:system_file:s0"
        
    if [[ "$PARTITION" == odm* || "$PARTITION" == vendor* ]]; then
        CONTEXT="u:object_r:vendor_file:s0"
    fi

    [ ! -d "${EXTRACTED_FIRM_DIR}/$PARTITION" ] && {
        echo -e "- Partition not found: $PARTITION"
        return 1
    }

    [ "$PARTITION" = "config" ] && return 0

    escape_path() {
        local path="$1"
        local result=""
        local c

        for ((i=0; i<${#path}; i++)); do
            c="${path:i:1}"

            case "$c" in
                '.'|'+'|'['|']'|'*'|'?'|'^'|'$'|'\\'|'('|')'|'{'|'}'|'|')
                    result+="\\$c"
                    ;;
                *)
                    result+="$c"
                    ;;
            esac
        done

        printf '%s' "$result"
    }

    mkdir -p "${EXTRACTED_FIRM_DIR}/config"
    local FILE_CONTEXTS="${EXTRACTED_FIRM_DIR}/config/${PARTITION}_file_contexts"

    touch "$FILE_CONTEXTS"
    sed -i 's/\r$//' "$FILE_CONTEXTS"

    echo -e "Generating file_contexts for partition: $PARTITION"

    if [ "$PARTITION" = "product" ]; then
        sed -i '/HotwordEnrollmentOKGoogleEx4CORTEXM55/d' "$FILE_CONTEXTS" 2>/dev/null || true
        sed -i '/HotwordEnrollmentXGoogleEx4CORTEXM55/d' "$FILE_CONTEXTS" 2>/dev/null || true
    fi

    # Deduplicate existing entries by path (first column)
    awk '!seen[$1]++' "$FILE_CONTEXTS" > "${FILE_CONTEXTS}.tmp" && mv "${FILE_CONTEXTS}.tmp" "$FILE_CONTEXTS"

    declare -A EXISTING=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [ -z "$line" ] && continue
        local PATH_ONLY="${line%% *}"
        EXISTING["$PATH_ONLY"]=1
    done < "$FILE_CONTEXTS"

    find "${EXTRACTED_FIRM_DIR}/$PARTITION" -mindepth 1 \( -type f -o -type d -o -type l \) | while IFS= read -r item; do
        local REL_PATH="${item#${EXTRACTED_FIRM_DIR}/$PARTITION}"
        local PATH_ENTRY="/$PARTITION$REL_PATH"
        local ESCAPED_PATH="/$(escape_path "${PATH_ENTRY#/}")"

        [[ -n "${EXISTING[$ESCAPED_PATH]-}" ]] && continue

        local BASENAME=$(basename "$item")
        local ITEM_CONTEXT="$CONTEXT"

        if [[ "$BASENAME" == "linker" || "$BASENAME" == "linker64" ]]; then
            ITEM_CONTEXT="u:object_r:system_linker_exec:s0"
        fi

        if [[ "$BASENAME" == "[" ]]; then
            ITEM_CONTEXT="u:object_r:system_file:s0"
        fi

        printf "%s %s\n" "$ESCAPED_PATH" "$ITEM_CONTEXT" >> "$FILE_CONTEXTS"
        EXISTING["$ESCAPED_PATH"]=1
    done

    if ! grep -qE "^/${PARTITION}\(/\.\*\)\?[[:space:]]" "$FILE_CONTEXTS"; then
        printf "/%s(/.*)? %s\n" "$PARTITION" "$CONTEXT" >> "$FILE_CONTEXTS"
        echo "- Added: /${PARTITION}(/.*)? ${CONTEXT}"
    fi

    echo -e "- $PARTITION file_contexts generated"

    unset EXISTING
}


BUILD_IMG() {
    echo " "

    if [ "$#" -ne 4 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> all|img_name <FILE_SYSTEM> <OUT_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local MODE="$2"
    local FILE_SYSTEM="$3"
    local OUT_DIR="$4"

    mkdir -p "$OUT_DIR"

    build_img() {
        local PARTITION="$1"

        mkdir -p "${EXTRACTED_FIRM_DIR}/${PARTITION}/lost+found"

        GEN_FS_CONFIG "$EXTRACTED_FIRM_DIR" "$PARTITION"
        GEN_FILE_CONTEXTS "$EXTRACTED_FIRM_DIR" "$PARTITION"

        local SOURCE_DIR="${EXTRACTED_FIRM_DIR}/$PARTITION"
        local OUT_IMG="$OUT_DIR/${PARTITION}.img"
        local FS_CONFIG="${EXTRACTED_FIRM_DIR}/config/${PARTITION}_fs_config"
        local FILE_CONTEXTS="${EXTRACTED_FIRM_DIR}/config/${PARTITION}_file_contexts"

        [[ -d "$SOURCE_DIR" ]] || return 0

        local EXTRACTED_SIZE=$(du -sb --apparent-size "$SOURCE_DIR" | cut -f1)
        local MOUNT_POINT="/$PARTITION"

        rm -rf "$OUT_IMG"

        [[ -f "$FS_CONFIG" ]] || {
            echo -e "Warning: $FS_CONFIG missing, skipping $PARTITION"
            return 0
        }

        [[ -f "$FILE_CONTEXTS" ]] || {
            echo -e "Warning: $FILE_CONTEXTS missing, skipping $PARTITION"
            return 0
        }

        awk '!seen[$1]++' "$FILE_CONTEXTS" | sort -u > "${FILE_CONTEXTS}.tmp" && mv "${FILE_CONTEXTS}.tmp" "$FILE_CONTEXTS"
        awk '!seen[$1]++' "$FS_CONFIG" | sort -u > "${FS_CONFIG}.tmp" && mv "${FS_CONFIG}.tmp" "$FS_CONFIG"

        if [[ "$FILE_SYSTEM" == "erofs" ]]; then
            echo " "
            echo -e "Building erofs image: $OUT_IMG"

            $mkfs_erofs \
                --mount-point="$MOUNT_POINT" \
                --fs-config-file="$FS_CONFIG" \
                --file-contexts="$FILE_CONTEXTS" \
                -z lz4hc \
                -b 4096 \
                -T 1199145600 \
                "$OUT_IMG" "$SOURCE_DIR"

        elif [[ "$FILE_SYSTEM" == "ext4" ]]; then
            echo " "
            echo -e "Building ext4 image: $OUT_IMG"

            SIZE=$(((EXTRACTED_SIZE + 4095) / 4096 * 4096))
            EXTENDED_SIZE=$((SIZE + SIZE / 5))

            if [ "$EXTENDED_SIZE" -lt "4349952" ]; then
                EXTENDED_SIZE="4349952"
            fi

            $make_ext4fs \
                -l "$EXTENDED_SIZE" \
                -J \
                -b 4096 \
                -S "$FILE_CONTEXTS" \
                -C "$FS_CONFIG" \
                -a "$MOUNT_POINT" \
                -L "$PARTITION" \
                "$OUT_IMG" "$SOURCE_DIR"

            resize2fs -M "$OUT_IMG"

        elif [[ "$FILE_SYSTEM" == "f2fs" ]]; then
            echo " "
            echo -e "Building f2fs image: $OUT_IMG"

            SIZE=$(((EXTRACTED_SIZE + 511) / 512 * 512))
            EXTENDED_SIZE=$((SIZE + SIZE / 8))

            if [ "$EXTENDED_SIZE" -lt "60000000" ]; then
                EXTENDED_SIZE="60000000"
            fi

            truncate -s "$EXTENDED_SIZE" "$OUT_IMG"

            $make_f2fs \
                -f -q \
                -g android \
                -O extra_attr,inode_checksum,sb_checksum,compression \
                -l "$MOUNT_POINT" \
                "$OUT_IMG"

            $sload_f2fs \
                -f "$SOURCE_DIR" \
                -C "$FS_CONFIG" \
                -s "$FILE_CONTEXTS" \
                -t "$MOUNT_POINT" \
                -P \
                -c \
                -L 2 \
                -a lz4 \
                "$OUT_IMG"

            img2simg "$OUT_IMG" "${OUT_IMG}.sparse"
            rm -rf "$OUT_IMG"
            mv "${OUT_IMG}.sparse" "$OUT_IMG"

        else
            echo -e "- Unsupported filesystem: $FILE_SYSTEM"
            return 0
        fi
    }

    if [ "$MODE" = "all" ]; then

        for PART in "$EXTRACTED_FIRM_DIR"/*; do
            [[ -d "$PART" ]] || continue

            local PARTITION="$(basename "$PART")"

            [[ "$PARTITION" == "config" ]] && continue

            build_img "$PARTITION"
        done

    else
        build_img "$MODE"
    fi

    chmod -R u+rwX "$OUT_DIR"
}


BUILD_SUPER_IMG() {
    echo " "

    local IMG_DIR="$1"
    local OUTPUT_DIR="$2"
    local OUTPUT_IMG="$OUTPUT_DIR/super.img"

    echo "Building: super.img"

    [ ! -d "$IMG_DIR" ] && {
        echo "- Input folder not found: $IMG_DIR"
        return 1
    }

    local PARTITIONS=""
    local IMAGES=""
    local TOTAL_SIZE=0
    local VALID_IMAGES=0

    rm -f "$OUTPUT_IMG"

    for img in "$IMG_DIR"/*.img; do
        [ -e "$img" ] || continue

        local name="$(basename "$img")"

        case "$name" in
            boot.img|init_boot.img|recovery.img|vbmeta.img|vbmeta_system.img|vbmeta_vendor.img|dtbo.img|userdata.img|cache.img|metadata.img|vendor_boot.img|super.img)
                echo "- Skipping $name"
                continue
                ;;
        esac

        local part_name="${name%.img}"
        local size=$(stat -c%s "$img")

        [ "$size" -le 0 ] && {
            echo "- Skipping empty image: $name"
            continue
        }

        echo "Adding: $part_name ($size bytes)"

        PARTITIONS+=" --partition ${part_name}:readonly:${size}:main"
        IMAGES+=" --image ${part_name}=$img"
        TOTAL_SIZE=$((TOTAL_SIZE + size))
        VALID_IMAGES=1
    done

    [ "$VALID_IMAGES" -eq 0 ] && {
        echo "- No valid logical partition images found"
        return 1
    }

    TOTAL_SIZE=$((TOTAL_SIZE + 4194304))

    $lpmake \
        --device super:$TOTAL_SIZE \
        --metadata-size 65536 \
        --metadata-slots 2 \
        --group main:$TOTAL_SIZE \
        --block-size 4096 \
        $PARTITIONS \
        $IMAGES \
        --output "$OUTPUT_IMG"
}
