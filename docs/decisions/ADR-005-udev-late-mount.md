# ADR-005: USB ストレージの late-mount を udev + systemd で実現する

## Status

Accepted

## Context

- BackupServer の `/mnt/timemachine` は外付け USB-HDD (1 台)
- FileServer の USB プールは USB-HDD × 15 を 1 VG にまとめている
- Boot 時に USB が間に合わず、fstab automount が失敗するケースが過去発生
- 旧運用では起動後に `mount_drive.sh` を **手動実行**して回避していた
- Ubuntu 26.04 移行を機に「全 USB が接続された時点で自動マウント」を実現したい

## Decision

2 段階の対策を組み合わせる。

### 1. fstab に `nofail` + `x-systemd.device-timeout` を付与

```
UUID=...  /mnt/timemachine  xfs  defaults,noatime,nofail,x-systemd.device-timeout=30s   0  0
UUID=...  /mnt/<usb-pool>   xfs  defaults,noatime,nofail,x-systemd.device-timeout=120s  0  0
```

- `nofail`: デバイス未検出時に boot を失敗させずスキップ (emergency mode 回避)
- `x-systemd.device-timeout`: デバイス待ち時間。USB hub の power-on cascade と LVM activation を考慮して BackupServer は 30s、FileServer USB プールは 120s

### 2. udev rule + oneshot systemd service による late-mount

`app/setup/auto_mount.sh` が以下を冪等に配置:

```
/etc/udev/rules.d/99-fileservers-automount-<vg>-<lv>.rules
  ACTION=="add|change", SUBSYSTEM=="block",
    ENV{DM_VG_NAME}=="<vg>", ENV{DM_LV_NAME}=="<lv>",
    TAG+="systemd", ENV{SYSTEMD_WANTS}+="fileservers-automount-<vg>-<lv>.service"

/etc/systemd/system/fileservers-automount-<vg>-<lv>.service
  [Unit]
  ConditionPathIsMountPoint=!<mount-point>
  [Service]
  Type=oneshot
  ExecStart=/usr/bin/mount <mount-point>
```

挙動:
1. USB-HDD が物理接続される
2. 全 PV 認識 → LVM event_activation で VG が自動 activate
3. `/dev/<vg>/<lv>` が出現 (DM_NAME = `<vg>-<lv>`)
4. udev "add" イベント発火 → systemd service を SYSTEMD_WANTS で起動
5. service が `mount /mnt/<mount-point>` を実行 (既マウントなら `ConditionPathIsMountPoint=!` で no-op)

`auto_mount.sh --remove` で udev rule + service を冪等削除できる。

## Alternatives Considered

| 案 | 評価 |
|---|---|
| `x-systemd.automount` (autofs lazy mount) | 初回アクセス時マウント。Samba がアクセスしないと mount が走らない可能性、Mac 不在時に mount されないため要件 (USB 接続 = 自動 mount) を満たさない |
| 旧 `mount_drive.sh` を残し手動 mount を継続 | 起動後に admin が常時介入する必要、自動化要件を満たさない |
| systemd `*.path` unit で LV パスを監視 | デバイスマッパー特有の "changes" を path unit で取りにくい |
| systemd `dev-<vg>-<lv>.device` の WantedBy で連動 | エスケープ規則が複雑で運用が脆い |
| `nofail` + 適度な `device-timeout` のみ (auto_mount.sh なし) | timeout 内に enumerate 完了しない場合は永続的に未マウント、後接続で自動マウントされない |

## Consequences

### 利点

- boot 時に USB が間に合わなくても emergency mode に落ちない (`nofail`)
- 起動後の物理接続でも自動マウントが完了 (udev driven)
- 手動 `mount_drive.sh` の運用が不要
- `--remove` でクリーンに後始末できる
- 設定は冪等で、再実行で破綻しない

### 欠点

- `/etc/udev/rules.d/` と `/etc/systemd/system/` に追加ファイルが増える (LV ごと 1 セット)
- LV 名 / VG 名変更時は再配置が必要 (`auto_mount.sh` を再実行)
- 認知すべき仕組み (udev → systemd → mount) が増え、トラブル時の調査ポイントが拡張

### 影響範囲

- BackupServer / FileServer USB プールに `auto_mount.sh` を適用
- FileServer SATA (内蔵プール) は `nofail` のみで十分、`auto_mount.sh` は不要
- ユーザー操作は `auto_mount.sh` を 1 回実行するだけ。常時 daemon は systemd / udev に任せる

## Related

- [how-to/mount-recovery.md](../how-to/mount-recovery.md)
- [reference/configurations.md](../reference/configurations.md#storageserverroleconf)
- [Architecture](../architecture.md)
