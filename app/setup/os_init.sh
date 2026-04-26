#!/usr/bin/env bash
#
# OS 初期化スクリプト (Ubuntu 26.04)
#
# 新規構築サーバー向けのベース設定:
#   - hostname / timezone / locale
#   - apt update + upgrade
#   - 共通ユーティリティのインストール
#   - unattended-upgrades の有効化 (セキュリティアップデート自動適用)
#
# 設定ファイル形式は app/config/os_init/sample.conf を参照。

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

OS ベース初期化を行う (Ubuntu 26.04 対応)。

引数:
  <設定ファイルパス>     絶対パス、CWD 相対パス、または app/config/os_init/ 配下のファイル名 (例: BackupServer.conf)

オプション:
  -h, --help             このヘルプを表示

設定項目:
  HOSTNAME                  ホスト名 (例: BackupServer)
  TIMEZONE                  例: Asia/Tokyo
  LOCALE                    例: ja_JP.UTF-8
  EXTRA_PACKAGES            追加で apt install するパッケージ (空白区切り)
  ENABLE_UNATTENDED_UPGRADES  yes でセキュリティアップデート自動適用を有効化
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
            "${SCRIPT_DIR}/../config/os_init/${INPUT_CONFIG}"
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

    for v in HOSTNAME TIMEZONE LOCALE ENABLE_UNATTENDED_UPGRADES; do
        [[ -n "${!v:-}" ]] || err "設定ファイルに ${v} が定義されていません。"
    done
}

require_root() {
    [[ $(id -u) -eq 0 ]] || err "root 権限で実行してください: sudo $0 ..."
}

# ----------------------------------------------------------------------------
# プラン
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "OS ベース初期化を実行します。"
    echo ""
    echo "  HOSTNAME:                   ${HOSTNAME} (現在: $(hostname))"
    echo "  TIMEZONE:                   ${TIMEZONE} (現在: $(timedatectl show -p Timezone --value))"
    echo "  LOCALE:                     ${LOCALE}"
    echo "  EXTRA_PACKAGES:             ${EXTRA_PACKAGES:-(なし)}"
    echo "  ENABLE_UNATTENDED_UPGRADES: ${ENABLE_UNATTENDED_UPGRADES}"
    echo "${sep}"
}

confirm_or_abort() {
    local yn
    read -r -p "この設定で OS 初期化を実行してよろしいですか？ (Y/n) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *) echo "中止しました。"; exit 0 ;;
    esac
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

set_hostname() {
    echo "Step 1: ホスト名設定 (${HOSTNAME})"
    hostnamectl set-hostname "${HOSTNAME}"
    # /etc/hosts のループバック行を更新 (sudo 不要、root 実行前提)
    if grep -qE "^127\.0\.1\.1\s" /etc/hosts; then
        sed -i -E "s|^(127\.0\.1\.1\s+).*|\1${HOSTNAME}|" /etc/hosts
    else
        echo "127.0.1.1   ${HOSTNAME}" >> /etc/hosts
    fi
    echo "  完了"
}

set_timezone() {
    echo "Step 2: タイムゾーン (${TIMEZONE})"
    timedatectl set-timezone "${TIMEZONE}"
    echo "  完了"
}

set_locale() {
    echo "Step 3: ロケール (${LOCALE})"
    apt-get install -y locales >/dev/null
    locale-gen "${LOCALE}" >/dev/null
    update-locale "LANG=${LOCALE}"
    echo "  完了"
}

apt_update_upgrade() {
    echo "Step 4: apt update + upgrade"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
    echo "  完了"
}

install_extra_packages() {
    if [[ -z "${EXTRA_PACKAGES:-}" ]]; then
        echo "Step 5: 追加パッケージ (なし、スキップ)"
        return 0
    fi
    echo "Step 5: 追加パッケージのインストール (${EXTRA_PACKAGES})"
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y ${EXTRA_PACKAGES}
    echo "  完了"
}

enable_unattended_upgrades() {
    if [[ "${ENABLE_UNATTENDED_UPGRADES}" != "yes" ]]; then
        echo "Step 6: unattended-upgrades はスキップ"
        return 0
    fi
    echo "Step 6: unattended-upgrades の有効化"
    DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
    # 最低限の設定 (デフォルトのセキュリティのみ更新でも十分なため上書きは控えめに)
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    systemctl enable --now unattended-upgrades.service
    echo "  完了"
}

verify_time_sync() {
    echo "Step 7: 時刻同期 (systemd-timesyncd) の確認"
    if timedatectl show -p NTPSynchronized --value | grep -q "yes"; then
        echo "  同期済み"
    else
        warn "時刻同期されていません。systemd-timesyncd が動作しているか確認してください: systemctl status systemd-timesyncd"
    fi
}

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
OS 初期化が完了しました。
${sep}

  hostname:    $(hostname)
  timezone:    $(timedatectl show -p Timezone --value)
  locale:      $(grep '^LANG=' /etc/default/locale 2>/dev/null || echo "(未設定)")
  unattended:  $(systemctl is-enabled unattended-upgrades.service 2>/dev/null || echo "n/a")

次のステップ候補:
  - app/setup/storage.sh (LVM 認識・マウント)
  - app/setup/firewall.sh (UFW、未作成なら手動)
  - app/setup/ssm_agent.sh (SSM Hybrid 登録)
  - app/setup/cloudwatch_agent.sh (監視)
  - app/setup/samba.sh (Samba)
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
    print_plan
    confirm_or_abort

    set_hostname
    set_timezone
    set_locale
    apt_update_upgrade
    install_extra_packages
    enable_unattended_upgrades
    verify_time_sync
    print_summary
}

main "$@"
