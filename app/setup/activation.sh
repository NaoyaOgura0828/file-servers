#!/usr/bin/env bash
#
# SSM ハイブリッドアクティベーション作成スクリプト (Ubuntu 26.04 対応)
#
# 指定サーバー名で SSM ハイブリッドアクティベーションを作成し、
# Activation ID/Code を JSON ファイルと登録手順 Markdown に保存する。
#
# 出力ファイル名は .gitignore に列挙済 (activation-*.json / How_to_Activation_for_*.md) のため
# コミット対象外となる。

set -euo pipefail

readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly AWS_PROFILE_NAME="FileServers"
readonly AWS_REGION="ap-northeast-1"
readonly IAM_ROLE_NAME="SSMCloudWatchAgentRole"
readonly REGISTRATION_LIMIT=1

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
使用方法: $0 <サーバー名>

SSM ハイブリッドアクティベーションを作成し、Activation ID/Code および登録手順を出力します。
出力先: ${SCRIPT_DIR}/activation-<サーバー名>-<タイムスタンプ>.json
        ${SCRIPT_DIR}/How_to_Activation_for_<サーバー名>.md

引数:
  <サーバー名>           例: FileServer / BackupServer
                         アクティベーション名・タグ・デフォルトインスタンス名に使用される。

オプション:
  -h, --help             このヘルプを表示

固定値:
  リージョン:            ${AWS_REGION}
  AWS プロファイル:      ${AWS_PROFILE_NAME}
  IAM ロール:            ${IAM_ROLE_NAME}
  登録制限数:            ${REGISTRATION_LIMIT}

前提:
  - aws CLI / jq が PATH 上にインストール済み
  - IAM ロール ${IAM_ROLE_NAME} がアカウントに存在 (CDK fs-prod-iam-role スタック由来)
  - AWS プロファイル ${AWS_PROFILE_NAME} が ssm:CreateActivation / iam:GetRole 権限を持つ
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "エラー: サーバー名を指定してください。" >&2
        echo "詳細は '$0 --help' を参照してください。" >&2
        exit 1
    fi

    SERVER_NAME=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                if [[ -z "${SERVER_NAME}" ]]; then
                    SERVER_NAME="$1"
                else
                    err "複数の引数が指定されています。サーバー名のみを指定してください。"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${SERVER_NAME}" ]]; then
        err "サーバー名を指定してください。"
    fi
}

# ----------------------------------------------------------------------------
# 前提チェック
# ----------------------------------------------------------------------------

ensure_dependencies() {
    command -v aws >/dev/null 2>&1 || err "aws CLI が見つかりません。インストールしてください。"
    command -v jq  >/dev/null 2>&1 || err "jq が見つかりません: 'sudo apt-get install -y jq' で導入してください。"
}

resolve_iam_role_arn() {
    IAM_ROLE_ARN=$(aws iam get-role \
        --role-name "${IAM_ROLE_NAME}" \
        --query 'Role.Arn' \
        --output text \
        --profile "${AWS_PROFILE_NAME}" 2>/dev/null) || IAM_ROLE_ARN=""

    if [[ -z "${IAM_ROLE_ARN}" || "${IAM_ROLE_ARN}" == "None" ]]; then
        err "IAM ロール '${IAM_ROLE_NAME}' が見つかりません。CDK スタック fs-prod-iam-role がデプロイ済みか確認してください。"
    fi
}

# ----------------------------------------------------------------------------
# プラン表示 + 確認
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "SSM ハイブリッドアクティベーションを作成します。"
    echo ""
    echo "  サーバー名:               ${SERVER_NAME}"
    echo "  説明:                     Activation for ${SERVER_NAME}"
    echo "  タグ:                     Name=${SERVER_NAME}"
    echo "  IAM ロール (ARN):         ${IAM_ROLE_ARN}"
    echo "  デフォルトインスタンス名: ${SERVER_NAME}"
    echo "  登録制限数:               ${REGISTRATION_LIMIT}"
    echo "  リージョン:               ${AWS_REGION}"
    echo "  AWS プロファイル:         ${AWS_PROFILE_NAME}"
    echo "${sep}"
}

confirm_or_abort() {
    local yn
    read -r -p "この設定でアクティベーションを作成してよろしいですか？ (Y/n) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *)
            echo "アクティベーション作成を中止しました。"
            exit 0
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Activation 作成
# ----------------------------------------------------------------------------

create_activation() {
    echo ""
    echo "アクティベーションを作成中..."
    echo ""

    local result
    result=$(aws ssm create-activation \
        --default-instance-name "${SERVER_NAME}" \
        --description "Activation for ${SERVER_NAME}" \
        --iam-role "${IAM_ROLE_NAME}" \
        --registration-limit "${REGISTRATION_LIMIT}" \
        --tags "Key=Name,Value=${SERVER_NAME}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE_NAME}" \
        --output json) || err "アクティベーションの作成に失敗しました。"

    ACTIVATION_ID=$(echo "${result}" | jq -r '.ActivationId')
    ACTIVATION_CODE=$(echo "${result}" | jq -r '.ActivationCode')

    if [[ -z "${ACTIVATION_ID}" || -z "${ACTIVATION_CODE}" ]]; then
        err "ActivationId / ActivationCode の取得に失敗しました。"
    fi

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    OUTPUT_JSON_PATH="${SCRIPT_DIR}/activation-${SERVER_NAME}-${timestamp}.json"
    OUTPUT_DOC_PATH="${SCRIPT_DIR}/How_to_Activation_for_${SERVER_NAME}.md"

    echo "${result}" | jq '.' > "${OUTPUT_JSON_PATH}"
    chmod 600 "${OUTPUT_JSON_PATH}"
    echo "  作成成功: ActivationId=${ACTIVATION_ID}"
}

# ----------------------------------------------------------------------------
# Markdown ドキュメント生成 (Ubuntu 26.04 向け)
# ----------------------------------------------------------------------------

write_markdown_doc() {
    local now
    now=$(date +"%Y-%m-%d %H:%M:%S")
    local arch_note='dpkg --print-architecture が "arm64" の場合は debian_amd64 を debian_arm64 に置換する。'

    cat > "${OUTPUT_DOC_PATH}" <<EOF
# SSM ハイブリッドアクティベーション - ${SERVER_NAME}

## アクティベーション情報

| 項目 | 値 |
|------|-----|
| サーバー名 | ${SERVER_NAME} |
| Activation ID | \`${ACTIVATION_ID}\` |
| Activation Code | \`${ACTIVATION_CODE}\` |
| リージョン | ${AWS_REGION} |
| IAM ロール | ${IAM_ROLE_NAME} |
| 作成日時 | ${now} |
| 登録制限数 | ${REGISTRATION_LIMIT} 台 |

> [!IMPORTANT]
> Activation Code は機密情報。安全に保管し、第三者と共有しないこと。本ファイルは git 管理外。

---

## 前提条件 (Ubuntu 26.04)

### ネットワーク要件
オンプレサーバーから以下への HTTPS (443) アウトバウンドが許可されていること。
- ssm.${AWS_REGION}.amazonaws.com
- ssmmessages.${AWS_REGION}.amazonaws.com
- ec2messages.${AWS_REGION}.amazonaws.com

### システム要件
- Ubuntu 22.04 / 24.04 / 26.04 (LTS 推奨)
- sudo 権限を持つユーザー
- インターネット接続 (S3 経由でパッケージ DL)

---

## 登録手順 (Ubuntu)

### Step 1: SSM Agent のダウンロード・インストール

\`\`\`bash
ARCH=\$(dpkg --print-architecture)   # amd64 / arm64
cd /tmp
wget "https://s3.${AWS_REGION}.amazonaws.com/amazon-ssm-${AWS_REGION}/latest/debian_\${ARCH}/amazon-ssm-agent.deb"
sudo dpkg -i amazon-ssm-agent.deb || sudo apt-get install -f -y
\`\`\`

> ${arch_note}

### Step 2: SSM Agent を一旦停止

\`\`\`bash
sudo systemctl stop amazon-ssm-agent
\`\`\`

### Step 3: ハイブリッドアクティベーション登録

\`\`\`bash
sudo amazon-ssm-agent -register \\
  -code "${ACTIVATION_CODE}" \\
  -id "${ACTIVATION_ID}" \\
  -region "${AWS_REGION}"
\`\`\`

### Step 4: SSM Agent を起動・自動起動

\`\`\`bash
sudo systemctl enable --now amazon-ssm-agent
\`\`\`

### Step 5: ステータス確認

\`\`\`bash
sudo systemctl status amazon-ssm-agent --no-pager
\`\`\`

---

## 登録後の確認

### マネジメントコンソール

1. AWS Systems Manager > Fleet Manager
2. Managed instances 一覧に \`${SERVER_NAME}-...\` 形式の行が表示される
3. Ping Status が \`Online\` になっていること

### CLI

\`\`\`bash
aws ssm describe-instance-information \\
  --filters "Key=ActivationIds,Values=${ACTIVATION_ID}" \\
  --region ${AWS_REGION} \\
  --profile ${AWS_PROFILE_NAME}
\`\`\`

### サーバー側ログ

\`\`\`bash
sudo tail -f /var/log/amazon/ssm/amazon-ssm-agent.log
\`\`\`

---

## トラブルシューティング

| 症状 | 主因 | 対処 |
|------|------|------|
| \`InvalidActivation\` | Activation 期限切れ (デフォルト 30 日) / 登録上限到達 | 新規アクティベーションを作成 |
| \`RequestError\` / 接続失敗 | エンドポイント疎通不可 | \`curl -I https://ssm.${AWS_REGION}.amazonaws.com\` で疎通確認、必要なら proxy 設定 |
| Ping Status が \`Offline\` | Agent 未起動 / IAM 権限不足 | \`sudo systemctl restart amazon-ssm-agent\` + \`/var/log/amazon/ssm/errors.log\` 確認 |

---

## 廃止時の処理

### アクティベーション削除

\`\`\`bash
aws ssm delete-activation \\
  --activation-id ${ACTIVATION_ID} \\
  --region ${AWS_REGION} \\
  --profile ${AWS_PROFILE_NAME}
\`\`\`

### マネージドインスタンス登録解除

\`\`\`bash
INSTANCE_ID=\$(aws ssm describe-instance-information \\
  --filters "Key=ActivationIds,Values=${ACTIVATION_ID}" \\
  --query "InstanceInformationList[0].InstanceId" \\
  --output text \\
  --region ${AWS_REGION} \\
  --profile ${AWS_PROFILE_NAME})

aws ssm deregister-managed-instance \\
  --instance-id "\${INSTANCE_ID}" \\
  --region ${AWS_REGION} \\
  --profile ${AWS_PROFILE_NAME}
\`\`\`

---

## 関連ファイル

- アクティベーション JSON: \`$(basename "${OUTPUT_JSON_PATH}")\`
- 本ドキュメント: \`$(basename "${OUTPUT_DOC_PATH}")\`

**生成日時**: ${now}
**AWS プロファイル**: ${AWS_PROFILE_NAME}
EOF
    chmod 600 "${OUTPUT_DOC_PATH}"
}

# ----------------------------------------------------------------------------
# サマリ
# ----------------------------------------------------------------------------

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
【重要】Activation Code は本実行でのみ取得可能です。下記ファイルを安全に保管してください。
${sep}

  Activation ID:   ${ACTIVATION_ID}
  Activation Code: ${ACTIVATION_CODE}

  JSON:            ${OUTPUT_JSON_PATH}
  登録手順 (MD):   ${OUTPUT_DOC_PATH}

次の作業:
  1. ${OUTPUT_DOC_PATH} を ${SERVER_NAME} に転送
  2. ${SERVER_NAME} 上で記載の登録コマンドを順次実行
  3. AWS Systems Manager コンソールで Online 状態を確認
${sep}
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    ensure_dependencies
    resolve_iam_role_arn
    print_plan
    confirm_or_abort

    create_activation
    write_markdown_doc
    print_summary
}

main "$@"
