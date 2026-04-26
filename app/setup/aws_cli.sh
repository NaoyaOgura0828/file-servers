#!/usr/bin/env bash
#
# AWS CLI v2 セットアップスクリプト (Ubuntu 26.04 対応)
#
# AWS 公式の zip インストーラで AWS CLI v2 を /usr/local 配下に導入し、
# 実行ユーザーの ~/.aws/config を本リポジトリの設定で上書きする。
#
# 認証は SSO 方式。初回利用時に `aws sso login --profile FileServers` が必要。
#
# 注意: 本スクリプトは **ユーザー権限で実行**する (sudo $0 ではない)。
#       バイナリ導入のみ内部で sudo を呼び出し、設定ファイルは $HOME 配下に書く。

set -euo pipefail

readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly DEFAULT_CONFIG_SRC="${SCRIPT_DIR}/../config/aws_cli/config"
readonly TARGET_CONFIG="${HOME}/.aws/config"

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
使用方法: $0 [<config ファイルパス>]

AWS CLI v2 をインストールし、~/.aws/config を本リポジトリの設定で上書きする (Ubuntu 26.04)。

引数 (オプション):
  <config ファイルパス>  ~/.aws/config に書き込む内容のソース。省略時:
                         ${DEFAULT_CONFIG_SRC}

オプション:
  -h, --help             このヘルプを表示

動作:
  1. AWS CLI v2 を https://awscli.amazonaws.com から zip でダウンロードして導入
     (アーキテクチャは dpkg --print-architecture から自動判定)
  2. 既存 ~/.aws/config があればタイムスタンプ付きでバックアップ
  3. ソース config を ~/.aws/config に配置 (パーミッション 600)
  4. SSO ログイン手順を表示

注意:
  - **ユーザー権限で実行する** (sudo \$0 ではない)。バイナリ導入のみ内部で sudo を呼び出し、
    設定ファイルは実行ユーザーの \$HOME に書き込む。
  - 認証情報 (~/.aws/credentials) は本スクリプトでは触らない。SSO 方式のため不要。
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    INPUT_CONFIG="${DEFAULT_CONFIG_SRC}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            *)
                INPUT_CONFIG="$1"
                shift
                ;;
        esac
    done
    [[ -f "${INPUT_CONFIG}" ]] || err "config ファイルが見つかりません: ${INPUT_CONFIG}"
}

ensure_not_root() {
    [[ $(id -u) -ne 0 ]] || err "本スクリプトはユーザー権限で実行してください (sudo は内部で必要時のみ呼び出します)。"
}

# ----------------------------------------------------------------------------
# プラン
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "AWS CLI v2 のセットアップを実行します。"
    echo ""
    echo "  ユーザー:       $(whoami)"
    echo "  HOME:           ${HOME}"
    echo "  source config:  ${INPUT_CONFIG}"
    echo "  target config:  ${TARGET_CONFIG}"
    echo "  既存 aws CLI:   $(command -v aws || echo "(未導入)")"
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
# Step 1: AWS CLI v2 導入
# ----------------------------------------------------------------------------

install_aws_cli_v2() {
    echo "Step 1: AWS CLI v2 のインストール"
    if command -v aws >/dev/null 2>&1 && aws --version 2>&1 | grep -q "aws-cli/2"; then
        echo "  既に AWS CLI v2 が導入されています ($(aws --version 2>&1))"
        local yn
        read -r -p "  上書きインストールしますか？ (y/N) " yn
        case "${yn}" in
            [yY]) ;;
            *) echo "  既存版を維持してスキップします。"; return 0 ;;
        esac
    fi

    local arch zip_arch
    arch=$(dpkg --print-architecture)
    case "${arch}" in
        amd64) zip_arch="x86_64" ;;
        arm64) zip_arch="aarch64" ;;
        *)     err "未対応アーキテクチャ: ${arch}" ;;
    esac

    local url="https://awscli.amazonaws.com/awscli-exe-linux-${zip_arch}.zip"
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' RETURN

    sudo apt-get update -qq
    sudo apt-get install -y unzip curl

    echo "  ダウンロード: ${url}"
    curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}/awscliv2.zip" "${url}" \
        || err "AWS CLI v2 のダウンロードに失敗しました。"
    unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"

    if command -v aws >/dev/null 2>&1; then
        sudo "${tmp}/aws/install" --update
    else
        sudo "${tmp}/aws/install"
    fi

    command -v aws >/dev/null 2>&1 || err "aws コマンドが見つかりません。インストールに失敗しました。"
    echo "  完了: $(aws --version 2>&1)"
}

# ----------------------------------------------------------------------------
# Step 2: ~/.aws/config 配置
# ----------------------------------------------------------------------------

install_aws_config() {
    echo "Step 2: ~/.aws/config の配置"
    install -d -m 700 "${HOME}/.aws"

    if [[ -f "${TARGET_CONFIG}" ]]; then
        local backup="${TARGET_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p "${TARGET_CONFIG}" "${backup}"
        echo "  既存設定をバックアップ: ${backup}"
    fi

    install -m 600 "${INPUT_CONFIG}" "${TARGET_CONFIG}"
    echo "  完了: ${TARGET_CONFIG}"
}

# ----------------------------------------------------------------------------
# サマリ
# ----------------------------------------------------------------------------

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
AWS CLI v2 のセットアップが完了しました。
${sep}

  バージョン:    $(aws --version 2>&1)
  config:        ${TARGET_CONFIG}
  プロファイル:  $(grep -E '^\[profile ' "${TARGET_CONFIG}" | sed 's/\[profile //; s/\]//' | tr '\n' ' ')

次の作業:
  1. SSO ログイン (ブラウザが開く / トークン入力):
       aws sso login --profile FileServers

  2. 動作確認:
       aws sts get-caller-identity --profile FileServers
       aws s3 ls --profile FileServers

  3. 必要に応じて他のプロファイルを追記 (~/.aws/config を編集)
${sep}
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    ensure_not_root
    print_plan
    confirm_or_abort

    install_aws_cli_v2
    install_aws_config
    print_summary
}

main "$@"
