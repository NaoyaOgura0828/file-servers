#!/usr/bin/env bash
#
# LVM 拡張スクリプト (Ubuntu 26.04 対応)
#
# 既存 VG に新規ディスクを追加 (vgextend) → LV を拡張 (lvextend) →
# ファイルシステムをオンライン拡張 (xfs_growfs / resize2fs)。
# 旧 add_lvm_drive.sh の後継。複数デバイスを一括取り込み可能。
#
# 注意: pvcreate は **対象デバイスを破壊的に初期化**する。事前にデータがないことを確認。

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
使用方法: $0 <vg_name> <lv_name> <device> [<device> ...]

既存 VG に追加デバイスを取り込み、LV を 100%FREE で拡張する (Ubuntu 26.04)。
xfs / ext4 はオンライン (マウント中) で拡張可能。

引数:
  <vg_name>         拡張対象の VG 名 (lvm_create.sh で作成済のもの)
  <lv_name>         拡張対象の LV 名
  <device>          追加するブロックデバイス (1 個以上、空白区切り)

オプション:
  -h, --help        このヘルプを表示

警告:
  - 各 <device> は pvcreate -ff で初期化される。**既存データは失われる**。
  - LV は --extents +100%FREE で拡張する (デバイス容量を全て使い切る)。

例:
  sudo $0 timemachine-group timemachine /dev/sdc
  sudo $0 timemachine-group timemachine /dev/sdc /dev/sdd
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    VG_NAME=""
    LV_NAME=""
    DEVICES=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            *)
                if   [[ -z "${VG_NAME}" ]]; then VG_NAME="$1"
                elif [[ -z "${LV_NAME}" ]]; then LV_NAME="$1"
                else DEVICES+=("$1")
                fi
                shift
                ;;
        esac
    done

    [[ -n "${VG_NAME}" ]] || err "<vg_name> を指定してください。"
    [[ -n "${LV_NAME}" ]] || err "<lv_name> を指定してください。"
    [[ ${#DEVICES[@]} -gt 0 ]] || err "追加するデバイスを 1 個以上指定してください。"
}

require_root() {
    [[ $(id -u) -eq 0 ]] || err "root 権限で実行してください: sudo $0 ..."
}

# ----------------------------------------------------------------------------
# 検証
# ----------------------------------------------------------------------------

validate_lv() {
    if ! lvs "${VG_NAME}/${LV_NAME}" >/dev/null 2>&1; then
        err "LV '/dev/${VG_NAME}/${LV_NAME}' が見つかりません。lvm_create.sh で作成済か確認してください。"
    fi
    LV_DEVICE="/dev/${VG_NAME}/${LV_NAME}"
    LV_FS=$(blkid -o value -s TYPE "${LV_DEVICE}" 2>/dev/null || echo "")
    [[ -n "${LV_FS}" ]] || err "${LV_DEVICE} のファイルシステムが取得できません。"
    LV_MOUNT=$(findmnt -n -o TARGET "${LV_DEVICE}" 2>/dev/null || echo "")
}

validate_devices() {
    local d
    for d in "${DEVICES[@]}"; do
        [[ -b "${d}" ]] || err "${d} はブロックデバイスではありません。"
        if findmnt -S "${d}" >/dev/null 2>&1; then
            err "${d} はマウント中です。事前に umount してください。"
        fi
        if pvs --noheadings "${d}" >/dev/null 2>&1; then
            err "${d} は既に PV として登録されています。重複追加はできません。"
        fi
    done
}

# ----------------------------------------------------------------------------
# プラン + 確認
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "LVM 拡張を実行します ⚠️  追加デバイスのデータは失われます。"
    echo ""
    echo "  Volume Group:    ${VG_NAME}"
    echo "  Logical Volume:  ${LV_NAME}  (= ${LV_DEVICE})"
    echo "  Filesystem:      ${LV_FS}"
    echo "  Mount point:     ${LV_MOUNT:-(未マウント)}"
    echo "  追加デバイス:    ${DEVICES[*]}"
    echo ""
    echo "  各デバイスの現状:"
    local d
    for d in "${DEVICES[@]}"; do
        echo "    ${d}:"
        lsblk -f "${d}" 2>&1 | sed 's/^/      /'
    done
    echo "${sep}"
}

confirm_or_abort() {
    local yn
    read -r -p "上記デバイスを初期化して VG ${VG_NAME} に取り込みます。本当に実行しますか？ (Y/n) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *) echo "中止しました。"; exit 0 ;;
    esac
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

extend_vg() {
    echo "Step 1: pvcreate + vgextend (${#DEVICES[@]} 台)"
    local d
    for d in "${DEVICES[@]}"; do
        echo "  [${d}] pvcreate"
        pvcreate -ff --yes "${d}"
        echo "  [${d}] vgextend ${VG_NAME}"
        vgextend "${VG_NAME}" "${d}"
    done
}

extend_lv() {
    echo "Step 2: lvextend -l +100%FREE ${LV_DEVICE}"
    lvextend -l +100%FREE "${LV_DEVICE}"
}

grow_filesystem() {
    echo "Step 3: ファイルシステム拡張 (${LV_FS}, オンライン)"
    case "${LV_FS}" in
        xfs)
            [[ -n "${LV_MOUNT}" ]] || err "xfs_growfs はマウント中の FS に対して実行する必要があります。${LV_DEVICE} は未マウントです。"
            xfs_growfs "${LV_MOUNT}"
            ;;
        ext4|ext3|ext2)
            resize2fs "${LV_DEVICE}"
            ;;
        btrfs)
            [[ -n "${LV_MOUNT}" ]] || err "btrfs filesystem resize はマウント中の FS に対して実行する必要があります。"
            btrfs filesystem resize max "${LV_MOUNT}"
            ;;
        *)
            warn "未対応 FS: ${LV_FS}。手動で拡張してください。"
            ;;
    esac
}

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
LVM 拡張が完了しました。
${sep}

  VG:              ${VG_NAME}
  LV:              ${LV_DEVICE}
  Filesystem:      ${LV_FS}
  Mount point:     ${LV_MOUNT:-(未マウント)}
  追加デバイス:    ${DEVICES[*]}

確認:
  pvs / vgs / lvs
  df -h ${LV_MOUNT:-${LV_DEVICE}}
  lsblk
${sep}
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    require_root
    validate_lv
    validate_devices
    print_plan
    confirm_or_abort

    extend_vg
    extend_lv
    grow_filesystem
    print_summary
}

main "$@"
