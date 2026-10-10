# InnoNetwork — Español

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

InnoNetwork es una biblioteca Swift de redes asíncronas y tipadas para plataformas Apple. Empieza con una estructura de endpoint explícita, `@APIDefinition` y `DefaultNetworkClient.request`. No hace falta enlazar todos los productos opcionales.

## Versión y alcance

La versión estable actual es **6.1.1**, publicada el 2026-10-07 UTC. Corrige documentación y herramientas sin cambiar el runtime ni la API pública de 6.1.0. El tag apunta a `44e4ca28c50c03f817231a077c0f3bdfdbc859c8`. Las siete guías actuales comparten instalación, ejemplos y contratos; el [README inglés](README.md) amplía la referencia.

[6.1.1 Release](https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.1) · [Release notes](docs/releases/6.1.1.md)

## Requisitos e instalación

Requiere Swift **6.2+** con modo de lenguaje Swift 6. Mínimos: iOS **16**, macOS **14**, tvOS **16**, watchOS **9** y visionOS **1**. Solo Apple; Linux no está soportado. Añade estas declaraciones a las dependencias del paquete y del target, respectivamente.

```swift
// Package.swift — dependencies
.package(
    url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
    .upToNextMinor(from: "6.1.1")
)

// Package.swift — target dependencies
.product(name: "InnoNetwork", package: "InnoNetwork")
```

Usa `.exact("6.1.1")` para reproducibilidad. El rango de parches evita adoptar automáticamente cambios de APIs Provisionally Stable en otro minor. Comprueba `Package.resolved`. Para prescindir de macros, añade `traits: []` a la dependencia e implementa el protocolo manualmente. Todos los caminos del grafo deben desactivar el trait `Macros`; SwiftPM aún puede resolver o descargar dependencias del manifiesto como SwiftSyntax.

## Elegir productos

- `InnoNetwork` — Peticiones HTTP tipadas y pipeline de políticas

- `InnoNetworkAuthAWS` — Firmante AWS SigV4 de una sola petición; no sustituye al SDK de AWS

- `InnoNetworkDownload` — Descargas, pausa/reanudación, restauración en segundo plano y eventos

- `InnoNetworkUpload` — Subidas desde archivos, progreso, restauración y respuestas acotadas

- `InnoNetworkWebSocket` — Conexiones bidireccionales, heartbeat, reconexión y clasificación de cierre

- `InnoNetworkPersistentCache` — Caché en disco con reglas RFC y límites de almacenamiento

- `InnoNetworkOpenAPI` — Adaptador del pipeline completo o transporte ligero de OpenAPI Runtime

- `InnoNetworkTrust` — Evaluador opcional de pinning de claves públicas

- `InnoNetworkTestSupport` — Helpers para tests de consumidores; no enlazar en producción

`InnoNetworkMacroSupport` es solo para el host del compilador. HLS pertenece a [InnoNetwork-Stream](https://github.com/InnoSquadCorp/InnoNetwork-Stream) y Protobuf a [InnoNetwork-Protobuf](https://github.com/InnoSquadCorp/InnoNetwork-Protobuf). Sus versiones 6.1.1 fijan Core exactamente a 6.1.1. Los módulos de Stream siguen siendo `InnoNetworkHLS`, `InnoNetworkHLSLive`, `InnoNetworkHLSAVFoundation` e `InnoNetworkHLSAudio`; no existe un módulo `InnoNetworkStream`. Audio tiene condiciones de compilación Swift 6.4 y disponibilidad OS 27. El producto preferido de Protobuf es `InnoNetwork-Protobuf`; se importa `InnoNetworkProtobuf`.

## Primera petición

El servidor es ilustrativo: sustituye la URL y el modelo por los de tu servicio y ejecuta en un contexto async. La estructura mantiene las entradas y `APIResponse`; la macro genera la conformidad repetitiva. Declara explícitamente `.anonymous`, `.optional` o `.required`. GET/HEAD infieren `query`; POST/PUT/PATCH/DELETE infieren `body`. Otros métodos o payloads personalizados requieren el contrato completo `Parameter`/`parameters`.

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

## Configuración, autenticación y seguridad

`DefaultNetworkClient(baseURL:)` equivale a `NetworkConfiguration.safeDefaults(baseURL:)`. Añade packs solo cuando el contrato del servidor lo exija. El path se añade al de la URL base y no admite `?` ni `#`; la consulta pasa por el encoder. Conserva HTTPS y la redacción de logs; no registres tokens ni cuerpos privados. La caché respeta `no-store`, `Vary` y los permisos de almacenamiento de respuestas autenticadas. Los fallbacks `Expires` y `Last-Modified` no permiten almacenar todo indefinidamente.

## Errores y reintentos

`request` y `upload` lanzan `NetworkError`. Distingue cancelación, estado HTTP, decodificación, configuración y confianza. Ejecuta este ejemplo de errores de forma independiente con un cliente abierto. GET/HEAD/OPTIONS/TRACE son elegibles para reintento por defecto; repetir mutaciones requiere idempotencia del servidor. Un 401 puede permitir una renovación coordinada; 403 no autoriza renovación ni replay automáticos.

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

## Propiedad y cierre de operaciones

Ejecuta el ejemplo de operación por separado del ejemplo de petición. `value()` lanza `NetworkFailure`, una clasificación sin payload retenido. Cancelar la tarea que espera `value()` cancela la operación. Guarda el handle si necesitas cancelación explícita. `cancel()` muestra la API del propietario cuando ya no necesita el trabajo; llamarla tras completarse no deshace el resultado. Los eventos conservan un ciclo acotado de inicio/fin; obtén el resultado mediante `value()`. Abandonar un iterador de eventos no es una API universal de cancelación.

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

`cancelAll()` cancela el trabajo en curso y permite reutilizar el cliente. `shutdown()` es idempotente y terminal: cancela trabajo y refresh, invalida solo las sesiones propias y rechaza nuevas peticiones con `.cancelled`. Las sesiones inyectadas siguen siendo del llamador. Conserva los managers de Download/Upload/WebSocket durante la vida de la funcionalidad; usa identificadores únicos y la barrera de restauración para sesiones de fondo. El retry explícito de WebSocket devuelve una nueva tarea lógica con su stream. Una clave automática por operación no se conserva al crear otra operación.

## Migración

Desde 5.x, aplica [la migración 6.0](docs/Migration-6.0.0.md) y [las adiciones encoded de 6.1](docs/Migration-EncodedRequests.md). Elimina `InnoNetworkNext` e importa `InnoNetwork`. Cambia el propietario SwiftPM de HLS a `InnoNetwork-Stream` manteniendo los imports HLS. La macro JSON no cambia; los codecs binarios usan la frontera pública `EncodedRequest`. 6.1.1 no exige migración de código desde 6.1.0. Las guías de majors anteriores describen contratos históricos.

## Validación y documentación

Estos ejemplos se contrastan con el código y mediante comprobaciones estáticas. Esto no afirma compilación Swift, renderizado DocC, pruebas de dispositivo ni revisión por hablantes nativos. Ejecuta las comprobaciones siguientes en un entorno Apple compatible y valida por separado servicios reales, restauración, autenticación y cancelación. La evidencia del fixture del skill fijado a 6.1.0 no demuestra cada parche posterior.

```bash
swift test
bash Scripts/check_docs_contract_sync.sh
swift build --target InnoNetworkDocSmoke
```

[API Stability](API_STABILITY.md) · [Examples](Examples/README.md) · [DocC](https://innosquadcorp.github.io/InnoNetwork/)

[Task ownership](docs/TaskOwnership.md) · [WebSocket lifecycle](docs/WebSocketLifecycle.md) · [Policy interactions](docs/PolicyInteractions.md)

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Support](SUPPORT.md) · [Release policy](docs/RELEASE_POLICY.md) · [Agent skill](skills/README.md) · [MIT License](LICENSE)

[README coreano anterior (histórico)](docs/ko/README.md)
