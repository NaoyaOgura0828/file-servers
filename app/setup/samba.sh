#!/usr/bin/env bash
#
# Samba セットアップスクリプト (Ubuntu 26.04 対応)
#
# app/config/samba/<ConfigFile> を読み込み、smbd / nmbd (+ avahi-daemon) を
# 導入・設定する。Time Machine バックアップ用途 (vfs_fruit) を主用途として設計。
#
# 設定ファイル形式: app/config/samba/sample.conf を参照。

set -euo pipefail

readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly SMB_CONF_PATH="/etc/samba/smb.conf"
readonly AVAHI_SERVICE_PATH="/etc/avahi/services/timemachine.service"
readonly AUDIT_RSYSLOG_DEST="/etc/rsyslog.d/40-samba-audit.conf"
readonly AUDIT_LOGROTATE_DEST="/etc/logrotate.d/samba_audit"
readonly AUDIT_LOG_PATH="/var/log/samba/audit.log"

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
使用方法: $0 <設定ファイルパス>

Samba (smbd/nmbd + 任意で avahi-daemon) をインストール・設定する。
Ubuntu 26.04 のハイブリッドファイルサーバー / Time Machine ストレージ向け。

引数:
  <設定ファイルパス>     設定ファイルのパス (必須)
                         絶対パス、CWD 相対パス、または app/config/samba/ 配下のファイル名 (例: BackupServer.conf)

オプション:
  -h, --help             このヘルプを表示

設定ファイルの書式:
  SERVER_NAME / NETBIOS_NAME / WORKGROUP / SERVER_STRING
  SHARE_NAME / SHARE_PATH / SHARE_VALID_USER / SHARE_TIMEMACHINE_MAX_SIZE
  HOSTS_ALLOW / INTERFACES
  ENABLE_AVAHI / ENABLE_FRUIT / ENABLE_AUDIT
  詳細は app/config/samba/sample.conf を参照。

ENABLE_AUDIT="yes" の場合の追加動作:
  - vfs_full_audit による SMB アクセスログを ${AUDIT_LOG_PATH} へ出力
  - rsyslog drop-in (${AUDIT_RSYSLOG_DEST}) と logrotate (${AUDIT_LOGROTATE_DEST}) を配置
  - CloudWatch Agent 設定 (app/config/cloudwatch_agent/) の LOG_PATHS で当該ファイルを参照すること

前提:
  - sudo 実行可能なユーザーで起動
  - インターネット接続 (apt で samba / avahi-daemon を導入)
  - SHARE_PATH の親マウントが存在すること (例: /mnt/timemachine)
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
    # 解決順: 1) CWD/絶対パス  2) スクリプト基準  3) app/config/samba/ 基準
    if [[ ! -f "${INPUT_CONFIG}" ]]; then
        local candidates=(
            "${SCRIPT_DIR}/${INPUT_CONFIG}"
            "${SCRIPT_DIR}/../config/samba/${INPUT_CONFIG}"
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

    local required=(SERVER_NAME NETBIOS_NAME WORKGROUP SERVER_STRING
                    SHARE_NAME SHARE_PATH SHARE_VALID_USER
                    HOSTS_ALLOW ENABLE_AVAHI ENABLE_FRUIT ENABLE_AUDIT)
    for v in "${required[@]}"; do
        if [[ -z "${!v:-}" ]]; then
            err "設定ファイルに ${v} が定義されていません: ${INPUT_CONFIG}"
        fi
    done
}

# ----------------------------------------------------------------------------
# プラン表示 + 確認
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "Samba のセットアップを開始します。"
    echo ""
    echo "  サーバー名:           ${SERVER_NAME}"
    echo "  NetBIOS 名:           ${NETBIOS_NAME}"
    echo "  ワークグループ:       ${WORKGROUP}"
    echo "  説明文:               ${SERVER_STRING}"
    echo ""
    echo "  共有名:               ${SHARE_NAME}"
    echo "  共有パス:             ${SHARE_PATH}"
    echo "  アクセスユーザー:     ${SHARE_VALID_USER}"
    if [[ -n "${SHARE_TIMEMACHINE_MAX_SIZE:-}" ]]; then
        echo "  Time Machine 上限:    ${SHARE_TIMEMACHINE_MAX_SIZE}"
    fi
    echo ""
    echo "  許可ホスト:           ${HOSTS_ALLOW}"
    echo "  Listen NIC:           ${INTERFACES:-全 NIC}"
    echo ""
    echo "  Avahi (mDNS):         ${ENABLE_AVAHI}"
    echo "  vfs_fruit:            ${ENABLE_FRUIT}"
    echo "  vfs_full_audit:       ${ENABLE_AUDIT}"
    if [[ "${ENABLE_AUDIT}" == "yes" ]]; then
        echo "  監査ログ出力先:       ${AUDIT_LOG_PATH}"
        echo "  監査対象操作:         connect disconnect mkdirat unlinkat renameat fchmod fchown"
    fi
    echo "${sep}"
}

confirm_or_abort() {
    local yn
    read -r -p "この設定で Samba をセットアップしてよろしいですか？ (Y/n) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *)
            echo "セットアップを中止しました。"
            exit 0
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Step 1: パッケージ導入
# ----------------------------------------------------------------------------

install_packages() {
    echo "Step 1: パッケージのインストール (apt)"
    local pkgs=(samba samba-common-bin)
    if [[ "${ENABLE_AVAHI}" == "yes" ]]; then
        pkgs+=(avahi-daemon)
    fi

    sudo apt-get update -qq
    sudo apt-get install -y "${pkgs[@]}"
    echo "  完了: ${pkgs[*]}"
}

# ----------------------------------------------------------------------------
# Step 2: 共有ディレクトリの確保
# ----------------------------------------------------------------------------

ensure_share_dir() {
    echo "Step 2: 共有ディレクトリの確保 (${SHARE_PATH})"
    if [[ ! -d "${SHARE_PATH}" ]]; then
        warn "${SHARE_PATH} が存在しません。作成しますが、本来は事前にマウント済みであることを確認してください。"
        sudo install -d -m 770 "${SHARE_PATH}"
    fi
    sudo chown "${SHARE_VALID_USER}:${SHARE_VALID_USER}" "${SHARE_PATH}" 2>/dev/null || true
    sudo chmod 770 "${SHARE_PATH}"
    echo "  権限設定完了 (770 / ${SHARE_VALID_USER}:${SHARE_VALID_USER})"
}

# ----------------------------------------------------------------------------
# Step 3: 共有用 Unix ユーザーの確保
# ----------------------------------------------------------------------------

ensure_share_user() {
    echo "Step 3: Unix ユーザー ${SHARE_VALID_USER} の確保"
    if id "${SHARE_VALID_USER}" >/dev/null 2>&1; then
        echo "  既に存在します。"
    else
        sudo useradd -r -s /usr/sbin/nologin -d "${SHARE_PATH}" "${SHARE_VALID_USER}"
        echo "  作成しました (system user, no login shell)"
    fi
    sudo chown "${SHARE_VALID_USER}:${SHARE_VALID_USER}" "${SHARE_PATH}"
}

# ----------------------------------------------------------------------------
# Step 4: smbpasswd 登録 (対話的)
# ----------------------------------------------------------------------------

set_smb_password() {
    echo "Step 4: Samba パスワード設定 (${SHARE_VALID_USER})"
    if sudo pdbedit -L 2>/dev/null | grep -q "^${SHARE_VALID_USER}:"; then
        local yn
        read -r -p "  Samba パスワードは既に設定済です。再設定しますか？ (y/N) " yn
        case "${yn}" in
            [yY]) sudo smbpasswd "${SHARE_VALID_USER}" ;;
            *)    echo "  既存パスワードを維持します。" ;;
        esac
    else
        echo "  ${SHARE_VALID_USER} の Samba パスワードを設定します。"
        sudo smbpasswd -a "${SHARE_VALID_USER}"
    fi
}

# ----------------------------------------------------------------------------
# Step 5: 既存 smb.conf のバックアップ
# ----------------------------------------------------------------------------

backup_existing_smb_conf() {
    echo "Step 5: 既存 ${SMB_CONF_PATH} のバックアップ"
    if [[ -f "${SMB_CONF_PATH}" ]]; then
        local ts
        ts=$(date +%Y%m%d-%H%M%S)
        local backup="${SMB_CONF_PATH}.bak.${ts}"
        sudo cp -p "${SMB_CONF_PATH}" "${backup}"
        echo "  保存先: ${backup}"
    else
        echo "  既存の smb.conf はありません。スキップ。"
    fi
}

# ----------------------------------------------------------------------------
# Step 6: smb.conf 生成
# ----------------------------------------------------------------------------

write_smb_conf() {
    echo "Step 6: ${SMB_CONF_PATH} の生成"

    # vfs_objects に積む module を組み立て (順序: catia fruit streams_xattr full_audit)
    # full_audit は他 module の変換後の呼び出しを捕捉できるよう末尾に置く。
    local vfs_modules=()
    local fruit_global=""
    local fruit_share=""
    local audit_global=""

    if [[ "${ENABLE_FRUIT}" == "yes" ]]; then
        vfs_modules+=(catia fruit streams_xattr)
        fruit_global=$(cat <<EOF

   # Time Machine / macOS 互換性 (vfs_fruit)
   fruit:nfs_aces = no
   fruit:zero_file_id = yes
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
   fruit:advertise_fullsync = true
EOF
)
        if [[ -n "${SHARE_TIMEMACHINE_MAX_SIZE:-}" ]]; then
            fruit_share=$(cat <<EOF

   # Time Machine 用設定
   fruit:time machine = yes
   fruit:time machine max size = ${SHARE_TIMEMACHINE_MAX_SIZE}
EOF
)
        fi
    fi

    if [[ "${ENABLE_AUDIT}" == "yes" ]]; then
        vfs_modules+=(full_audit)
        audit_global=$(cat <<EOF

   # SMB アクセス監査 (vfs_full_audit) - LOCAL5 経由で ${AUDIT_LOG_PATH} へ出力
   # opname は Samba 4.18+ の VFS "-at" 系統合に追従 (mkdirat / unlinkat / renameat / fchmod / fchown)
   # unlinkat は rmdir と unlink の双方を包括する。
   full_audit:prefix = %u|%I|%S
   full_audit:success = connect disconnect mkdirat unlinkat renameat fchmod fchown
   full_audit:failure = connect
   full_audit:facility = LOCAL5
   full_audit:priority = NOTICE
EOF
)
    fi

    local vfs_objects_line=""
    if [[ ${#vfs_modules[@]} -gt 0 ]]; then
        vfs_objects_line=$'\n   vfs objects = '"${vfs_modules[*]}"
    fi

    local interfaces_line=""
    if [[ -n "${INTERFACES:-}" ]]; then
        interfaces_line=$(cat <<EOF

   interfaces = ${INTERFACES}
   bind interfaces only = yes
EOF
)
    fi

    sudo tee "${SMB_CONF_PATH}" >/dev/null <<EOF
# /etc/samba/smb.conf — generated by app/setup/samba.sh from ${INPUT_CONFIG}

[global]
   workgroup = ${WORKGROUP}
   server string = ${SERVER_STRING}
   netbios name = ${NETBIOS_NAME}
   security = user
   map to guest = never
   log file = /var/log/samba/log.%m
   max log size = 50
   server min protocol = SMB2
   ea support = yes
   hosts allow = ${HOSTS_ALLOW}${interfaces_line}${vfs_objects_line}${fruit_global}${audit_global}

[${SHARE_NAME}]
   path = ${SHARE_PATH}
   valid users = ${SHARE_VALID_USER}
   browseable = yes
   writable = yes
   create mask = 0660
   directory mask = 0770
   force user = ${SHARE_VALID_USER}
   force group = ${SHARE_VALID_USER}${fruit_share}
EOF
    sudo chmod 644 "${SMB_CONF_PATH}"
    echo "  生成完了"
}

# ----------------------------------------------------------------------------
# Step 7: Avahi サービス定義 (mDNS)
# ----------------------------------------------------------------------------

write_avahi_service() {
    if [[ "${ENABLE_AVAHI}" != "yes" ]]; then
        echo "Step 7: Avahi はスキップ (ENABLE_AVAHI != yes)"
        return 0
    fi
    echo "Step 7: Avahi mDNS サービス定義 (${AVAHI_SERVICE_PATH})"
    sudo install -d -m 755 /etc/avahi/services
    sudo tee "${AVAHI_SERVICE_PATH}" >/dev/null <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<!-- Generated by app/setup/samba.sh -->
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service>
    <type>_smb._tcp</type>
    <port>445</port>
  </service>
  <service>
    <type>_device-info._tcp</type>
    <port>0</port>
    <txt-record>model=TimeCapsule8,119</txt-record>
  </service>
  <service>
    <type>_adisk._tcp</type>
    <port>9</port>
    <txt-record>dk0=adVN=${SHARE_NAME},adVF=0x82</txt-record>
    <txt-record>sys=waMa=0,adVF=0x100</txt-record>
  </service>
</service-group>
EOF
    sudo chmod 644 "${AVAHI_SERVICE_PATH}"
    echo "  生成完了"
}

# ----------------------------------------------------------------------------
# Step 8: 監査ログ用 rsyslog / logrotate 配置 (ENABLE_AUDIT=yes 時のみ)
# ----------------------------------------------------------------------------

write_audit_log_setup() {
    if [[ "${ENABLE_AUDIT}" != "yes" ]]; then
        echo "Step 8: SMB 監査ログ設定はスキップ (ENABLE_AUDIT != yes)"
        # OFF への切替時に古い drop-in が残っていると意図せず転送が継続するため除去
        if [[ -f "${AUDIT_RSYSLOG_DEST}" ]]; then
            sudo rm -f "${AUDIT_RSYSLOG_DEST}"
            echo "  既存の ${AUDIT_RSYSLOG_DEST} を削除しました。"
        fi
        if [[ -f "${AUDIT_LOGROTATE_DEST}" ]]; then
            sudo rm -f "${AUDIT_LOGROTATE_DEST}"
            echo "  既存の ${AUDIT_LOGROTATE_DEST} を削除しました。"
        fi
        return 0
    fi

    echo "Step 8: SMB 監査ログ設定 (rsyslog drop-in + logrotate)"

    local rsyslog_src="${SCRIPT_DIR}/../config/rsyslog/samba_audit.conf"
    local logrotate_src="${SCRIPT_DIR}/../config/logrotate/samba_audit.conf"

    [[ -f "${rsyslog_src}" ]]   || err "rsyslog 設定ファイルが見つかりません: ${rsyslog_src}"
    [[ -f "${logrotate_src}" ]] || err "logrotate 設定ファイルが見つかりません: ${logrotate_src}"

    # samba パッケージに含まれない環境向けに samba-vfs-modules を担保 (Ubuntu では同梱の場合あり)
    if ! dpkg -s samba-vfs-modules >/dev/null 2>&1; then
        sudo apt-get install -y samba-vfs-modules || warn "samba-vfs-modules のインストールに失敗 (samba 本体に含まれていれば動作します)"
    fi

    sudo install -m 644 -o root -g root "${rsyslog_src}"   "${AUDIT_RSYSLOG_DEST}"
    echo "  配置: ${AUDIT_RSYSLOG_DEST}"
    sudo install -m 644 -o root -g root "${logrotate_src}" "${AUDIT_LOGROTATE_DEST}"
    echo "  配置: ${AUDIT_LOGROTATE_DEST}"

    # rsyslog は Ubuntu 既定で syslog:adm で稼働するため、ログファイルもこのオーナーで作成する。
    # /var/log/samba/ は drwxr-x--- root:adm のため、syslog がディレクトリへの新規作成権を持たない。
    # 事前に syslog:adm 0640 で用意することで rsyslog が append のみで動けるようにする。
    if [[ ! -f "${AUDIT_LOG_PATH}" ]]; then
        sudo install -m 640 -o syslog -g adm /dev/null "${AUDIT_LOG_PATH}"
        echo "  作成: ${AUDIT_LOG_PATH} (640 syslog:adm)"
    else
        # 旧バージョンで root:adm 0640 で作成された場合に rsyslog が omfile suspended になる事故を防ぐ
        sudo chown syslog:adm "${AUDIT_LOG_PATH}"
        sudo chmod 640 "${AUDIT_LOG_PATH}"
        echo "  既存ファイルのオーナー/モードを syslog:adm 0640 に正規化"
    fi

    if sudo logrotate -d "${AUDIT_LOGROTATE_DEST}" >/dev/null 2>&1; then
        echo "  logrotate 構文 OK"
    else
        warn "logrotate 構文チェックでエラー。詳細: sudo logrotate -d ${AUDIT_LOGROTATE_DEST}"
    fi
}

# ----------------------------------------------------------------------------
# Step 9: 設定検証 (testparm)
# ----------------------------------------------------------------------------

test_smb_conf() {
    echo "Step 9: testparm による smb.conf 構文検証"
    if sudo testparm -s "${SMB_CONF_PATH}" >/dev/null 2>&1; then
        echo "  OK"
    else
        warn "testparm がエラーを報告しました。詳細は: sudo testparm ${SMB_CONF_PATH}"
        sudo testparm -s "${SMB_CONF_PATH}" || true
        err "smb.conf に問題があります。修正してから再実行してください。"
    fi
}

# ----------------------------------------------------------------------------
# Step 10: サービス起動・自動起動
# ----------------------------------------------------------------------------

enable_and_restart_services() {
    echo "Step 10: smbd / nmbd${ENABLE_AVAHI:+ / avahi-daemon}${ENABLE_AUDIT:+ / rsyslog} の起動・自動起動"
    sudo systemctl enable --now smbd nmbd
    if [[ "${ENABLE_AVAHI}" == "yes" ]]; then
        sudo systemctl enable --now avahi-daemon
    fi
    sudo systemctl restart smbd nmbd
    if [[ "${ENABLE_AVAHI}" == "yes" ]]; then
        sudo systemctl restart avahi-daemon
    fi
    # 監査の有効/無効切替に伴う drop-in の追加/削除を反映するため rsyslog を再読込
    if systemctl list-unit-files rsyslog.service >/dev/null 2>&1; then
        sudo systemctl restart rsyslog 2>/dev/null || warn "rsyslog の再起動に失敗"
    fi
    echo "  サービス起動完了"
}

# ----------------------------------------------------------------------------
# サマリ
# ----------------------------------------------------------------------------

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
Samba のセットアップが完了しました。
${sep}

  共有 UNC:        \\\\${NETBIOS_NAME}\\${SHARE_NAME}
  Time Machine:    macOS 「システム設定 > Time Machine」で「${NETBIOS_NAME}」を選択 (Avahi 有効時は自動検出)
  認証ユーザー:    ${SHARE_VALID_USER}

確認コマンド:
  testparm -s            # 構成全体の解析
  systemctl status smbd  # サービス状態
  smbclient -L ${NETBIOS_NAME} -U ${SHARE_VALID_USER}  # 共有一覧 (パスワード入力)
  avahi-browse -r _adisk._tcp  # mDNS 広告確認 (avahi 有効時)

サービス管理:
  sudo systemctl restart smbd nmbd
  sudo systemctl restart avahi-daemon
EOF
    if [[ "${ENABLE_AUDIT}" == "yes" ]]; then
        cat <<EOF

SMB 監査ログ (vfs_full_audit):
  出力先:          ${AUDIT_LOG_PATH}
  rsyslog drop-in: ${AUDIT_RSYSLOG_DEST}
  logrotate 設定:  ${AUDIT_LOGROTATE_DEST}
  ログ形式:        <timestamp> <host> smbd_audit: <user>|<client_ip>|<share>|<op>|ok|<args...>
  確認:            sudo tail -f ${AUDIT_LOG_PATH}
  CloudWatch Logs: app/config/cloudwatch_agent/<server>.conf の LOG_PATHS に
                   "${AUDIT_LOG_PATH}:smb-audit" を含めて cloudwatch_agent.sh を再実行する
EOF
    fi
    echo "${sep}"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    load_config
    print_plan
    confirm_or_abort

    install_packages
    ensure_share_dir
    ensure_share_user
    set_smb_password
    backup_existing_smb_conf
    write_smb_conf
    write_avahi_service
    write_audit_log_setup
    test_smb_conf
    enable_and_restart_services
    print_summary
}

main "$@"
