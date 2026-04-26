#!/usr/bin/env bash
#
# ストレージ (LVM) セットアップスクリプト (Ubuntu 26.04 対応)
#
# 既存 LVM ボリュームを検出・アクティベートし、/etc/fstab 登録 + マウントまでを行う。
# 旧サーバーから物理ディスクを移設したケース、および LVM 構築済みのディスクを
# 新サーバーで認識させる用途を想定。
#
# **本スクリプトは PV/VG/LV の新規作成およびフォーマットは行わない**。
# データ消失リスクのため、新規構築は手動 (sample.conf 末尾の手順を参照)。

set -euo pipefail

readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

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
使用方法: $0 <設定ファイルパス>

既存 LVM ボリュームの検出・アクティベート・マウントを行う (Ubuntu 26.04 対応)。

引数:
  <設定ファイルパス>     絶対パス、CWD 相対パス、または app/config/storage/ 配下のファイル名 (例: BackupServer.conf)

オプション:
  -h, --help             このヘルプを表示

設定項目:
  VG_NAME / LV_NAME / MOUNT_POINT / FILESYSTEM / MOUNT_OPTIONS

備考:
  - PV/VG/LV の新規作成・フォーマットは行わない (sample.conf 末尾の手順を参照)
  - 新規ディスクの場合は事前に pvcreate/vgcreate/lvcreate/mkfs.xfs を手動実行すること
    (本プロジェクトの標準ファイルシステムは xfs)
EOF
}

# ----------------------------------------------------------------------------
# 引数パース・設定ロード
# ----------------------------------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "エラー: 設定ファイルを指定してください。" >&2
        echo "詳細は '$0 --help' を参照してください。" >&2
        exit 1
    fi
    INPUT_CONFIG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            *)
                if [[ -z "${INPUT_CONFIG}" ]]; then
                    INPUT_CONFIG="$1"
                else
                    err "複数の引数が指定されています。"
                fi
                shift
                ;;
        esac
    done
}

load_config() {
    if [[ ! -f "${INPUT_CONFIG}" ]]; then
        local candidates=(
            "${SCRIPT_DIR}/${INPUT_CONFIG}"
            "${SCRIPT_DIR}/../config/storage/${INPUT_CONFIG}"
        )
        local resolved=""
        for c in "${candidates[@]}"; do
            if [[ -f "${c}" ]]; then
                resolved=$(cd "$(dirname "${c}")" && pwd)/$(basename "${c}")
                break
            fi
        done
        [[ -n "${resolved}" ]] || err "設定ファイルが見つかりません: ${INPUT_CONFIG}"
        INPUT_CONFIG="${resolved}"
    fi
    echo "設定ファイルを読み込みます: ${INPUT_CONFIG}"
    # shellcheck disable=SC1090
    source "${INPUT_CONFIG}"

    for v in VG_NAME LV_NAME MOUNT_POINT FILESYSTEM MOUNT_OPTIONS; do
        [[ -n "${!v:-}" ]] || err "設定ファイルに ${v} が定義されていません。"
    done

    LV_DEVICE="/dev/${VG_NAME}/${LV_NAME}"
}

require_root() {
    [[ $(id -u) -eq 0 ]] || err "root 権限で実行してください: sudo $0 ..."
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

install_lvm2_and_fs_tools() {
    echo "Step 1: lvm2 + ファイルシステムツールの確認・インストール"
    local pkgs=(lvm2)
    case "${FILESYSTEM}" in
        xfs)            pkgs+=(xfsprogs) ;;
        ext4|ext3|ext2) pkgs+=(e2fsprogs) ;;
        btrfs)          pkgs+=(btrfs-progs) ;;
        *)              warn "FILESYSTEM=${FILESYSTEM} 用ツールパッケージは自動インストールされません。" ;;
    esac
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    echo "  完了 (${pkgs[*]})"
}

activate_vgs() {
    echo "Step 2: 既存 LVM の検出・アクティベート"
    pvscan --cache 2>/dev/null || true   # 古い LVM では --cache 非対応の場合あり
    vgscan
    vgchange -ay
    echo ""
    echo "  検出された VG / LV:"
    vgs --noheadings --options vg_name,vg_size 2>/dev/null | sed 's/^/    /'
    echo ""
    lvs --noheadings --options vg_name,lv_name,lv_size 2>/dev/null | sed 's/^/    /'
    echo ""
}

verify_lv_exists() {
    echo "Step 3: 対象 LV の存在確認 (${LV_DEVICE})"
    if ! lvs "${VG_NAME}/${LV_NAME}" >/dev/null 2>&1; then
        err "LV が見つかりません: ${LV_DEVICE}
  - 対象ディスクが本サーバーに接続されているか
  - VG_NAME / LV_NAME が正しいか
  - 'sudo vgs' / 'sudo lvs' で実際の名前を確認してください"
    fi
    [[ -b "${LV_DEVICE}" ]] || err "ブロックデバイス ${LV_DEVICE} が存在しません。'sudo vgchange -ay ${VG_NAME}' を再実行してください。"
    echo "  OK: ${LV_DEVICE} を検出"
}

verify_filesystem() {
    echo "Step 4: ファイルシステム検証 (期待: ${FILESYSTEM})"
    local actual_fs uuid
    actual_fs=$(blkid -o value -s TYPE "${LV_DEVICE}" || echo "")
    uuid=$(blkid -o value -s UUID "${LV_DEVICE}" || echo "")

    if [[ -z "${actual_fs}" ]]; then
        err "${LV_DEVICE} にファイルシステムがありません。データ消失リスクのため自動フォーマットしません。
  必要なら手動で実行してください: sudo mkfs.${FILESYSTEM} ${LV_DEVICE}"
    fi
    if [[ "${actual_fs}" != "${FILESYSTEM}" ]]; then
        warn "ファイルシステム不一致: 期待=${FILESYSTEM}, 実際=${actual_fs}. 続行しますが /etc/fstab には actual=${actual_fs} で書きます。"
        FILESYSTEM="${actual_fs}"
    fi
    [[ -n "${uuid}" ]] || err "UUID を取得できません: ${LV_DEVICE}"
    LV_UUID="${uuid}"
    echo "  OK: type=${actual_fs} UUID=${uuid}"
}

ensure_mount_point() {
    echo "Step 5: マウントポイントの確保 (${MOUNT_POINT})"
    install -d -m 755 "${MOUNT_POINT}"
    echo "  OK"
}

update_fstab() {
    echo "Step 6: /etc/fstab 更新"
    # 6 列目 (fs_passno) は xfs/btrfs では 0 固定 (boot 時 fsck を実施しない)、ext系は 2
    local fsck_pass=2
    case "${FILESYSTEM}" in
        xfs|btrfs) fsck_pass=0 ;;
    esac
    local fstab_line="UUID=${LV_UUID}  ${MOUNT_POINT}  ${FILESYSTEM}  ${MOUNT_OPTIONS}  0  ${fsck_pass}"

    # 同一 UUID または同一 mount point の行を削除して書き換え
    if grep -qE "^[^#]*\b(UUID=${LV_UUID}|${MOUNT_POINT})\b" /etc/fstab; then
        local backup="/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p /etc/fstab "${backup}"
        echo "  既存エントリを検出。バックアップ: ${backup}"
        sed -i -E "/^[^#]*\b(UUID=${LV_UUID}|${MOUNT_POINT//\//\\/})\b/d" /etc/fstab
    fi
    echo "${fstab_line}" >> /etc/fstab
    echo "  追記: ${fstab_line}"
}

mount_volume() {
    echo "Step 7: マウント"
    systemctl daemon-reload
    if mountpoint -q "${MOUNT_POINT}"; then
        echo "  既にマウント済み。再マウントします。"
        umount "${MOUNT_POINT}" || warn "umount 失敗。使用中のプロセスを確認してください。"
    fi
    mount -a
    if mountpoint -q "${MOUNT_POINT}"; then
        echo "  OK: ${MOUNT_POINT} マウント完了"
    else
        err "マウントに失敗しました。'mount -a' / 'dmesg' を確認してください。"
    fi
}

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
ストレージセットアップが完了しました。
${sep}

  Volume Group:    ${VG_NAME}
  Logical Volume:  ${LV_NAME}
  Device:          ${LV_DEVICE}
  UUID:            ${LV_UUID}
  Filesystem:      ${FILESYSTEM}
  Mount Point:     ${MOUNT_POINT}

確認:
  df -h ${MOUNT_POINT}
  lsblk
  cat /etc/fstab | grep "${LV_UUID}"

トラブル時:
  sudo vgs / sudo lvs                 # LVM 構成
  sudo blkid ${LV_DEVICE}              # FS 情報
  sudo journalctl -u local-fs.target   # boot 時のマウントログ
${sep}
EOF
}

# ----------------------------------------------------------------------------
# プラン + 確認
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "ストレージ (LVM) セットアップを実行します。"
    echo ""
    echo "  Volume Group:    ${VG_NAME}"
    echo "  Logical Volume:  ${LV_NAME}"
    echo "  Device:          ${LV_DEVICE}"
    echo "  Mount Point:     ${MOUNT_POINT}"
    echo "  Filesystem:      ${FILESYSTEM}"
    echo "  Mount Options:   ${MOUNT_OPTIONS}"
    echo ""
    echo "  注意: PV/VG/LV の新規作成およびフォーマットは行いません。"
    echo "${sep}"
}

confirm_or_abort() {
    local yn
    read -r -p "この設定で実行してよろしいですか？ (Y/n) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *) echo "中止しました。"; exit 0 ;;
    esac
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    require_root
    load_config
    print_plan
    confirm_or_abort

    install_lvm2_and_fs_tools
    activate_vgs
    verify_lv_exists
    verify_filesystem
    ensure_mount_point
    update_fstab
    mount_volume
    print_summary
}

main "$@"
