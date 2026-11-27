# sigil-herald-queue

[ADR 0066 の決定 2・5](https://github.com/goodnasubi/sigil/blob/main/docs/decisions/0066-herald-queue.md) に基づくメモリ内キューです。`herald_queue.sigil` の `Queue` は単一の論理キューを表します。

- `enqueue` はバイト列を受け取り、キュー内で一意な ID を返します。遅延は 0〜86,400 秒、`max_retries` の既定値は 3 です。
- `dequeue` は配送可能なジョブを投入順で選び、呼び出し側が指定した期間だけリースします。返る配送情報には 16 バイトのリーストークンが含まれます。トークンの一意性はキューのインスタンス内で保証されます。
- `ack` は有効なリースを持つジョブを削除します。`nack` は失敗を 1 回加算し、即時または指定秒数後の再配送を予定します。リース期限切れも失敗 1 回として扱い、`attempt > max_retries` でジョブを `DeadLettered` として保持します。最初の配送の `attempt` は 0 です。
- 各操作には単調非減少の時刻（秒）を渡します。`advance` はリース期限切れと遅延の解除を反映し、`inspect` は指定したジョブの現在の状態を返します。`now` が期限に達するとリースは失効し、遅延ジョブはその可視化時刻に達すると配送可能になります。

## テスト

Sigil の `5735a993d2cea0c02bc15e9b47f003754b8fa217` で検証しています。コンパイラは Sigil のチェックアウトで `cargo build --locked --bin sigil` を実行してビルドできます。以下は、このリポジトリのルートで `sigil` が PATH にある状態で実行します。

```sh
sigil fmt --check herald_queue.sigil herald_queue_test.sigil
sigil check --root . herald_queue_test.sigil
sigil run --root . herald_queue_test.sigil main
sigil build --root . herald_queue_test.sigil main -o /tmp/herald-queue-test
/tmp/herald-queue-test
```

テストは固定の時刻を渡し、成功時には `0`、失敗時には検査箇所を示す番号を出力します。

## 永続化アダプター（第2段）

`herald_persistence` は第1段の状態機械を再利用する単一キューのアダプターです。
`open_persistent(dir, db_id, now)` はデータベースを排他的に開いて WAL を再生し、復旧処理を完了してからキューを返します。
`db_id` は新規データベースに使う 16 バイトの識別子です。
`close_persistent` はハンドルを消費し、排他ロックを解放します。
`new_memory()` で起動すると同じキュー操作をメモリ専用で利用できます。
操作は `enqueue_job`、`dequeue_job`、`ack_job`、`nack_job`、`advance_queue`、`inspect_job` です。

永続モードの `now` には UTC Unix 秒を渡します。
再起動時に残っていたリースは失敗を 1 回加算して即時再配送の対象にし、再試行上限を超えたジョブは DLQ に保持します。
遅延の解除には保存した絶対時刻を使います。
ジョブの投入、状態遷移、ACK による削除は型付き関係 API の直列トランザクションで行い、`Enqueued` は WAL の同期が成功した後に返します。
`CommitUnknown` が返った場合は、ハンドルを閉じて再度開き、WAL から復旧してください。

### 固定版と検証

`deps/pins.env` に Sigil コンパイラ・標準ライブラリと sigil-db 核の完全な SHA を記録しています。
下記の手順は固定版を取得し、sigil-db の `db/` を一時プロジェクトに展開して、復旧試験を評価器とネイティブバイナリで実行します。

```sh
scripts/fetch-deps.sh
cargo build --locked --manifest-path .deps/sigil-compiler/Cargo.toml --bin sigil
scripts/test-persistence.sh
```

既に用意したコンパイラと核を使う場合は、絶対パスを `SIGIL` と `SIGIL_DB_CORE` に指定できます。
