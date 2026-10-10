# InnoNetwork — 简体中文

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

InnoNetwork 是面向 Apple 平台的类型安全异步 Swift 网络库。从显式 endpoint 结构体、`@APIDefinition` 和 `DefaultNetworkClient.request` 开始即可，无需预先链接所有可选产品。

## 当前版本与范围

当前稳定版本为 **6.1.1**，于 2026-10-07 UTC 发布。该补丁修正文档与工具，不改变 6.1.0 的运行时或公共 API。标签对应 `44e4ca28c50c03f817231a077c0f3bdfdbc859c8`。七种语言的当前指南覆盖相同的安装、示例和契约范围；[英文 README](README.md) 提供详细参考。

[6.1.1 Release](https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.1) · [Release notes](docs/releases/6.1.1.md)

## 要求与安装

要求 Swift **6.2+** 和 Swift 6 语言模式。最低系统版本：iOS **16**、macOS **14**、tvOS **16**、watchOS **9**、visionOS **1**。仅支持 Apple，不支持 Linux。将以下声明分别放入包依赖与 target 依赖。

```swift
// Package.swift — dependencies
.package(
    url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
    .upToNextMinor(from: "6.1.1")
)

// Package.swift — target dependencies
.product(name: "InnoNetwork", package: "InnoNetwork")
```

需要可复现解析时使用 `.exact("6.1.1")`。补丁范围可避免自动采用下一 minor 中暂时稳定 API 的变化。检查 `Package.resolved` 的实际版本。如不使用宏，在包依赖上添加 `traits: []` 并手动实现协议。所有依赖路径都必须禁用 `Macros`；SwiftPM 仍可能解析或下载 SwiftSyntax 等 manifest 依赖。

## 选择产品

- `InnoNetwork` — 类型安全 HTTP 请求与策略流水线

- `InnoNetworkAuthAWS` — 可选 AWS SigV4 单次签名器，不替代 AWS SDK

- `InnoNetworkDownload` — 下载、暂停/恢复、后台恢复与事件

- `InnoNetworkUpload` — 文件上传、进度、恢复与有大小限制的响应

- `InnoNetworkWebSocket` — 双向连接、心跳、重连与关闭分类

- `InnoNetworkPersistentCache` — 遵循 RFC 相关规则的磁盘缓存与容量限制

- `InnoNetworkOpenAPI` — 完整 client 流水线适配器或轻量 OpenAPI Runtime transport

- `InnoNetworkTrust` — 可选公钥固定验证器

- `InnoNetworkTestSupport` — 消费者测试 helper，不应链接到生产 target

`InnoNetworkMacroSupport` 仅供编译器宿主使用。HLS 位于独立的 [InnoNetwork-Stream](https://github.com/InnoSquadCorp/InnoNetwork-Stream)，Protobuf 位于 [InnoNetwork-Protobuf](https://github.com/InnoSquadCorp/InnoNetwork-Protobuf)。两者的 6.1.1 均精确依赖 Core 6.1.1。Stream 模块仍名为 `InnoNetworkHLS`、`InnoNetworkHLSLive`、`InnoNetworkHLSAVFoundation`、`InnoNetworkHLSAudio`；不存在 `InnoNetworkStream` 模块。Audio 受 Swift 6.4 编译条件与 OS 27 可用性约束。Protobuf 首选 product 为 `InnoNetwork-Protobuf`，导入模块为 `InnoNetworkProtobuf`。

## 第一个请求

示例服务器仅用于说明，请替换为实际 URL 和响应模型，并在 async 上下文中运行。结构体定义输入和 `APIResponse`，宏生成重复的协议实现。必须显式选择 `.anonymous`、`.optional` 或 `.required`。GET/HEAD 推断存储的 `query`；POST/PUT/PATCH/DELETE 推断 `body`。其他方法或自定义 payload 需要完整的 `Parameter`/`parameters` 契约。

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

## 配置、认证与安全

`DefaultNetworkClient(baseURL:)` 等价于 `NetworkConfiguration.safeDefaults(baseURL:)`。仅在服务器契约需要时添加配置 pack。endpoint path 附加到 base URL 路径之后，不得包含 `?` 或 `#`；查询参数通过 encoder 处理。保留 HTTPS 和日志脱敏，不记录令牌或隐私正文。缓存遵守 `no-store`、`Vary` 和认证响应的存储许可；`Expires`、`Last-Modified` 回退不代表可以无限缓存所有内容。

## 错误与重试

`request` 和 `upload` 抛出 `NetworkError`。区分取消、HTTP 状态、解码、配置和信任验证失败。错误示例需独立运行，使用尚未关闭的 client。默认可重试方法为 GET/HEAD/OPTIONS/TRACE；重复修改操作需要服务器提供幂等保证。401 可能允许协调的令牌刷新，403 不授权自动刷新或重放。

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

## 操作所有权与关闭

操作示例与请求示例分开运行。`value()` 抛出不保留响应 payload 的值类型 `NetworkFailure`。取消等待 `value()` 的 task 会将取消转发给 operation。需要显式取消时应保存 handle。示例的 `cancel()` 是所有者不再需要任务时使用的 API；完成后调用不会撤销结果。事件保留有界的开始/终止生命周期，结果应通过 `value()` 获取。丢弃事件迭代器不是通用取消方式。

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

`cancelAll()` 取消进行中的工作，client 仍可复用。`shutdown()` 是幂等且终结性的：取消工作与刷新，只使自己拥有的 session 失效，后续请求以 `.cancelled` 失败。注入的 session 仍由调用方管理。Download/Upload/WebSocket manager 应覆盖功能的整个生命周期；后台 session 使用唯一 ID 并遵守恢复屏障。WebSocket 显式 retry 返回新的逻辑 task 及其事件 stream。按 operation 自动生成的幂等键不会跨新 operation 保持一致。

## 迁移

从 5.x 升级时，先应用 [6.0 迁移](docs/Migration-6.0.0.md)，再应用 [6.1 encoded request](docs/Migration-EncodedRequests.md)。移除 `InnoNetworkNext`，改为导入 `InnoNetwork`。HLS 产品的 SwiftPM package 所有者改为 `InnoNetwork-Stream`，HLS import 名称保持不变。JSON 宏不变；二进制 codec 使用公共 `EncodedRequest` 边界。6.1.0 到 6.1.1 没有新增源码迁移。旧 major 指南描述历史契约。

## 验证与文档

这些示例经过源码对照与静态检查；这不表示已运行 Swift 编译、DocC 渲染、真实设备测试或母语审校。请在受支持的 Apple 环境中执行以下检查，并单独验证真实服务、后台恢复、认证和取消行为。技能包中精确针对 6.1.0 的测试记录不能证明所有后续补丁均已验证。

```bash
swift test
bash Scripts/check_docs_contract_sync.sh
swift build --target InnoNetworkDocSmoke
```

[API Stability](API_STABILITY.md) · [Examples](Examples/README.md) · [DocC](https://innosquadcorp.github.io/InnoNetwork/)

[Task ownership](docs/TaskOwnership.md) · [WebSocket lifecycle](docs/WebSocketLifecycle.md) · [Policy interactions](docs/PolicyInteractions.md)

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Support](SUPPORT.md) · [Release policy](docs/RELEASE_POLICY.md) · [Agent skill](skills/README.md) · [MIT License](LICENSE)

[旧版韩语 README（历史资料）](docs/ko/README.md)
