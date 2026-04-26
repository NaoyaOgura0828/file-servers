#!/usr/bin/env bash
#
# rsync ログ用 logrotate 設定インストーラ (Ubuntu 26.04 対応)
#
# /var/log/rsync/rsync_fileserver.log のローテーション設定を /etc/logrotate.d/ に配置する。
# CloudWatch Agent はローカルファイルを tail するだけでローテーション管理はしないため、
# ローカルディスクの容量管理用に本スクリプトでの logrotate 設定が必要となる。

set -euo pipefail

readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly CONFIG_RELPATH="logrotate/rsync_fileserver.conf"
readonly DEST_PATH="/etc/logrotate.d/rsync_fileserver"
readonly LOG_FILE="/var/log/rsync/rsync_fileserver.log"
readonly LOG_DIR=$(dirname "${LOG_FILE}")

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
使用方法: $0 [-h|--help]

rsync ログ (${LOG_FILE}) の logrotate 設定を ${DEST_PATH} にインストールします。
Ubuntu 26.04 の systemd-timer (logrotate.timer) または cron.daily から自動実行されます。

設定内容 (app/config/${CONFIG_RELPATH}):
  - 頻度:           日次 (daily)
  - 保持世代:       30 日分
  - 圧縮:           gzip (delaycompress により最新世代は無圧縮)
  - 再作成:         create 0644 root root
  - CloudWatch:     postrotate 不要 (Agent がローテーションを自動検知)

前提:
  - logrotate パッケージがインストール済み (未導入時は apt で導入)
  - sudo 実行可能なユーザーで起動すること
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                err "不明な引数: $1 (詳細は '$0 --help')"
                ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 前提チェック
# ----------------------------------------------------------------------------

ensure_logrotate_installed() {
    if command -v logrotate >/dev/null 2>&1; then
        return 0
    fi
    warn "logrotate コマンドが見つかりません。apt でインストールします。"
    sudo apt-get update -qq
    sudo apt-get install -y logrotate
    if ! command -v logrotate >/dev/null 2>&1; then
        err "logrotate のインストールに失敗しました。"
    fi
}

resolve_source_config() {
    # スクリプト配置ディレクトリ (app/setup) から見た相対パスで app/config/<purpose>/ を参照
    local resolved="${SCRIPT_DIR}/../config/${CONFIG_RELPATH}"
    if [[ ! -f "${resolved}" ]]; then
        err "設定ファイルが見つかりません: ${resolved}"
    fi
    SOURCE_PATH=$(cd "$(dirname "${resolved}")" && pwd)/$(basename "${resolved}")
}

detect_runner() {
    # systemd-timer 優先 (Ubuntu 22.04+ の標準)、無ければ cron.daily を確認
    if systemctl list-unit-files logrotate.timer >/dev/null 2>&1 \
        && systemctl is-enabled logrotate.timer >/dev/null 2>&1; then
        RUNNER_DESC="systemd-timer (logrotate.timer)"
    elif [[ -f /etc/cron.daily/logrotate ]]; then
        RUNNER_DESC="cron.daily (/etc/cron.daily/logrotate)"
    else
        RUNNER_DESC="不明 (logrotate.timer / cron.daily いずれも未検出)"
    fi
}

# ----------------------------------------------------------------------------
# プラン表示 + 確認
# ----------------------------------------------------------------------------

print_plan() {
    local sep="=========================================="
    echo "${sep}"
    echo "rsync 用 logrotate 設定のインストール"
    echo "${sep}"
    echo ""
    echo "ソース:           ${SOURCE_PATH}"
    echo "インストール先:   ${DEST_PATH}"
    echo "対象ログ:         ${LOG_FILE}"
    echo "実行スケジューラ: ${RUNNER_DESC}"
    if [[ -f "${DEST_PATH}" ]]; then
        echo ""
        warn "既存設定が存在します。上書きされます: ${DEST_PATH}"
    fi
    echo ""
}

confirm_or_abort() {
    local yn
    read -r -p "この設定でインストールしてよろしいですか？ (Y/n) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *)
            echo "インストールを中止しました。"
            exit 0
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

install_config() {
    echo "Step 1: 設定ファイルを ${DEST_PATH} に配置 (パーミッション 644 / root:root)"
    sudo install -m 644 -o root -g root "${SOURCE_PATH}" "${DEST_PATH}"
    echo "  完了。"
}

verify_syntax() {
    echo "Step 2: logrotate 構文チェック (debug mode)"
    if sudo logrotate -d "${DEST_PATH}" >/dev/null 2>&1; then
        echo "  OK"
    else
        warn "構文チェックでエラー。詳細は: sudo logrotate -d ${DEST_PATH}"
    fi
}

ensure_log_dir() {
    echo "Step 3: ログディレクトリ ${LOG_DIR} の確保"
    if [[ -d "${LOG_DIR}" ]]; then
        echo "  既に存在します。"
    else
        sudo install -d -m 700 -o root -g root "${LOG_DIR}"
        echo "  作成しました (700 / root:root)。"
    fi
}

print_summary() {
    local sep="=========================================="
    cat <<EOF

${sep}
インストールが完了しました。
${sep}

設定:
  ファイル:         ${DEST_PATH}
  パーミッション:   $(sudo stat -c '%a (%A)' "${DEST_PATH}")
  所有者:           $(sudo stat -c '%U:%G' "${DEST_PATH}")
  実行スケジューラ: ${RUNNER_DESC}

確認コマンド:
  内容確認:        sudo cat ${DEST_PATH}
  ドライラン:      sudo logrotate -d ${DEST_PATH}
  詳細実行:        sudo logrotate -v ${DEST_PATH}
  強制実行 (試験): sudo logrotate -f ${DEST_PATH}
  状態:            sudo grep rsync_fileserver /var/lib/logrotate/logrotate.status
  systemd timer:   systemctl status logrotate.timer
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    ensure_logrotate_installed
    resolve_source_config
    detect_runner
    print_plan
    confirm_or_abort

    install_config
    verify_syntax
    ensure_log_dir
    print_summary
}

main "$@"
