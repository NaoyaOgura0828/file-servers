# ADR-006: オンプレサーバー (FileServer/BackupServer) の hostname を Ubuntu 26.04 移行時に PascalCase で正規化する

## Status

Accepted

## Context

- 旧 FileServer / BackupServer (RHEL/Rocky 系) はいずれも **hostname=lowercase** (`fileserver` / `backupserver`) で稼働中
- 旧 FileServer の Samba ワークグループは `SAMBA` (BackupServer は `WORKGROUP`)
- プロジェクト全ドキュメント (architecture / operations / reference) と一部 conf ファイル (`os_init/BackupServer.conf` 等) は **PascalCase + `WORKGROUP`** 前提で記述されている
- `infra/cdk/config/{dev,prod}.ts` の CloudWatch Dashboard メトリクスフィルタは `host: 'fileserver'` / `host: 'backupserver'` (lowercase) で旧サーバーの実態に追従していた
- 両サーバーを Ubuntu 26.04 新サーバーへ移行するタイミングがある。OS 再構築のため **hostname 変更コストが既に発生する** 移行点
- in-place で旧サーバーの hostname/workgroup を変更するのは、稼働中の SMB クライアント・CloudWatch メトリクスを分断するため避けたい

## Decision

新 FileServer / BackupServer (Ubuntu 26.04) では以下の正規化を適用する:

| 項目 | FileServer | BackupServer |
|---|---|---|
| `HOSTNAME` | `FileServer` | `BackupServer` |
| Samba `WORKGROUP` | `WORKGROUP` | `WORKGROUP` (現行維持) |

`app/config/os_init/{FileServer,BackupServer}.conf` および `app/config/samba/{FileServer,BackupServer}.conf` は本決定に従い、新サーバー側で `os_init.sh` / `samba.sh` を実行することを前提とした値を保持する。

`infra/cdk/config/{dev,prod}.ts` の CloudWatch Dashboard メトリクスフィルタも PascalCase に揃える (`fileServer.host="FileServer"` / `backupServer.host="BackupServer"`)。

旧サーバーは廃止まで現行 (lowercase hostname / 既存 workgroup) のまま運用継続し、in-place 変更は行わない。

## Alternatives Considered

| 案 | 却下理由 |
|---|---|
| 旧サーバーで in-place に hostname/workgroup を変更 | 稼働中の SMB クライアント認証 / CloudWatch メトリクス `host` ディメンション / DHCP リースが分断され、移行リスクが高い割に Ubuntu 26.04 移行で結局再設定する |
| 新サーバーでも lowercase hostname / `SAMBA` workgroup を踏襲 | プロジェクト全ドキュメントが PascalCase + `WORKGROUP` 前提で書かれており、ドキュメントとの不揃いが残り続ける。両サーバーが Network Neighborhood で別ワークグループに分かれる |
| 新サーバー稼働後に旧サーバーを徐々に統合 (ローリング) | hostname / workgroup は一意であるべきで、ローリング統合は意味がない。クリーンカットオーバーが妥当 |

## Consequences

### 利点

- 全サーバーが PascalCase 命名 + 同一ワークグループ (`WORKGROUP`) に統一される
- BackupServer / FileServer の Network Neighborhood 表示が同一グループになり、Mac/Win の SMB ブラウジングが直感的になる
- ドキュメント (architecture / operations / reference / ADR) と実機の命名が完全に一致し、認知負荷が下がる
- CloudWatch メトリクスの `host` ディメンションが新サーバー稼働開始時点で PascalCase に切り替わり、以後統一される

### 欠点

- 移行カットオーバーの瞬間、CloudWatch メトリクスの `host` ディメンションが lowercase → PascalCase に切り替わるため、旧 host で時系列クエリしているダッシュボード/アラームは新 host での再設定が必要
- 旧サーバー稼働期間と新サーバー稼働期間でログ/メトリクスの hostname フィールドが分断される (期間跨ぎ検索は両 host を OR 指定する必要)
- Mac クライアント側で `smb://fileserver/...` 等の lowercase ブックマークを登録している場合、PascalCase への更新が望ましい (大文字小文字不問のため動作はする)

### 影響範囲

- `app/config/os_init/{FileServer,BackupServer}.conf` の `HOSTNAME` を PascalCase で維持
- `app/config/samba/{FileServer,BackupServer}.conf` の `WORKGROUP="WORKGROUP"` を維持
- `infra/cdk/config/{dev,prod}.ts` の `fileServer.host="FileServer"` / `backupServer.host="BackupServer"` に変更済 (CloudWatch Dashboard のメトリクスフィルタが新サーバーの `host` ディメンションと一致)
- 旧サーバー稼働中は CloudWatch Dashboard のメトリクスが空表示になる。**新サーバー切替と同時に CDK deploy** することでカットオーバーを揃える

## Related

- [reference/configurations.md](../reference/configurations.md#os_initserver-conf)
- [reference/configurations.md](../reference/configurations.md#sambaserver-conf)
- [Architecture](../architecture.md)
- [ADR-003: SMB ユーザー = NaoyaOgura](ADR-003-naoyaogura-smb-user.md)
