# ADR-003: Samba 共有の Unix ユーザーを既存 admin (`NaoyaOgura`) で運用する

## Status

Accepted

## Context

- 旧 BackupServer (RHEL/Rocky 系) では `setup_smb_conf.sh` が `SMB_VALID_USERS='NaoyaOgura'` で smb.conf を生成していた
- 旧 `mount_drive.sh` も `/mnt/timemachine` の所有者を `NaoyaOgura:NaoyaOgura` に chown していた
- Mac クライアントの Time Machine は `NaoyaOgura` の SMB credential で認証済
- 当初の Ubuntu 26.04 移行設計では、Time Machine 用の専用システムユーザー `timemachine` を新設する案を採用していた

## Decision

新サーバーでも **既存 admin ユーザー `NaoyaOgura`** を SMB 共有の `valid users` / `force user` / `force group` として使用する。`samba.sh` の `SHARE_VALID_USER` を `NaoyaOgura` で運用する。

`samba.sh` の `ensure_share_user` ステップは:
- `id NaoyaOgura` が成功 → 既存ユーザーとして検出 → `useradd` をスキップ
- chown は `NaoyaOgura:NaoyaOgura` を `/mnt/timemachine` に適用
- `smbpasswd -a NaoyaOgura` で Samba パスワード DB に登録 (対話)

## Alternatives Considered

| 案 | 却下理由 |
|---|---|
| 専用システムユーザー `timemachine` を新設 | 既存 Mac クライアント側の Time Machine 認証情報を再設定する必要があり、移行コストが発生 |
| ユーザー名を Server ごとに分離 (`backup`, `fileserver` 等) | 移行作業が増える割に役割分離の実利が小さい (運用は admin 1 名) |
| nobody / guest アクセス | Time Machine の運用上、認証付きが望ましい (ローカル LAN とは言え盗難リスク) |

## Consequences

### 利点

- 既存 Mac の Time Machine credential が無変更で済む (移行コスト 0)
- `/mnt/timemachine` 配下のファイル所有者が連続性を保つ (旧サーバーで NaoyaOgura が書いたファイルがそのまま読み書き可能)
- Samba 運用ユーザー = SSH 運用ユーザーで一致し、運用上の認知負荷が低い

### 欠点

- admin 個人アカウントが SMB 共有の owner になる (専用ユーザーによる役割分離が薄い)
- `NaoyaOgura` のパスワード管理を SMB と OS 側で同時に意識する必要 (実運用では `smbpasswd` を別途設定するため、独立ではある)
- 将来的に複数 admin が共有を扱うケースで分離が必要になる可能性

### 影響範囲

- `app/config/samba/BackupServer.conf` の `SHARE_VALID_USER="NaoyaOgura"` を維持
- `samba.sh` のロジック自体は無修正で動作 (既存ユーザー検出時にスキップ)
- 旧 `mount_drive.sh` の chown 動作は `samba.sh` の `ensure_share_dir` ステップに統合される

## Related

- [reference/configurations.md](../reference/configurations.md#sambaserver-conf)
- [Operations](../operations.md)
