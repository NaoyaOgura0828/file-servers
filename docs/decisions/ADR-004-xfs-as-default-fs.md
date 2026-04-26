# ADR-004: ファイルシステム標準を Ubuntu 上でも xfs に揃える

## Status

Accepted

## Context

- 旧 BackupServer (RHEL/Rocky 系) は `/` も `/mnt/timemachine` も xfs で運用
- 旧 `create_lvm_group.sh` は `mkfs.xfs -f` を使用
- Ubuntu 26.04 では LVM のデフォルト FS は ext4 だが、本プロジェクトは旧サーバーから物理ディスクを移設して認識させる運用がある
- ディスク移設時、Ubuntu 上でも xfs を読み書きする必要がある

## Decision

本プロジェクトの **標準ファイルシステムは xfs**。Ubuntu 上で新規作成する場合も xfs を採用する。

- `app/config/storage/sample.conf` および `app/config/storage/<server>/*.conf` のデフォルト `FILESYSTEM="xfs"`
- `app/setup/lvm_create.sh` のデフォルト `--fs xfs` (`mkfs.xfs -f`)
- `app/setup/storage.sh` は FS 種別に応じて `xfsprogs` / `e2fsprogs` / `btrfs-progs` を自動 install (xfs 以外も使えるが、ドキュメントの推奨は xfs)
- fstab の `fs_passno` (6 列目) は xfs/btrfs では `0` (boot 時 fsck を実施しない、xfs 公式推奨)、ext 系では `2`

## Alternatives Considered

| 案 | 却下理由 |
|---|---|
| Ubuntu のデフォルト ext4 に揃える | 旧サーバーから移設した既存 xfs ボリュームを ext4 に変換する必要があり、データ全コピーが必要 |
| 各サーバーで個別判断 (混在容認) | 運用混乱、管理者が「これはどっち?」を毎回確認する負担 |
| btrfs 採用 | プロジェクトとして運用知見が薄く、現用途で xfs より優位な特徴 (snapshot / RAID) は使っていない |

## Consequences

### 利点

- 旧サーバーの物理ディスク (xfs) をそのまま新サーバーで認識できる
- `xfs_growfs` によるオンライン拡張が使える (`lvm_extend.sh`)
- 大容量ファイル (Time Machine sparsebundle 等) との相性が良い
- 拡張属性 (xattr) を使った Samba `vfs_fruit` の動作が安定

### 欠点

- `xfsprogs` パッケージが Ubuntu のデフォルト minimal install に含まれない (storage.sh で自動 apt install で対応)
- xfs はオンライン縮小不可 (拡張のみ可)。LV を縮小したい場合は別 FS への移行が必要
- ext4 専用の運用ツール (例: 一部の dump/restore) は使えない

### 影響範囲

- `lvm_create.sh` のデフォルト FS を xfs に統一
- `storage.sh` は FS 種別を config から受け取り、対応するツールパッケージを install する分岐を持つ (xfs / ext / btrfs)
- 既存の Ubuntu 由来の ext4 ボリューム (root, swap 用 LV 等) は OS 側に任せ、本プロジェクト管理外とする

## Related

- [reference/configurations.md](../reference/configurations.md#storageserverroleconf)
- [tutorials/new-server-setup.md](../tutorials/new-server-setup.md)
