#!/bin/bash

cd $(dirname $0)

# AWSプロファイル設定
AWS_PROFILE="FileServers"

# スタック作成関数
create_stack() {
    SERVICE_NAME=$1
    STACK_NAME=${SERVICE_NAME}
    TEMPLATE_PATH="./templates/${SERVICE_NAME}/${SERVICE_NAME}.yml"

    echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "スタック: ${STACK_NAME}を作成します。"

    aws cloudformation create-stack \
        --stack-name ${STACK_NAME} \
        --template-body file://${TEMPLATE_PATH} \
        --capabilities CAPABILITY_NAMED_IAM \
        --profile ${AWS_PROFILE}

    aws cloudformation wait stack-create-complete \
        --stack-name ${STACK_NAME} \
        --profile ${AWS_PROFILE}

    echo "スタック: ${STACK_NAME}の作成が完了しました。"
}

#####################################
# 構築対象リソース
#####################################
# IAMロールスタックの作成
# create_stack iam-role

exit 0
