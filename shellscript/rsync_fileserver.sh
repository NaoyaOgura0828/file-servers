#!/bin/bash

# rsyncバックアップスクリプト
# /mnt/fileserver/ → /mnt/fileserver-backup/ への定期バックアップ

# 引数の解析
DELETE_FLAG=""
for arg in "$@"; do
    case "${arg}" in
        --delete)
            DELETE_FLAG="--delete"
            ;;
    esac
done

# ログファイルパス（固定）
LOG_FILE="/var/log/rsync/rsync_fileserver.log"
LOCK_FILE="/var/run/rsync_fileserver.lock"

# エラー時の処理
error_exit() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] エラー: ${message}" | tee -a ${LOG_FILE}
    # ロックファイルを削除
    rm -f ${LOCK_FILE}
    exit 1
}

# root権限チェック
if [ "$(id -u)" -ne 0 ]; then
    echo "エラー: このスクリプトはroot権限で実行する必要があります。"
    echo "実行方法: sudo $0"
    exit 1
fi

# ロックファイルで重複実行を防止
if [ -e ${LOCK_FILE} ]; then
    # 既存のロックファイルが存在する場合、プロセスが実行中か確認
    if [ -f ${LOCK_FILE} ]; then
        OLD_PID=$(cat ${LOCK_FILE})
        if ps -p ${OLD_PID} > /dev/null 2>&1; then
            echo "エラー: rsyncは既に実行中です (PID: ${OLD_PID})"
            exit 1
        else
            echo "警告: 古いロックファイルを削除します (PID: ${OLD_PID} は存在しません)"
            rm -f ${LOCK_FILE}
        fi
    fi
fi

# ロックファイルを作成
echo $$ > ${LOCK_FILE}

# ログディレクトリが存在しない場合は作成
mkdir -p "$(dirname ${LOG_FILE})"

# 開始時刻を記録
START_TIME=$(date +%s)
START_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# 実行開始のタイムスタンプをログに記録
{
    echo "========================================"
    echo "[${START_TIMESTAMP}] rsync開始"
    echo "ソース: /mnt/fileserver/"
    echo "宛先: /mnt/fileserver-backup/"
    if [ -n "${DELETE_FLAG}" ]; then
        echo "オプション: --delete（宛先の不要ファイルを削除）"
    fi
    echo "PID: $$"
    echo "========================================"
} | tee -a ${LOG_FILE} > /dev/null

# rsyncの実行前にソース・宛先の存在確認
if [ ! -d "/mnt/fileserver" ]; then
    error_exit "ソースディレクトリが見つかりません: /mnt/fileserver"
fi

if [ ! -d "/mnt/fileserver-backup" ]; then
    error_exit "宛先ディレクトリが見つかりません: /mnt/fileserver-backup"
fi

# rsyncコマンドを実行（フォアグラウンドで実行し、完了を待つ）
# オプション:
#   -a: アーカイブモード（パーミッション、タイムスタンプ等を保持）
#   -h: 人間が読みやすい形式
#   -v: 詳細表示
#   --progress: 進捗表示
#   --delete: 宛先にのみ存在するファイルを削除（完全同期）※--delete引数指定時のみ
#   --stats: 統計情報を表示
rsync -ahv --progress ${DELETE_FLAG} --stats \
    /mnt/fileserver/ \
    /mnt/fileserver-backup/ \
    >> ${LOG_FILE} 2>&1

# rsyncの終了ステータスを保存
RSYNC_EXIT_CODE=$?

# 終了時刻を記録
END_TIME=$(date +%s)
END_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
ELAPSED_TIME=$((END_TIME - START_TIME))

# 経過時間を人間が読みやすい形式に変換
ELAPSED_HOURS=$((ELAPSED_TIME / 3600))
ELAPSED_MINUTES=$(((ELAPSED_TIME % 3600) / 60))
ELAPSED_SECONDS=$((ELAPSED_TIME % 60))

# 終了ステータスをログに記録
{
    echo "========================================"
    echo "[${END_TIMESTAMP}] rsync終了"
    if [ ${RSYNC_EXIT_CODE} -eq 0 ]; then
        echo "ステータス: 成功"
    else
        echo "ステータス: 失敗 (終了コード: ${RSYNC_EXIT_CODE})"
    fi
    echo "実行時間: ${ELAPSED_HOURS}時間 ${ELAPSED_MINUTES}分 ${ELAPSED_SECONDS}秒"
    echo "========================================"
    echo ""
} | tee -a ${LOG_FILE} > /dev/null

# ロックファイルを削除
rm -f ${LOCK_FILE}

# rsyncの終了コードをそのまま返す
exit ${RSYNC_EXIT_CODE}
