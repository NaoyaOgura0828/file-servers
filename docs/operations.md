# Operations

日常運用に必要な手順とポイントをまとめる。

## 構成サマリ

| 対象 | 主要構成 |
|---|---|
| BackupServer | `/mnt/timemachine` (USB×1, xfs)、Samba (Time Machine 共有)、CloudWatch Agent |
| FileServer | `/mnt/fileserver` (SATA×14, xfs) と `/mnt/fileserver-backup` (USB×29, xfs)、Samba、rsync ローカルバックアップ |

## 日常確認

### CloudWatch Dashboard
- AWS Console → CloudWatch → Dashboards → `FileServer` / `BackupServer`
- CPU / メモリ / ディスク / Swap が見える ([metrics リファレンス](reference/metrics.md))

### SSM Managed Instance
- AWS Console → Systems Manager → Fleet Manager
- 各サーバーが Online であることを確認

```bash
aws ssm describe-instance-information \
  --filters "Key=PingStatus,Values=Online" \
  --region ap-northeast-1 --profile FileServers
```

### サーバーローカル

```bash
systemctl status amazon-ssm-agent           # SSM Agent
systemctl status amazon-cloudwatch-agent    # CloudWatch Agent (state: onPremise)
systemctl status smbd nmbd avahi-daemon     # Samba 関連
findmnt /mnt/<mount-point>                  # マウント状態
df -h                                        # 容量
swapon --show                                # Swap
```

## 定期ジョブ (FileServer)

`app/jobs/rsync_fileserver.sh` を `app/setup/crontab.sh` 経由で `/etc/cron.d/fileserver` に登録する。

```bash
sudo app/setup/crontab.sh FileServer.conf       # 毎時 0 分に rsync 実行 (config: app/config/crontab/FileServer.conf)
```

設定内容は `app/config/crontab/FileServer.conf` を参照。比較は mtime + size による高速モードで、毎時実行を前提に I/O 負荷を抑えている。実行履歴は `/var/log/rsync/rsync_fileserver.log` に残り、CloudWatch Logs `/onprem/FileServer` の `rsync` ストリームに転送される。

> [!WARNING]
> `--checksum` (内容ハッシュ比較) は 100TB 規模ではソース・宛先双方を全件読むため I/O 過大。**定期実行はしない**。
> サイレント破損が疑われた場合のみ、対象を絞って手動でスポット検査する:
>
> ```bash
> sudo /home/NaoyaOgura/file-servers/app/jobs/rsync_fileserver.sh --checksum --dry-run
> ```
>
> 背景・代替手段の検討は [ADR-007](decisions/ADR-007-rsync-no-periodic-checksum.md) を参照。

## Backup Drive 管理 (BackupServer)

BackupServer の `/mnt/timemachine` は USB 接続 1 台。物理着脱時の手順:

1. SMB クライアントが切断されていることを確認
2. 必要なら手動で unmount: `sudo umount /mnt/timemachine`
3. USB を物理交換
4. 再接続後は **udev + systemd の auto_mount.sh** が `/mnt/timemachine` を自動再マウント (詳細は [how-to/mount-recovery.md](how-to/mount-recovery.md))

## FileServer USB プール (29 PV) の起動シナリオ

> [!IMPORTANT]
> USB プールはどれか 1 PV でも欠ければ VG が partial 状態となり、LV をマウントできない。

| シナリオ | 挙動 |
|---|---|
| boot 時に 29 USB すべて接続済 | fstab で自動マウント |
| boot 時に USB 未接続、起動後に全 29 を接続 | LVM event_activation → udev rule → `auto_mount.sh` の service が `/mnt/fileserver-backup` をマウント |
| 起動後の接続で一部が欠けたまま | VG が partial 状態。`pvs` / `vgs` で欠落 PV を特定 → 物理確認 |

## ログ確認

| ログ | 場所 |
|---|---|
| SSM Agent | `/var/log/amazon/ssm/amazon-ssm-agent.log` |
| CloudWatch Agent | `/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log` |
| Samba | `/var/log/samba/log.smbd` / `log.nmbd` |
| Samba 監査 (FileServer) | `/var/log/samba/audit.log` (CloudWatch Logs `/onprem/FileServer` の `smb-audit` ストリーム) |
| rsync | `/var/log/rsync/rsync_fileserver.log` |
| systemd | `journalctl -u <unit> --no-pager -n 50` |
| udev | `journalctl -t systemd-udevd --no-pager -n 50` |

## 監視・アラート

CloudWatch Alarm の推奨設定:

| 優先度 | メトリクス | 条件 |
|---|---|---|
| 🔴 高 | `DISK_USED_PERCENT` | > 90% |
| 🔴 高 | `MEM_USED_PERCENT` | > 90% |
| 🟡 中 | `SWAP_USED_PERCENT` | > 10% |
| 🟡 中 | `CPU_IOWAIT` (取得時) | > 50% |

詳細メトリクス一覧は [reference/metrics.md](reference/metrics.md) 参照。

## CDK インフラ更新

```bash
cd infra/cdk
npm install
npx cdk diff -c env=prod --all --profile FileServers
npx cdk deploy -c env=prod --all --profile FileServers
```

詳細は [how-to/deploy-cdk.md](how-to/deploy-cdk.md)。

## トラブルシュート

| 症状 | 着眼点 |
|---|---|
| SMB クライアントが繋がらない | `systemctl status smbd nmbd`、`hosts allow` の CIDR、`testparm -s`、smbd ログに `init_bitmap: Could not find opname` ([ADR-008](decisions/ADR-008-smb-vfs-full-audit.md)) |
| SMB 監査ログが CW Logs に出ない | `tail /var/log/samba/audit.log` でローカル出力確認、`testparm -s | grep full_audit`、`rsyslog` 状態、`amazon-cloudwatch-agent.json` の `collect_list` ([how-to/smb-audit-logs.md](how-to/smb-audit-logs.md)) |
| Time Machine が検出されない | `avahi-browse -r _adisk._tcp` で広告確認、`avahi-daemon` の状態 |
| CloudWatch にメトリクスが出ない | Agent ログ、IAM Role (`SSMCloudWatchAgentRole`)、`/root/.aws/credentials` |
| マウントが消えた | `dmesg`、`pvs` / `vgs` / `lvs`、USB 物理接続、`auto_mount.sh` の service ログ |
| rsync が実行されない | cron 設定、ロックファイル `/var/run/rsync_fileserver.lock` の有無 |

## Related Documents

- [Architecture](architecture.md)
- [新サーバー構築](tutorials/new-server-setup.md)
- [How-to: CDK デプロイ](how-to/deploy-cdk.md)
- [How-to: マウント復旧](how-to/mount-recovery.md)
- [How-to: SMB アクセスログを CloudWatch Logs に転送する](how-to/smb-audit-logs.md)
- [スクリプトリファレンス](reference/scripts.md)
- [ADR-007: rsync `--checksum` を定期実行しない](decisions/ADR-007-rsync-no-periodic-checksum.md)
- [ADR-008: vfs_full_audit + rsyslog + CloudWatch Logs](decisions/ADR-008-smb-vfs-full-audit.md)
