#!/usr/bin/env bash
#
# Docker CE セットアップスクリプト (Ubuntu 26.04 対応)
#
# Docker 公式 apt repo (download.docker.com) から Docker CE + Buildx + Compose プラグインを
# 導入し、実行ユーザーを docker グループに追加してサービスを起動する。
# /etc/docker/daemon.json は作成しない (現環境と同等のデフォルト設定)。
#
# 注意: 本スクリプトは **ユーザー権限で実行**する (sudo $0 ではない)。
#       内部で必要時のみ sudo を呼び出し、グループ追加は実行ユーザーに対して行う。

set -euo pipefail

readonly DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
readonly DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly DOCKER_SOURCES="/etc/apt/sources.list.d/docker.list"

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
使用方法: $0 [--codename <Ubuntu codename>] [--skip-group]

Docker CE + Buildx + Compose プラグインを公式 apt repo から導入する (Ubuntu 26.04)。

オプション:
  --codename <name>      Docker repo で使用する Ubuntu codename を上書き
                         (省略時は /etc/os-release の VERSION_CODENAME を自動検出)
                         例: noble (24.04 LTS), questing (25.10) など
                         本リリースで Docker 側パッケージが未公開の場合に有効。
  --skip-group           docker グループへの実行ユーザー追加をスキップ
  -h, --help             このヘルプを表示

動作:
  1. apt prerequisites (ca-certificates / curl / gnupg) を導入
  2. 競合パッケージ (docker.io / docker-compose / podman-docker 等) を除去
  3. Docker 公式 GPG キーを ${DOCKER_KEYRING} に配置
  4. ${DOCKER_SOURCES} に Docker 公式 apt repo を登録
  5. docker-ce + docker-ce-cli + containerd.io + docker-buildx-plugin + docker-compose-plugin を導入
  6. docker.service を enable --now
  7. 実行ユーザーを docker グループに追加 (--skip-group で抑止可)

注意:
  - **ユーザー権限で実行する** (sudo \$0 ではない)。内部で必要時のみ sudo を呼ぶ。
  - グループ追加は **再ログイン (もしくは newgrp docker)** で初めて反映される。
  - 現環境と同様 /etc/docker/daemon.json は作成しない (デフォルト設定で運用)。
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    UBUNTU_CODENAME=""
    SKIP_GROUP="no"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --codename)
                shift
                [[ $# -gt 0 ]] || err "--codename の引数が不足しています。"
                UBUNTU_CODENAME="$1"
                shift
                ;;
            --skip-group)
                SKIP_GROUP="yes"
                shift
                ;;
            *) err "不明な引数: $1 (詳細は '$0 --help')" ;;
        esac
    done

    if [[ -z "${UBUNTU_CODENAME}" ]]; then
        # /etc/os-release から自動検出
        # shellcheck disable=SC1091
        UBUNTU_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
        [[ -n "${UBUNTU_CODENAME}" ]] || err "VERSION_CODENAME を検出できません。--codename で明示指定してください。"
    fi
}

ensure_not_root() {
    [[ $(id -u) -ne 0 ]] || err "本スクリプトはユーザー権限で実行してください (sudo \$0 ではない)。"
}

# ----------------------------------------------------------------------------
# プラン
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "Docker CE のセットアップを実行します。"
    echo ""
    echo "  ユーザー:           $(whoami)"
    echo "  既存 docker:        $(command -v docker || echo "(未導入)")"
    echo "  Ubuntu codename:    ${UBUNTU_CODENAME}"
    echo "  Architecture:       $(dpkg --print-architecture)"
    echo "  GPG keyring:        ${DOCKER_KEYRING}"
    echo "  apt sources:        ${DOCKER_SOURCES}"
    echo "  docker グループ追加: $([[ "${SKIP_GROUP}" == "yes" ]] && echo "スキップ" || echo "実行")"
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

install_apt_prereqs() {
    echo "Step 1: apt 前提パッケージの導入 (ca-certificates / curl / gnupg)"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    echo "  完了"
}

remove_conflicting_packages() {
    echo "Step 2: 競合パッケージの除去 (best effort)"
    local conflicts=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
    for pkg in "${conflicts[@]}"; do
        sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y "${pkg}" 2>/dev/null || true
    done
    echo "  完了"
}

setup_docker_repo() {
    echo "Step 3: Docker 公式 apt repo の登録"
    sudo install -d -m 0755 /etc/apt/keyrings

    # GPG キーを取得して keyring に保存
    sudo curl -fsSL "${DOCKER_GPG_URL}" -o "${DOCKER_KEYRING}"
    sudo chmod a+r "${DOCKER_KEYRING}"

    # sources.list.d に登録
    local arch
    arch=$(dpkg --print-architecture)
    local line="deb [arch=${arch} signed-by=${DOCKER_KEYRING}] ${DOCKER_REPO_URL} ${UBUNTU_CODENAME} stable"
    echo "${line}" | sudo tee "${DOCKER_SOURCES}" >/dev/null

    echo "  ${DOCKER_SOURCES}: ${line}"
    sudo apt-get update -qq
}

install_docker_packages() {
    echo "Step 4: Docker パッケージの導入"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    echo "  完了"
    docker --version 2>&1 | sed 's/^/  /'
    docker buildx version 2>&1 | head -1 | sed 's/^/  /'
    docker compose version 2>&1 | sed 's/^/  /'
}

enable_docker_service() {
    echo "Step 5: docker.service の起動・自動起動"
    sudo systemctl enable --now docker
    sudo systemctl status docker --no-pager --lines=3 | sed 's/^/  /' || true
}

add_user_to_docker_group() {
    if [[ "${SKIP_GROUP}" == "yes" ]]; then
        echo "Step 6: docker グループ追加はスキップ"
        return 0
    fi
    echo "Step 6: ${USER} を docker グループに追加"
    if id -nG "${USER}" | tr ' ' '\n' | grep -qx docker; then
        echo "  既に所属済み"
    else
        sudo usermod -aG docker "${USER}"
        echo "  追加完了。**再ログインまたは 'newgrp docker' で反映されます**。"
    fi
}

# ----------------------------------------------------------------------------
# サマリ
# ----------------------------------------------------------------------------

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
Docker CE のセットアップが完了しました。
${sep}

  $(docker --version 2>&1)
  $(docker compose version 2>&1)
  $(docker buildx version 2>&1 | head -1)

次の作業:
  1. グループ反映 (再ログインしないなら):
       newgrp docker

  2. 動作確認 (sudo なしで実行できるか):
       docker run --rm hello-world

  3. /etc/docker/daemon.json は作成していない (デフォルト設定)。
     必要なら手動で配置: log-driver / storage-driver / registry-mirrors 等

トラブル時:
  systemctl status docker --no-pager
  journalctl -u docker --no-pager -n 50
  docker info
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

    install_apt_prereqs
    remove_conflicting_packages
    setup_docker_repo
    install_docker_packages
    enable_docker_service
    add_user_to_docker_group
    print_summary
}

main "$@"
