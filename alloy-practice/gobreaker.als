module gobreaker

open util/ordering[Time]

/* * 1. 状態の定義
 */
abstract sig State {}
one sig Closed, HalfOpen, Open extends State {}

/*
 * 2. イベントの抽象化
 */
abstract sig Event {}
one sig SuccessOp, Failure, TimeoutOp, NoOp extends Event {}

/*
 * 3. 時間ステップの定義
 */
sig Time {
    state: one State,
    event: one Event
}

/*
 * 初期状態
 */
fact Init {
    first.state = Closed
}

/*
 * 遷移ロジック
 * 曖昧さを防ぐため、各状態のロジックを () で囲み、and で繋いでいます。
 */
pred transition [t, nextT: Time] {
    // --- State: Closed ---
    (t.state = Closed implies (
        t.event = Failure implies nextT.state = Open 
        else nextT.state = Closed
    ))
    and 

    // --- State: Open ---
    (t.state = Open implies (
        t.event = TimeoutOp implies nextT.state = HalfOpen 
        else nextT.state = Open
    ))
    and 

    // --- State: HalfOpen ---
    (t.state = HalfOpen implies (
        t.event = SuccessOp implies nextT.state = Closed 
        else t.event = Failure implies nextT.state = Open 
        else nextT.state = HalfOpen
    ))
}

/* * モデルの追加: 現実的なイベント発生制約 
 * 各状態で発生し得ないイベントを排除する
 */
fact ValidEvents {
    all t: Time {
        // Closed: タイムアウトは発生しない（リクエスト成功/失敗のみ）
        t.state = Closed implies t.event in (SuccessOp + Failure + NoOp)
        // Open: リクエスト処理は行われない（タイムアウトのみ待機）
        t.state = Open implies t.event in (TimeoutOp + NoOp)
        // HalfOpen: タイムアウト判定より先にリクエスト結果が出る前提
        t.state = HalfOpen implies t.event in (SuccessOp + Failure + NoOp)
    }
}

// トレース: すべての隣接する時刻で遷移ルールを守る
fact Traces {
    all t: Time - last | let nextT = t.next | transition[t, nextT]
}

/*
 * 4. 検証
 */

// 検証1: OpenからClosedへ直接ジャンプするような時刻tは「存在しない(no)」
assert NoJumpFromOpenToClosed {
    no t: Time - last | 
        (t.state = Open and t.next.state = Closed)
}

// 検証2: HalfOpenで失敗したら、次の状態はOpenであることを検証
assert HalfOpenFailureTripsBreaker {
    all t: Time - last |
        (t.state = HalfOpen and t.event = Failure) implies t.next.state = Open
}

/* 検証3: 到達可能性 (Reachability)
 * エラーからの回復サイクル（Closed -> Open -> HalfOpen -> Closed）が
 * モデル上で実行可能であることを確認する。
 */
pred showScenario {
    some t: Time | t.state = Open
    some t: Time | t.state = HalfOpen
    last.state = Closed
}

// 実行コマンド
--check NoJumpFromOpenToClosed for 10 Time
--check HalfOpenFailureTripsBreaker for 10 Time
--run showScenario for 10 Time