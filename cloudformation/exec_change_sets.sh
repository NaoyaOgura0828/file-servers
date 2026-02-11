#!/bin/bash

cd $(dirname $0)

# AWSプロファイル設定
AWS_PROFILE="FileServers"

# 変更セット作成・実行関数
exec_change_set() {
    SERVICE_NAME=$1
    STACK_NAME=${SERVICE_NAME}
    TEMPLATE_PATH="./templates/${SERVICE_NAME}/${SERVICE_NAME}.yml"
    CHANGE_SET_NAME="${STACK_NAME}-change-set"

    echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "変更セット: ${CHANGE_SET_NAME}を作成します。"

    # 変更セット作成
    aws cloudformation create-change-set \
        --stack-name ${STACK_NAME} \
        --change-set-name ${CHANGE_SET_NAME} \
        --template-body file://${TEMPLATE_PATH} \
        --capabilities CAPABILITY_NAMED_IAM \
        --profile ${AWS_PROFILE}

    # ChangeSetCreateComplete 待機
    aws cloudformation wait change-set-create-complete \
        --stack-name ${STACK_NAME} \
        --change-set-name ${CHANGE_SET_NAME} \
        --profile ${AWS_PROFILE}

    # 変更セット Status 取得
    CHANGE_SET_STATUS=$(aws cloudformation describe-change-set \
        --stack-name ${STACK_NAME} \
        --change-set-name ${CHANGE_SET_NAME} \
        --query 'Status' \
        --output text \
        --profile ${AWS_PROFILE})

    # 変更セット作成失敗時処理
    if [ "$CHANGE_SET_STATUS" = "FAILED" ]; then
        echo "変更セットの作成に失敗しました。"
        echo "変更セット: ${CHANGE_SET_NAME}を削除します。"

        # 変更セット削除
        aws cloudformation delete-change-set \
            --stack-name ${STACK_NAME} \
            --change-set-name ${CHANGE_SET_NAME} \
            --profile ${AWS_PROFILE}

        echo "変更セット: ${CHANGE_SET_NAME}を削除しました。"
        return 1
    fi

    # 変更セット詳細表示
    DESCRIBE_CHANGE_SET=$(aws cloudformation describe-change-set \
        --stack-name ${STACK_NAME} \
        --change-set-name ${CHANGE_SET_NAME} \
        --query 'Changes[*].[ResourceChange.Action, ResourceChange.LogicalResourceId, ResourceChange.PhysicalResourceId, ResourceChange.ResourceType, ResourceChange.Replacement]' \
        --output json \
        --profile ${AWS_PROFILE})

    echo "変更セット: ${CHANGE_SET_NAME}"
    echo "$DESCRIBE_CHANGE_SET" | jq -r '.[] | "--------------------------------------------------\nアクション: \(.[0])\n論理ID: \(.[1])\n物理ID: \(.[2])\nリソースタイプ: \(.[3])\n置換: \(.[4])"'
    echo "--------------------------------------------------"

    # 変更セット実行確認処理
    read -p "変更セット: ${CHANGE_SET_NAME}を実行してよろしいですか？ (Y/n) " yn

    case ${yn} in
    [yY])
        echo "変更セットを実行します。"

        # 変更セット実行
        aws cloudformation execute-change-set \
            --stack-name ${STACK_NAME} \
            --change-set-name ${CHANGE_SET_NAME} \
            --profile ${AWS_PROFILE}

        # StackUpdateComplete 待機
        aws cloudformation wait stack-update-complete \
            --stack-name ${STACK_NAME} \
            --profile ${AWS_PROFILE}

        echo "${STACK_NAME}のUpdateが完了しました。"
        ;;
    *)
        # 中止
        echo "変更セットの実行を中止しました。"

        # 変更セット削除
        aws cloudformation delete-change-set \
            --stack-name ${STACK_NAME} \
            --change-set-name ${CHANGE_SET_NAME} \
            --profile ${AWS_PROFILE}

        echo "変更セット: ${CHANGE_SET_NAME}を削除しました。"
        ;;
    esac

}

#####################################
# 変更対象リソース
#####################################
# IAMロールスタックの変更セット実行
# exec_change_set iam-role

exit 0
