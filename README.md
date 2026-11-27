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
