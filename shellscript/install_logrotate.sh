#!/bin/bash

cd $(dirname $0)

# ログローテーション設定ファイルのインストールスクリプト

echo "=========================================="
echo "ログローテーション設定のインストール"
echo "=========================================="
echo ""

# 設定ファイルのパス
SOURCE_FILE="config/rsync_logrotate.conf"
DEST_FILE="/etc/logrotate.d/rsync_fileserver"
LOG_FILE="/var/log/rsync/rsync_fileserver.log"

# 設定ファイルの存在確認
if [ ! -f "${SOURCE_FILE}" ]; then
    echo "エラー: 設定ファイルが見つかりません: ${SOURCE_FILE}"
    exit 1
fi

# 設定内容の表示
echo "インストールする設定:"
echo "  設定ファイル: ${SOURCE_FILE}"
echo "  インストール先: ${DEST_FILE}"
echo "  対象ログファイル: ${LOG_FILE}"
echo ""
echo "ローテーション設定:"
echo "  頻度: 日次 (daily)"
echo "  保持世代数: 30日分"
echo "  圧縮: 有効 (gzip)"
echo "  最新世代: 無圧縮 (delaycompress)"
echo ""

# 既存設定の確認
if [ -f "${DEST_FILE}" ]; then
    echo "警告: 既存の設定ファイルが見つかりました: ${DEST_FILE}"
    echo "既存の設定は上書きされます。"
    echo ""
fi

# 実行確認
read -p "この設定でログローテーション設定をインストールしてよろしいですか？ (Y/n) " yn

case ${yn} in
[yY])
    echo ""
    echo "インストールを開始します..."
    echo ""

    # Step 1: 設定ファイルをコピー
    echo "Step 1: 設定ファイルのコピー"
    sudo cp "${SOURCE_FILE}" "${DEST_FILE}"

    if [ $? -ne 0 ]; then
        echo "エラー: 設定ファイルのコピーに失敗しました。"
        exit 1
    fi

    echo "設定ファイルをコピーしました: ${DEST_FILE}"
    echo ""

    # Step 2: パーミッション設定
    echo "Step 2: パーミッションの設定"
    sudo chmod 644 "${DEST_FILE}"

    if [ $? -ne 0 ]; then
        echo "エラー: パーミッションの設定に失敗しました。"
        exit 1
    fi

    echo "パーミッションを設定しました: 644 (rw-r--r--)"
    echo ""

    # Step 3: 構文チェック
    echo "Step 3: 設定の構文チェック"
    sudo logrotate -d "${DEST_FILE}" > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo "警告: 構文チェックでエラーが発生しました。"
        echo "詳細を確認するには以下を実行してください:"
        echo "  sudo logrotate -d ${DEST_FILE}"
        echo ""
    else
        echo "構文チェック: 正常"
        echo ""
    fi

    # Step 4: ログディレクトリの確認
    echo "Step 4: ログディレクトリの確認"
    LOG_DIR=$(dirname "${LOG_FILE}")

    if [ ! -d "${LOG_DIR}" ]; then
        echo "ログディレクトリが存在しないため作成します: ${LOG_DIR}"
        sudo mkdir -p "${LOG_DIR}"
        sudo chmod 700 "${LOG_DIR}"
        echo "ログディレクトリを作成しました。"
    else
        echo "ログディレクトリは既に存在します: ${LOG_DIR}"
    fi
    echo ""

    # Step 5: インストール結果の確認
    echo "=========================================="
    echo "インストールが完了しました"
    echo "=========================================="
    echo ""
    echo "インストールされた設定:"
    echo "  設定ファイル: ${DEST_FILE}"
    echo "  パーミッション: $(sudo stat -c '%a' ${DEST_FILE}) ($(sudo stat -c '%A' ${DEST_FILE}))"
    echo "  所有者: $(sudo stat -c '%U:%G' ${DEST_FILE})"
    echo ""
    echo "ログローテーションの動作:"
    echo "  - 毎日自動的にログがローテーションされます"
    echo "  - 実行タイミング: 毎日午前3時頃（cron.daily）"
    echo "  - 保持期間: 30日分"
    echo "  - 古いログは自動的に圧縮されます（.gz）"
    echo ""
    echo "確認コマンド:"
    echo "  # 設定内容の確認"
    echo "  sudo cat ${DEST_FILE}"
    echo ""
    echo "  # 構文チェック（ドライラン）"
    echo "  sudo logrotate -d ${DEST_FILE}"
    echo ""
    echo "  # 詳細モードで実行確認"
    echo "  sudo logrotate -v ${DEST_FILE}"
    echo ""
    echo "  # 強制実行（テスト）"
    echo "  sudo logrotate -f ${DEST_FILE}"
    echo ""
    echo "  # ローテーション状況の確認"
    echo "  sudo grep rsync_fileserver /var/lib/logrotate/logrotate.status"
    echo ""
    ;;
*)
    # 中止
    echo "インストールを中止しました。"
    exit 0
    ;;
esac

exit 0
