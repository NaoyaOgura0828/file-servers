#!/usr/bin/env bash
#
# rsync 定期バックアップ (Ubuntu 26.04 対応)
#
# /mnt/fileserver/ -> /mnt/fileserver-backup/ への同期を実行する。
# cron など定期実行を前提とした運用スクリプト。
# 比較モード: --checksum (mtime/size ではなく内容ハッシュで差分判定、サイレント破損検出)
#
# ログ:        /var/log/rsync/rsync_fileserver.log
#              (logrotate.sh で配置した /etc/logrotate.d/rsync_fileserver でローテーション、
#               cloudwatch_agent.sh が tail し CloudWatch Logs /onprem/FileServer に転送)
# 重複実行防止: flock(1) によるアドバイザリロック (/var/run/rsync_fileserver.lock)

set -euo pipefail

readonly SOURCE_DIR="/mnt/fileserver"
readonly DEST_DIR="/mnt/fileserver-backup"
readonly LOG_FILE="/var/log/rsync/rsync_fileserver.log"
readonly LOCK_FILE="/var/run/rsync_fileserver.lock"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

log_line() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${ts}] $*" >> "${LOG_FILE}"
}

show_help() {
    cat <<EOF
使用方法: $0 [--delete] [-h|--help]

${SOURCE_DIR}/ -> ${DEST_DIR}/ への rsync 同期を行う。
ファイル比較は常に --checksum モード (内容ハッシュで差分判定) で実行する。

オプション:
  --delete       宛先側に存在し、ソースに無いファイルを削除して完全ミラー化する
  -h, --help     このヘルプを表示

ログ:           ${LOG_FILE}
ロック:         ${LOCK_FILE} (flock(1) によるアドバイザリロック)

前提:
  - root 権限で実行 (sudo)
  - rsync / flock / coreutils が PATH 上に存在 (Ubuntu 26.04 標準で導入済み)
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    DELETE_FLAG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --delete)
                DELETE_FLAG="--delete"
                ;;
            *)
                echo "エラー: 不明な引数: $1" >&2
                echo "詳細は '$0 --help'" >&2
                exit 1
                ;;
        esac
        shift
    done
}

# ----------------------------------------------------------------------------
# 前提チェック
# ----------------------------------------------------------------------------

require_root() {
    if [[ $(id -u) -ne 0 ]]; then
        echo "エラー: root 権限で実行してください: sudo $0" >&2
        exit 1
    fi
}

require_directories() {
    if [[ ! -d "${SOURCE_DIR}" ]]; then
        log_line "エラー: ソースディレクトリが見つかりません: ${SOURCE_DIR}"
        echo "エラー: ソースディレクトリが見つかりません: ${SOURCE_DIR}" >&2
        exit 1
    fi
    if [[ ! -d "${DEST_DIR}" ]]; then
        log_line "エラー: 宛先ディレクトリが見つかりません: ${DEST_DIR}"
        echo "エラー: 宛先ディレクトリが見つかりません: ${DEST_DIR}" >&2
        exit 1
    fi
}

ensure_log_dir() {
    local log_dir
    log_dir=$(dirname "${LOG_FILE}")
    install -d -m 700 -o root -g root "${log_dir}"
}

# ----------------------------------------------------------------------------
# 同期本体
# ----------------------------------------------------------------------------

run_rsync() {
    local start_epoch end_epoch elapsed
    start_epoch=$(date +%s)

    {
        echo "========================================"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] rsync 開始"
        echo "ソース: ${SOURCE_DIR}/"
        echo "宛先:   ${DEST_DIR}/"
        echo "比較:   --checksum (ファイル内容のチェックサム比較)"
        if [[ -n "${DELETE_FLAG}" ]]; then
            echo "オプション: --delete (宛先の余剰ファイルを削除し完全ミラー)"
        fi
        echo "PID: $$"
        echo "========================================"
    } >> "${LOG_FILE}"

    # --checksum: mtime/size ではなく内容ハッシュで差分判定 (サイレント破損検出)
    # 副作用: ソース・宛先双方を全件読むため、データセット規模に応じて I/O 時間が増加する
    # 失敗しても終了処理を実行するため一時的に errexit を緩める
    set +e
    rsync -ahv --checksum --progress ${DELETE_FLAG} --stats \
        "${SOURCE_DIR}/" \
        "${DEST_DIR}/" \
        >> "${LOG_FILE}" 2>&1
    local rc=$?
    set -e

    end_epoch=$(date +%s)
    elapsed=$((end_epoch - start_epoch))
    local hh=$((elapsed / 3600))
    local mm=$(((elapsed % 3600) / 60))
    local ss=$((elapsed % 60))

    {
        echo "========================================"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] rsync 終了"
        if [[ ${rc} -eq 0 ]]; then
            echo "ステータス: 成功"
        else
            echo "ステータス: 失敗 (終了コード: ${rc})"
        fi
        echo "実行時間: ${hh}時間 ${mm}分 ${ss}秒"
        echo "========================================"
        echo ""
    } >> "${LOG_FILE}"

    return ${rc}
}

# ----------------------------------------------------------------------------
# main (flock で多重起動を排他)
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    require_root
    ensure_log_dir
    require_directories

    # flock により再入時は即座に exit 1。stale PID ファイルの管理が不要になる。
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        echo "エラー: rsync は既に実行中です (lock: ${LOCK_FILE})" >&2
        log_line "重複実行を検出したためスキップ"
        exit 1
    fi

    run_rsync
}

main "$@"
