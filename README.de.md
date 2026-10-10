# InnoNetwork — Deutsch

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

InnoNetwork ist eine typsichere asynchrone Swift-Netzwerkbibliothek für Apple-Plattformen. Beginne mit einer expliziten Endpoint-Struktur, `@APIDefinition` und `DefaultNetworkClient.request`. Optionale Produkte müssen nicht vorsorglich eingebunden werden.

## Version und Umfang

Die aktuelle stabile Version ist **6.1.1**, veröffentlicht am 2026-10-07 UTC. Dieser Patch korrigiert Dokumentation und Werkzeuge, ohne Laufzeit oder öffentliche API von 6.1.0 zu ändern. Der Tag verweist auf `44e4ca28c50c03f817231a077c0f3bdfdbc859c8`. Alle sieben aktuellen Sprachfassungen behandeln Installation, Beispiele und Verträge; das [englische README](README.md) enthält die ausführliche Referenz.

[6.1.1 Release](https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.1) · [Release notes](docs/releases/6.1.1.md)

## Voraussetzungen und Installation

Erforderlich sind Swift **6.2+** und Swift-6-Sprachmodus. Mindestversionen: iOS **16**, macOS **14**, tvOS **16**, watchOS **9**, visionOS **1**. Nur Apple; Linux wird nicht unterstützt. Die folgenden Deklarationen gehören jeweils in die Paket- und Target-Abhängigkeiten.

```swift
// Package.swift — dependencies
.package(
    url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
    .upToNextMinor(from: "6.1.1")
)

// Package.swift — target dependencies
.product(name: "InnoNetwork", package: "InnoNetwork")
```

Für reproduzierbare Auflösung verwende `.exact("6.1.1")`. Der Patchbereich übernimmt keine Änderungen vorläufig stabiler APIs aus einem neuen Minor automatisch. Prüfe `Package.resolved`. Ohne Makros ergänzt du `traits: []` an der Paketabhängigkeit und implementierst das Protokoll manuell. Alle Abhängigkeitspfade müssen `Macros` deaktivieren; SwiftPM kann Manifest-Abhängigkeiten wie SwiftSyntax trotzdem auflösen oder herunterladen.

## Produkte auswählen

- `InnoNetwork` — Typsichere HTTP-Anfragen und Richtlinien-Pipeline

- `InnoNetworkAuthAWS` — Optionaler AWS-SigV4-Einzelsignierer; kein Ersatz für das AWS SDK

- `InnoNetworkDownload` — Downloads, Pause/Fortsetzung, Hintergrundwiederherstellung und Ereignisse

- `InnoNetworkUpload` — Dateibasierte Uploads, Fortschritt, Wiederherstellung und begrenzte Antworten

- `InnoNetworkWebSocket` — Bidirektionale Verbindungen, Heartbeat, Wiederverbindung und Abschlussklassifikation

- `InnoNetworkPersistentCache` — RFC-bewusster Festplatten-Cache mit Speichergrenzen

- `InnoNetworkOpenAPI` — Adapter für die vollständige Pipeline oder schlanker OpenAPI-Runtime-Transport

- `InnoNetworkTrust` — Optionaler Evaluator für Public-Key-Pinning

- `InnoNetworkTestSupport` — Hilfen für Consumer-Tests; nicht in Produktion einbinden

`InnoNetworkMacroSupport` gehört nur auf den Compiler-Host. HLS liegt in [InnoNetwork-Stream](https://github.com/InnoSquadCorp/InnoNetwork-Stream), Protobuf in [InnoNetwork-Protobuf](https://github.com/InnoSquadCorp/InnoNetwork-Protobuf). Beide 6.1.1-Releases binden Core exakt an 6.1.1. Stream-Module heißen weiterhin `InnoNetworkHLS`, `InnoNetworkHLSLive`, `InnoNetworkHLSAVFoundation` und `InnoNetworkHLSAudio`; ein Modul `InnoNetworkStream` existiert nicht. Audio ist durch Swift-6.4-Compilerbedingungen und OS-27-Verfügbarkeit begrenzt. Das bevorzugte Protobuf-Produkt heißt `InnoNetwork-Protobuf`, der Import `InnoNetworkProtobuf`.

## Erste Anfrage

Der Beispielserver ist ein Platzhalter. Ersetze URL und Antwortmodell und führe den Code in einem async-Kontext aus. Die Struktur definiert Eingaben und `APIResponse`; das Makro erzeugt wiederkehrende Konformität. Wähle ausdrücklich `.anonymous`, `.optional` oder `.required`. GET/HEAD leiten `query`, POST/PUT/PATCH/DELETE `body` ab. Andere Methoden oder eigene Payloads benötigen den vollständigen Vertrag `Parameter`/`parameters`.

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

## Konfiguration, Authentifizierung und Sicherheit

`DefaultNetworkClient(baseURL:)` entspricht `NetworkConfiguration.safeDefaults(baseURL:)`. Ergänze Packs nur, wenn der Serververtrag sie verlangt. Der Endpoint-Pfad wird an den Basispfad angehängt und darf weder `?` noch `#` enthalten; Query-Werte laufen durch den Encoder. Behalte HTTPS und Log-Redaktion bei; protokolliere keine Tokens oder privaten Bodies. Der Cache beachtet `no-store`, `Vary` und Speichererlaubnis für authentifizierte Antworten. `Expires`- und `Last-Modified`-Fallbacks bedeuten keine unbegrenzte Speicherung.

## Fehler und Wiederholungen

`request` und `upload` werfen `NetworkError`. Unterscheide Abbruch, HTTP-Status, Dekodierung, Konfiguration und Vertrauensprüfung. Das Fehlerbeispiel läuft separat mit einem noch offenen Client. GET/HEAD/OPTIONS/TRACE sind standardmäßig für Retry zugelassen; Änderungen dürfen nur mit serverseitiger Idempotenz wiederholt werden. 401 kann koordinierte Token-Erneuerung erlauben; 403 erlaubt weder automatisches Refresh noch Replay.

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

## Besitz und Beenden von Operationen

Das Operationsbeispiel wird getrennt vom Anfragebeispiel ausgeführt. `value()` wirft `NetworkFailure`, eine Klassifikation ohne gespeicherte Antwort-Payload. Wird die auf `value()` wartende Task abgebrochen, wird dies an die Operation weitergegeben. Behalte das Handle für expliziten Abbruch. `cancel()` zeigt die API für nicht mehr benötigte Arbeit; nach Abschluss macht sie das Ergebnis nicht rückgängig. Ereignisse speichern einen begrenzten Start-/Endzyklus; das Ergebnis kommt aus `value()`. Das Verwerfen eines Event-Iterators ist keine allgemeine Abbruch-API.

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

`cancelAll()` bricht laufende Arbeit ab; der Client bleibt nutzbar. `shutdown()` ist idempotent und endgültig: Arbeit und Refresh werden abgebrochen, nur eigene Sessions invalidiert, neue Anfragen mit `.cancelled` abgewiesen. Injizierte Sessions bleiben im Besitz des Aufrufers. Halte Download/Upload/WebSocket-Manager für die Funktionsdauer; verwende eindeutige Hintergrund-Session-IDs und die Wiederherstellungsbarriere. Explizites WebSocket-Retry liefert eine neue logische Task samt Stream. Ein automatisch erzeugter Schlüssel pro Operation bleibt über neue Operationen hinweg nicht gleich.

## Migration

Von 5.x aus zuerst [6.0-Migration](docs/Migration-6.0.0.md), danach [Encoded Requests in 6.1](docs/Migration-EncodedRequests.md). Entferne `InnoNetworkNext` und importiere `InnoNetwork`. Ändere den SwiftPM-Paketbesitzer der HLS-Produkte zu `InnoNetwork-Stream`, behalte die HLS-Imports. Das JSON-Makro bleibt unverändert; Binärcodecs verwenden das öffentliche `EncodedRequest`. Von 6.1.0 zu 6.1.1 ist keine Quellmigration nötig. Ältere Major-Anleitungen dokumentieren historische Verträge.

## Validierung und Dokumentation

Die Beispiele werden mit dem Quellcode und statisch abgeglichen. Das behauptet weder Swift-Kompilierung noch DocC-Rendering, Gerätetests oder muttersprachliche Prüfung. Führe die folgenden Prüfungen in einer unterstützten Apple-Umgebung aus; reale Dienste, Wiederherstellung, Authentifizierung und Abbruch brauchen eigene Anwendungstests. Der Skill-Testnachweis für exakt 6.1.0 belegt nicht jeden späteren Patch.

```bash
swift test
bash Scripts/check_docs_contract_sync.sh
swift build --target InnoNetworkDocSmoke
```

[API Stability](API_STABILITY.md) · [Examples](Examples/README.md) · [DocC](https://innosquadcorp.github.io/InnoNetwork/)

[Task ownership](docs/TaskOwnership.md) · [WebSocket lifecycle](docs/WebSocketLifecycle.md) · [Policy interactions](docs/PolicyInteractions.md)

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Support](SUPPORT.md) · [Release policy](docs/RELEASE_POLICY.md) · [Agent skill](skills/README.md) · [MIT License](LICENSE)

[Früheres koreanisches README (historisch)](docs/ko/README.md)
