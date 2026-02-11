#!/bin/bash

cd $(dirname $0)

# AWS CLIを元のユーザーとして実行する関数
run_aws_cli() {
    if [ -n "${SUDO_USER}" ]; then
        sudo -u ${SUDO_USER} /usr/local/bin/aws "$@"
    else
        /usr/local/bin/aws "$@"
    fi
}

# 引数チェック
SERVER_NAME=$1

if [ -z "${SERVER_NAME}" ]; then
    echo "エラー: サーバー名を指定してください。"
    echo ""
    echo "使用方法: $0 <サーバー名>"
    echo ""
    echo "例:"
    echo "  $0 BackupServer"
    echo ""
    exit 1
fi

# リージョン設定
AWS_REGION="ap-northeast-1"

# CloudWatch Agent設定ファイルのパス
CONFIG_FILE="/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"

echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
echo "CloudWatch Agentのセットアップを開始します。"
echo ""
echo "設定内容:"
echo "  サーバー名: ${SERVER_NAME}"
echo "  リージョン: ${AWS_REGION}"
echo "  メトリクス: CPU, メモリ, ディスク使用率, ディスク空き容量"
echo "  ログ: Sambaログ (/var/log/samba/log.smbd, /var/log/samba/log.nmbd)"
echo "        システムログ (/var/log/messages)"
echo "  ロググループ名: /onprem/${SERVER_NAME}"
echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
echo ""

# 実行確認
read -p "この設定でCloudWatch Agentをセットアップしてよろしいですか？ (Y/n) " yn

case ${yn} in
[yY])
    echo ""
    echo "セットアップを開始します..."
    echo ""

    # Step 1: CloudWatch Agentのインストール確認
    if command -v amazon-cloudwatch-agent-ctl &> /dev/null; then
        echo "CloudWatch Agentは既にインストールされています。"
    else
        echo "Step 1: CloudWatch Agentのダウンロードとインストール"

        # RPMパッケージをダウンロード
        echo "RPMパッケージをダウンロード中..."
        wget -q https://s3.${AWS_REGION}.amazonaws.com/amazoncloudwatch-agent-${AWS_REGION}/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm

        if [ $? -ne 0 ]; then
            echo "エラー: CloudWatch Agentのダウンロードに失敗しました。"
            exit 1
        fi

        # RPMパッケージをインストール
        echo "CloudWatch Agentをインストール中..."
        sudo rpm -U ./amazon-cloudwatch-agent.rpm

        if [ $? -ne 0 ]; then
            echo "エラー: CloudWatch Agentのインストールに失敗しました。"
            exit 1
        fi

        # ダウンロードしたRPMファイルを削除
        rm -f ./amazon-cloudwatch-agent.rpm

        echo "CloudWatch Agentのインストールが完了しました。"
    fi

    echo ""
    echo "Step 2: CloudWatch Agent設定ファイルの作成"

    # 設定ファイルを作成
    sudo bash -c "cat > ${CONFIG_FILE}" <<EOF
{
  "agent": {
    "region": "${AWS_REGION}",
    "run_as_user": "root"
  },
  "metrics": {
    "namespace": "OnPremises/${SERVER_NAME}",
    "metrics_collected": {
      "cpu": {
        "measurement": [
          {
            "name": "cpu_usage_idle",
            "rename": "CPU_IDLE",
            "unit": "Percent"
          },
          {
            "name": "cpu_usage_iowait",
            "rename": "CPU_IOWAIT",
            "unit": "Percent"
          }
        ],
        "metrics_collection_interval": 60,
        "totalcpu": true
      },
      "disk": {
        "measurement": [
          {
            "name": "used_percent",
            "rename": "DISK_USED_PERCENT",
            "unit": "Percent"
          },
          {
            "name": "free",
            "rename": "DISK_FREE",
            "unit": "Bytes"
          },
          {
            "name": "used",
            "rename": "DISK_USED",
            "unit": "Bytes"
          }
        ],
        "metrics_collection_interval": 60,
        "resources": [
          "/"
        ]
      },
      "mem": {
        "measurement": [
          {
            "name": "mem_used_percent",
            "rename": "MEM_USED_PERCENT",
            "unit": "Percent"
          },
          {
            "name": "mem_available",
            "rename": "MEM_AVAILABLE",
            "unit": "Bytes"
          },
          {
            "name": "mem_used",
            "rename": "MEM_USED",
            "unit": "Bytes"
          }
        ],
        "metrics_collection_interval": 60
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/samba/log.smbd",
            "log_group_name": "/onprem/${SERVER_NAME}",
            "log_stream_name": "smbd",
            "timezone": "Local"
          },
          {
            "file_path": "/var/log/samba/log.nmbd",
            "log_group_name": "/onprem/${SERVER_NAME}",
            "log_stream_name": "nmbd",
            "timezone": "Local"
          },
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/onprem/${SERVER_NAME}",
            "log_stream_name": "messages",
            "timezone": "Local"
          }
        ]
      }
    }
  }
}
EOF

    if [ $? -ne 0 ]; then
        echo "エラー: 設定ファイルの作成に失敗しました。"
        exit 1
    fi

    echo "設定ファイルを作成しました: ${CONFIG_FILE}"
    echo ""

    echo "Step 3: systemdサービスファイルの設定"

    # CloudWatch AgentがSSM Agentの認証情報を使用できるようにsystemdサービスファイルを修正
    # リージョン情報を環境変数として設定
    sudo bash -c "cat > /etc/systemd/system/amazon-cloudwatch-agent.service" <<EOF
# Amazon CloudWatch Agent Service for On-Premises (Hybrid Activation)
[Unit]
Description=Amazon CloudWatch Agent
After=network.target amazon-ssm-agent.service
Wants=amazon-ssm-agent.service

[Service]
Type=simple
ExecStart=/opt/aws/amazon-cloudwatch-agent/bin/start-amazon-cloudwatch-agent
KillMode=process
Restart=on-failure
RestartSec=60s

# 環境変数: リージョンを明示的に設定
Environment="AWS_REGION=${AWS_REGION}"
Environment="AWS_DEFAULT_REGION=${AWS_REGION}"

# オンプレミス環境ではIMDS（EC2メタデータサービス）が存在しないため無効化
# entitystore ExtensionがIMDSへの接続を試みて10分間タイムアウトするのを防止
Environment="AWS_EC2_METADATA_DISABLED=true"

[Install]
WantedBy=multi-user.target
EOF

    if [ $? -ne 0 ]; then
        echo "エラー: systemdサービスファイルの作成に失敗しました。"
        exit 1
    fi

    echo "systemdサービスファイルを設定しました: /etc/systemd/system/amazon-cloudwatch-agent.service"

    # systemdデーモンをリロード
    sudo systemctl daemon-reload

    if [ $? -ne 0 ]; then
        echo "エラー: systemdデーモンのリロードに失敗しました。"
        exit 1
    fi

    echo "systemdデーモンをリロードしました"
    echo ""

    echo "Step 4: AWS設定ファイルの作成"

    # /root/.aws/config ファイルを作成（リージョン設定）
    sudo mkdir -p /root/.aws
    sudo bash -c "cat > /root/.aws/config" <<EOF
[default]
region = ${AWS_REGION}
EOF

    if [ $? -ne 0 ]; then
        echo "エラー: AWS設定ファイルの作成に失敗しました。"
        exit 1
    fi

    sudo chmod 600 /root/.aws/config
    sudo chown root:root /root/.aws/config

    echo "AWS設定ファイルを作成しました: /root/.aws/config"
    echo ""

    echo "Step 5: 共通設定ファイルの作成"

    # common-config.tomlでSSM Agentが生成した認証情報ファイルを指定
    sudo bash -c "cat > /opt/aws/amazon-cloudwatch-agent/etc/common-config.toml" <<EOF
# CloudWatch Agent common configuration for on-premises (Hybrid Activation)
# Reference: https://dev.classmethod.jp/articles/tsnote-hybrid-activation-cloudwatch-agent-using-iam-role-001/

[credentials]
  shared_credential_profile = "default"
  shared_credential_file = "/root/.aws/credentials"

[proxy]
  http_proxy = ""
  https_proxy = ""
  no_proxy = ""
EOF

    if [ $? -ne 0 ]; then
        echo "エラー: 共通設定ファイルの作成に失敗しました。"
        exit 1
    fi

    echo "共通設定ファイルを作成しました: /opt/aws/amazon-cloudwatch-agent/etc/common-config.toml"
    echo ""

    echo "Step 6: SSM Parameter Storeに設定を保存（オプション）"

    # SSM Parameter Storeのパラメータ名
    PARAMETER_NAME="AmazonCloudWatch-${SERVER_NAME}-Config"

    # 設定をParameter Storeに保存（バックアップ目的）
    echo "設定をSSM Parameter Storeに保存中: ${PARAMETER_NAME}"

    # 設定ファイルの内容を読み取り
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo "エラー: 設定ファイルが見つかりません: ${CONFIG_FILE}"
        exit 1
    fi

    CONFIG_CONTENT=$(sudo cat ${CONFIG_FILE})

    # 元のユーザーとしてawsコマンドを実行（sudo環境でも認証情報にアクセス可能）
    run_aws_cli ssm put-parameter \
        --name "${PARAMETER_NAME}" \
        --type "String" \
        --value "${CONFIG_CONTENT}" \
        --overwrite \
        --region ${AWS_REGION} \
        --profile FileServers > /dev/null

    if [ $? -ne 0 ]; then
        echo "警告: SSM Parameter Storeへの保存に失敗しました（省略可能な手順です）"
    else
        echo "SSM Parameter Storeに保存しました: ${PARAMETER_NAME}"
    fi
    echo ""

    echo "Step 7: CloudWatch Agentの設定適用"
    echo "CloudWatch Agentに設定を適用し、起動します..."
    echo ""

    # CloudWatch Agentに設定を適用して起動
    sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
        -a fetch-config \
        -m onPremise \
        -s \
        -c file:${CONFIG_FILE}

    if [ $? -ne 0 ]; then
        echo ""
        echo "エラー: CloudWatch Agentの設定適用に失敗しました。"
        echo ""
        echo "トラブルシューティング:"
        echo "  1. SSM Agentが正しく登録されているか確認:"
        echo "     sudo systemctl status amazon-ssm-agent"
        echo ""
        echo "  2. ハイブリッドアクティベーションが有効か確認:"
        echo "     sudo cat /var/lib/amazon/ssm/registration"
        echo ""
        echo "  3. IAMロールに必要な権限があるか確認:"
        echo "     - cloudwatch:PutMetricData"
        echo "     - logs:CreateLogGroup"
        echo "     - logs:CreateLogStream"
        echo "     - logs:PutLogEvents"
        echo ""
        exit 1
    fi

    echo ""
    echo "CloudWatch Agentの設定適用が完了しました。"
    echo ""

    echo ""

    # ステータス確認
    echo ""
    echo "Step 8: CloudWatch Agentのステータス確認"
    sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
        -a status \
        -m onPremise

    echo ""
    echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "CloudWatch Agentのセットアップが完了しました。"
    echo ""
    echo "確認事項:"
    echo "  1. AWS CloudWatchコンソールでメトリクスが表示されることを確認してください"
    echo "     - 名前空間: OnPremises/${SERVER_NAME}"
    echo "     - メトリクス: CPU_IDLE, CPU_IOWAIT, DISK_USED_PERCENT, DISK_FREE, MEM_USED_PERCENT など"
    echo ""
    echo "  2. CloudWatch Logsでログが収集されていることを確認してください"
    echo "     - ロググループ: /onprem/${SERVER_NAME}"
    echo "       ログストリーム: smbd, nmbd, messages"
    echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo ""
    echo "CloudWatch Agent管理コマンド:"
    echo "  - ステータス確認:"
    echo "    sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status -m onPremise"
    echo ""
    echo "  - 停止:"
    echo "    sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop -m onPremise"
    echo ""
    echo "  - 再起動（設定を再読み込み）:"
    echo "    sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m onPremise -s -c file:${CONFIG_FILE}"
    echo ""
    echo "  - systemctlでの確認:"
    echo "    sudo systemctl status amazon-cloudwatch-agent"
    echo ""
    ;;
*)
    # 中止
    echo "セットアップを中止しました。"
    exit 0
    ;;
esac

exit 0
