#!/bin/bash

cd $(dirname $0)

# 引数チェック
SERVER_NAME=$1

if [ -z "${SERVER_NAME}" ]; then
    echo "エラー: サーバー名を指定してください。"
    echo ""
    echo "使用方法: $0 <サーバー名>"
    echo ""
    echo "例:"
    echo "  $0 ServerA"
    echo "  $0 ServerB"
    echo ""
    exit 1
fi

# AWSプロファイル設定
AWS_PROFILE="FileServers"

# リージョン設定
AWS_REGION="ap-northeast-1"

# IAMロール名
IAM_ROLE_NAME="SSMCloudWatchAgentRole"

# デフォルトインスタンス名（引数から設定）
DEFAULT_INSTANCE_NAME="${SERVER_NAME}"

# 登録制限数（個別アクティベーション用）
REGISTRATION_LIMIT=1

# 出力ファイル名（サーバー名とタイムスタンプ付き）
OUTPUT_FILE="activation-${SERVER_NAME}-$(date +%Y%m%d-%H%M%S).json"

echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
echo "SSM ハイブリッドアクティベーションを作成します。"
echo ""
echo "設定内容:"
echo "  サーバー名: ${SERVER_NAME}"
echo "  説明: Activation for ${SERVER_NAME}"
echo "  タグ: Name=${SERVER_NAME}"
echo "  IAMロール名: ${IAM_ROLE_NAME}"
echo "  デフォルトインスタンス名: ${DEFAULT_INSTANCE_NAME}"
echo "  登録制限数: ${REGISTRATION_LIMIT}"
echo "  リージョン: ${AWS_REGION}"
echo "  AWSプロファイル: ${AWS_PROFILE}"
echo "------------------------------------------------------------------------------------------------------------------------------------------------------"

# 実行確認
read -p "この設定でアクティベーションを作成してよろしいですか？ (Y/n) " yn

case ${yn} in
[yY])
    echo ""
    echo "アクティベーションを作成中..."
    echo ""

    # IAMロールのARN取得
    IAM_ROLE_ARN=$(aws iam get-role \
        --role-name ${IAM_ROLE_NAME} \
        --query 'Role.Arn' \
        --output text \
        --profile ${AWS_PROFILE} 2>/dev/null)

    if [ -z "${IAM_ROLE_ARN}" ]; then
        echo "エラー: IAMロール '${IAM_ROLE_NAME}' が見つかりません。"
        echo "先にCloudFormationでIAMロールを作成してください。"
        exit 1
    fi

    echo "IAMロールARN: ${IAM_ROLE_ARN}"
    echo ""

    # ハイブリッドアクティベーション作成
    ACTIVATION_RESULT=$(aws ssm create-activation \
        --default-instance-name ${DEFAULT_INSTANCE_NAME} \
        --description "Activation for ${SERVER_NAME}" \
        --iam-role ${IAM_ROLE_NAME} \
        --registration-limit ${REGISTRATION_LIMIT} \
        --tags Key=Name,Value=${SERVER_NAME} \
        --region ${AWS_REGION} \
        --profile ${AWS_PROFILE} \
        --output json)

    if [ $? -eq 0 ]; then
        echo "アクティベーションの作成に成功しました。"
        echo ""
        echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
        echo "【重要】以下の情報は1回のみ表示されます。安全な場所に保管してください。"
        echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
        echo ""

        # ActivationIDとActivationCodeを抽出
        ACTIVATION_ID=$(echo ${ACTIVATION_RESULT} | jq -r '.ActivationId')
        ACTIVATION_CODE=$(echo ${ACTIVATION_RESULT} | jq -r '.ActivationCode')

        echo "Activation ID: ${ACTIVATION_ID}"
        echo "Activation Code: ${ACTIVATION_CODE}"
        echo ""

        # 結果をJSONファイルに保存
        echo ${ACTIVATION_RESULT} | jq '.' > ${OUTPUT_FILE}

        # ドキュメントファイル名
        DOC_FILE="How_to_Activation_for_${SERVER_NAME}.md"
        CURRENT_DATE=$(date +"%Y-%m-%d %H:%M:%S")

        # マークダウンドキュメント生成
        cat > ${DOC_FILE} <<EOF
# SSM ハイブリッドアクティベーション - ${SERVER_NAME}

## アクティベーション情報

| 項目 | 値 |
|------|-----|
| サーバー名 | ${SERVER_NAME} |
| Activation ID | \`${ACTIVATION_ID}\` |
| Activation Code | \`${ACTIVATION_CODE}\` |
| リージョン | ${AWS_REGION} |
| IAMロール | ${IAM_ROLE_NAME} |
| 作成日時 | ${CURRENT_DATE} |
| 登録制限数 | ${REGISTRATION_LIMIT}台 |

**重要**: Activation Codeは機密情報です。安全に保管し、第三者と共有しないでください。

---

## 前提条件

### ネットワーク要件
- オンプレミスサーバーからAWS Systems Managerエンドポイントへの通信が可能であること
- 必要なアウトバウンド通信:
  - HTTPS (443): ssm.\${region}.amazonaws.com
  - HTTPS (443): ssmmessages.\${region}.amazonaws.com
  - HTTPS (443): ec2messages.\${region}.amazonaws.com

### システム要件
- サポートされているOS（RHEL 8/9、Rocky Linux 8/9、Ubuntu 20.04/22.04/24.04、Debian 11/12）
- rootまたはsudo権限
- インターネット接続

---

## 登録手順

### 1. RHEL / Rocky Linux の場合

#### Step 1: SSM Agentのダウンロードとインストール

RHEL/Rocky Linuxでは、SSM Agentはデフォルトリポジトリにないため、AWS S3から直接RPMパッケージをダウンロードしてインストールします。

\`\`\`bash
# RPMパッケージをダウンロードしてインストール
sudo dnf install -y https://s3.${AWS_REGION}.amazonaws.com/amazon-ssm-${AWS_REGION}/latest/linux_amd64/amazon-ssm-agent.rpm
\`\`\`

または、個別にダウンロードしてからインストール:

\`\`\`bash
# RPMパッケージをダウンロード
wget https://s3.${AWS_REGION}.amazonaws.com/amazon-ssm-${AWS_REGION}/latest/linux_amd64/amazon-ssm-agent.rpm

# ダウンロードしたRPMパッケージをインストール
sudo dnf install -y ./amazon-ssm-agent.rpm
\`\`\`

#### Step 2: SSM Agentの停止

\`\`\`bash
sudo systemctl stop amazon-ssm-agent
\`\`\`

#### Step 3: ハイブリッドアクティベーションの登録

\`\`\`bash
sudo amazon-ssm-agent -register \\
  -code "${ACTIVATION_CODE}" \\
  -id "${ACTIVATION_ID}" \\
  -region "${AWS_REGION}"
\`\`\`

#### Step 4: SSM Agentの起動と自動起動設定

\`\`\`bash
sudo systemctl start amazon-ssm-agent
sudo systemctl enable amazon-ssm-agent
\`\`\`

#### Step 5: ステータス確認

\`\`\`bash
sudo systemctl status amazon-ssm-agent
\`\`\`

---

### 2. Ubuntu / Debian の場合

#### Step 1: SSM Agentのダウンロードとインストール

Ubuntu/Debianでは、SSM Agentはデフォルトリポジトリにないため、AWS S3から直接DEBパッケージをダウンロードしてインストールします。

\`\`\`bash
# 作業ディレクトリに移動
cd /tmp

# DEBパッケージをダウンロード
wget https://s3.${AWS_REGION}.amazonaws.com/amazon-ssm-${AWS_REGION}/latest/debian_amd64/amazon-ssm-agent.deb

# ダウンロードしたDEBパッケージをインストール
sudo dpkg -i amazon-ssm-agent.deb

# 依存関係を解決（エラーが出た場合のみ実行）
sudo apt-get install -f -y
\`\`\`

#### Step 2: SSM Agentの停止

\`\`\`bash
sudo systemctl stop amazon-ssm-agent
\`\`\`

#### Step 3: ハイブリッドアクティベーションの登録

\`\`\`bash
sudo amazon-ssm-agent -register \\
  -code "${ACTIVATION_CODE}" \\
  -id "${ACTIVATION_ID}" \\
  -region "${AWS_REGION}"
\`\`\`

#### Step 4: SSM Agentの起動と自動起動設定

\`\`\`bash
sudo systemctl start amazon-ssm-agent
sudo systemctl enable amazon-ssm-agent
\`\`\`

#### Step 5: ステータス確認

\`\`\`bash
sudo systemctl status amazon-ssm-agent
\`\`\`

---

## 登録後の確認

### AWSマネジメントコンソールでの確認

1. AWS Systems Managerコンソールにアクセス
2. 左メニューから「フリートマネージャー」を選択
3. マネージドインスタンスの一覧に「${SERVER_NAME}-」で始まるインスタンスが表示されることを確認
4. Ping StatusがOnlineになっていることを確認

### CLIでの確認

\`\`\`bash
aws ssm describe-instance-information \\
  --filters "Key=ActivationIds,Values=${ACTIVATION_ID}" \\
  --region ${AWS_REGION} \\
  --profile ${AWS_PROFILE}
\`\`\`

### ローカルでの確認

\`\`\`bash
# ログファイルの確認
sudo tail -f /var/log/amazon/ssm/amazon-ssm-agent.log

# エージェントの状態確認
sudo systemctl status amazon-ssm-agent
\`\`\`

---

## トラブルシューティング

### 登録が失敗する場合

#### エラー: "InvalidActivation"
- Activation IDまたはActivation Codeが間違っている
- アクティベーションの有効期限が切れている（デフォルト30日）
- 登録制限数（${REGISTRATION_LIMIT}台）に達している

**対処法**: アクティベーション情報を再確認し、必要に応じて新しいアクティベーションを作成

#### エラー: "RequestError"
- ネットワーク接続の問題
- プロキシ設定が必要な環境でプロキシが設定されていない
- ファイアウォールでAWS Systems Managerエンドポイントへの通信がブロックされている

**対処法**:
1. ネットワーク接続を確認
   \`\`\`bash
   curl -I https://ssm.${AWS_REGION}.amazonaws.com
   \`\`\`

2. プロキシが必要な場合、環境変数を設定
   \`\`\`bash
   export http_proxy=http://proxy.example.com:8080
   export https_proxy=http://proxy.example.com:8080
   export no_proxy=169.254.169.254
   \`\`\`

3. SSM Agent設定ファイルにプロキシを追加
   \`\`\`bash
   # /etc/amazon/ssm/amazon-ssm-agent.json に追加
   sudo vi /etc/amazon/ssm/amazon-ssm-agent.json
   \`\`\`

### Ping StatusがOfflineの場合

**原因**:
- SSM Agentが起動していない
- ネットワーク接続の問題
- IAMロールの権限不足

**対処法**:
1. SSM Agentの再起動
   \`\`\`bash
   sudo systemctl restart amazon-ssm-agent
   \`\`\`

2. ログファイルの確認
   \`\`\`bash
   sudo tail -100 /var/log/amazon/ssm/amazon-ssm-agent.log
   sudo tail -100 /var/log/amazon/ssm/errors.log
   \`\`\`

---

## セキュリティのベストプラクティス

### 1. Activation Codeの管理
- Activation Codeはパスワードと同様に扱う
- 使用後は安全な場所に保管
- 不要になったアクティベーションは削除

### 2. アクティベーションの削除

使用済みまたは不要なアクティベーションは削除してください。

\`\`\`bash
aws ssm delete-activation \\
  --activation-id ${ACTIVATION_ID} \\
  --region ${AWS_REGION} \\
  --profile ${AWS_PROFILE}
\`\`\`

### 3. マネージドインスタンスの登録解除

サーバーを廃止する場合、マネージドインスタンスを登録解除してください。

\`\`\`bash
# インスタンスIDを取得
INSTANCE_ID=\$(aws ssm describe-instance-information \\
  --filters "Key=ActivationIds,Values=${ACTIVATION_ID}" \\
  --query "InstanceInformationList[0].InstanceId" \\
  --output text \\
  --region ${AWS_REGION} \\
  --profile ${AWS_PROFILE})

# 登録解除
aws ssm deregister-managed-instance \\
  --instance-id \${INSTANCE_ID} \\
  --region ${AWS_REGION} \\
  --profile ${AWS_PROFILE}
\`\`\`

---

## 参考情報

### AWS公式ドキュメント
- [ハイブリッド環境向けに AWS Systems Manager を設定する](https://docs.aws.amazon.com/ja_jp/systems-manager/latest/userguide/systems-manager-managedinstances.html)
- [SSM Agent のインストール](https://docs.aws.amazon.com/ja_jp/systems-manager/latest/userguide/ssm-agent.html)

### 関連ファイル
- アクティベーション詳細（JSON）: \`${OUTPUT_FILE}\`
- このドキュメント: \`${DOC_FILE}\`

---

**生成日時**: ${CURRENT_DATE}
**AWSプロファイル**: ${AWS_PROFILE}
EOF

        echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
        echo "アクティベーション情報を以下のファイルに保存しました:"
        echo "  - JSON: ${OUTPUT_FILE}"
        echo "  - ドキュメント: ${DOC_FILE}"
        echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
        echo ""
        echo "次のステップ:"
        echo "  1. ${DOC_FILE} を開いて登録手順を確認してください"
        echo "  2. オンプレミスサーバー（${SERVER_NAME}）で登録コマンドを実行してください"
        echo "  3. AWS Systems Managerコンソールでインスタンスが登録されたことを確認してください"
        echo ""

    else
        echo "エラー: アクティベーションの作成に失敗しました。"
        exit 1
    fi
    ;;
*)
    # 中止
    echo "アクティベーション作成を中止しました。"
    exit 0
    ;;
esac

exit 0
