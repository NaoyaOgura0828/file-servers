#!/usr/bin/env bash
#
# Network セットアップスクリプト (Ubuntu 26.04 / NetworkManager)
#
# Ethernet の route-metric / autoconnect、Wi-Fi の接続 + route-metric を設定する。
# 旧 setup_comon_server.sh のネットワーク部分の後継。
#
# Wi-Fi パスワードは本スクリプト・config ファイルには **保存しない**。
# 取得優先順位: 環境変数 WIFI_PASSWORD > --password-file > 対話プロンプト (read -s)。

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
使用方法: $0 <設定ファイルパス> [--password-file <path>]

Ethernet (有線) と Wi-Fi の NetworkManager 設定を行う (Ubuntu 26.04)。

引数:
  <設定ファイルパス>     絶対パス、CWD 相対パス、または app/config/network/ 配下のファイル名 (例: BackupServer.conf)

オプション:
  --password-file <path> Wi-Fi パスワードを記載したファイルパス (1 行目を採用)
  -h, --help             このヘルプを表示

Wi-Fi パスワードの取得優先順位 (1 が最優先):
  1. 環境変数 WIFI_PASSWORD
  2. --password-file <path>
  3. 対話プロンプト (read -s)

設定項目:
  ETHERNET_ROUTE_METRIC / ETHERNET_AUTOCONNECT
  WIFI_INTERFACE / WIFI_SSID / WIFI_ROUTE_METRIC / WIFI_AUTOCONNECT
  詳細は app/config/network/sample.conf を参照。

注意:
  - root 権限で実行: sudo $0 ...
  - NetworkManager (apt: network-manager) が未導入なら自動インストール
  - systemd-networkd と NM が同時に有効な場合、競合する可能性あり (警告のみ)
  - --password-file を使う場合は当該ファイルを **必ず .gitignore で除外**してください
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "エラー: 設定ファイルを指定してください。" >&2
        echo "詳細は '$0 --help' を参照してください。" >&2
        exit 1
    fi

    INPUT_CONFIG=""
    PASSWORD_FILE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --password-file)
                shift
                [[ $# -gt 0 ]] || err "--password-file の引数が不足しています。"
                PASSWORD_FILE="$1"
                shift
                ;;
            *)
                if [[ -z "${INPUT_CONFIG}" ]]; then
                    INPUT_CONFIG="$1"
                else
                    err "複数の引数が指定されています: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "${INPUT_CONFIG}" ]] || err "設定ファイルパスを指定してください。"
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
            "${SCRIPT_DIR}/../config/network/${INPUT_CONFIG}"
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

    : "${ETHERNET_ROUTE_METRIC:=10}"
    : "${ETHERNET_AUTOCONNECT:=yes}"
    : "${WIFI_INTERFACE:=}"
    : "${WIFI_SSID:=}"
    : "${WIFI_ROUTE_METRIC:=50}"
    : "${WIFI_AUTOCONNECT:=yes}"
}

# ----------------------------------------------------------------------------
# 前提
# ----------------------------------------------------------------------------

ensure_network_manager() {
    echo "Step 1: NetworkManager の導入確認"
    if command -v nmcli >/dev/null 2>&1; then
        echo "  既にインストール済み"
    else
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager
    fi
    systemctl enable --now NetworkManager >/dev/null 2>&1 || true

    if systemctl is-active --quiet systemd-networkd; then
        warn "systemd-networkd が active です。NetworkManager と競合する可能性があります。"
        warn "  /etc/netplan/*.yaml の renderer を NetworkManager に切替後、'sudo netplan apply' を推奨"
    fi
}

# ----------------------------------------------------------------------------
# インターフェース検出
# ----------------------------------------------------------------------------

detect_ethernets() {
    # nmcli -t は : 区切り。DEVICE,TYPE を取って ethernet を抽出。
    mapfile -t ETHERNET_DEVICES < <(
        nmcli -t -f DEVICE,TYPE device 2>/dev/null \
            | awk -F: '$2=="ethernet" {print $1}'
    )
}

detect_wifi() {
    if [[ -n "${WIFI_INTERFACE}" ]]; then
        WIFI_DEVICE="${WIFI_INTERFACE}"
        return 0
    fi
    WIFI_DEVICE=$(
        nmcli -t -f DEVICE,TYPE device 2>/dev/null \
            | awk -F: '$2=="wifi" {print $1; exit}'
    )
}

# ----------------------------------------------------------------------------
# プラン
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "Network セットアップを実行します。"
    echo ""
    echo "  config:                ${INPUT_CONFIG}"
    echo "  Ethernet 検出:         ${ETHERNET_DEVICES[*]:-(なし)}"
    echo "    route-metric:        ${ETHERNET_ROUTE_METRIC}"
    echo "    autoconnect:         ${ETHERNET_AUTOCONNECT}"
    echo ""
    if [[ -n "${WIFI_SSID}" ]]; then
        echo "  Wi-Fi 設定:"
        echo "    SSID:              ${WIFI_SSID}"
        echo "    interface:         ${WIFI_DEVICE:-(検出失敗)}"
        echo "    route-metric:      ${WIFI_ROUTE_METRIC}"
        echo "    autoconnect:       ${WIFI_AUTOCONNECT}"
        echo "    password source:   $(
            if [[ -n "${WIFI_PASSWORD:-}" ]]; then echo "環境変数 WIFI_PASSWORD"
            elif [[ -n "${PASSWORD_FILE}" ]];     then echo "${PASSWORD_FILE}"
            else echo "対話プロンプト"
            fi
        )"
    else
        echo "  Wi-Fi 設定:            (WIFI_SSID 未設定のためスキップ)"
    fi
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
# Wi-Fi パスワード取得
# ----------------------------------------------------------------------------

get_wifi_password() {
    if [[ -n "${WIFI_PASSWORD:-}" ]]; then
        WIFI_PASSWORD_VALUE="${WIFI_PASSWORD}"
        return 0
    fi
    if [[ -n "${PASSWORD_FILE}" ]]; then
        [[ -f "${PASSWORD_FILE}" ]] || err "password file が見つかりません: ${PASSWORD_FILE}"
        WIFI_PASSWORD_VALUE=$(head -n1 "${PASSWORD_FILE}")
    else
        # 対話プロンプト (echo 抑止)
        read -r -s -p "Wi-Fi password (${WIFI_SSID}): " WIFI_PASSWORD_VALUE
        echo
    fi
    [[ -n "${WIFI_PASSWORD_VALUE}" ]] || err "Wi-Fi パスワードが空です。"
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

configure_ethernets() {
    if [[ ${#ETHERNET_DEVICES[@]} -eq 0 ]]; then
        echo "Step 2: ethernet デバイスなし。スキップ。"
        return 0
    fi
    echo "Step 2: Ethernet ${#ETHERNET_DEVICES[@]} 台を設定"
    local dev conn
    for dev in "${ETHERNET_DEVICES[@]}"; do
        # device に紐づく active connection 名を取得 (なければ device 名で modify を試みる)
        conn=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
            | awk -F: -v d="${dev}" '$2==d {print $1; exit}')
        conn="${conn:-${dev}}"
        echo "  [${dev}] connection='${conn}' route-metric=${ETHERNET_ROUTE_METRIC} autoconnect=${ETHERNET_AUTOCONNECT}"
        nmcli connection modify "${conn}" \
            ipv4.route-metric "${ETHERNET_ROUTE_METRIC}" \
            ipv6.route-metric "${ETHERNET_ROUTE_METRIC}" \
            connection.autoconnect "${ETHERNET_AUTOCONNECT}" \
            || warn "  ${dev}: 設定失敗 (connection 不在の可能性)"
    done
}

configure_wifi() {
    if [[ -z "${WIFI_SSID}" ]]; then
        echo "Step 3: Wi-Fi 設定はスキップ (WIFI_SSID 未設定)"
        return 0
    fi
    if [[ -z "${WIFI_DEVICE}" ]]; then
        err "Wi-Fi デバイスが検出できません。WIFI_INTERFACE を明示するか、Wi-Fi NIC を有効化してください。"
    fi
    echo "Step 3: Wi-Fi 接続 (SSID=${WIFI_SSID} ifname=${WIFI_DEVICE})"

    get_wifi_password

    # 接続 (新規 or 既存 SSID への再接続)。stdout に password が出ないように 2>&1 だけにし、
    # 失敗時のメッセージは echo するが password は表示しない。
    local rc=0
    nmcli device wifi connect "${WIFI_SSID}" \
        password "${WIFI_PASSWORD_VALUE}" \
        ifname "${WIFI_DEVICE}" \
        >/dev/null 2>&1 \
        || rc=$?
    unset WIFI_PASSWORD_VALUE   # メモリから即時消去 (best effort)
    [[ ${rc} -eq 0 ]] || err "Wi-Fi 接続に失敗しました (SSID=${WIFI_SSID})。電波・パスワード・近接 AP を確認してください。"

    # 接続後の設定 (route-metric / autoconnect)。connection 名は SSID と同じが既定。
    nmcli connection modify "${WIFI_SSID}" \
        ipv4.route-metric "${WIFI_ROUTE_METRIC}" \
        ipv6.route-metric "${WIFI_ROUTE_METRIC}" \
        connection.autoconnect "${WIFI_AUTOCONNECT}" \
        || warn "  route-metric / autoconnect 設定に失敗。connection 名が SSID と異なる可能性あり。"

    echo "  接続成功"
}

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
Network セットアップが完了しました。
${sep}

接続状態:
$(nmcli -t -f NAME,DEVICE,STATE connection show --active 2>/dev/null | sed 's/^/  /')

ルート優先度確認:
  ip route show
  nmcli connection show --active

問題発生時:
  nmcli device wifi list
  nmcli device status
  journalctl -u NetworkManager --no-pager -n 50
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
    ensure_network_manager
    detect_ethernets
    detect_wifi
    print_plan
    confirm_or_abort

    configure_ethernets
    configure_wifi
    print_summary
}

main "$@"
