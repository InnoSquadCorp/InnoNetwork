# InnoNetwork — Русский

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

InnoNetwork — типобезопасная асинхронная сетевая библиотека Swift для платформ Apple. Начните с явной структуры endpoint, `@APIDefinition` и `DefaultNetworkClient.request`. Подключать все дополнительные продукты заранее не нужно.

## Версия и область применения

Текущая стабильная версия — **6.1.1**, опубликована 2026-10-07 UTC. Патч исправляет документацию и инструменты без изменений runtime и публичного API относительно 6.1.0. Тег указывает на `44e4ca28c50c03f817231a077c0f3bdfdbc859c8`. Семь актуальных руководств охватывают одинаковые установку, примеры и контракты; подробности приведены в [английском README](README.md).

[6.1.1 Release](https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.1) · [Release notes](docs/releases/6.1.1.md)

## Требования и установка

Требуются Swift **6.2+** и языковой режим Swift 6. Минимумы: iOS **16**, macOS **14**, tvOS **16**, watchOS **9**, visionOS **1**. Только Apple; Linux не поддерживается. Добавьте объявления ниже соответственно в зависимости пакета и target.

```swift
// Package.swift — dependencies
.package(
    url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
    .upToNextMinor(from: "6.1.1")
)

// Package.swift — target dependencies
.product(name: "InnoNetwork", package: "InnoNetwork")
```

Для воспроизводимости используйте `.exact("6.1.1")`. Диапазон патчей не принимает автоматически изменения Provisionally Stable API из следующего minor. Проверьте `Package.resolved`. Чтобы отказаться от макросов, добавьте `traits: []` к зависимости пакета и реализуйте протокол вручную. Все пути графа должны отключать `Macros`; SwiftPM всё ещё может разрешать или скачивать зависимости манифеста, например SwiftSyntax.

## Выбор продуктов

- `InnoNetwork` — Типизированные HTTP-запросы и конвейер политик

- `InnoNetworkAuthAWS` — Опциональная однократная подпись AWS SigV4; не замена AWS SDK

- `InnoNetworkDownload` — Загрузки, пауза/возобновление, фоновое восстановление и события

- `InnoNetworkUpload` — Отправка файлов, прогресс, восстановление и ограниченные ответы

- `InnoNetworkWebSocket` — Двунаправленные соединения, heartbeat, переподключение и классификация закрытия

- `InnoNetworkPersistentCache` — Дисковый кеш с правилами RFC и ограничениями хранения

- `InnoNetworkOpenAPI` — Адаптер полного конвейера или тонкий транспорт OpenAPI Runtime

- `InnoNetworkTrust` — Опциональная проверка закреплённых публичных ключей

- `InnoNetworkTestSupport` — Вспомогательные средства тестов потребителя; не подключать в production

`InnoNetworkMacroSupport` предназначен только для хоста компилятора. HLS находится в [InnoNetwork-Stream](https://github.com/InnoSquadCorp/InnoNetwork-Stream), Protobuf — в [InnoNetwork-Protobuf](https://github.com/InnoSquadCorp/InnoNetwork-Protobuf). Их версии 6.1.1 точно фиксируют Core 6.1.1. Модули Stream по-прежнему называются `InnoNetworkHLS`, `InnoNetworkHLSLive`, `InnoNetworkHLSAVFoundation`, `InnoNetworkHLSAudio`; модуля `InnoNetworkStream` нет. Audio ограничен условиями компиляции Swift 6.4 и доступностью OS 27. Предпочтительный продукт Protobuf — `InnoNetwork-Protobuf`, импортируемый модуль — `InnoNetworkProtobuf`.

## Первый запрос

Сервер приведён для иллюстрации: замените URL и модель ответа и выполняйте код в async-контексте. Структура определяет входные данные и `APIResponse`, макрос генерирует повторяющуюся реализацию протокола. Явно выбирайте `.anonymous`, `.optional` или `.required`. GET/HEAD выводят `query`, POST/PUT/PATCH/DELETE — `body`. Остальные методы и собственные payload требуют полного контракта `Parameter`/`parameters`.

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

## Настройка, аутентификация и безопасность

`DefaultNetworkClient(baseURL:)` соответствует `NetworkConfiguration.safeDefaults(baseURL:)`. Добавляйте packs только по требованиям сервера. Путь endpoint добавляется к пути base URL и не должен содержать `?` или `#`; query проходит через encoder. Сохраняйте HTTPS и скрытие секретов в логах, не записывайте токены и приватные тела. Кеш учитывает `no-store`, `Vary` и разрешение хранения аутентифицированных ответов. Fallback по `Expires` и `Last-Modified` не означает неограниченное хранение любых данных.

## Ошибки и повторы

`request` и `upload` выбрасывают `NetworkError`. Различайте отмену, HTTP-статус, декодирование, конфигурацию и проверку доверия. Пример ошибок запускается отдельно с ещё открытым клиентом. По умолчанию для повторов допустимы GET/HEAD/OPTIONS/TRACE; повтор изменения требует идемпотентности на сервере. 401 может допускать координированное обновление токена; 403 не разрешает автоматический refresh или replay.

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

## Владение операциями и завершение

Пример операции запускается отдельно от примера запроса. `value()` выбрасывает `NetworkFailure`: классификацию без сохранения payload ответа. Отмена задачи, ожидающей `value()`, передаётся операции. Сохраняйте handle для явной отмены. `cancel()` показывает API владельца для больше не нужной работы; после завершения вызов не отменяет полученный результат. События сохраняют ограниченный цикл начала/завершения; результат получайте через `value()`. Отказ от итератора событий не является универсальной отменой.

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

`cancelAll()` отменяет текущую работу, сохраняя возможность повторного использования клиента. `shutdown()` идемпотентен и окончателен: отменяет работу и refresh, инвалидирует только собственные sessions и отклоняет новые запросы с `.cancelled`. Переданные sessions остаются ответственностью вызывающего кода. Сохраняйте Download/Upload/WebSocket managers на весь срок функции; используйте уникальные ID фоновых sessions и барьер восстановления. Явный retry WebSocket возвращает новую логическую задачу и её stream. Автоматический ключ на операцию не остаётся одинаковым между новыми операциями.

## Миграция

С 5.x сначала примените [миграцию 6.0](docs/Migration-6.0.0.md), затем [encoded requests 6.1](docs/Migration-EncodedRequests.md). Удалите `InnoNetworkNext` и импортируйте `InnoNetwork`. Измените владельца HLS-продуктов в SwiftPM на `InnoNetwork-Stream`, сохранив имена HLS imports. Макрос JSON не меняется; бинарные codecs используют публичный `EncodedRequest`. При переходе с 6.1.0 на 6.1.1 новая миграция исходников не нужна. Руководства прежних major описывают исторические контракты.

## Проверка и документация

Примеры сверяются с исходниками и статически проверяются. Это не означает выполненную компиляцию Swift, рендеринг DocC, тесты устройств или проверку носителями языка. Выполните команды ниже в поддерживаемой Apple-среде; реальные сервисы, восстановление, аутентификацию и отмену проверьте отдельно в приложении. Тестовая запись skill для exact 6.1.0 не доказывает проверку каждого следующего патча.

```bash
swift test
bash Scripts/check_docs_contract_sync.sh
swift build --target InnoNetworkDocSmoke
```

[API Stability](API_STABILITY.md) · [Examples](Examples/README.md) · [DocC](https://innosquadcorp.github.io/InnoNetwork/)

[Task ownership](docs/TaskOwnership.md) · [WebSocket lifecycle](docs/WebSocketLifecycle.md) · [Policy interactions](docs/PolicyInteractions.md)

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Support](SUPPORT.md) · [Release policy](docs/RELEASE_POLICY.md) · [Agent skill](skills/README.md) · [MIT License](LICENSE)

[Прежний корейский README (исторический)](docs/ko/README.md)
