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

## TCP プロトコルと Sigil クライアント（第3段）

`herald_wire`（バイナリ符号化）、`herald_server`（TCP サーバー）、`herald_client`（型付きクライアント）が ADR 0066 の決定 5 を実装します。

### プロトコル v1

フレームは `u32 長さ（ビッグエンディアン）| バージョン(1) | 型 | 本文` です。長さはバージョン以降のバイト数で、上限は 1 MiB のペイロード + 4 KiB = 1,052,672 バイトです。サーバーは長さを確認してから本文を読み、超過や未知のバージョン・型は ERROR フレーム 1 つを返して接続を閉じます。

- 要求の型: 1 ENQUEUE、2 DEQUEUE、3 ACK、4 NACK、5 INSPECT、6 PING
- 応答の型: 128 DONE、129 ENQUEUED、130 JOB、131 NO_JOB、132 STATS、255 ERROR
- キュー名は 1〜256 バイトで、サーバー起動時に設定した固定の集合から選びます。未知のキューは `UnknownQueue` を返します。
- DEQUEUE の `wait_seconds`（0〜30）はロングポーリングです。ジョブが無い間は `poll_ms`（既定 20 ms）ごとに再確認し、投入があれば残り時間を待たずに返します。30 を超える値は `InvalidWait` です。

サーバーの既定は `127.0.0.1:7480` で、同時接続数 64、読み書きの期限は 1 フレームあたり 10,000 ms です。上限を超える接続は閉じられ、期限を過ぎた接続は切断されます。`with_listen`・`with_limits`・`with_data_dir`（永続化）で変更できます。

### クライアント

```
let mut client = connect(&host, 7480, 10000)?;
let id = client.enqueue(&queue, payload, 0, 3)?;
match client.dequeue(&queue, 30, 10)? { Some(job) => ..., None => ... }
client.ack(&queue, job.id, &job.lease_token)?;
```

`ping`・`enqueue`・`dequeue`・`ack`・`nack`・`inspect` を持ち、エラーは `ClientError`（`Io`・`Timeout`・`Protocol`・`Server`）で返ります。

### 検証

```sh
scripts/fetch-deps.sh
cargo build --locked --manifest-path .deps/sigil-compiler/Cargo.toml --bin sigil
scripts/test-tcp.sh
```

`herald_wire_test.sigil` は符号化の往復・拒否・上限と、変異フレームのファジング（受理したフレームは再符号化で元と一致する性質を検査）を行います。`herald_tcp_test.sigil` はループバックでサーバーとクライアントを動かし、基本操作・1 MiB ペイロード・ロングポーリング・不正フレーム・低速接続・接続数上限・永続モード・変異フレーム 240 件の実接続ファジングを検査します。

## 負荷・境界試験と公開前記録（第4段）

ADR 0066 決定 5 第4段に基づき、大量ジョブ投入時の資源上限（メモリ・スロット再利用）、Poison Message 耐性、ディスク枯渇時の WAL 同期保証、DoS 境界防御を検証します。

### 試験項目

- **Poison Message 耐性とワーカー突然死**: ワーカーが貸出中にクラッシュ（切断）した場合、リース期限切れ後に自動的に不可視状態が解除され、`attempt` が 1 加算されて再配送されます。再試行上限（`max_retries`）を超えた異常ジョブは自動的にデッドレターキュー（DLQ、`DeadLettered` 状態）へ移送されます。
- **旧ワーカーの遅延 ACK 拒絶**: リース失効後に別ワーカーへ再貸出された場合、旧ワーカーが遅延して送った ACK は `TokenExpired`（エラーコード 23）で拒絶され、新ワーカーの成果物を保護します。
- **大量ジョブ投入とスロット再利用**: 多数のジョブの投入・取得・ACK サイクルにおいて、完了したスロットを優先的に再利用し、インメモリ配列の無制限な伸長を防止します。
- **ディスク枯渇時の振る舞い**: `sigil-db` 核の I/O 関門へ `act_fail_space`（ENOSPC）を注入し、WAL 同期失敗時に `Enqueued` 応答が返らず、トランザクションが安全にロールバックされ、再起動後も既存ジョブが破損なく保全されることを検証します。
- **DoS 防御とプロトコル境界**: 1 MiB ペイロード上限（超過時 `PayloadTooLarge`）、1 MiB + 4 KiB フレーム長上限（超過時 `FrameTooLarge`）、同時接続数上限（`max_connections`）、I/O タイムアウト（低速接続切断）、および既定ループバック（`127.0.0.1`）待ち受けを検証します。

### 公開前検証記録（G2）

[ADR 0020](https://github.com/goodnasubi/sigil/blob/main/docs/decisions/0020-p1-security-addendum.md) 決定 3 の G2 関門に基づくセキュリティ検証記録、および G3 関門において所有者（goodnasubi）へ提示する確認項目を [`docs/pre-publish-record.md`](docs/pre-publish-record.md) に記録しています。

### 検証

```sh
scripts/fetch-deps.sh
cargo build --locked --manifest-path .deps/sigil-compiler/Cargo.toml --bin sigil
scripts/test-stage4.sh
```

`KEEP_SCRATCH=1` を指定すると一時ディレクトリを保持できます。

