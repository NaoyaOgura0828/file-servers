# Reference: Configurations

`app/config/` 配下の設定ファイル形式。各 setup スクリプトが `source` する bash 変数定義 (一部は logrotate / aws-cli config の形式を直接保持)。

## ディレクトリ構成

```text
app/config/
├── aws_cli/
│   └── config                          # AWS CLI 用 (~/.aws/config に展開)
├── cloudwatch_agent/
│   ├── BackupServer.conf
│   ├── FileServer.conf
│   └── sample.conf
├── crontab/
│   ├── FileServer.conf
│   └── sample.conf
├── logrotate/
│   ├── rsync_fileserver.conf           # logrotate 形式そのもの
│   └── samba_audit.conf                # logrotate 形式そのもの (samba.sh が ENABLE_AUDIT=yes 時に配置)
├── network/
│   ├── BackupServer.conf
│   └── sample.conf
├── os_init/
│   ├── BackupServer.conf
│   ├── FileServer.conf
│   └── sample.conf
├── rsyslog/
│   └── samba_audit.conf                # rsyslog drop-in (LOCAL5 → /var/log/samba/audit.log)
├── samba/
│   ├── BackupServer.conf
│   ├── FileServer.conf
│   └── sample.conf
└── storage/
    ├── BackupServer/
    │   └── timemachine.conf
    ├── FileServer/
    │   ├── fileserver.conf
    │   └── fileserver-backup.conf
    └── sample.conf
```

## 共通ルール

- bash の `source` で読み込めるシンタックス (空白を含む値はクォート、`#` でコメント)
- `sample.conf` は新サーバー追加時の雛形 (各値は空 or プレースホルダ)
- 機密情報 (Wi-Fi password, Activation Code, AWS credential) は **設定ファイルに保存しない**

## 個別仕様

### `aws_cli/config`

`~/.aws/config` に展開される AWS CLI 形式 (ini)。プロファイル `FileServers` は `sso_account_id=856221042201`, region=ap-northeast-1。

> [!IMPORTANT]
> `~/.aws/config` はコメント (`#`/`;`) を解釈しないことがあるため、本ファイルにもコメントを書かない。

### `cloudwatch_agent/<server>.conf`

```bash
SERVER_NAME="BackupServer"               # CloudWatch 名前空間 (OnPremises/<SERVER_NAME>) と CloudWatch Logs ロググループ (/onprem/<SERVER_NAME>) に使用
MOUNTPOINTS="/mnt/timemachine"           # 監視するマウントポイント (空白区切り、/ は常に追加される)
LOG_PATHS=""                             # 追加で監視するログ。形式: "<path>:<stream> ..." 空白区切り
```

| 変数 | 型 | 必須 | 既定 |
|---|---|---|---|
| `SERVER_NAME` | string | ✓ | — |
| `MOUNTPOINTS` | space-sep string | — | "" |
| `LOG_PATHS` | space-sep string ("path:stream") | — | "" |

### `crontab/<server>.conf`

```bash
CRON_FILENAME="fileserver"               # /etc/cron.d/<CRON_FILENAME> として配置
CRON_BODY='
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

0 * * * * root /home/NaoyaOgura/file-servers/app/jobs/rsync_fileserver.sh
'
```

| 変数 | 必須 | 補足 |
|---|---|---|
| `CRON_FILENAME` | ✓ | 小文字英数字とハイフンのみ (cron はドット入りファイルを無視) |
| `CRON_BODY` | ✓ | システム crontab 形式 (`分 時 日 月 曜日 ユーザー コマンド`) |

`crontab.sh` が `/etc/cron.d/<CRON_FILENAME>` に install -m 644 root:root で配置。cron は mtime 検知で自動 reload (daemon 再起動不要)。

> [!NOTE]
> FileServer の cron は **rsync の通常実行のみ**を登録する。`--checksum` 付きの定期ジョブは登録しない (100TB 規模で I/O 過大、[ADR-007](../decisions/ADR-007-rsync-no-periodic-checksum.md))。

### `logrotate/rsync_fileserver.conf`

logrotate 設定そのもの。`logrotate.sh` が `/etc/logrotate.d/rsync_fileserver` に install -m 644 で配置。

### `logrotate/samba_audit.conf`

logrotate 設定そのもの。`samba.sh` が `ENABLE_AUDIT="yes"` のとき `/etc/logrotate.d/samba_audit` に install -m 644 で配置する (`ENABLE_AUDIT="no"` 時は撤去)。daily / 30 世代 / postrotate で rsyslog にファイル再オープンを通知 ([ADR-008](../decisions/ADR-008-smb-vfs-full-audit.md))。

### `rsyslog/samba_audit.conf`

rsyslog drop-in そのもの。`samba.sh` が `ENABLE_AUDIT="yes"` のとき `/etc/rsyslog.d/40-samba-audit.conf` に install -m 644 で配置する。`local5.* /var/log/samba/audit.log` + `& stop` で LOCAL5 ファシリティを Samba 監査専用に振り分ける ([ADR-008](../decisions/ADR-008-smb-vfs-full-audit.md))。

### `network/<server>.conf`

```bash
ETHERNET_ROUTE_METRIC="10"
ETHERNET_AUTOCONNECT="yes"
WIFI_INTERFACE=""                # 空 = nmcli 自動検出
WIFI_SSID="Kure Naval District"  # 空 = Wi-Fi 設定スキップ
WIFI_ROUTE_METRIC="50"
WIFI_AUTOCONNECT="yes"
```

> [!IMPORTANT]
> `WIFI_PASSWORD` は本ファイルに書かない。env / `--password-file` / 対話入力のいずれかで供給する。

### `os_init/<server>.conf`

```bash
HOSTNAME="BackupServer"
TIMEZONE="Asia/Tokyo"
LOCALE="ja_JP.UTF-8"
EXTRA_PACKAGES="curl wget jq vim git unzip ca-certificates"
ENABLE_UNATTENDED_UPGRADES="yes"
```

### `samba/<server>.conf`

```bash
SERVER_NAME="BackupServer"
NETBIOS_NAME="BACKUPSERVER"
WORKGROUP="WORKGROUP"
SERVER_STRING="Backup Server (Time Machine)"
SHARE_NAME="timemachine"
SHARE_PATH="/mnt/timemachine"
SHARE_VALID_USER="NaoyaOgura"             # 既存 admin ユーザーをそのまま使用 (ADR-003)
SHARE_TIMEMACHINE_MAX_SIZE="2T"
HOSTS_ALLOW="192.168.0.0/16 127.0.0.1"
INTERFACES=""                              # 空 = 全 NIC で待ち受け
ENABLE_AVAHI="yes"                         # mDNS で macOS 自動検出
ENABLE_FRUIT="yes"                         # vfs_fruit (Time Machine 必須)
ENABLE_AUDIT="no"                          # vfs_full_audit による SMB アクセス監査 (ADR-008)
```

| 変数 | 必須 | 補足 |
|---|---|---|
| `SHARE_TIMEMACHINE_MAX_SIZE` | — | Time Machine 用途のとき (1T / 2T / 500G 形式) |
| `ENABLE_FRUIT` | ✓ | "yes" で `vfs objects` に `catia fruit streams_xattr` を追加 |
| `ENABLE_AUDIT` | ✓ | "yes" で `vfs objects` に `full_audit` を追加し、`/var/log/samba/audit.log` へ出力 + rsyslog drop-in と logrotate を配置。FileServer=yes / BackupServer=no が原則 ([ADR-008](../decisions/ADR-008-smb-vfs-full-audit.md)) |

### `storage/<server>/<role>.conf`

```bash
VG_NAME="timemachine-group"
LV_NAME="timemachine"
MOUNT_POINT="/mnt/timemachine"
FILESYSTEM="xfs"                                              # プロジェクト標準
MOUNT_OPTIONS="defaults,noatime,nofail,x-systemd.device-timeout=30s"
```

| 用途 | 推奨 `MOUNT_OPTIONS` |
|---|---|
| 内蔵 SATA (常に存在) | `defaults,noatime` |
| 着脱可能 SATA / 内蔵プール | `defaults,noatime,nofail` |
| USB 単一台 (BackupServer) | `defaults,noatime,nofail,x-systemd.device-timeout=30s` |
| USB プール 29 PV (FileServer) | `defaults,noatime,nofail,x-systemd.device-timeout=120s` |

## ネスト構造のサポート

config パスはネストディレクトリも扱える (`storage/` を例に):

```bash
sudo app/setup/storage.sh BackupServer.conf                 # 1 階層 (廃止予定)
sudo app/setup/storage.sh BackupServer/timemachine.conf     # 2 階層 (現行)
sudo app/setup/storage.sh FileServer/fileserver.conf
sudo app/setup/storage.sh FileServer/fileserver-backup.conf
```

[scripts.md > Path 解決ルール](scripts.md#path-解決ルール) 参照。

## 機密情報の扱い

| 種類 | 取扱 |
|---|---|
| AWS SSO トークン | `aws sso login` で取得、`~/.aws/sso/cache/` (本ファイル外) |
| Activation Code | `app/setup/output/` に出力、`.gitignore` で除外、登録後 `shred -u` |
| Wi-Fi password | env / `--password-file` (gitignore 対象) / 対話入力 |
| Samba password | `smbpasswd -a` 対話入力、サーバーローカル DB のみ |

## 関連

- [スクリプトリファレンス](scripts.md)
- [メトリクスリファレンス](metrics.md)
- [ADR-002: config を目的別ディレクトリに分割](../decisions/ADR-002-app-config-purpose-split.md)
- [ADR-007: rsync `--checksum` を定期実行しない](../decisions/ADR-007-rsync-no-periodic-checksum.md)
- [ADR-008: SMB アクセスログを vfs_full_audit + CloudWatch Logs で収集](../decisions/ADR-008-smb-vfs-full-audit.md)
