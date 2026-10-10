# InnoNetwork — 日本語

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

InnoNetwork は Apple プラットフォーム向けの型安全な非同期 Swift ネットワークライブラリです。明示的な endpoint 構造体、`@APIDefinition`、`DefaultNetworkClient.request` から始められます。すべての追加製品を事前にリンクする必要はありません。

## 現在のバージョンと範囲

現在の安定版は **6.1.1**、公開日は 2026-10-07 UTC です。6.1.0 からランタイムや公開 API を変えず、文書とツールを修正したパッチです。タグの revision は `44e4ca28c50c03f817231a077c0f3bdfdbc859c8` です。現行の七言語ガイドは同じ導入・例・契約範囲を扱い、詳細は [英語 README](README.md) にあります。

[6.1.1 Release](https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.1) · [Release notes](docs/releases/6.1.1.md)

## 要件とインストール

Swift **6.2+** と Swift 6 言語モードが必要です。最低対応 OS は iOS **16**、macOS **14**、tvOS **16**、watchOS **9**、visionOS **1** です。Apple 専用で Linux は非対応です。次の宣言をそれぞれパッケージ依存と target 依存に追加します。

```swift
// Package.swift — dependencies
.package(
    url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
    .upToNextMinor(from: "6.1.1")
)

// Package.swift — target dependencies
.product(name: "InnoNetwork", package: "InnoNetwork")
```

再現性が必要なら `.exact("6.1.1")` を使います。パッチ範囲なら Provisionally Stable API の次の minor での変更を自動採用しません。`Package.resolved` を確認してください。マクロを使わない場合は依存宣言に `traits: []` を追加し、プロトコルを手動実装します。全依存経路で `Macros` を無効にする必要があります。SwiftPM は SwiftSyntax など manifest 上の依存を引き続き解決・取得することがあります。

## 製品の選択

- `InnoNetwork` — 型付き HTTP リクエストとポリシーパイプライン

- `InnoNetworkAuthAWS` — 任意の AWS SigV4 単発署名器。AWS SDK の代替ではない

- `InnoNetworkDownload` — ダウンロード、一時停止・再開、バックグラウンド復元、イベント

- `InnoNetworkUpload` — ファイルアップロード、進捗、復元、サイズ制限付き応答

- `InnoNetworkWebSocket` — 双方向接続、heartbeat、再接続、終了分類

- `InnoNetworkPersistentCache` — RFC のルールを考慮したディスクキャッシュと容量制限

- `InnoNetworkOpenAPI` — 完全な client パイプラインの adapter または軽量 OpenAPI Runtime transport

- `InnoNetworkTrust` — 任意の公開鍵 pinning evaluator

- `InnoNetworkTestSupport` — 利用側テスト用 helper。production target にはリンクしない

`InnoNetworkMacroSupport` はコンパイラホスト専用です。HLS は別の [InnoNetwork-Stream](https://github.com/InnoSquadCorp/InnoNetwork-Stream)、Protobuf は [InnoNetwork-Protobuf](https://github.com/InnoSquadCorp/InnoNetwork-Protobuf) にあります。両方の 6.1.1 は Core 6.1.1 を厳密に固定します。Stream のモジュールは引き続き `InnoNetworkHLS`、`InnoNetworkHLSLive`、`InnoNetworkHLSAVFoundation`、`InnoNetworkHLSAudio` で、`InnoNetworkStream` モジュールはありません。Audio には Swift 6.4 のコンパイル条件と OS 27 の availability 制約があります。Protobuf の推奨 product は `InnoNetwork-Protobuf`、import は `InnoNetworkProtobuf` です。

## 最初のリクエスト

サーバーは説明用です。実際の URL と応答モデルに置き換え、async 文脈で実行してください。構造体が入力と `APIResponse` を定義し、マクロは反復的な適合コードを生成します。認証は `.anonymous`、`.optional`、`.required` を明示します。GET/HEAD は保存された `query`、POST/PUT/PATCH/DELETE は `body` を推論します。他のメソッドや独自 payload は完全な `Parameter`/`parameters` 契約が必要です。

```swift
import Foundation
import InnoNetwork

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User
    let id: Int
}

let client = DefaultNetworkClient(
    baseURL: URL(string: "https://api.example.com/v1")!
)
let user = try await client.request(GetUser(id: 42))
print(user.name)
```

## 設定・認証・セキュリティ

`DefaultNetworkClient(baseURL:)` は `NetworkConfiguration.safeDefaults(baseURL:)` と同じ経路です。サーバー契約が要求するときだけ pack を追加します。endpoint path は base URL のパスに追加され、`?` や `#` は含められません。query は encoder を通します。HTTPS とログの秘匿化を維持し、トークンや非公開の本文を記録しないでください。キャッシュは `no-store`、`Vary`、認証付き応答の保存許可に従います。`Expires` と `Last-Modified` の fallback は無制限保存を意味しません。

## エラーとリトライ

`request` と `upload` は `NetworkError` を送出します。キャンセル、HTTP ステータス、デコード、設定、信頼評価の失敗を区別してください。エラー例はまだ終了していない client で独立に実行します。GET/HEAD/OPTIONS/TRACE がデフォルトの再試行対象です。更新処理の再実行にはサーバーの冪等性保証が必要です。401 は調整された refresh を許可し得ますが、403 は自動 refresh・replay の許可ではありません。

```swift
do {
    let user = try await client.request(GetUser(id: 42))
    print(user.name)
} catch {
    switch error {
    case .cancelled:
        print("Cancelled")
    case .statusCode(let response):
        print(response.statusCode)
    default:
        print(error)
    }
}
```

## 操作の所有権と終了

操作例はリクエスト例とは別に実行します。`value()` は応答 payload を保持しない値分類 `NetworkFailure` を送出します。`value()` を待つ task のキャンセルは operation に転送されます。明示的キャンセルには handle を保持してください。`cancel()` は所有者が処理を不要としたときの API で、完了後に呼んでも結果は取り消しません。イベントは bounded な開始・終端を保持し、結果は `value()` から取得します。イベント iterator の破棄だけで全処理がキャンセルされるとは限りません。

```swift
let operations = OperationNetworkClient(client: client)
let operation = operations.start(GetUser(id: 42))
do {
    let user = try await operation.value()
    print(user.name)
} catch {
    print(error) // NetworkFailure
}
// Owner: call operation.cancel() when in-flight work is no longer needed.
await client.shutdown()
```

`cancelAll()` は処理中の作業をキャンセルし、client は再利用できます。`shutdown()` は冪等で終端的です。作業と refresh をキャンセルし、自分が所有する session のみ無効化して、以後の要求を `.cancelled` で拒否します。注入した session は呼び出し側の所有です。Download/Upload/WebSocket manager は機能の寿命に合わせて保持し、固有の background session ID と復元 barrier を使ってください。WebSocket の明示的 retry は新しい論理 task と stream を返します。operation ごとの自動冪等キーは新しい operation 間では維持されません。

## 移行

5.x からは [6.0 移行](docs/Migration-6.0.0.md)、続いて [6.1 encoded request](docs/Migration-EncodedRequests.md) を適用します。`InnoNetworkNext` を削除し `InnoNetwork` を import します。HLS の SwiftPM package 所有者を `InnoNetwork-Stream` に変更し、HLS import 名は維持します。JSON マクロは変わらず、binary codec は公開 `EncodedRequest` 境界を使います。6.1.0 から 6.1.1 に追加のソース移行はありません。旧 major のガイドは歴史的契約です。

## 検証とドキュメント

例はソースとの照合と静的検査の対象です。Swift ビルド、DocC レンダリング、実機試験、母語話者による校閲を実施したという意味ではありません。対応する Apple 環境で以下を実行し、実サービス、復元、認証、キャンセルはアプリで別途検証してください。スキルの exact 6.1.0 テスト記録は後続の全パッチを検証した証拠ではありません。

```bash
swift test
bash Scripts/check_docs_contract_sync.sh
swift build --target InnoNetworkDocSmoke
```

[API Stability](API_STABILITY.md) · [Examples](Examples/README.md) · [DocC](https://innosquadcorp.github.io/InnoNetwork/)

[Task ownership](docs/TaskOwnership.md) · [WebSocket lifecycle](docs/WebSocketLifecycle.md) · [Policy interactions](docs/PolicyInteractions.md)

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Support](SUPPORT.md) · [Release policy](docs/RELEASE_POLICY.md) · [Agent skill](skills/README.md) · [MIT License](LICENSE)

[旧韓国語 README（歴史資料）](docs/ko/README.md)
