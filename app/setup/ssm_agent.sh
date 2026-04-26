#!/usr/bin/env bash
#
# SSM Agent インストール + ハイブリッドアクティベーション登録 (Ubuntu 26.04)
#
# 対象サーバー (オンプレ) で実行することで、SSM Agent を導入し、
# 管理ホストで activation.sh が生成した Activation JSON の値で
# ハイブリッドマネージドインスタンスとして登録する。
#
# 想定フロー:
#   1. 管理ホスト: app/setup/activation.sh BackupServer
#      -> app/setup/output/activation-BackupServer-<ts>.json 生成
#   2. 対象サーバーへ JSON を転送 (scp / 安全な経路)
#   3. 対象サーバー: sudo app/setup/ssm_agent.sh /path/to/activation-*.json

set -euo pipefail

readonly AWS_REGION="ap-northeast-1"
readonly SSM_AGENT_S3_BASE="https://s3.${AWS_REGION}.amazonaws.com/amazon-ssm-${AWS_REGION}/latest"

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
使用方法: $0 <activation JSON ファイルパス>

SSM Agent を Ubuntu 26.04 にインストールし、ハイブリッドアクティベーションで登録する。

引数:
  <activation JSON>      app/setup/activation.sh が出力した JSON ファイル
                         (例: app/setup/output/activation-BackupServer-20260301-120000.json)
                         この JSON から ActivationId / ActivationCode を読み取る。

オプション:
  -h, --help             このヘルプを表示

固定値:
  AWS_REGION:            ${AWS_REGION}

前提:
  - sudo 実行可能なユーザーで起動
  - 既に管理ホスト側で activation.sh を実行済みで、JSON ファイルを本サーバーへ転送済み
  - インターネット接続 (S3 から amazon-ssm-agent.deb を取得)
  - jq インストール済 (未導入なら apt で自動導入)

セキュリティ:
  - Activation JSON には Activation Code (機密) が含まれる。転送時の経路に注意。
  - 登録完了後、JSON は不要になるので削除推奨。
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "エラー: activation JSON ファイルパスを指定してください。" >&2
        echo "詳細は '$0 --help' を参照してください。" >&2
        exit 1
    fi
    INPUT_JSON=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            *)
                if [[ -z "${INPUT_JSON}" ]]; then
                    INPUT_JSON="$1"
                else
                    err "複数の引数が指定されています。"
                fi
                shift
                ;;
        esac
    done
    [[ -f "${INPUT_JSON}" ]] || err "ファイルが見つかりません: ${INPUT_JSON}"
}

require_root() {
    [[ $(id -u) -eq 0 ]] || err "root 権限で実行してください: sudo $0 ..."
}

ensure_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq を apt でインストールします..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y jq
    fi
}

# ----------------------------------------------------------------------------
# JSON パース
# ----------------------------------------------------------------------------

parse_activation_json() {
    ACTIVATION_ID=$(jq -r '.ActivationId // empty' "${INPUT_JSON}")
    ACTIVATION_CODE=$(jq -r '.ActivationCode // empty' "${INPUT_JSON}")
    [[ -n "${ACTIVATION_ID}"   ]] || err "JSON に ActivationId がありません: ${INPUT_JSON}"
    [[ -n "${ACTIVATION_CODE}" ]] || err "JSON に ActivationCode がありません: ${INPUT_JSON}"
}

# ----------------------------------------------------------------------------
# プラン + 確認
# ----------------------------------------------------------------------------

print_plan() {
    local masked_code="${ACTIVATION_CODE:0:4}****${ACTIVATION_CODE: -4}"
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "SSM Agent インストール + ハイブリッド登録を実行します。"
    echo ""
    echo "  ActivationId:    ${ACTIVATION_ID}"
    echo "  ActivationCode:  ${masked_code} (マスク表示)"
    echo "  Region:          ${AWS_REGION}"
    echo "  Architecture:    $(dpkg --print-architecture)"
    echo "  ホスト名:        $(hostname)"
    echo "${sep}"
}

confirm_or_abort() {
    local yn
    read -r -p "この設定で実行してよろしいですか？ (Y/n) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *) echo "中止しました。"; exit 0 ;;
    esac
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

install_ssm_agent() {
    echo "Step 1: amazon-ssm-agent のダウンロード・インストール"
    if command -v amazon-ssm-agent >/dev/null 2>&1; then
        echo "  既にインストール済み (再インストールせず続行)"
        return 0
    fi
    local arch
    arch=$(dpkg --print-architecture)
    case "${arch}" in
        amd64|arm64) ;;
        *) err "未対応アーキテクチャ: ${arch}" ;;
    esac

    local url="${SSM_AGENT_S3_BASE}/debian_${arch}/amazon-ssm-agent.deb"
    local tmp deb
    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' RETURN
    deb="${tmp}/amazon-ssm-agent.deb"

    echo "  ダウンロード: ${url}"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "${deb}" "${url}"; then
        err "amazon-ssm-agent.deb のダウンロードに失敗しました。"
    fi

    echo "  dpkg -i 実行..."
    if ! dpkg -i "${deb}"; then
        echo "  依存関係を解決して再試行..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -f
    fi

    command -v amazon-ssm-agent >/dev/null 2>&1 \
        || err "amazon-ssm-agent コマンドが見つかりません。インストールに失敗しています。"
    echo "  OK"
}

stop_agent_for_register() {
    echo "Step 2: SSM Agent を停止 (登録のため)"
    systemctl stop amazon-ssm-agent || true
    echo "  完了"
}

register() {
    echo "Step 3: ハイブリッドアクティベーション登録"
    if ! amazon-ssm-agent -register \
        -code "${ACTIVATION_CODE}" \
        -id "${ACTIVATION_ID}" \
        -region "${AWS_REGION}" -y; then
        err "登録に失敗しました。Activation の有効期限・登録上限・ネットワークを確認してください。"
    fi
    echo "  完了"
}

enable_and_start() {
    echo "Step 4: SSM Agent の起動・自動起動"
    systemctl daemon-reload
    systemctl enable --now amazon-ssm-agent
    sleep 2
    systemctl status amazon-ssm-agent --no-pager --lines=5 || true
}

verify_registration() {
    echo "Step 5: 登録結果の検証"
    local reg="/var/lib/amazon/ssm/registration"
    if [[ -f "${reg}" ]]; then
        echo "  registration ファイル:"
        cat "${reg}" | sed 's/^/    /'
    else
        warn "${reg} がありません。/var/log/amazon/ssm/amazon-ssm-agent.log を確認してください。"
    fi
}

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
SSM Agent のセットアップ・登録が完了しました。
${sep}

確認:
  systemctl status amazon-ssm-agent --no-pager
  sudo tail -f /var/log/amazon/ssm/amazon-ssm-agent.log
  cat /var/lib/amazon/ssm/registration

AWS 側 (管理ホスト):
  aws ssm describe-instance-information \\
      --filters "Key=ActivationIds,Values=${ACTIVATION_ID}" \\
      --region ${AWS_REGION} --profile FileServers

セキュリティ:
  本登録に使用した JSON ファイル (${INPUT_JSON}) は不要になりました。削除を推奨:
    shred -u "${INPUT_JSON}"
${sep}
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    require_root
    ensure_jq
    parse_activation_json
    print_plan
    confirm_or_abort

    install_ssm_agent
    stop_agent_for_register
    register
    enable_and_start
    verify_registration
    print_summary
}

main "$@"
