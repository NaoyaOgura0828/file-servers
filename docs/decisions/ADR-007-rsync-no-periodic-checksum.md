# ADR-007: FileServer の rsync バックアップで `--checksum` を定期実行しない

## Status

Accepted

## Context

- FileServer の主データ領域は LVM linear xfs / SATA × 13 + USB × 15 の構成で、容量は **約 100TB 級**
- ローカルバックアップ `/mnt/fileserver/ → /mnt/fileserver-backup/` は `app/jobs/rsync_fileserver.sh` で実行し、cron により毎時 0 分に起動する
- 当初設計では「サイレント破損検出」を目的に rsync を **常時 `--checksum`** で動かしていた
  - 旧コマンド: `rsync -ahv --checksum --progress --stats /mnt/fileserver/ /mnt/fileserver-backup/`
- `rsync --checksum` の挙動は **「変更されたファイルだけをチェックサム計算する」のではなく、「変更されたかを判定するためにソース・宛先の対応ファイルを内容ハッシュで比較する」**
  - つまり `--checksum` 指定時は、ツリー全体のうちソース・宛先で同名・同サイズに揃っているファイルすべてが内容比較対象になる
- このため、毎時実行は**転送量が少なくても 100TB 級の読み取り I/O** を恒常的に走らせていた
- 影響:
  - HDD (SATA + USB) の累積読取バイト数が増え、機械寿命を縮める
  - USB バス / SATA コントローラに恒常的な高負荷
  - 1 サイクルが長くなり毎時のスケジュールに収まらないリスク
  - サイレント破損検出の実効性は週単位以下で十分だが、毎時走らせる必要性はない

## Decision

FileServer の rsync バックアップで `--checksum` は **定期実行しない**。

| 項目 | 採用 |
|---|---|
| 毎時 cron (`0 * * * *`) | **mtime + size** による高速比較。`rsync -aHAXh --numeric-ids --stats` |
| 週次 cron (`--checksum --dry-run`) | **採用しない**。100TB 規模では週次でも I/O 過大なため |
| 月次 cron | 採用しない |
| 手動スポット検査 | スクリプトのオプションとして `--checksum` / `--dry-run` を残す。破損が疑われたディレクトリに絞って手動で実行する想定 |

スクリプトのデフォルトモードは「mtime + size 比較」とし、`--checksum` はオプトインの手動オプションに格下げする。cron に登録するのは引数なしの通常実行のみとする。

サイレント破損 (bit rot) の検出と対処は別レイヤーで設計し直す (本 ADR の範囲外、後述「未対応事項」)。

## Alternatives Considered

| 案 | 却下理由 |
|---|---|
| 旧来通り毎時 `--checksum` を継続 | 100TB ツリー全体を毎時 read する I/O コストが SATA + USB HDD の寿命と毎時スケジュールに対して過大。本 ADR の起点 |
| 週次 1 回 `--checksum --dry-run` で検証専用ジョブを追加 | 週次でも 100TB の全件読みは HDD 寿命・USB バス負荷に響くと判断。検出のために常時走らせる価値より、必要時に対象を絞って手動実行する方が合理的 |
| 月次 1 回 `--checksum --dry-run` | 検出粒度が荒すぎる割に、100TB 全件読みが軽くなるわけではない。同じ I/O コストを払うなら別レイヤーの仕組み (FS レベル checksum / SMART / 復元テスト) で検出した方が信頼性が高い |
| 毎時 `--checksum` のままハッシュアルゴリズムを軽量化 (`--checksum-choice=xxh3`) | 計算コストは下がるが **読取 I/O 自体は減らない**。100TB スピンドル read を毎時走らせる根本問題が残る |
| ZFS / Btrfs などチェックサム機能を持つ FS への移行 | 本決定と同じ問題の真の解。ただしファイルシステム移行は別 ADR 級の意思決定であり、本 ADR では rsync 運用の即時是正のみを扱う ([ADR-004](ADR-004-xfs-as-default-fs.md) で xfs を採用済) |

## Consequences

### 利点

- 毎時 rsync の I/O が、変更ファイルだけの転送 + メタデータ比較に縮退し、**HDD 寿命と USB バス負荷が大幅に減る**
- 1 サイクルの所要時間が短くなり、毎時スケジュール内に確実に収まる
- 手動 `--checksum` は対象を絞れるため、必要なときに実用的なコストで破損検査が可能
- 通常 rsync が高速化されたことで、バックアップ遅延がインシデント検知 (CloudWatch Logs `/onprem/FileServer/rsync` ストリーム) で見えやすくなる

### 欠点 / 未対応事項

- **常時のサイレント破損 (bit rot) 検出手段が rsync の二重実行から外れる**
  - 同名・同サイズ・同 mtime のままビット化けしたファイルは、通常 rsync では検出できない (size と mtime しか見ないため)
  - 本 ADR では即時の是正としてこの検出を意図的に外す。代替手段として以下を別タスクで設計する想定:
    - SMART (`smartctl`) の定期確認 (CloudWatch メトリクス / アラーム)
    - 復元テスト (BackupServer 等への部分リストアで実物読み出し)
    - 重要ディレクトリへの `sha256sum` 履歴ファイル方式 (生成・比較を週次で別ジョブ化、対象を絞り込む)
    - 中長期的には FS レベル checksum を持つ ZFS/Btrfs への移行検討 (別 ADR 化が妥当)
- 通常 rsync は `--delete` を**付けない**運用なので、ソース側で削除されたファイルは backup 側に残る (これは本 ADR 以前からの仕様で、`rsync_fileserver.sh --delete` で完全ミラー化できるオプションは維持)

### 影響範囲

- `app/jobs/rsync_fileserver.sh`: 既定 `--checksum` を撤去し、`--checksum` / `--dry-run` を手動オプションに格下げ。rsync オプションは `-aHAXh --numeric-ids --stats` を採用 (hard link / ACL / xattr 保持、UID/GID 数値化)
- `app/config/crontab/FileServer.conf`: 毎時 0 分の通常 rsync のみ。`--checksum` の定期実行行は登録しない
- `README.md` / `docs/architecture.md` / `docs/operations.md` / `docs/reference/scripts.md`: 「常時 `--checksum`」前提の記述を「mtime + size による高速同期」「`--checksum` は手動スポット検査」に追従

## Related

- [Operations](../operations.md#定期ジョブ-fileserver)
- [Architecture](../architecture.md#fileserver-ローカルバックアップ)
- [reference/scripts.md](../reference/scripts.md#rsync_fileserversh)
- [reference/configurations.md](../reference/configurations.md#crontabserverconf)
- [ADR-004: xfs を既定ファイルシステムとする](ADR-004-xfs-as-default-fs.md)
- [ADR-005: udev による USB late-mount](ADR-005-udev-late-mount.md)
