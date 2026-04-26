# ADR-002: app/config/ を目的別サブディレクトリに分割する

## Status

Accepted

## Context

- 当初 `app/config/` 配下にすべての conf を平置きしていた
  - `BackupServer.conf` (CloudWatch Agent 用)
  - `FileServer.conf` (CloudWatch Agent 用)
  - `rsync_logrotate.conf` (logrotate 用)
  - `sample.conf` (CloudWatch Agent 用 sample)
- Samba 用 conf を新設するにあたり、CloudWatch Agent と同一スキーマでないため、平置き継続は混乱を招く
- 各 setup スクリプトが `source` で読み込む形式のため、無関係な変数 (例: Samba 用が CWAgent 実行時に環境汚染する) を防ぐ意味でも分離が必要

## Decision

`app/config/<purpose>/` という目的別ディレクトリに再編する。`<purpose>` は対応する `app/setup/<purpose>.sh` と 1:1 対応。

```
app/config/
├── cloudwatch_agent/   ← cloudwatch_agent.sh
├── logrotate/          ← logrotate.sh
├── samba/              ← samba.sh
├── network/            ← network.sh
├── os_init/            ← os_init.sh
├── storage/            ← storage.sh / lvm_create.sh / lvm_extend.sh / auto_mount.sh
└── aws_cli/            ← aws_cli.sh
```

ファイル命名は purpose ごとに最適化:
- per-server (CWAgent / Samba / Network / OS init): `<ServerName>.conf` (PascalCase)
- per-target (logrotate): 対象ログ名 (`rsync_fileserver.conf`)
- 複数ボリュームを持つサーバーの storage は更にネスト: `storage/<Server>/<role>.conf` (例: `FileServer/sata.conf`, `FileServer/usb.conf`)
- `aws_cli/config` のみ AWS CLI ini 形式そのものを保持

各 setup スクリプトのパス解決ロジックは:
1. CWD 相対 / 絶対パス
2. スクリプト同居ディレクトリ (`${SCRIPT_DIR}/...`)
3. `app/config/<purpose>/` 配下 (`${SCRIPT_DIR}/../config/<purpose>/...`)

の優先順位で resolve する。これにより `BackupServer.conf` のようなファイル名 1 個でも `FileServer/sata.conf` のようなネスト指定でも解決できる。

## Alternatives Considered

| 案 | 却下理由 |
|---|---|
| 平置き継続 | スキーマが異なる conf が混在、`source` 時の環境汚染、可読性低下 |
| サーバー別ディレクトリ (`config/BackupServer/`, `config/FileServer/`) | logrotate 等の per-target conf が収まらない、setup スクリプト側からの参照が散らかる |
| 1 conf に複数 purpose を集約 (例: `BackupServer.conf` に CWAgent + Samba + Storage 全てを書く) | スクリプトが互いの変数を意識する必要があり、責務分離が崩れる |

## Consequences

### 利点

- スクリプトと config が 1:1 対応し、関係性が一目で分かる
- 新規 purpose 追加 = `app/setup/X.sh` + `app/config/X/` を増やすだけ
- ネスト構造で複数ボリューム持つサーバー (FileServer 等) を整理できる
- `source` 時の変数衝突を防ぎ、各スクリプトが独立した名前空間を持つ
- 同一スクリプトを `<server>.conf` を切り替えて再実行することで、新サーバー追加が容易

### 欠点

- ディレクトリ階層が深くなる (`app/config/storage/FileServer/sata.conf` で 4 階層)
- サーバー単位の全体像を見るのに複数ディレクトリを横断する

### 影響範囲

- `app/setup/cloudwatch_agent.sh` / `logrotate.sh` 等のパス解決ロジックを更新
- shellscript/ 配下の旧 README 記述は削除し、本 ADR + reference/configurations.md に集約

## Related

- [reference/configurations.md](../reference/configurations.md)
- [reference/scripts.md](../reference/scripts.md)
