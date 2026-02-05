# Alloyによる形式検証の実習：sony/gobreaker

## 検証対象のOSS
- **名称:** `sony/gobreaker`
- **URL:** https://github.com/sony/gobreaker
- **概要:** `gobreaker` は、システムにおける **Circuit Breaker パターン**のGo言語による実装である。外部サービスへの呼び出し失敗が連続した場合に、自動的にリクエストを遮断（`Open` 状態）し、一定時間後に試験的にリクエストを許可（`Half-Open` 状態）することで、システムの過負荷や連鎖的な障害を防ぐ機能を提供する。

## 検証すべき性質
CircuitBreakerにおける状態遷移の整合性を検証する。具体的には、以下の3つの性質が常に満たされることを検証対象とする。

1. **不当な遮断の禁止:** エラー発生等のトリガーがない限り、`Closed`（定常）状態から `Open`（遮断）状態へ遷移しないこと。
2. **復帰プロセスの順序:** `Open` 状態から再び `Closed` 状態に戻るには、必ず `Half-Open`（試験）状態を経由しなければならないこと（`Open` から直接 `Closed` へ遷移しない）。
3. **試験中の挙動:** `Half-Open` 状態でリクエストが成功した場合のみ `Closed` 状態へ遷移し、失敗した場合には即座に `Open` 状態に戻ること。

> **判断材料:** CircuitBreakerにおいて、状態遷移ロジックの誤りは正常な通信を妨げ、サーバーへの過剰アクセスに繋がるため、以上の性質は当該OSSの仕様として重要である（`gobreaker` のREADME、`gobreaker.go` 内の定義、および [Martin Fowlerの文献](https://martinfowler.com/bliki/CircuitBreaker.html) を参考）。



## モデル化
`sony/gobreaker` の中核ロジックである `gobreaker.go` を解析し、Alloyによる形式検証に適した抽象度でモデル化した。本モデルでは、具体的なカウンタ数値や時刻そのものではなく、**状態遷移の因果関係**に焦点を当てている。



### 1. 状態（State）の定義
Go言語の実装における `const` 定数定義を、Alloyの `sig` として定義した。各状態は互いに排他的であるため、`extends` を用いて表現している。

| Go (`gobreaker.go`) | Alloy (Model) | 説明 |
| :--- | :--- | :--- |
| `StateClosed` | `sig Closed` | 定常状態。リクエストは通過する。 |
| `StateHalfOpen` | `sig HalfOpen` | 試験状態。リクエストを一つだけ通し、結果を待つ。 |
| `StateOpen` | `sig Open` | 遮断状態。リクエストは即座にエラーとなる。 |

### 2. イベントとトリガーの抽象化
`gobreaker` は内部に `Counts` 構造体を持ち、リクエスト数や失敗数をカウントして遷移を判定するが、モデル検証において無限の整数空間を扱うことは探索空間の爆発を招く。そのため、本モデルでは「遷移条件が満たされた」という事実をイベントとして抽象化した。

* **`Failure` (失敗閾値到達):**
    * Goの `onFailure` メソッド内で呼び出される `cb.readyToTrip(cb.counts)` が `true` を返す状況に対応。
* **`TimeoutOp` (タイムアウト経過):**
    * Goの `beforeRequest` メソッド内での `cb.expiry.Before(now)` が `true` となる（`Open` 期間が終了した）状況に対応。
* **`SuccessOp` (試験成功):**
    * Goの `onSuccess` メソッドの呼び出しに対応。特に `Half-Open` 状態での成功は状態遷移のトリガーとなる。

### 3. 別の状態への遷移の記述
`util/ordering` モジュールを用いて時間の経過（ステップ）を表現し、ある時点 `t` から次の時点 `nextT` への変化を述語 `pred transition` として記述した。Goのソースコード上のロジックと、Alloyモデルの対応関係は以下の通りである。

| 遷移元 | 遷移先 | トリガー (Alloy) | 対応するGo実装ロジック |
| :--- | :--- | :--- | :--- |
| `Closed` | `Open` | `Failure` | `onFailure`: `readyToTrip` が真の場合、`setState(StateOpen)` を実行。 |
| `Open` | `Half-Open` | `TimeoutOp` | `beforeRequest`: `expiry` を過ぎている場合、`setState(StateHalfOpen)` を実行。 |
| `Half-Open` | `Closed` | `SuccessOp` | `onSuccess`: 無条件で `setState(StateClosed)` を実行し、カウンタをリセット。 |
| `Half-Open` | `Open` | `Failure` | `onFailure`: 無条件で `setState(StateOpen)` を実行（試験失敗）。 |

### 4. 前提条件の制約
* **並行性の捨象:** `gobreaker` は `sync.Mutex` を用いて実装されているが、本検証の目的はロジックの正当性にあるため、システムの状態が離散的に遷移するモデルとして記述した。
* **No-Opの許容:** システムにリクエストが発生しない期間を考慮し、状態が変化しないイベント（`NoOp`）を許容した。

### 5. イベント発生の制約
単純な状態遷移だけでなく、現実のソフトウェアの挙動に即した検証を行うため、各状態で発生し得るイベントを制限する `fact ValidEvents` を定義した。

Go言語の実装において、例えば `Closed` 状態でタイムアウトの判定処理は行われない（リクエストの成功・失敗のみが判定される）。このように「論理的には記述できるが、現実には発生しないイベントの組み合わせ」を排除することで、反例の精度を高めている。

| 状態 (State) | 発生可能なイベント | 排除したイベント | 理由 |
| :--- | :--- | :--- | :--- |
| `Closed` | `SuccessOp`, `Failure`, `NoOp` | `Timeout` | 定常時はリクエストの結果のみを監視するため |
| `Open` | `Timeout`, `NoOp` | `SuccessOp`, `Failure` | 遮断中はリクエスト処理自体が行われないため |
| `Half-Open` | `SuccessOp`, `Failure`, `NoOp` | `Timeout` | リクエストの合否がタイムアウト判定より先に確定する前提のため |



## 検証手法
Alloy Analyzerのモデル検査機能を用い、`assert` 記述による反例探索を以下の2つの観点から実施した。

### 1. 安全性の検証1： 不正な復帰の不在
**目的:** `Open`（遮断）状態から、試験期間（`Half-Open`）を経ずにいきなり `Closed`（復旧）してしまうという遷移の不在を証明する。

```alloy
assert NoJumpFromOpenToClosed {
    // 最後の時刻を除くすべての時刻 t について
    all t: Time - last | 
        // OpenからClosedへの直接遷移は存在しない
        not (t.state = Open and t.next.state = Closed)
}
```

### 2. 安全性の検証2：試験失敗時の即時遮断
**目的:** `gobreaker` の仕様において、`Half-Open` 状態でのリクエスト失敗は、サーバーがまだ復旧していないことを意味するため、即座に `Open` 状態へ戻らなければならない。この挙動が保証されているかを検証する。

**論理式:**
任意の時刻 `t` において、状態が `Half-Open` かつイベントが `Failure` であるならば、直後の時刻 `nextT` の状態は必ず `Open` であることを主張する。

```alloy
assert HalfOpenFailureTripsBreaker {
    // 最後の時刻を除くすべての時刻 t について
    all t: Time - last |
        // 状態が HalfOpen かつ 失敗イベントが発生した場合、次は Open になる
        (t.state = HalfOpen and t.event = Failure) implies t.next.state = Open
}
```

### 3. 到達可能性の検証
前述の `assert` による検証は「不正な状態遷移が起きないこと（安全性：Safety）」を確認するものである。これに加え、システムがデッドロックに陥ることなく、正常に機能することを確認するため、到達可能性の検証を行った。

**目的:**
障害発生によって `Closed` から `Open` に遷移した後、適切な手順（`Half-Open` での成功）を経て、最終的に再び正常な `Closed` 状態へ復帰するシナリオが論理的に存在することを証明する。

**検証コード:**
`pred showScenario` を定義し、以下の条件を満たすトレース（実行経路）が存在するかを `run` コマンドで探索させた。

1. ある時刻で `Open` 状態になる。
2. ある時刻で `Half-Open` 状態になる。
3. 最終的な時刻で `Closed` 状態に戻っている。

```alloy
pred showScenario {
    // 少なくとも一度はOpenになる
    some t: Time | t.state = Open
    // 少なくとも一度はHalfOpenになる
    some t: Time | t.state = HalfOpen
    // 最終的にClosedに戻っている
    last.state = Closeds
}
```

### 4. 検証範囲の設定（Scope）
Alloy は有限の探索空間内で反例を探す「有界モデル検査」を行う。本検証では以下のコマンドを用いた。

```alloy
check NoJumpFromOpenToClosed for 10 Time
check HalfOpenFailureTripsBreaker for 10 Time
run showScenario for 10 Time
```

**スコープ設定の根拠（Small Scope Hypothesis）**: 形式手法における「小スコープ仮説」に基づき、探索範囲を 10 Timeとした。 Circuit Breaker の基本的なサイクル（`Closed` → `Open` → `Half-Open` → `Closed`/`Open`）は最短でも3〜4ステップで一周する。10ステップあれば、このサイクルを2周以上繰り返すシナリオを網羅できるため、論理的な欠陥が存在すれば検出可能であると判断した。

### 4. 結果の考察
Alloy Analyzer 4.2 にて上記`check`, `run`コマンドを実行した結果、**No counterexample found.** , **Predicate is consistent.** という結果を得た。

これにより、以下の結論が得られる。

- **仕様の堅牢性**: `gobreaker` の状態遷移ロジックは、モデル化された抽象度において矛盾を含んでいない。
- **安全性の担保**: 復旧手順（`Half-Open`）をスキップするような不正な遷移は論理的に発生し得ない。
- **到達可能性の担保**: Circuit Breaker の基本的なサイクル（`Closed` → `Open` → `Half-Open` → `Closed`/`Open`）を正しく踏めている。
- **意図通りの挙動**: 失敗時の遮断ロジックが仕様通りに機能している。

以上の結果より、`sony/gobreaker` のステートマシン設計は、Circuit Breakerパターンとして要求される基本的な安全性を満たしていると結論付ける。

## 補足事項
### 提出ファイルの構成
本リポジトリに含まれる主要なファイルとその役割は以下の通りである。

* **`gobreaker.als`**: Alloy 6 で記述された検証モデル本体。Go言語の実装ロジックを抽象化し、状態遷移と不変条件を記述している。
* **`README.md`**: 本ドキュメント。検証対象の解説、モデル化のアプローチ、検証結果の考察をまとめている。