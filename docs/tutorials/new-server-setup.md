# Tutorial: 新サーバー (Ubuntu 26.04) の構築

新規 BackupServer / FileServer を Ubuntu 26.04 で構築するチュートリアル。**順序通りに実行**することで、現環境と同等の構成を再現できる。

## 対象読者

これからオンプレミス Ubuntu 26.04 サーバーをセットアップして、SSM ハイブリッド管理 + CloudWatch 監視 + Samba 提供を整える運用者。

## 前提条件

- **Ubuntu 26.04 LTS** のインストールが完了 (admin ユーザーは `NaoyaOgura` を想定)
- ネットワーク疎通あり (apt および AWS エンドポイントへ HTTPS 443)
- `sudo` 権限、リポジトリ (`/home/NaoyaOgura/file-servers/`) を clone 済 (or scp で配置)
- 管理ホスト側で AWS CLI v2 + SSO ログイン済 (`aws sso login --profile FileServers`)
- [AWS CDK スタックがデプロイ済](../how-to/deploy-cdk.md) (`SSMCloudWatchAgentRole` が AWS に存在)

> [!CAUTION]
> 本チュートリアルは破壊的操作 (パッケージ導入・パーティション初期化・マウント点変更) を含む。本番運用中サーバーで実行しないこと。

## 全体フロー

```mermaid
flowchart TB
    A[OS 初期化<br>os_init.sh] --> B[ストレージ<br>storage.sh]
    B --> C[late-mount<br>auto_mount.sh]
    C --> D[ネットワーク<br>network.sh]
    D --> E[swap<br>swap.sh]
    E --> F[AWS CLI<br>aws_cli.sh]
    F --> G[Activation 受領<br>管理ホストで activation.sh]
    G --> H[SSM Agent<br>ssm_agent.sh]
    H --> I[CloudWatch Agent<br>cloudwatch_agent.sh]
    I --> J[Samba<br>samba.sh]
    J --> K{用途による}
    K -->|FileServer| L[logrotate.sh]
    L --> M[cron 登録]
    K -->|BackupServer| N[完了]
```

## Step 1. OS 初期化

```bash
sudo app/setup/os_init.sh BackupServer.conf   # または FileServer.conf
```

何が起きるか: hostname / timezone / locale 設定、`apt update && upgrade`、`unattended-upgrades` 有効化、共通ツール (jq, vim, git 等) の導入。

## Step 2. ストレージ (LVM) のマウント

### 2-A. 既存 LVM ボリュームを移設してきた場合

```bash
sudo app/setup/storage.sh BackupServer/timemachine.conf
```

何が起きるか: `vgchange -ay` で既存 VG を activate、`/etc/fstab` に UUID で登録、`mount -a` で実マウント。

### 2-B. 新規 PV/VG/LV を作る場合

```bash
sudo app/setup/lvm_create.sh /dev/sdX <vg-name> <lv-name>
# 例: sudo app/setup/lvm_create.sh /dev/sdb timemachine-group timemachine
sudo app/setup/storage.sh BackupServer/timemachine.conf
```

容量を後から増やすには:
```bash
sudo app/setup/lvm_extend.sh <vg-name> <lv-name> /dev/sdY [/dev/sdZ ...]
```

### 2-C. USB ストレージの late-mount を有効化 (BackupServer / FileServer USB)

```bash
sudo app/setup/auto_mount.sh BackupServer/timemachine.conf
```

何が起きるか: `/etc/udev/rules.d/99-...rules` と `/etc/systemd/system/...service` を配置し、LV 出現時に自動マウントするようにする。詳細は [ADR-005](../decisions/ADR-005-udev-late-mount.md)。

## Step 3. ネットワーク設定 (Wi-Fi 含む)

```bash
sudo app/setup/network.sh BackupServer.conf
```

ethernet の route-metric / autoconnect を設定。Wi-Fi 設定がある場合はパスワードを聞かれる:

```
Wi-Fi password (Kure Naval District): ********
```

> [!TIP]
> 自動化したい場合は `WIFI_PASSWORD=xxx sudo -E app/setup/network.sh ...` または `--password-file <path>` (gitignore 必須)。

## Step 4. Swap セットアップ

```bash
sudo app/setup/swap.sh                # デフォルト 6GB
# または: sudo app/setup/swap.sh --size 16
```

## Step 5. AWS CLI

```bash
app/setup/aws_cli.sh                  # ユーザー権限で実行 (~/.aws/config が ~/ 直下のため)
aws sso login --profile FileServers   # 初回認証 (ブラウザが開く)
aws sts get-caller-identity --profile FileServers
```

## Step 6. SSM ハイブリッドアクティベーション

### 6-A. 管理ホストで Activation を発行

```bash
# 管理ホスト側
cd /path/to/file-servers
app/setup/activation.sh BackupServer    # FileServer の場合は FileServer
```

`app/setup/output/activation-<Server>-<ts>.json` が生成される。

### 6-B. JSON を新サーバーへ転送

```bash
scp app/setup/output/activation-BackupServer-*.json NaoyaOgura@<new-server>:/tmp/
```

### 6-C. 新サーバーで登録

```bash
sudo app/setup/ssm_agent.sh /tmp/activation-BackupServer-*.json
shred -u /tmp/activation-BackupServer-*.json   # 登録後は不要
```

## Step 7. CloudWatch Agent

```bash
sudo app/setup/cloudwatch_agent.sh BackupServer.conf
```

CloudWatch コンソールで `OnPremises/BackupServer` 名前空間のメトリクスと `/onprem/BackupServer` ロググループを確認できれば成功。

## Step 8. Samba (Time Machine 対応)

```bash
sudo app/setup/samba.sh BackupServer.conf
```

`smbpasswd -a NaoyaOgura` の対話プロンプトが出るので Samba 用パスワードを設定。Mac の Time Machine 設定で BackupServer が表示されるようになる (Avahi 経由)。

## Step 9. (FileServer のみ) rsync ジョブと logrotate

```bash
sudo app/setup/logrotate.sh                     # rsync ログのローテーション設定
sudo app/setup/crontab.sh FileServer.conf       # /etc/cron.d/fileserver を配置 (毎時 0 分に rsync 実行)

# 動作確認 (手動実行)
sudo app/jobs/rsync_fileserver.sh
sudo tail -f /var/log/rsync/rsync_fileserver.log
```

## Step 10. (オプション) Docker / Claude Code

ファイルサーバー本来の役割には不要だが、現環境と揃えるため:

```bash
app/setup/docker.sh                   # Docker CE
newgrp docker                         # グループ反映 (再ログイン or newgrp)
docker run --rm hello-world

app/setup/claude.sh                   # Claude Code + ~/.claude/ クローン
claude login                          # 初回認証 (ブラウザが開く)
```

## 検証チェックリスト

セットアップ完了後の確認:

- [ ] `df -h` で `/mnt/<mount>` がマウント済み (容量も期待通り)
- [ ] `systemctl status amazon-ssm-agent amazon-cloudwatch-agent smbd nmbd` がすべて active
- [ ] AWS Console > Systems Manager > Fleet Manager でサーバーが Online
- [ ] AWS Console > CloudWatch > Dashboards で値が出ている
- [ ] `smbclient -L <netbios-name> -U NaoyaOgura` で共有が見える
- [ ] (BackupServer) Mac の Time Machine で対象が選択肢に出る
- [ ] (FileServer) `rsync_fileserver.sh` が手動で成功し、ログが CloudWatch Logs に出ている

## トラブル発生時

- マウントが失敗した: [how-to/mount-recovery.md](../how-to/mount-recovery.md)
- CloudWatch にメトリクスが出ない: [operations.md](../operations.md#トラブルシュート)
- Samba 接続できない: 同上
- AWS 認証エラー: `aws sso login --profile FileServers` 再実行

## 次のステップ

- 日常運用は [operations.md](../operations.md) を参照
- 設定の詳細は [reference/](../reference/) を参照
