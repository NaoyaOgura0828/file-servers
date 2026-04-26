#!/usr/bin/env bash
#
# LVM 新規作成スクリプト (Ubuntu 26.04 対応)
#
# 指定したブロックデバイスを物理ボリューム化し、新規 VG / LV を作成して
# ファイルシステム (デフォルト: xfs) でフォーマットする。
# 旧 create_lvm_group.sh の後継。
#
# **データ消失を伴う破壊的操作**のため、対象デバイスの状態を表示して
# 確認プロンプトを必ず通す。

set -euo pipefail

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

err() {
    echo "エラー: $*" >&2
    exit 1
}

warn() {
    echo "警告: $*" >&2
}

show_help() {
    cat <<EOF
使用方法: $0 <device> <vg_name> <lv_name> [--fs <type>] [--size <size>]

新規 LVM (PV → VG → LV → mkfs) を一括作成する (Ubuntu 26.04)。

引数:
  <device>          物理ブロックデバイス (例: /dev/sdb, /dev/nvme1n1)
  <vg_name>         VG 名 (例: timemachine-group)
  <lv_name>         LV 名 (例: timemachine)

オプション:
  --fs <type>       ファイルシステム種別 (省略時: xfs。本プロジェクト標準)
  --size <size>     LV サイズ (lvcreate -l に渡される、省略時: 100%FREE)
                    例: 100%FREE / 50%VG / 100G
  -h, --help        このヘルプを表示

警告:
  本スクリプトは <device> を pvcreate -ff で初期化します。
  既存データは失われます。実行前に必ず lsblk / blkid で対象を確認してください。

例:
  sudo $0 /dev/sdb timemachine-group timemachine
  sudo $0 /dev/nvme1n1 data-group data --fs xfs --size 50%VG
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    DEVICE=""
    VG_NAME=""
    LV_NAME=""
    FS_TYPE="xfs"
    LV_SIZE="100%FREE"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --fs)
                shift; [[ $# -gt 0 ]] || err "--fs の引数が不足しています。"
                FS_TYPE="$1"; shift ;;
            --size)
                shift; [[ $# -gt 0 ]] || err "--size の引数が不足しています。"
                LV_SIZE="$1"; shift ;;
            *)
                if   [[ -z "${DEVICE}"  ]]; then DEVICE="$1"
                elif [[ -z "${VG_NAME}" ]]; then VG_NAME="$1"
                elif [[ -z "${LV_NAME}" ]]; then LV_NAME="$1"
                else err "不明な引数: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "${DEVICE}"  ]] || err "<device> を指定してください。"
    [[ -n "${VG_NAME}" ]] || err "<vg_name> を指定してください。"
    [[ -n "${LV_NAME}" ]] || err "<lv_name> を指定してください。"
}

require_root() {
    [[ $(id -u) -eq 0 ]] || err "root 権限で実行してください: sudo $0 ..."
}

ensure_dependencies() {
    local pkgs=(lvm2)
    case "${FS_TYPE}" in
        xfs)            pkgs+=(xfsprogs) ;;
        ext4|ext3|ext2) pkgs+=(e2fsprogs) ;;
        btrfs)          pkgs+=(btrfs-progs) ;;
    esac
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -l "${p}" >/dev/null 2>&1 || missing+=("${p}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Step 0: 依存パッケージをインストール (${missing[*]})"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
}

# ----------------------------------------------------------------------------
# 検証
# ----------------------------------------------------------------------------

validate_device() {
    [[ -b "${DEVICE}" ]] || err "${DEVICE} はブロックデバイスではありません。"

    if findmnt -S "${DEVICE}" >/dev/null 2>&1; then
        err "${DEVICE} は現在マウント中です。事前に umount してください。"
    fi

    if pvs --noheadings "${DEVICE}" >/dev/null 2>&1; then
        warn "${DEVICE} は既に PV として認識されています。"
    fi
}

validate_names() {
    if vgs --noheadings "${VG_NAME}" >/dev/null 2>&1; then
        err "VG '${VG_NAME}' は既に存在します。lvm_extend.sh で拡張するか別名を指定してください。"
    fi
}

# ----------------------------------------------------------------------------
# プラン + 確認
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "新規 LVM 作成を実行します ⚠️  ${DEVICE} のデータは失われます。"
    echo ""
    echo "  対象デバイス:    ${DEVICE}"
    echo "  Volume Group:    ${VG_NAME}"
    echo "  Logical Volume:  ${LV_NAME}"
    echo "  LV size:         ${LV_SIZE}"
    echo "  Filesystem:      ${FS_TYPE}"
    echo ""
    echo "  デバイス情報:"
    lsblk -f "${DEVICE}" 2>&1 | sed 's/^/    /'
    echo ""
    echo "  既存ラベル / FS:"
    blkid "${DEVICE}" 2>&1 | sed 's/^/    /' || echo "    (なし)"
    echo "${sep}"
}

confirm_or_abort() {
    local yn
    read -r -p "${DEVICE} を初期化して新規 LVM を作成します。本当に実行しますか？ (Y/n) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *) echo "中止しました。"; exit 0 ;;
    esac
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

create_pv() {
    echo "Step 1: pvcreate ${DEVICE}"
    pvcreate -ff --yes "${DEVICE}"
}

create_vg() {
    echo "Step 2: vgcreate ${VG_NAME} ${DEVICE}"
    vgcreate "${VG_NAME}" "${DEVICE}"
}

create_lv() {
    echo "Step 3: lvcreate -l ${LV_SIZE} -n ${LV_NAME} ${VG_NAME}"
    lvcreate -l "${LV_SIZE}" -n "${LV_NAME}" "${VG_NAME}"
}

format_lv() {
    echo "Step 4: mkfs.${FS_TYPE} /dev/${VG_NAME}/${LV_NAME}"
    case "${FS_TYPE}" in
        xfs)            "mkfs.${FS_TYPE}" -f      "/dev/${VG_NAME}/${LV_NAME}" ;;
        ext4|ext3|ext2) "mkfs.${FS_TYPE}" -F      "/dev/${VG_NAME}/${LV_NAME}" ;;
        btrfs)          "mkfs.${FS_TYPE}" -f      "/dev/${VG_NAME}/${LV_NAME}" ;;
        *)              "mkfs.${FS_TYPE}"         "/dev/${VG_NAME}/${LV_NAME}" ;;
    esac
}

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
LVM 新規作成が完了しました。
${sep}

  Device:          ${DEVICE}
  VG:              ${VG_NAME}
  LV:              ${LV_NAME}
  LV path:         /dev/${VG_NAME}/${LV_NAME}
  Filesystem:      ${FS_TYPE}
  UUID:            $(blkid -o value -s UUID "/dev/${VG_NAME}/${LV_NAME}" 2>/dev/null || echo "(取得不可)")

次の作業:
  - app/setup/storage.sh で /etc/fstab 登録 + マウント
    (app/config/storage/<server>.conf の VG_NAME / LV_NAME を本コマンドの値に揃える)

確認:
  lsblk
  pvs / vgs / lvs
  blkid /dev/${VG_NAME}/${LV_NAME}
${sep}
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    require_root
    ensure_dependencies
    validate_device
    validate_names
    print_plan
    confirm_or_abort

    create_pv
    create_vg
    create_lv
    format_lv
    print_summary
}

main "$@"
