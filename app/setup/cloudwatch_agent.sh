#!/usr/bin/env bash
#
# CloudWatch Agent セットアップスクリプト (Ubuntu 26.04 対応)
#
# 設定ファイルを読み込んで CloudWatch Agent をインストール・設定し、
# メトリクスとログ収集を開始する。ハイブリッドアクティベーション環境向け。

set -euo pipefail

readonly AWS_REGION="ap-northeast-1"
readonly AWS_PROFILE_NAME="FileServers"
readonly CWAGENT_DIR="/opt/aws/amazon-cloudwatch-agent"
readonly CWAGENT_CONFIG_PATH="${CWAGENT_DIR}/etc/amazon-cloudwatch-agent.json"
readonly CWAGENT_COMMON_CONFIG_PATH="${CWAGENT_DIR}/etc/common-config.toml"
readonly CWAGENT_SYSTEMD_PATH="/etc/systemd/system/amazon-cloudwatch-agent.service"
readonly DEFAULT_SYSLOG_PATH="/var/log/syslog"
readonly DEFAULT_SAMBA_SMBD_LOG="/var/log/samba/log.smbd"
readonly DEFAULT_SAMBA_NMBD_LOG="/var/log/samba/log.nmbd"

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

# 元のユーザーの認証情報で AWS CLI を実行 (sudo 起動でも .aws/credentials を参照)
run_aws_cli() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "${SUDO_USER}" aws "$@"
    else
        aws "$@"
    fi
}

show_help() {
    cat <<EOF
使用方法: $0 <設定ファイルパス>

CloudWatch Agent をインストール・設定し、メトリクスとログ収集を開始します。
Ubuntu 26.04 (debian-family) のハイブリッドアクティベーション環境向け。

引数:
  <設定ファイルパス>     設定ファイルのパス (必須)
                         絶対パス、CWD 相対パス、または app/config/ 配下のファイル名 (例: FileServer.conf)

オプション:
  -h, --help             このヘルプを表示

設定ファイルの形式:
  SERVER_NAME="FileServer"
  MOUNTPOINTS="/mnt/data /mnt/backup"
  LOG_PATHS="/var/log/rsync/rsync.log:rsync-backup"

デフォルトで監視されるログ:
  - ${DEFAULT_SAMBA_SMBD_LOG}   (ストリーム: smbd)
  - ${DEFAULT_SAMBA_NMBD_LOG}   (ストリーム: nmbd)
  - ${DEFAULT_SYSLOG_PATH}      (ストリーム: syslog)

前提条件:
  - sudo 実行可能なユーザーで起動すること
  - SSM Agent (amazon-ssm-agent) がハイブリッドアクティベーション登録済みであること
  - AWS CLI v2 がインストール済みで、profile "${AWS_PROFILE_NAME}" が設定済み (Parameter Store 保存に使用)
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "エラー: 設定ファイルを指定してください。" >&2
        echo "詳細は '$0 --help' を参照してください。" >&2
        exit 1
    fi

    INPUT_CONFIG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                if [[ -z "${INPUT_CONFIG}" ]]; then
                    INPUT_CONFIG="$1"
                else
                    err "複数の引数が指定されています。設定ファイルパスのみを指定してください。"
                fi
                shift
                ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# 設定ファイルロード
# ----------------------------------------------------------------------------

load_config() {
    # 相対パス指定の場合は次の優先順位で解決:
    #   1. CWD 基準 (-f で既にチェック済み)
    #   2. スクリプト配置ディレクトリ基準 (app/setup/...)
    #   3. app/config 基準 (FileServer.conf 等のファイル名のみ指定)
    if [[ ! -f "${INPUT_CONFIG}" ]]; then
        local script_dir
        script_dir=$(cd "$(dirname "$0")" && pwd)
        local candidates=(
            "${script_dir}/${INPUT_CONFIG}"
            "${script_dir}/../config/${INPUT_CONFIG}"
        )
        local resolved=""
        for c in "${candidates[@]}"; do
            if [[ -f "${c}" ]]; then
                resolved=$(cd "$(dirname "${c}")" && pwd)/$(basename "${c}")
                break
            fi
        done
        if [[ -n "${resolved}" ]]; then
            INPUT_CONFIG="${resolved}"
        else
            err "設定ファイルが見つかりません: ${INPUT_CONFIG}"
        fi
    fi

    echo "設定ファイルを読み込みます: ${INPUT_CONFIG}"
    # shellcheck disable=SC1090
    source "${INPUT_CONFIG}"

    if [[ -z "${SERVER_NAME:-}" ]]; then
        err "設定ファイルに SERVER_NAME が定義されていません。"
    fi

    # MOUNTPOINTS / LOG_PATHS を配列化 (未定義時は空配列)
    ADDITIONAL_MOUNTPOINTS=()
    if [[ -n "${MOUNTPOINTS:-}" ]]; then
        # shellcheck disable=SC2206
        ADDITIONAL_MOUNTPOINTS=(${MOUNTPOINTS})
    fi

    CUSTOM_LOG_PATHS=()
    if [[ -n "${LOG_PATHS:-}" ]]; then
        # shellcheck disable=SC2206
        CUSTOM_LOG_PATHS=(${LOG_PATHS})
    fi
}

# ----------------------------------------------------------------------------
# 設定サマリ + 確認
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "CloudWatch Agent のセットアップを開始します。"
    echo ""
    echo "設定内容:"
    echo "  サーバー名:        ${SERVER_NAME}"
    echo "  リージョン:        ${AWS_REGION}"
    echo "  名前空間:          OnPremises/${SERVER_NAME}"
    echo "  ロググループ名:    /onprem/${SERVER_NAME}"
    echo "  メトリクス:        CPU使用率, メモリ使用率, ディスク使用率, Swap使用率"
    if [[ ${#ADDITIONAL_MOUNTPOINTS[@]} -gt 0 ]]; then
        echo "  監視対象ディスク:  / ${ADDITIONAL_MOUNTPOINTS[*]}"
    else
        echo "  監視対象ディスク:  /"
    fi
    echo "  デフォルトログ:    ${DEFAULT_SAMBA_SMBD_LOG}"
    echo "                     ${DEFAULT_SAMBA_NMBD_LOG}"
    echo "                     ${DEFAULT_SYSLOG_PATH}"
    if [[ ${#CUSTOM_LOG_PATHS[@]} -gt 0 ]]; then
        echo "  カスタムログ:"
        for spec in "${CUSTOM_LOG_PATHS[@]}"; do
            local file stream
            IFS=':' read -r file stream <<< "${spec}"
            [[ -z "${stream}" ]] && stream=$(basename "${file}" | sed 's/\.[^.]*$//')
            echo "                     ${file} (ストリーム: ${stream})"
        done
    fi
    echo "${sep}"
    echo ""
}

confirm_or_abort() {
    local yn
    read -r -p "この設定で CloudWatch Agent をセットアップしてよろしいですか？ (Y/n) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *)
            echo "セットアップを中止しました。"
            exit 0
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Step 1: パッケージ導入 (Ubuntu / debian-family)
# ----------------------------------------------------------------------------

install_agent() {
    echo "Step 1: CloudWatch Agent のインストール"

    if command -v amazon-cloudwatch-agent-ctl >/dev/null 2>&1; then
        echo "  既にインストール済みのためスキップします。"
        return 0
    fi

    local arch
    arch=$(dpkg --print-architecture)
    case "${arch}" in
        amd64|arm64) ;;
        *) err "未対応アーキテクチャです: ${arch} (amd64 / arm64 のみ対応)" ;;
    esac

    local url="https://s3.${AWS_REGION}.amazonaws.com/amazoncloudwatch-agent-${AWS_REGION}/ubuntu/${arch}/latest/amazon-cloudwatch-agent.deb"
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' RETURN
    local deb="${tmp}/amazon-cloudwatch-agent.deb"

    echo "  ダウンロード中 (${arch}): ${url}"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "${deb}" "${url}"; then
        err "CloudWatch Agent (.deb) のダウンロードに失敗しました。"
    fi

    echo "  パッケージをインストール中..."
    if ! sudo dpkg -i "${deb}"; then
        # 依存関係不足を解消して再試行
        echo "  依存関係を解決して再試行します..."
        sudo apt-get update -qq
        sudo apt-get install -y -f
    fi

    if ! command -v amazon-cloudwatch-agent-ctl >/dev/null 2>&1; then
        err "CloudWatch Agent のインストールに失敗しました。"
    fi
    echo "  インストール完了。"
}

# ----------------------------------------------------------------------------
# Step 2: Agent 設定ファイル生成
# ----------------------------------------------------------------------------

write_agent_config() {
    echo "Step 2: CloudWatch Agent 設定ファイルの生成"

    # 監視対象ディスクの JSON 配列
    local disk_resources='          "/"'
    local mp
    for mp in "${ADDITIONAL_MOUNTPOINTS[@]}"; do
        disk_resources+=",
          \"${mp}\""
    done

    # カスタムログの JSON 配列 (デフォルト3件の後にカンマ区切りで追加)
    local custom_logs_json=""
    local spec file stream
    for spec in "${CUSTOM_LOG_PATHS[@]}"; do
        IFS=':' read -r file stream <<< "${spec}"
        if [[ ! -f "${file}" ]]; then
            warn "ログファイルが見つかりません: ${file} (設定には含めますが、収集はファイル生成後に開始されます)"
        fi
        [[ -z "${stream}" ]] && stream=$(basename "${file}" | sed 's/\.[^.]*$//')
        custom_logs_json+=",
          {
            \"file_path\": \"${file}\",
            \"log_group_name\": \"/onprem/${SERVER_NAME}\",
            \"log_stream_name\": \"${stream}\",
            \"timezone\": \"Local\"
          }"
    done

    if [[ ! -f "${DEFAULT_SYSLOG_PATH}" ]]; then
        warn "${DEFAULT_SYSLOG_PATH} が存在しません。Ubuntu 26.04 では rsyslog が未導入の場合があります。"
        warn "  -> 必要なら 'sudo apt-get install -y rsyslog' を実行してください。"
    fi

    sudo tee "${CWAGENT_CONFIG_PATH}" >/dev/null <<EOF
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
          }
        ],
        "metrics_collection_interval": 60,
        "resources": [
${disk_resources}
        ]
      },
      "mem": {
        "measurement": [
          {
            "name": "mem_used_percent",
            "rename": "MEM_USED_PERCENT",
            "unit": "Percent"
          }
        ],
        "metrics_collection_interval": 60
      },
      "swap": {
        "measurement": [
          {
            "name": "used_percent",
            "rename": "SWAP_USED_PERCENT",
            "unit": "Percent"
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
            "file_path": "${DEFAULT_SAMBA_SMBD_LOG}",
            "log_group_name": "/onprem/${SERVER_NAME}",
            "log_stream_name": "smbd",
            "timezone": "Local"
          },
          {
            "file_path": "${DEFAULT_SAMBA_NMBD_LOG}",
            "log_group_name": "/onprem/${SERVER_NAME}",
            "log_stream_name": "nmbd",
            "timezone": "Local"
          },
          {
            "file_path": "${DEFAULT_SYSLOG_PATH}",
            "log_group_name": "/onprem/${SERVER_NAME}",
            "log_stream_name": "syslog",
            "timezone": "Local"
          }${custom_logs_json}
        ]
      }
    }
  }
}
EOF
    echo "  生成完了: ${CWAGENT_CONFIG_PATH}"
}

# ----------------------------------------------------------------------------
# Step 3: systemd unit 上書き (オンプレ向け、IMDS 無効化)
# ----------------------------------------------------------------------------

write_systemd_service() {
    echo "Step 3: systemd サービスファイルの設定"

    sudo tee "${CWAGENT_SYSTEMD_PATH}" >/dev/null <<EOF
# Amazon CloudWatch Agent Service for On-Premises (Hybrid Activation, Ubuntu)
[Unit]
Description=Amazon CloudWatch Agent
After=network.target amazon-ssm-agent.service
Wants=amazon-ssm-agent.service

[Service]
Type=simple
ExecStart=${CWAGENT_DIR}/bin/start-amazon-cloudwatch-agent
KillMode=process
Restart=on-failure
RestartSec=60s

# リージョンを明示
Environment="AWS_REGION=${AWS_REGION}"
Environment="AWS_DEFAULT_REGION=${AWS_REGION}"

# オンプレ環境では IMDS が存在しないため無効化
# (entitystore Extension の IMDS 問い合わせタイムアウト回避)
Environment="AWS_EC2_METADATA_DISABLED=true"

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    echo "  生成完了: ${CWAGENT_SYSTEMD_PATH}"
}

# ----------------------------------------------------------------------------
# Step 4: /root/.aws/config (リージョン)
# ----------------------------------------------------------------------------

write_aws_config() {
    echo "Step 4: AWS 設定ファイル (/root/.aws/config) の作成"
    sudo install -d -m 700 -o root -g root /root/.aws
    sudo tee /root/.aws/config >/dev/null <<EOF
[default]
region = ${AWS_REGION}
EOF
    sudo chmod 600 /root/.aws/config
    sudo chown root:root /root/.aws/config
    echo "  生成完了: /root/.aws/config"
}

# ----------------------------------------------------------------------------
# Step 5: common-config.toml (SSM Agent 認証情報を流用)
# ----------------------------------------------------------------------------

write_common_config() {
    echo "Step 5: 共通設定ファイル (common-config.toml) の作成"
    sudo tee "${CWAGENT_COMMON_CONFIG_PATH}" >/dev/null <<EOF
# CloudWatch Agent common configuration for on-premises (Hybrid Activation)
# SSM Agent が生成する /root/.aws/credentials を流用する。

[credentials]
  shared_credential_profile = "default"
  shared_credential_file = "/root/.aws/credentials"

[proxy]
  http_proxy = ""
  https_proxy = ""
  no_proxy = ""
EOF
    echo "  生成完了: ${CWAGENT_COMMON_CONFIG_PATH}"
}

# ----------------------------------------------------------------------------
# Step 6: SSM Parameter Store にバックアップ (失敗しても続行)
# ----------------------------------------------------------------------------

put_ssm_parameter() {
    echo "Step 6: SSM Parameter Store への設定バックアップ"
    local param_name="AmazonCloudWatch-${SERVER_NAME}-Config"
    local content
    content=$(sudo cat "${CWAGENT_CONFIG_PATH}")

    if run_aws_cli ssm put-parameter \
        --name "${param_name}" \
        --type "String" \
        --value "${content}" \
        --overwrite \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE_NAME}" >/dev/null 2>&1; then
        echo "  保存完了: ${param_name}"
    else
        warn "Parameter Store への保存に失敗しました (省略可能な手順のため続行します)"
    fi
}

# ----------------------------------------------------------------------------
# Step 7: 設定適用 + 起動
# ----------------------------------------------------------------------------

apply_and_start() {
    echo "Step 7: CloudWatch Agent への設定適用・起動"
    if ! sudo "${CWAGENT_DIR}/bin/amazon-cloudwatch-agent-ctl" \
        -a fetch-config \
        -m onPremise \
        -s \
        -c "file:${CWAGENT_CONFIG_PATH}"; then
        cat <<EOF
エラー: CloudWatch Agent の設定適用に失敗しました。

トラブルシューティング:
  1. SSM Agent の状態:           sudo systemctl status amazon-ssm-agent
  2. ハイブリッド登録情報:       sudo cat /var/lib/amazon/ssm/registration
  3. IAM ロールの権限:           cloudwatch:PutMetricData / logs:CreateLogGroup / logs:CreateLogStream / logs:PutLogEvents
  4. ネットワーク疎通:           amazoncloudwatch-agent-ap-northeast-1 S3 / monitoring.ap-northeast-1.amazonaws.com
EOF
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Step 8: ステータス確認 + サマリ出力
# ----------------------------------------------------------------------------

print_summary() {
    echo "Step 8: ステータス確認"
    sudo "${CWAGENT_DIR}/bin/amazon-cloudwatch-agent-ctl" -a status -m onPremise || true

    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
CloudWatch Agent のセットアップが完了しました。

確認:
  - CloudWatch メトリクス
      名前空間: OnPremises/${SERVER_NAME}
      メトリクス: CPU_IDLE / MEM_USED_PERCENT / DISK_USED_PERCENT / SWAP_USED_PERCENT
  - CloudWatch Logs
      ロググループ: /onprem/${SERVER_NAME}
      デフォルトログストリーム: smbd / nmbd / syslog

管理コマンド:
  ステータス:  sudo ${CWAGENT_DIR}/bin/amazon-cloudwatch-agent-ctl -a status -m onPremise
  停止:        sudo ${CWAGENT_DIR}/bin/amazon-cloudwatch-agent-ctl -a stop -m onPremise
  再読込:      sudo ${CWAGENT_DIR}/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m onPremise -s -c file:${CWAGENT_CONFIG_PATH}
  systemd:     sudo systemctl status amazon-cloudwatch-agent
${sep}
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    load_config
    print_plan
    confirm_or_abort

    install_agent
    write_agent_config
    write_systemd_service
    write_aws_config
    write_common_config
    put_ssm_parameter
    apply_and_start
    print_summary
}

main "$@"
