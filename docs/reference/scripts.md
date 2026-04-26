# Reference: Scripts

`app/setup/` (1 回実行) と `app/jobs/` (定期実行) に格納されているスクリプトの一覧と引数仕様。

## Setup Scripts (`app/setup/`)

すべて `--help` / `-h` で usage を表示できる。`set -euo pipefail` 前提。

| スクリプト | 実行権限 | 主な引数 | 役割 |
|---|---|---|---|
| `os_init.sh` | root | `<config>` | hostname / timezone / locale / apt upgrade / unattended-upgrades |
| `storage.sh` | root | `<config>` | 既存 LVM 検出 → fstab 登録 → mount |
| `lvm_create.sh` | root | `<device> <vg> <lv> [--fs] [--size]` | 新規 PV/VG/LV 作成 + mkfs (デフォルト xfs) |
| `lvm_extend.sh` | root | `<vg> <lv> <device>...` | VG 拡張 (vgextend + lvextend + xfs_growfs) |
| `auto_mount.sh` | root | `<storage config> [--remove]` | LV 出現時の udev + systemd late-mount 設定 |
| `network.sh` | root | `<config> [--password-file]` | Ethernet route-metric / Wi-Fi 接続 (NetworkManager) |
| `swap.sh` | root | `[--size GB] [--path]` | swapfile 作成 + fstab 登録 |
| `aws_cli.sh` | user | `[<config path>]` | AWS CLI v2 導入 + `~/.aws/config` 配置 |
| `ssm_agent.sh` | root | `<activation JSON>` | SSM Agent 導入 + ハイブリッド登録 |
| `cloudwatch_agent.sh` | root | `<config>` | CloudWatch Agent 導入 + 設定 + 起動 |
| `samba.sh` | root | `<config>` | Samba (smbd/nmbd + Avahi) + Time Machine 設定 |
| `logrotate.sh` | root | (なし) | rsync ログ用 logrotate 設定の配置 |
| `docker.sh` | user | `[--codename <name>] [--skip-group]` | Docker CE + plugins 導入 |
| `claude.sh` | user | `[--config-repo URL] [--skip-config]` | Claude Code 導入 + ~/.claude/ クローン |
| `activation.sh` | user (管理ホスト) | `<server name>` | SSM ハイブリッドアクティベーション発行 + 登録手順 MD 出力 |

### 各スクリプト詳細

#### `os_init.sh`
- 入力 config: `app/config/os_init/<server>.conf` (`HOSTNAME`, `TIMEZONE`, `LOCALE`, `EXTRA_PACKAGES`, `ENABLE_UNATTENDED_UPGRADES`)
- ステップ: hostname → timezone → locale → apt update+upgrade → 追加パッケージ → unattended-upgrades → 時刻同期確認

#### `storage.sh`
- 入力 config: `app/config/storage/<server>/<role>.conf` (`VG_NAME`, `LV_NAME`, `MOUNT_POINT`, `FILESYSTEM`, `MOUNT_OPTIONS`)
- ステップ: lvm2/fs-tools 導入 → `vgchange -ay` → LV 検証 → blkid 検証 → mount point 確保 → fstab 追記 → `mount -a`
- フォーマットは行わない (新規作成は `lvm_create.sh`)

#### `lvm_create.sh`
- 引数: `<device> <vg_name> <lv_name>` + `--fs <type>` (デフォルト xfs) + `--size <size>` (デフォルト 100%FREE)
- ステップ: lvm2 + fs-tools 導入 → デバイス検証 → pvcreate → vgcreate → lvcreate → mkfs

#### `lvm_extend.sh`
- 引数: `<vg_name> <lv_name> <device> [<device>...]`
- ステップ: 検証 → 各デバイスで pvcreate + vgextend → lvextend +100%FREE → xfs_growfs / resize2fs

#### `auto_mount.sh`
- 引数: `<storage config>` (storage.sh と同じ形式) / `--remove`
- ステップ: udev rule (`/etc/udev/rules.d/99-...rules`) + oneshot service (`/etc/systemd/system/...service`) を冪等配置 → systemd / udev reload
- 配置されるサービスは `ConditionPathIsMountPoint=!<mount>` で重複マウントを防止

#### `network.sh`
- 入力 config: `app/config/network/<server>.conf` (`ETHERNET_ROUTE_METRIC`, `ETHERNET_AUTOCONNECT`, `WIFI_INTERFACE`, `WIFI_SSID`, `WIFI_ROUTE_METRIC`, `WIFI_AUTOCONNECT`)
- パスワード取得優先順位: 環境変数 `WIFI_PASSWORD` > `--password-file <path>` > 対話プロンプト (`read -s`)

#### `swap.sh`
- 引数: `--size <GB>` (デフォルト 6) / `--path <swapfile path>` (デフォルト `/swapfile`)
- ステップ: `fallocate` → 失敗時 `dd` → mkswap → swapon → fstab 追記
- 既存有効 swapfile (同パス) を検出した場合は skip (idempotent)

#### `aws_cli.sh`
- 引数: optional `<config path>` (デフォルト `app/config/aws_cli/config`)
- ステップ: AWS CLI v2 公式 zip を arch 自動判定で導入 → `~/.aws/config` を配置 (既存はバックアップ)
- 認証は SSO 方式、`~/.aws/credentials` は触らない

#### `ssm_agent.sh`
- 引数: `<activation JSON>` (`activation.sh` 出力)
- ステップ: jq 導入 → JSON から ActivationId/Code 抽出 → amazon-ssm-agent.deb (arch 自動) 導入 → register → `enable --now`

#### `cloudwatch_agent.sh`
- 入力 config: `app/config/cloudwatch_agent/<server>.conf` (`SERVER_NAME`, `MOUNTPOINTS`, `LOG_PATHS`)
- ステップ: amazon-cloudwatch-agent.deb (arch 自動) 導入 → JSON 設定生成 → systemd unit 上書き (IMDS 無効化) → `/root/.aws/config` + common-config.toml 配置 → SSM Parameter Store にバックアップ → fetch-config + 起動 → ステータス確認

#### `samba.sh`
- 入力 config: `app/config/samba/<server>.conf` (`SERVER_NAME`, `NETBIOS_NAME`, `WORKGROUP`, `SERVER_STRING`, `SHARE_NAME`, `SHARE_PATH`, `SHARE_VALID_USER`, `SHARE_TIMEMACHINE_MAX_SIZE`, `HOSTS_ALLOW`, `INTERFACES`, `ENABLE_AVAHI`, `ENABLE_FRUIT`)
- ステップ: apt 導入 → 共有ディレクトリ確保 → Unix ユーザー確保 (既存ならスキップ) → smbpasswd 対話 → smb.conf 生成 → Avahi service (条件付き) → testparm → `enable --now smbd nmbd avahi-daemon`

#### `logrotate.sh`
- 入力 config: `app/config/logrotate/rsync_fileserver.conf` (logrotate 形式そのもの)
- ステップ: logrotate 導入確認 → `install -m 644 -o root -g root /etc/logrotate.d/rsync_fileserver` → `logrotate -d` 構文検証 → ログディレクトリ確保

#### `docker.sh`
- 引数: `--codename <name>` (省略時は `/etc/os-release` から自動検出) / `--skip-group`
- ステップ: 競合パッケージ除去 → Docker GPG キー → apt sources 登録 → docker-ce + plugins 導入 → `enable --now docker` → docker グループに追加

#### `claude.sh`
- 引数: `--config-repo <git URL>` (デフォルト `claude-settings`) / `--skip-config`
- ステップ: 公式 install.sh で Claude Code 導入 → 既存 `~/.claude/` を timestamp バックアップ → リポジトリを clone

#### `activation.sh` (管理ホスト用)
- 引数: `<server name>` (例: `BackupServer` / `FileServer`)
- 出力先: `app/setup/output/activation-<name>-<ts>.json` (権限 600) と同 `How_to_Activation_for_<name>.md`
- 認証: SSO `--profile FileServers` で `aws iam get-role` + `aws ssm create-activation`

## Job Scripts (`app/jobs/`)

定期実行を前提とする運用ジョブ。

| スクリプト | 実行権限 | 主な引数 | 役割 |
|---|---|---|---|
| `rsync_fileserver.sh` | root | `[--delete]` | `/mnt/fileserver/` → `/mnt/fileserver-backup/` の rsync 同期 |

### `rsync_fileserver.sh`

- 比較モード: 常時 `--checksum` (内容ハッシュ、サイレント破損検出)
- 多重起動防止: `flock(1)` (`/var/run/rsync_fileserver.lock`)
- ログ: `/var/log/rsync/rsync_fileserver.log` (CloudWatch Agent 経由で `/onprem/FileServer/rsync` ストリームへ)
- オプション: `--delete` で宛先側余剰ファイルを削除し完全ミラー化

```bash
sudo /home/NaoyaOgura/file-servers/app/jobs/rsync_fileserver.sh
sudo /home/NaoyaOgura/file-servers/app/jobs/rsync_fileserver.sh --delete   # 完全ミラー
```

## Path 解決ルール

`<config>` 引数を受け取るスクリプトは次の優先順位で config を解決する:

1. 絶対パス / CWD 相対パス (`-f` チェック)
2. `${SCRIPT_DIR}/${INPUT}` (スクリプト同居 dir)
3. `${SCRIPT_DIR}/../config/<purpose>/${INPUT}` (`app/config/<purpose>/` 配下)

これにより `BackupServer.conf` のようなファイル名 1 個だけでも、`FileServer/sata.conf` のようなネスト指定でも解決できる。

## 関連

- [設定ファイルリファレンス](configurations.md)
- [メトリクスリファレンス](metrics.md)
- [新サーバー構築チュートリアル](../tutorials/new-server-setup.md)
