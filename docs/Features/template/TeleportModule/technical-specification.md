---
document_type: technical-specification
status: approved
revision: 2
language: Russian
approved_at: 2026-08-03T18:40:06Z
source_prd_path: docs/Features/template/TeleportModule/product-requirements.md
source_prd_revision: 2
source_prd_sha256: d18ef9edd0cb97b348cc1c2e49b644025a161dd95dd733e4d4f4c64f95f91f77
---

# TeleportModule

## 1. Goal and Concept

`TeleportModule` — серверно-авторитетная граница телепортации внутри одного Roblox Experience. Она создаёт непрозрачный `sessionId` при внешнем входе, продолжает его только после проверенного прибытия из разрешённого плейса, передаёт его при инициированном модулем телепорте и публикует раздельные события попытки, принятия платформой, отказа, ухода и подтверждённого прибытия.

Источник продукта — `docs/Features/template/TeleportModule/product-requirements.md`, revision `2`, exact-byte SHA-256 `d18ef9edd0cb97b348cc1c2e49b644025a161dd95dd733e4d4f4c64f95f91f77`. Эта спецификация не расширяет продуктовый scope за пределы `PRD-REQ-001..025`, `PRD-NFR-001..009` и `PRD-AC-001..021`.

Главный инвариант: принятие `TeleportService:TeleportAsync()` и удаление игрока с исходного сервера не являются доказательством прибытия. Только обработка `Player:GetJoinData()` на целевом сервере создаёт событие подтверждённого прибытия.

## 2. Context and Scope Boundaries

Репозиторий является reusable Roblox template. Реализация обязана сохранить существующие архитектурные границы:

- один bootstrap и один явный manifest на каждой стороне;
- server runtime state и решение о продолжении сессии принадлежат `TeleportModule`;
- `PlayersModule` остаётся единственным владельцем прямых подписок на `Players.PlayerAdded` и `Players.PlayerRemoving`;
- `CommunicationServer` / `CommunicationClient` остаются единственной сетевой границей игровых уведомлений;
- `Shared/Util/Signal` используется только для событий внутри одного server/client runtime;
- `TeleportService:TeleportAsync()` вызывается только серверной реализацией;
- данные телепортации считаются видимыми клиенту и недоверенными и не дают прав на валюту, прогресс или защищённое состояние.

Внутри L0 находятся server orchestration, server session/attempt state, shared DTO/policy contract, client projection и отключённый по умолчанию operator validation harness. Вне L0 остаются Roblox `TeleportService`, проектные `PlayersModule`, communication transport, UI конкретной игры, retry-политика конкретной игры, сохранение прогресса, межсерверное общее состояние матча/группы и самостоятельная release-readiness тестового endpoint-плейса.

Платформенная база: новый код использует `TeleportService:TeleportAsync(placeId, players, teleportOptions)`, `TeleportOptions` и `TeleportService.TeleportInitFailed`; legacy `Teleport`, `TeleportPartyAsync`, `TeleportToPlaceInstance` и `TeleportToPrivateServer` не используются. Обычный Studio Play не доказывает реальный успешный телепорт; сквозной gate выполняется в опубликованном Experience через Roblox client.

## 3. Terminology and Glossary

| Термин | Определение |
|---|---|
| Игровая сессия | Непрерывная цепочка подтверждённых посещений серверов/плейсов одним игроком, коррелируемая `sessionId`. Не является сохранением или доказательством права. |
| Внешний вход | Вход без допустимого продолжения сессии из разрешённого `SourcePlaceId`; создаёт новый `sessionId`. |
| Внутреннее прибытие | Вход, у которого официальный `SourcePlaceId` разрешён, envelope корректен и содержит допустимый `sessionId` именно для прибывшего `UserId`. |
| Попытка телепорта | Серверная per-player запись с уникальным `attemptId`, созданная перед вызовом платформы. |
| Принятие | `TeleportAsync` вернулся без исключения. Это не успешное прибытие. |
| Поздний отказ | `TeleportInitFailed` сообщил, что конкретный игрок остался на исходном сервере после ранее принятого запроса. |
| Фактический уход | `PlayersModule` сообщил removal игрока с текущего сервера. Не подтверждает целевое прибытие. |
| Презентационное уведомление | Компактное сообщение о появлении/уходе другого игрока без `sessionId`, `attemptId` и деталей назначения. |
| Validation harness | Отключённый по умолчанию server-side операторский инструмент, который при полном совпадении opt-in конфигурации создаёт runtime-only pad для опубликованного E2E. Не является gameplay-механикой. |

## 4. System Decomposition

### 4.1. Level 0 — TeleportModule feature boundary

```text
TeleportModule (L0)
├── Server teleport lifecycle (L1)
│   ├── TeleportModule
│   ├── TeleportPolicy
│   └── TeleportInitializationCommand
├── Operator validation harness (L1)
│   ├── TeleportValidationConfig
│   ├── TeleportValidationPad
│   └── TeleportValidationPadInitializationCommand
├── Shared teleport contract (L1)
│   ├── TeleportTypes
│   └── TeleportProtocol
└── Client teleport projection (L1)
    ├── TeleportClient
    └── TeleportInitializationCommand

Outside L0: PlayersModule, CommunicationServer/Client, TeleportService,
HttpService, game-specific callers, presentation/UI and the published test endpoint scene.
```

### 4.2. Level 1 — Server teleport lifecycle

#### `ServerScriptService/Modules/Teleport/TeleportModule.luau`

Entity kind: server-authoritative module and public facade.

Constructor:

```luau
TeleportModule.new({
    TeleportService: any,
    HttpService: any,
    PlayersModule: any,
    Communication: any,
    Policy: TeleportPolicy,
}) -> TeleportModule
```

Public contract:

```luau
Initialize(self) -> ()
Stop(self) -> ()
GetSession(self, player: Player) -> SessionSnapshot?
GetAttempt(self, player: Player) -> AttemptSnapshot?
Teleport(self, players: { Player }, destination: TeleportDestination) -> TeleportRequestResult
```

Responsibilities:

- подписаться через `PlayersModule:ObservePlayers(onAdded, onRemoving)` и обработать уже присутствующих игроков;
- подписаться на `TeleportService.TeleportInitFailed` как на платформенный результат телепорта, не как на player lifecycle;
- создать или продолжить per-player `SessionRecord` при arrival;
- валидировать destination, список игроков, активное присутствие, уникальность и отсутствие active attempt до изменения состояния;
- создать один `attemptId` для группового запроса и отдельный `AttemptRecord` для каждого участника;
- создать новый `TeleportOptions`, записать только module-owned teleport envelope и ровно один совместимый destination selector;
- вызвать `TeleportAsync` за `pcall`, отдельно завершить каждого участника при синхронной ошибке и отдельно обработать per-player `TeleportInitFailed`;
- публиковать side-local server signals и компактные client messages;
- выполнять idempotent cleanup на removal и `Stop`.

Не владеет: прямыми `Players` subscriptions; automatic retry; UI; сохранением прогресса; подтверждением целевого прибытия на исходном сервере; произвольным caller-supplied `TeleportData`.

Owned side-local signals:

```luau
PlayerArrived       -- (player, ArrivalSnapshot)
AttemptStarted      -- (player, AttemptSnapshot)
AttemptAccepted     -- (player, AttemptSnapshot)
AttemptFailed       -- (player, AttemptSnapshot, FailureSnapshot)
PlayerDeparted      -- (player, DepartureSnapshot)
```

Каждый signal создаётся через общий `Signal`, listener выполняются неблокирующе, а `Stop` после per-player cleanup уничтожает signals. `Initialize` и `Stop` идемпотентны.

#### `ServerScriptService/Modules/Teleport/TeleportPolicy.luau`

Entity kind: explicit server policy value.

```luau
export type TeleportPolicy = {
    AllowedPlaceIds: { [number]: boolean },
    MaxGroupSize: number,
    MaxSessionIdLength: number,
    MaxAttemptIdLength: number,
}
```

Template policy включает текущий положительный `game.PlaceId`; каждый дополнительно разрешённый destination/source place указывается явно композицией проекта. Для неопубликованного local DataModel с `game.PlaceId=0` и `game.GameId=0` template composition создаёт пустую inert policy: lifecycle/projection инициализируются, но любой destination отклоняется до platform call. `MaxGroupSize` не превышает платформенный предел `50`. Policy валидируется и копируется при construction; внешняя мутация не меняет активную политику.

#### `ServerScriptService/Initialization/Commands/TeleportInitializationCommand.luau`

Entity kind: server manifest command.

```luau
Id = "Teleport"
DependsOn = { "Players", "Communication" }
Initialize(context) -> module:Initialize()
```

`ServerManifest` создаёт module с явными зависимостями, добавляет `Services.Teleport`, и размещает command после `Communication`, до потребителей, которым нужен teleport service. Новый standalone Script не создаётся.

#### Interaction at level 1 — server lifecycle

1. `PlayersModule` сообщает arrival/removal; `TeleportModule` меняет только собственные records.
2. Game-specific server code вызывает `Services.Teleport:Teleport(...)`.
3. `TeleportModule` подготавливает envelope и вызывает injected `TeleportService`.
4. Server local signals наблюдают доменные потребители; communication получает отдельные DTO для client projection.
5. `TeleportInitFailed` переводит только соответствующего игрока из active attempt в failed; остальные участники группы не меняются.

### 4.3. Level 1 — Operator validation harness

#### `ServerScriptService/Modules/Teleport/TeleportValidationConfig.luau`

Entity kind: server-only static opt-in configuration owned by project composition.

```luau
export type TeleportValidationConfig = {
    Enabled: boolean,
    GameId: number,
    RoutesBySourcePlaceId: { [number]: number },
    AuthorizedUserIds: { [number]: boolean },
}
```

Шаблон поставляет `Enabled=false`, `GameId=0` и пустые frozen maps. Производный проект меняет только этот конфигурационный артефакт, указывая собственные проверенные cloud identity и tester allowlist. Конфигурация статична на lifetime сервера, не реплицируется клиентам, не хранится в DataStore и не расширяет `TeleportPolicy` автоматически.

#### `ServerScriptService/Modules/Teleport/TeleportValidationPad.luau`

Entity kind: optional server runtime controller.

Constructor дополнительно получает `Config: TeleportValidationConfig`. Controller принимает только plain dictionary без metatable и ровно с полями `Enabled`, `GameId`, `RoutesBySourcePlaceId`, `AuthorizedUserIds`; затем проверяет `Enabled`, положительный точный `GameId`, положительные source/destination PlaceIds, отсутствие self-route, boolean-set allowlist и совпадение текущих `game.GameId`/`game.PlaceId`. Любая отсутствующая, дополнительная, неверная или не совпадающая часть делает controller неактивным: он не устанавливает player observer, не создаёт Part и не вызывает `TeleportModule`.

При валидном opt-in controller наблюдает игроков только через `PlayersModule`, сначала собирает полную initial enumeration без промежуточного создания pad, затем детерминированно выбирает наименьший присутствующий allowlisted UserId независимо от порядка доставки observer. Он создаёт один runtime-only pad только для этого tester, разрешает touch только его персонажу, вызывает публичный `Services.Teleport:Teleport` с настроенным `Public` destination и при изменении присутствия повторяет тот же выбор с idempotent cleanup. Он не создаёт remotes, не пишет session diagnostics и не изменяет `place.rbxl`.

#### `ServerScriptService/Initialization/Commands/TeleportValidationPadInitializationCommand.luau`

```luau
Id = "TeleportValidationPad"
DependsOn = { "Players", "Teleport" }
Initialize(context) -> controller:Initialize()
```

Command остаётся в server manifest, но default-disabled controller завершает initialization без observer и scene mutation. `ServerManifest` явно внедряет `TeleportValidationConfig`; controller не ищет конфигурацию через service locator или `Workspace`.

#### Interaction at level 1 — validation harness

1. Оператор записывает проверенные identity и tester allowlist в `TeleportValidationConfig`, затем явно устанавливает `Enabled=true`.
2. Controller независимо подтверждает текущие DataModel identity и только после этого подписывается через `PlayersModule`.
3. Touch allowlisted tester вызывает существующий `TeleportModule`; destination также обязан пройти отдельную `TeleportPolicy` проверку.
4. После E2E оператор возвращает `Enabled=false`, синхронизирует и публикует оба плейса; новый сервер не создаёт pad.

### 4.4. Level 1 — Shared teleport contract

#### `ReplicatedStorage/Shared/Teleport/TeleportTypes.luau`

Entity kind: side-neutral strict type contract; module возвращает `nil`, как существующие shared type modules.

```luau
export type EntryKind = "External" | "Teleported"
export type AttemptState = "Started" | "Accepted"

export type SessionSnapshot = {
    SessionId: string,
    EntryKind: EntryKind,
    SourcePlaceId: number?,
}

export type TeleportDestination =
    { Kind: "Public", PlaceId: number }
    | { Kind: "ServerInstance", PlaceId: number, ServerInstanceId: string }
    | { Kind: "ReservedServer", PlaceId: number, ReservedServerAccessCode: string }
    | { Kind: "NewReservedServer", PlaceId: number }

export type AttemptSnapshot = {
    AttemptId: string,
    State: AttemptState,
    DestinationKind: string,
    PlaceId: number,
}

export type TeleportRequestResult =
    { Ok: true, AttemptId: string }
    | { Ok: false, Code: string, Error: string, AttemptId: string? }
```

Snapshots возвращаются как fresh copies. Raw `TeleportOptions`, access code и server instance ID не публикуются в общих player appearance DTO.

#### `ReplicatedStorage/Shared/Teleport/TeleportProtocol.luau`

Entity kind: frozen message/request and envelope constants.

```luau
EnvelopeKey = "TeleportModule"
EnvelopeVersion = 1

RequestTypes.Bootstrap = "Teleport.Bootstrap"
MessageTypes.LocalAttemptStarted = "Teleport.LocalAttemptStarted"
MessageTypes.LocalAttemptAccepted = "Teleport.LocalAttemptAccepted"
MessageTypes.LocalAttemptFailed = "Teleport.LocalAttemptFailed"
MessageTypes.LocalArrived = "Teleport.LocalArrived"
MessageTypes.PlayerAppeared = "Teleport.PlayerAppeared"
MessageTypes.PlayerDeparted = "Teleport.PlayerDeparted"
```

Bootstrap request имеет `nil`/empty-dictionary input validator и возвращает только local session snapshot, current local attempt snapshot и safe appearance records текущих игроков.

### 4.5. Level 1 — Client teleport projection

#### `ReplicatedStorage/Client/Teleport/TeleportClient.luau`

Entity kind: client read-only state projection and presentation event facade.

Constructor:

```luau
TeleportClient.new({ Communication: any, PlayersModule: any }) -> TeleportClient
```

Public contract:

```luau
Initialize(self) -> ()
Stop(self) -> ()
GetLocalArrival(self) -> ClientArrivalSnapshot?
GetLocalAttempt(self) -> ClientAttemptSnapshot?
GetPresentPlayers(self) -> { [number]: PlayerAppearanceSnapshot }
```

Owned signals:

```luau
LocalArrived
LocalAttemptStarted
LocalAttemptAccepted
LocalAttemptFailed
PlayerAppeared
PlayerDeparted
```

Constructor до первого bootstrap request регистрирует все message handlers в `CommunicationClient`. `Initialize` выполняет bounded synchronous `CommunicationClient:Request("Teleport.Bootstrap", {})`, валидирует полный response, атомарно устанавливает initial projection и только затем считается готовым. После готовности сообщения применяются последовательно; invalid payload или невозможный transition вызывает ошибку handler, чтобы существующий communication recovery запустил resync, а не оставил ложное состояние.

Client не создаёт session ID, не инициирует server teleport, не вызывает `TeleportAsync`, не решает validity и не сообщает серверу результат. Отсутствие signal listeners не меняет обработку projection.

#### `ReplicatedStorage/Client/Initialization/Commands/TeleportInitializationCommand.luau`

```luau
Id = "Teleport"
DependsOn = { "Players", "Communication" }
Initialize(context) -> module:Initialize()
```

`ClientManifest` создаёт `TeleportClient`, добавляет `Services.Teleport`, и ставит command после `Communication`. Все handlers регистрируются при construction до bootstrap request.

#### Interaction at level 1 — client projection

- own lifecycle DTO меняют local arrival/attempt projection и затем fire соответствующий signal;
- appearance DTO меняют `presentPlayers` и fire presentation signal;
- duplicate terminal DTO не fire повторный terminal event;
- `PlayerDeparted` никогда не преобразуется в arrival другого сервера.

### 4.6. Interaction at level 0

Network boundary использует только `CommunicationServer:Queue`, `RegisterRequestHandler` и `CommunicationClient:RegisterHandler` / `Request`. Own lifecycle messages имеют priority `State`; appearance/departure других игроков — `Presentation`. Ни один новый `RemoteEvent` или `RemoteFunction` не создаётся.

## 5. Data Models

### 5.0. Server-only validation configuration

- `Enabled` — обязательный boolean; default `false`.
- `GameId` — при `Enabled=true` finite positive integer, точно совпадающий с текущим `game.GameId`.
- `RoutesBySourcePlaceId` — frozen dictionary `source PlaceId -> destination PlaceId`; обе стороны round trip задаются отдельными направленными entries, каждый ID finite positive integer, self-route запрещён.
- `AuthorizedUserIds` — frozen boolean-set положительных integer UserIds; только значение `true` авторизует tester.

Пустые maps и `GameId=0` допустимы только при `Enabled=false`. Controller копирует/проверяет наблюдаемую конфигурацию или завершает работу fail-closed; внешняя мутация после construction не меняет активный контракт.

### 5.1. Server-owned `SessionRecord`

```luau
{
    SessionId: string,          -- canonical GUID, ровно 36 ASCII chars
    EntryKind: "External" | "Teleported",
    SourcePlaceId: number?,     -- только официальный joinData.SourcePlaceId
}
```

Ключ — `Player`; lifetime — присутствие игрока на сервере. Record не сохраняется в DataStore и удаляется на removal/Stop.

### 5.2. Server-owned `AttemptRecord`

```luau
{
    AttemptId: string,
    State: "Started" | "Accepted",
    Destination: TeleportDestination,
    TerminalPublished: boolean,
}
```

Один player имеет не более одной active attempt. Групповой вызов использует общий `AttemptId`, но хранит отдельную запись и terminal transition для каждого player.

### 5.3. Teleport envelope

```luau
{
    TeleportModule = {
        Version = 1,
        SourcePlaceId = game.PlaceId,
        AttemptId = attemptId,
        SessionsByUserId = {
            [tostring(player.UserId)] = sessionId,
        },
    },
}
```

Envelope содержит только текущих участников вызова. Перед изменением arrival state server проверяет:

1. `joinData` — table, `joinData.SourcePlaceId` — finite positive integer и присутствует в `Policy.AllowedPlaceIds`;
2. `TeleportData`, `TeleportModule`, `SessionsByUserId` — string-key dictionaries без metatable/cycle/extra unsupported shape;
3. `Version == 1`, envelope `SourcePlaceId == joinData.SourcePlaceId` и
   `AttemptId` является canonical GUID;
4. для `tostring(player.UserId)` существует ровно один canonical session GUID;
5. depth, node count, string lengths и количество session entries bounded `MaxGroupSize`.

Любой отказ полностью отклоняет continuation для этого игрока и создаёт новый session; частично валидный envelope не переносит чужой ID. Данные не используются как authority за пределами correlation.

### 5.4. Client-safe DTO

- own arrival: `SessionId`, `EntryKind`, optional `SourcePlaceId`;
- own attempt: `AttemptId`, state, destination kind и `PlaceId`, а failure дополнительно имеет bounded `Code` и bounded sanitized `Error`;
- other appearance: `UserId`, `EntryKind`, optional `SourcePlaceId`;
- other departure: `UserId`.

Other-player DTO не содержат `SessionId`, `AttemptId`, reserved access code, server instance ID или failure details.

## 6. System Diagram

```mermaid
sequenceDiagram
    participant Caller as Server gameplay caller
    participant TM as TeleportModule
    participant PM as PlayersModule
    participant CS as CommunicationServer
    participant TS as Roblox TeleportService
    participant Target as Target TeleportModule
    participant Client as TeleportClient

    Caller->>TM: Teleport(players, destination)
    TM->>TM: validate all; create per-player attempts
    TM->>CS: LocalAttemptStarted DTO per player
    TM->>TS: TeleportAsync(placeId, players, options)
    alt synchronous exception
        TS--xTM: throw
        TM->>CS: LocalAttemptFailed DTO per player
    else request returned
        TS-->>TM: TeleportAsyncResult
        TM->>CS: LocalAttemptAccepted DTO per player
        alt late per-player failure
            TS-->>TM: TeleportInitFailed(player, ...)
            TM->>CS: LocalAttemptFailed DTO for that player
        else player leaves source
            PM-->>TM: removing(player)
            TM->>CS: PlayerDeparted presentation
            Target->>Target: validate Player:GetJoinData()
            Target->>Client: LocalArrived / PlayerAppeared DTO
        end
    end
```

## 7. User / Core / Behaviour Flows

### 7.1. Arrival

1. `PlayersModule:ObservePlayers` delivers a present player.
2. Server reads `player:GetJoinData()` inside `pcall`.
3. Valid continuation creates `SessionRecord(EntryKind="Teleported")`; missing/throwing/invalid/untrusted input creates a new GUID and `EntryKind="External"`.
4. Server fires exactly one `PlayerArrived` and publishes own `LocalArrived` plus safe `PlayerAppeared` to other clients.
5. Bootstrap request lets a late client obtain the same current state without relying on an already-fired event.

### 7.2. Valid teleport request

1. Validate destination discriminant and allowed `PlaceId`; reject empty, sparse, duplicate, non-Player, absent, over-50, missing-session or active-attempt inputs without platform call.
2. Allocate GUID `attemptId`; install all per-player Started records atomically.
3. Fire/queue Started separately for each player.
4. Build new `TeleportOptions`: set exactly one of no selector, `ServerInstanceId`, `ReservedServerAccessCode`, or `ShouldReserveServer=true`; set module envelope.
5. Execute one protected `TeleportAsync` call.
6. On return, transition every still-started participant to Accepted and publish Accepted. Returned reserved-server information may be included only in server return metadata when needed; it is never presentation data.

### 7.3. Synchronous failure

1. `pcall` fails before platform acceptance.
2. Each participant whose record still matches `attemptId` receives one Failed terminal event.
3. Active attempt is removed; `SessionRecord` and ordinary presence remain.
4. No departure/arrival event is emitted.

### 7.4. Late or partial failure

1. `TeleportInitFailed` is matched by player and current active attempt.
2. Unknown/stale/duplicate failure is ignored with bounded diagnostic and cannot terminate a newer attempt.
3. Matching player receives one Failed terminal event and its attempt is cleared.
4. Other group participants retain their own state.

### 7.5. Removal and shutdown

1. First removal publishes one source-server departure containing whether an attempt existed, but never a target success.
2. Attempt/session records are cleared even if notification queueing fails.
3. Repeated removal/Stop cleanup is a no-op.
4. `Stop` disconnects observer and `TeleportInitFailed`, cleans all players, then destroys signals; no listener is awaited.

### 7.6. Published validation workflow

1. Оператор создаёт или выбирает два опубликованных плейса одного тестового Experience и считывает фактические nonzero `game.GameId`/`game.PlaceId` из каждой точной Studio-сессии.
2. Каждый owning repository записывает собственные top-level `placeId`/`gameId`, точный `servePlaceIds` и требуемый owning ADR до cloud-dependent Play/Publish.
3. Основной проект конфигурирует `TeleportPolicy` для обоих PlaceIds; оба test endpoints получают идентичный Teleport source revision.
4. В `TeleportValidationConfig` задаются `Enabled=true`, exact GameId, две обратные routes и минимальный tester allowlist. Любая inherited identity из другого проекта запрещена.
5. После Rojo preflight, sync и обычного Publish оператор запускает свежий Roblox client, подтверждает подпись destination, переход A→B, B→A и несколько быстрых round trips без session-lock kick; server/client output проверяется на in-scope errors.
6. Оператор возвращает `Enabled=false`, повторно синхронизирует и публикует оба endpoint и в новом сервере подтверждает отсутствие runtime pad. Второй проект остаётся test endpoint и не становится release-readiness объектом основного шаблона.

## 8. Implementation Constraints

### 8.1. Normative constraints

- Все production Luau modules сохраняют `--!strict`.
- GUID generation is injected through `HttpService` and faked deterministically in tests.
- Platform service, options factory/Instance creation, player lifecycle, communication and GUID source are injectable; deterministic suites не вызывают реальную сеть.
- Validate the whole group before installing any attempt. Validation failure cannot leave a subset active.
- `TeleportAsync` group size is `1..min(Policy.MaxGroupSize, 50)`.
- Destination selectors are mutually exclusive and strings are non-empty, bounded and free of control characters.
- Caller cannot append or replace module envelope with arbitrary teleport data.
- Queue failure does not roll back authoritative session/attempt transition, but is logged with bounded diagnostics; communication resync/bootstrap restores projection.
- Client payload validation uses expected prior attempt state; impossible order triggers communication recovery.
- No full provider/profile snapshot is introduced; TeleportModule is not a save provider.
- No direct gameplay remotes, `_G`, service locator, new bootstrap, standalone Script or LocalScript.
- Validation harness MUST be disabled by default, configured only through `TeleportValidationConfig`, and fail closed before player observation or scene mutation when any enablement/identity/route/tester field is invalid or mismatched.
- `TeleportValidationConfig` MUST NOT expand `TeleportPolicy`; both the operator harness route and the module destination policy must independently allow the transition.
- The repository operator guide MUST cover template and derived-project setup, exact Studio identity selection, Rojo sync, ordinary Publish, forward/return/rapid E2E, expected evidence, teardown to `Enabled=false`, and the test-only status of the secondary endpoint.
- `docs/TestCoverage.md` must gain a Teleport lifecycle row and name its focused suite.
- Эта новая durable cross-module decision требует нового template ADR (следующий свободный ID) с enforcement paths for rules/docs/code/tests; существующие Accepted ADR не переписываются.

### 8.2. PRD traceability

| Техническая область | PRD IDs |
|---|---|
| session creation/continuation/envelope validation | `PRD-REQ-001..007`, `PRD-NFR-001..002` |
| arrival/attempt/accept/failure/departure state machine | `PRD-REQ-008..015`, `PRD-REQ-017`, `PRD-NFR-003..006` |
| client own lifecycle and initial state | `PRD-REQ-016`, `PRD-NFR-008` |
| PlayersModule boundary | `PRD-REQ-018` |
| safe common presentation and project communication | `PRD-REQ-019..022` |
| deterministic and published verification | `PRD-NFR-007` |
| disabled-by-default validation harness and operator workflow | `PRD-REQ-023..025`, `PRD-NFR-009` |

### 8.3. Acceptance and verification matrix

| PRD AC | Обязательное доказательство |
|---|---|
| `PRD-AC-001` | focused deterministic test: missing join data -> one External arrival and non-empty GUID |
| `PRD-AC-002` | published two-place Roblox-client E2E: same GUID and Teleported classification at target |
| `PRD-AC-003` | table tests for nil/type/oversize/version/source/user-key/GUID failures -> new session |
| `PRD-AC-004` | injected throwing `TeleportAsync`: Failed only; same session/presence |
| `PRD-AC-005` | injected `TeleportInitFailed` after Accepted: attempt cleared and client terminal failure |
| `PRD-AC-006` | deterministic assertion: Accepted/removal never fires target arrival |
| `PRD-AC-007` | PlayersModule removal: one departure, cleanup, no arrival |
| `PRD-AC-008` | group Accepted then one per-player late failure; independent states |
| `PRD-AC-009` | deterministic GUID fake sequence for two external players; IDs differ |
| `PRD-AC-010` | three simulated arrival envelopes plus published three-visit check when environment supports it |
| `PRD-AC-011` | removal + Stop + repeated Stop produce no duplicate terminal event/error |
| `PRD-AC-012` | published Experience Roblox-client success plus operator-induced supported failure; record server/client output |
| `PRD-AC-013` | injected fake PlayersModule plus static `rg` assertion forbidding direct PlayerAdded/Removing in Teleport paths |
| `PRD-AC-014` | client focused test for Started then synchronous/late Failed transition |
| `PRD-AC-015` | two-client integration: appearance then departure through Communication |
| `PRD-AC-016` | serializer/payload assertions exclude private fields from other-player DTO |
| `PRD-AC-017` | identical state/results with zero signal subscribers and with subscribers |
| `PRD-AC-018` | public server/client API test with only template communication, no extra remote |
| `PRD-AC-019` | default config test: no observer, no pad factory call, no platform request even for the former template tester/identity |
| `PRD-AC-020` | table tests for valid opt-in, wrong GameId/PlaceId, malformed routes/allowlist, unauthorized touch, cleanup and public facade invocation |
| `PRD-AC-021` | documented operator checklist plus published A→B→A and rapid-repeat evidence; after disabling and republishing, fresh server has no pad |

### 8.4. Required checks

1. `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1` immediately before first source edit and again before first Studio operation.
2. Rojo build to a temporary path.
3. `scripts/validate-repository-layout.ps1` after ADR/layout changes.
4. Focused `TeleportModuleTestRunner`, `SystemTestRunner`, `ProductionIntegrationTestRunner`, `ProductionReadinessTestRunner`, then `AllTestsRunner`; every result `failed = 0`.
5. Clean server/client bootstrap in the explicitly selected existing primary Studio session with exact repository-recorded identity and matching `servePlaceIds`; default-disabled run must contain no validation pad.
6. Published Roblox-client E2E for real teleport. If the available Experience contains only one usable place or runtime client evidence cannot be observed, `PRD-AC-002`, `PRD-AC-010` and `PRD-AC-012` remain explicitly not run and production readiness is blocked; creating/publishing another place requires separate user authorization.

## 9. Mandatory Implementation Approach

1. Add shared types/protocol first with frozen constants and bounded DTO validators.
2. Implement server module against injected fakes, including atomic group validation and per-player state machine.
3. Implement client projection and bootstrap request contract.
4. Add server/client initialization commands and manifest composition; no self-starting module.
5. Add focused positive, negative, boundary and cleanup tests before runtime integration.
6. Add/update current runtime docs, `docs/TestCoverage.md`, and a new template ADR for the teleport ownership/protocol decision.
7. Run deterministic machine gates, two independent clean audits, then runtime QA.
8. Keep the reusable default disabled; published validation is a temporary operator procedure that ends by restoring and publishing `Enabled=false`.

## 10. Forbidden Formal Solutions

- считать `TeleportAsync` return, `PlayerRemoving` или `Player.OnTeleport` доказательством целевого прибытия;
- доверять payload `SourcePlaceId` без официального `joinData.SourcePlaceId` и explicit allowlist;
- использовать `sessionId` как security credential или хранить в teleport data валюту/прогресс;
- иметь одну group attempt record без per-player terminal state;
- передавать `sessionId`/attempt details в common appearance/departure messages;
- подписываться на `Players.PlayerAdded`/`PlayerRemoving` вне `PlayersModule`;
- добавлять direct RemoteEvent/RemoteFunction или использовать `Signal` как сеть;
- автоматически retry любой отказ в base module;
- принимать caller-owned raw `TeleportOptions`/`TeleportData`, позволяя обойти envelope/policy;
- ослаблять тесты под ограничения Studio или заявлять E2E passed без опубликованного client evidence.
- включать validation harness по умолчанию, хранить активные персональные identity в reusable default или создавать pad при неполной/несовпадающей конфигурации;
- использовать validation config как обход `TeleportPolicy`, оставлять test pad включённым после E2E или считать тестовый endpoint самостоятельным release-объектом шаблона.

## 11. Open Questions

Нет открытых продуктовых или реализационно-блокирующих вопросов. Сквозной published E2E является обязательным evidence gate, а не вопросом спецификации; отсутствие авторизованной двух-place среды блокирует production-ready verdict, но не детерминированную реализацию.
