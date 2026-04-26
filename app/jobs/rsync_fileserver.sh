#!/usr/bin/env bash
#
# rsync 定期バックアップ (Ubuntu 26.04 対応)
#
# /mnt/fileserver/ -> /mnt/fileserver-backup/ への同期を実行する。
# cron など定期実行を前提とした運用スクリプト。
#
# 比較モード:
#   - 既定: mtime + size による高速比較 (毎時 cron 用)
#   - --checksum: 内容ハッシュで差分判定 (サイレント破損検出)。
#                 100TB 規模では I/O が極めて重いため定期実行はせず、
#                 破損が疑われた場合の手動スポット検査でのみ使用する。
#   - --dry-run:  実転送せず差分のみ報告 (--checksum と併用して検証用途)
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
使用方法: $0 [--delete] [--checksum] [--dry-run] [-h|--help]

${SOURCE_DIR}/ -> ${DEST_DIR}/ への rsync 同期を行う。
既定は mtime + size 比較。--checksum 指定時のみ内容ハッシュで差分判定する。

オプション:
  --delete       宛先側に存在し、ソースに無いファイルを削除して完全ミラー化する
  --checksum     ファイル内容のチェックサムで差分判定する (サイレント破損検出用)
                 副作用: ソース・宛先双方を全件読むため I/O が極めて重い。
                 100TB 級の運用では定期実行禁止。破損疑いがある場合の
                 手動スポット検査としてのみ使用すること。
  --dry-run      実転送せず差分のみ報告する (--checksum と併用で検証ジョブ用途)
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
    CHECKSUM_FLAG=""
    DRYRUN_FLAG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --delete)
                DELETE_FLAG="--delete"
                ;;
            --checksum)
                CHECKSUM_FLAG="--checksum"
                ;;
            --dry-run)
                DRYRUN_FLAG="--dry-run"
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

    local compare_label="mtime + size (高速)"
    if [[ -n "${CHECKSUM_FLAG}" ]]; then
        compare_label="--checksum (内容ハッシュ。全件読みで I/O 高負荷)"
    fi

    {
        echo "========================================"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] rsync 開始"
        echo "ソース: ${SOURCE_DIR}/"
        echo "宛先:   ${DEST_DIR}/"
        echo "比較:   ${compare_label}"
        if [[ -n "${DRYRUN_FLAG}" ]]; then
            echo "オプション: --dry-run (実転送なし)"
        fi
        if [[ -n "${DELETE_FLAG}" ]]; then
            echo "オプション: --delete (宛先の余剰ファイルを削除し完全ミラー)"
        fi
        echo "PID: $$"
        echo "========================================"
    } >> "${LOG_FILE}"

    # -a: アーカイブ (権限/所有/タイムスタンプ/シンボリックリンク等を保持)
    # -H: ハードリンクを保持
    # -A: ACL を保持
    # -X: 拡張属性 (xattr) を保持
    # --numeric-ids: UID/GID を名前ではなく数値で同期 (移植時の取り違え防止)
    # -h: human-readable な数値表示
    # --stats: 転送量サマリをログ末尾に出力
    # 失敗しても終了処理を実行するため一時的に errexit を緩める
    set +e
    rsync -aHAXh --numeric-ids --stats \
        ${CHECKSUM_FLAG} ${DRYRUN_FLAG} ${DELETE_FLAG} \
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
