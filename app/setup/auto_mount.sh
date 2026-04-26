#!/usr/bin/env bash
#
# LV 出現時 自動マウント設定スクリプト (Ubuntu 26.04 対応)
#
# 指定 LV (/dev/<vg>/<lv>) が **後付けで出現したとき** にマウントされるよう、
# udev rule + oneshot systemd service を冪等に配置する。
#
# 用途:
#   - 起動後に USB-HDD を接続するワークフロー (FileServer の 15 PV プール等)
#   - storage.sh の fstab automount (boot 時) を補完して late-mount を実現
#
# 仕組み:
#   1. udev rule: SUBSYSTEM=block + DM_VG_NAME/DM_LV_NAME 一致で systemd を呼び出す
#   2. systemd service: oneshot で /usr/bin/mount <mount-point> を実行
#      ConditionPathIsMountPoint=!<path> によりマウント済みなら no-op (冪等)

set -euo pipefail

readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly UNIT_NAME_PREFIX="fileservers-automount"

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
使用方法: $0 <storage config> [--remove]

LV 出現を契機に late-mount する udev rule + systemd service を配置/削除する。
storage.sh で fstab に登録した late-mount ボリュームに対し、起動後の接続でも
**確実にマウントされる**ようにする。

引数:
  <storage config>       app/setup/storage.sh と同じ形式の config ファイル
                         (絶対パス / CWD 相対 / app/config/storage/ 配下のパス)
                         例: BackupServer/timemachine.conf, FileServer/usb.conf

オプション:
  --remove               作成済の udev rule + systemd service を削除する
  -h, --help             このヘルプを表示

参照する config 値:
  VG_NAME / LV_NAME / MOUNT_POINT (storage.sh と同じ)

生成されるファイル:
  /etc/udev/rules.d/99-${UNIT_NAME_PREFIX}-<VG>-<LV>.rules
  /etc/systemd/system/${UNIT_NAME_PREFIX}-<VG>-<LV>.service

注意:
  - root 権限で実行: sudo $0 ...
  - <VG> <LV> は config の VG_NAME / LV_NAME を sanitize した値
  - storage.sh で /etc/fstab 登録 + 初回マウントを済ませてから本スクリプトを実行する
    (本スクリプトは fstab を編集しない)

例:
  sudo $0 BackupServer/timemachine.conf
  sudo $0 FileServer/usb.conf
  sudo $0 FileServer/usb.conf --remove
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "エラー: storage config を指定してください。" >&2
        echo "詳細は '$0 --help' を参照してください。" >&2
        exit 1
    fi

    INPUT_CONFIG=""
    REMOVE_MODE="no"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --remove) REMOVE_MODE="yes"; shift ;;
            *)
                if [[ -z "${INPUT_CONFIG}" ]]; then
                    INPUT_CONFIG="$1"
                else
                    err "複数の config が指定されています: $1"
                fi
                shift
                ;;
        esac
    done
    [[ -n "${INPUT_CONFIG}" ]] || err "storage config を指定してください。"
}

require_root() {
    [[ $(id -u) -eq 0 ]] || err "root 権限で実行してください: sudo $0 ..."
}

# ----------------------------------------------------------------------------
# 設定ファイルロード
# ----------------------------------------------------------------------------

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
        [[ -n "${resolved}" ]] || err "config が見つかりません: ${INPUT_CONFIG}"
        INPUT_CONFIG="${resolved}"
    fi

    echo "config: ${INPUT_CONFIG}"
    # shellcheck disable=SC1090
    source "${INPUT_CONFIG}"

    for v in VG_NAME LV_NAME MOUNT_POINT; do
        [[ -n "${!v:-}" ]] || err "config に ${v} が定義されていません。"
    done

    # プレースホルダ検出 (FileServer 系の <usb-vg-name> 等)
    if [[ "${VG_NAME}${LV_NAME}${MOUNT_POINT}" == *"<"* ]]; then
        err "プレースホルダ <...> が含まれています。実 FileServer 上で実値に置換してから実行してください。"
    fi
}

# ----------------------------------------------------------------------------
# 名前生成
# ----------------------------------------------------------------------------

generate_unit_paths() {
    # systemd / udev 用に sanitize ([a-zA-Z0-9-] 以外は - に置換)
    # echo は末尾改行を付与するため printf を使用 (改行が tr -c で - に変換される問題を回避)
    local sanitized
    sanitized=$(printf '%s' "${VG_NAME}-${LV_NAME}" | tr -c 'a-zA-Z0-9-' '-')
    UNIT_NAME="${UNIT_NAME_PREFIX}-${sanitized}"
    UDEV_RULE_PATH="/etc/udev/rules.d/99-${UNIT_NAME}.rules"
    SERVICE_PATH="/etc/systemd/system/${UNIT_NAME}.service"
}

# ----------------------------------------------------------------------------
# プラン
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    if [[ "${REMOVE_MODE}" == "yes" ]]; then
        echo "Auto-mount 設定の **削除**を実行します。"
    else
        echo "Auto-mount 設定の配置を実行します。"
    fi
    echo ""
    echo "  VG_NAME:           ${VG_NAME}"
    echo "  LV_NAME:           ${LV_NAME}"
    echo "  MOUNT_POINT:       ${MOUNT_POINT}"
    echo "  service unit:      ${UNIT_NAME}.service"
    echo "  udev rule path:    ${UDEV_RULE_PATH}"
    echo "  service path:      ${SERVICE_PATH}"
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
# 配置 (install)
# ----------------------------------------------------------------------------

ensure_mount_point() {
    if [[ ! -d "${MOUNT_POINT}" ]]; then
        echo "Step 0: マウントポイント ${MOUNT_POINT} を作成"
        install -d -m 755 "${MOUNT_POINT}"
    fi
}

write_udev_rule() {
    echo "Step 1: udev rule の配置 (${UDEV_RULE_PATH})"
    cat > "${UDEV_RULE_PATH}" <<EOF
# Generated by app/setup/auto_mount.sh
# /dev/${VG_NAME}/${LV_NAME} が出現/変化したら ${UNIT_NAME}.service を起動して
# ${MOUNT_POINT} へマウントする。
ACTION=="add|change", SUBSYSTEM=="block", ENV{DM_VG_NAME}=="${VG_NAME}", ENV{DM_LV_NAME}=="${LV_NAME}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="${UNIT_NAME}.service"
EOF
    chmod 644 "${UDEV_RULE_PATH}"
}

write_service() {
    echo "Step 2: systemd service の配置 (${SERVICE_PATH})"
    cat > "${SERVICE_PATH}" <<EOF
# Generated by app/setup/auto_mount.sh
[Unit]
Description=Auto-mount ${MOUNT_POINT} when LV ${VG_NAME}/${LV_NAME} becomes available
After=local-fs.target
ConditionPathIsMountPoint=!${MOUNT_POINT}

[Service]
Type=oneshot
ExecStart=/usr/bin/mount ${MOUNT_POINT}
RemainAfterExit=false
EOF
    chmod 644 "${SERVICE_PATH}"
}

reload_systemd_udev() {
    echo "Step 3: systemd / udev に reload を要求"
    systemctl daemon-reload
    udevadm control --reload-rules
}

# ----------------------------------------------------------------------------
# 削除 (uninstall)
# ----------------------------------------------------------------------------

remove_unit_files() {
    echo "Step 1: udev rule + systemd service を削除"
    local removed=0
    for f in "${UDEV_RULE_PATH}" "${SERVICE_PATH}"; do
        if [[ -f "${f}" ]]; then
            rm -f "${f}"
            echo "  削除: ${f}"
            removed=$((removed + 1))
        else
            echo "  (skip) 存在せず: ${f}"
        fi
    done
    [[ ${removed} -gt 0 ]] || warn "削除対象が見つかりませんでした。"
}

# ----------------------------------------------------------------------------
# サマリ
# ----------------------------------------------------------------------------

print_summary_install() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
Auto-mount 設定が配置されました。
${sep}

動作確認:
  # 既に LV が出現しているなら、udev トリガで service が走る
  sudo udevadm trigger --action=change --subsystem-match=block

  # service の状態
  systemctl status ${UNIT_NAME}.service --no-pager

  # マウント結果
  findmnt ${MOUNT_POINT}

USB デバイスを物理接続した際の挙動:
  1. 全 PV が enumerate → LVM event_activation で VG が activate
  2. /dev/${VG_NAME}/${LV_NAME} が出現 → udev "add" イベント発火
  3. udev rule が ${UNIT_NAME}.service を呼び出す
  4. systemd が /usr/bin/mount ${MOUNT_POINT} を実行 (既マウントなら ConditionPathIsMountPoint で skip)
${sep}
EOF
}

print_summary_remove() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
Auto-mount 設定を削除しました。
${sep}

  ${UDEV_RULE_PATH}
  ${SERVICE_PATH}

確認:
  systemctl status ${UNIT_NAME}.service --no-pager 2>&1 | head -3
  ls -la /etc/udev/rules.d/ | grep ${UNIT_NAME} || echo "  (rule 削除済)"
${sep}
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    require_root
    load_config
    generate_unit_paths
    print_plan
    confirm_or_abort

    if [[ "${REMOVE_MODE}" == "yes" ]]; then
        remove_unit_files
        reload_systemd_udev
        print_summary_remove
    else
        ensure_mount_point
        write_udev_rule
        write_service
        reload_systemd_udev
        print_summary_install
    fi
}

main "$@"
