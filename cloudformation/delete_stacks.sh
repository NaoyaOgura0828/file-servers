#!/bin/bash

cd $(dirname $0)

# AWSプロファイル設定
AWS_PROFILE="FileServers"

# ShellScript実行時確認処理
echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
read -p "削除対象リソースで選択された、全リソースを削除します。実行してよろしいですか？ (Y/n) " yn

case ${yn} in
[yY])
    echo '削除を開始します。'

    # スタック削除関数
    delete_stack() {
        SERVICE_NAME=$1
        STACK_NAME=${SERVICE_NAME}

        echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
        echo "スタック: ${STACK_NAME}を削除します。"

        aws cloudformation delete-stack \
            --stack-name ${STACK_NAME} \
            --profile ${AWS_PROFILE}

        aws cloudformation wait stack-delete-complete \
            --stack-name ${STACK_NAME} \
            --profile ${AWS_PROFILE}

        echo "スタック: ${STACK_NAME}の削除が完了しました。"
    }

    #####################################
    # 削除対象リソース
    #####################################
    # IAMロールスタックの削除
    # delete_stack iam-role

    echo '削除が完了しました。'
    ;;
*)
    # 中止
    echo '中止しました。'
    ;;
esac

exit 0
