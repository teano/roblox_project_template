---
document_type: technical-specification
status: approved
revision: 9
language: Russian
source_prd_path: docs/Features/template/ui-system/product-requirements.md
source_prd_revision: 3
source_prd_sha256: 31f00b75820a2a917ea55c1f486a3846b7e273eb689f563601ec2093269c0995
---
# Техническая спецификация UI System

## 1. Цель и концепция

Клиентская `UiSystem` добавляет к существующему manifest-driven bootstrap один принадлежащий `Player` корень игрового интерфейса, три host-контейнера и оконную подсистему. Она предоставляет внешним клиентским модулям только корневые точки интеграции и единый поток осмысленных UI-событий; серверная логика, аналитика, конкретные HUD/toast/window designs и ранний `ReplicatedFirst` UI остаются вне границы feature.

Нормативные формулировки этой спецификации имеют стабильные идентификаторы `TS-REQ-*`. Каждая из них сохраняет силу связанных `PRD-REQ-*`, `PRD-NFR-*` и проверяется одним или несколькими `TS-TEST-*`. Трёхсекундные сроки в документе означают один абсолютный deadline от начала соответствующей операции, а не три секунды на каждую её фазу.

## 2. Контекст и границы

### 2.1. Подтверждённые проектные прецеденты

- `src/ReplicatedStorage/Client/Initialization/ClientManifest.luau` является единственной клиентской composition root: он создаёт долгоживущие client services, передаёт зависимости конструкторам и отдаёт один упорядоченный manifest общему `InitializationRunner`.
- Клиентские `PoolModule`, `ContentPreloader` и `PlayersModule` уже существуют как явно скомпонованные service dependencies. `PoolModule` выдаёт generation leases и уничтожает объект после ошибки adapter `Release`; `ContentPreloader:Preload` допускает anonymous requests без sticky record; `PlayersModule` централизует `LocalPlayer`/Character lifecycle и показывает принятый проектом публичный event surface только с `Connect`/`Once` поверх private backing `Signal`.
- `src/ReplicatedStorage/Shared/Util/Signal.luau` запускает listeners независимо: `Fire` не ждёт listener, а ошибка или yield одного listener не блокирует других.
- `src/ReplicatedStorage/Shared/Communication/CommunicationSerialize.luau` уже предоставляет bounded `inspect`/`validate` для finite Roblox value types, dense arrays и string-keyed dictionaries; UI не создаёт второй serializer.
- `src/StarterPlayerScripts/Bootstrap.client.luau` остаётся единственным игровым client bootstrap. Новый standalone `LocalScript` не создаётся.
- `default.project.json` отображает весь `src/ReplicatedStorage` и сохраняет hybrid Rojo/Studio ownership. Cloud GUI-prefab не становится исполняемым source и не заменяет repo-owned Luau.
- В репозитории до этой feature нет UI runtime module; поэтому UI-объекты ниже являются новой клиентской bounded context, а не параллельными владельцами существующих capability.

### 2.2. Внутри границы

- создание и проверка `UiRoot`, `HudHost`, `ToastHost`, `WindowHost`;
- immutable runtime `WindowConfig`, immutable `UiActionCatalog`, cloud-template loading/validation/preload/cache;
- stack, navigation authority, visibility, focus, transitions, handles, blocking tokens, window cleanup и concrete window pools;
- `BaseUiElement`, `BaseWindowView`, narrow `UiElementContext`, начальные base controllers, identity registry, ownership bubbling и `Connect`/`Once`-only root event source;
- authoring template, repo-local window-authoring/project-initialize skills и derived-project initialization enforcement.

### 2.3. Вне границы

- gameplay/domain решение о том, какое первое окно запросить, и domain events, на которые реагирует Active Window;
- lifecycle, runtime registry или универсальный facade конкретного HUD и toast content;
- серверные mutations, RemoteEvent/RemoteFunction protocol и аналитический consumer;
- `ReplicatedFirst/Loading.client.luau`, persistence, универсальный HUD registry, toast scheduler/queue, Back/history и глобальная animation system.

Внешние владельцы `PoolModule`, `ContentPreloader`, `PlayersModule`, `Signal`, Roblox `AssetService`, `GuiService` и `PlayerGui` используются через узкие зависимости; UI feature не меняет их общие контракты.

## 3. Терминология

- **Operation generation** — монотонный идентификатор одной stack-changing navigation operation внутри одного `WindowNavigator`; late continuation обязана повторно проверить его перед любым navigator-owned commit.
- **Prepared Window** — загруженный/preloaded, созданный или acquired и синхронно initialized view с root `Parent = nil`, ещё не добавленный в stack/`WindowHost` и потому non-rendering.
- **Effective blocking** — наличие текущего пригодного `GuiObject` sink и хотя бы одного активного неинертного blocking token.
- **Quarantine** — принадлежащая `WindowNavigator` недоступная коллекция timed-out pooled views с активными leases; это не состояние или новая операция `PoolModule`.
- **UI cleanup** — защищённый вызов синхронного рекурсивного `BaseUiElement:Clear()` с последующей configured lifecycle policy.
- **Authoring source** — `TemplateWindowConfig` либо exact-path `DerivedWindowConfig`; они не являются runtime registry.
- **Canonical template** — успешно cloud-loaded, data-only validated и content-preloaded неизменяемый GUI root, клонируемый только внутри одного `UiSystem` lifetime.

Остальные канонические product terms (`UiRoot`, hosts, `WindowId`, `WindowDefinition(TView, TViewModel)`, `WindowHandle`, Active/Paused Window, `UIElementId`, `UINavigationEnabled`, `UIActionId`, `BlockObjectRef`, `HideBelow`, `KeepBelow`, `Open`, `Close`) сохраняют определения PRD без новых синонимов.

## 4. Декомпозиция

### 4.1. Level 0 — клиентская UI bounded context

```text
UiSystem (L0)
├─ клиентская композиция и UiRoot (L1)
│  ├─ UiInitializationCommand
│  ├─ UiSystem facade
│  └─ UiRootController
├─ определения и создание окон (L1)
│  ├─ WindowConfigCompiler
│  ├─ WindowAssetLoader
│  └─ WindowPoolOwner
├─ оконная навигация (L1)
│  ├─ WindowNavigator
│  ├─ WindowHandle
│  ├─ WindowInputBlocker
│  ├─ WindowNavigationRegistry
│  └─ UiSyncHookGuard (private)
├─ UI controllers и события (L1)
│  ├─ BaseUiElement / BaseWindowView
│  ├─ UiElementIdentityRegistry
│  ├─ UiRootEventStream / UiElementContext
│  └─ base element controllers
└─ authoring contract (L1)
   ├─ data-only window template
   ├─ window-authoring skill
   ├─ project-initialize skill
   └─ derived-project initialization enforcement

Outside L0: domain event owners, project HUD/toast owners, PoolModule,
ContentPreloader, PlayersModule, AssetService, GuiService, PlayerGui.
```

### 4.2. Level 1 — клиентская композиция и `UiRoot`

#### `UiInitializationCommand`

**Путь:** `src/ReplicatedStorage/Client/Initialization/Commands/UiInitializationCommand.luau`.

**Ответственность:** вызвать `UiSystem:Initialize()` после `StartupContentPreload`, `Pooling` и `Players`; command имеет `Id = "UI"` и `DependsOn = { "StartupContentPreload", "Pooling", "Players" }`. `ClientManifest` конструирует все UI dependencies, публикует `services.UI = uiSystem` и помещает command после перечисленных dependencies. `UiInitializationCommand:Initialize` явно unwrap-ит returned `UiVoidResult`: `Success` возвращает normally, а `Error` синхронно throws stable bounded message `UiInitializationFailed:<UiError.Code>` без instances или произвольных details.

**Состояние/lifecycle:** command не создаёт второй runner и не ловит thrown failure; result-to-throw adaptation существует только на command boundary. Existing `InitializationRunner` записывает failed result с `CommandId = "UI"`, останавливает следующие commands, после чего existing client bootstrap выставляет `ClientInitializationFailed = true` и не выставляет `ClientInitialized`. `UiSystem` остаётся result-only и не throws через public API; его atomic error branch не оставляет usable partial UI state. Повторный `Initialize` делегируется idempotent contract `UiSystem`.

**Не владеет:** окнами, domain decisions, `PlayerGui` вне `UiRoot`, Character lifecycle или bootstrap continuation.

#### `UiSystem`

**Путь:** `src/ReplicatedStorage/Client/UI/UiSystem.luau`.

**Ответственность и API:** facade создаёт/проверяет `UiRootController`, компилирует config и action catalog, создаёт `WindowAssetLoader` и `WindowNavigator`, запускает bounded eager attempts и предоставляет только следующий surface:

```lua
Events: UiEventSource<UiRootEvent> -- only Connect / Once
Initialize(self) -> UiVoidResult
GetHudHost(self) -> Frame
GetToastHost(self) -> Frame
GetUiElementContext(self) -> UiElementContext
AddWindowAsync(self, windowId: WindowId, viewModel: unknown) -> UiValueResult<WindowHandle<BaseWindowView>>
AddWindowTypedAsync<TView, TViewModel>(self, definition: WindowDefinition<TView, TViewModel>, viewModel: TViewModel) -> UiValueResult<WindowHandle<TView>>
Destroy(self) -> ()
```

Facade `AddWindow*` допустим только при пустом stack. После появления первого окна facade не предоставляет внешнему caller обход authority: последующие Add/Close/replacement проходят через одноимённые helpers текущего Active Window. `Events` повторяет shape `PlayersLifecycleSignal`: caller получает `Connect` и `Once`, но не `Fire`, `Wait` или `Destroy`; backing repo `Signal` остаётся private у `UiRootEventStream`. `Destroy` предназначен для окончания `Player`/client runtime, а не respawn.

**Owned state:** один initialization state, immutable service references, `UiRootController`, один frozen `WindowConfig`, один frozen `UiActionCatalog`, asset cache owner, navigator, root event stream и один frozen `UiElementContext`.

**Не владеет:** HUD/toast content lifecycle, конкретной ViewModel после `Initialize`, Character reaction, analytics, server domain data.

#### `UiRootController`

**Путь:** `src/ReplicatedStorage/Client/UI/UiRootController.luau`.

**Ответственность:** получить `LocalPlayer` только из injected client `PlayersModule`, получить его `PlayerGui`, создать ровно один `ScreenGui` `UiRoot` с `ResetOnSpawn = false`, `ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets`, `ClipToDeviceSafeArea = true`, sibling Z-order и тремя full-area `Frame` hosts. Relative Z-order неизменно `HudHost < ToastHost < WindowHost`; `WindowHost` после initialization пуст.

`ScreenInsets` является engine-owned safe-area projection, поэтому при viewport/orientation/platform inset change host bounds меняются без переинициализации. Конкретное содержимое самостоятельно адаптирует внутренний layout.

Инициализация строит кандидата off-tree, полностью проверяет имена, классы и уникальность hosts, затем одним commit parent-ит `ScreenGui` в `PlayerGui`. Existing compatible root можно идемпотентно принять; duplicate/malformed root даёт `UiRootMalformed` и не публикует частичный service. `ReplicatedFirst` UI никогда не переносится внутрь `UiRoot`.

**Не владеет:** содержимым hosts, stack, global input overlay, Character events или ранним loading UI.

#### Взаимодействие уровня

`ClientManifest -> UiInitializationCommand -> UiSystem -> UiRootController`. Отдельная project initialization command, зависящая от `UI`, получает от composition root конкретный project HUD/toast controller и после успешной UI initialization передаёт ему соответствующий host вместе с тем же frozen `UiElementContext`. Контроллер создаёт свой root `BaseUiElement`, сохраняет собственный runtime state и cleanup; UI context только атомарно заявляет/освобождает live `UIElementId` и доставляет уже обогащённое событие к root stream. Ни `UiRootController`, ни `UiSystem` не создают `HudId`, runtime HUD/toast registry, queue или lifecycle API.

**TS-REQ-001 — корень, hosts и владение.** Реализация выше обязательна; respawn/Character replacement не вызывает `Destroy`, повторный `Initialize` или content clear. Нарушенная обязательная структура abort-ит UI initialization атомарно. Источники: PRD-REQ-001, PRD-REQ-002, PRD-REQ-003, PRD-REQ-004, PRD-REQ-005, PRD-REQ-006, PRD-REQ-007, PRD-REQ-008, PRD-REQ-096, PRD-REQ-097, PRD-REQ-123, PRD-REQ-125, PRD-REQ-128, PRD-REQ-129, PRD-REQ-130, PRD-REQ-131, PRD-REQ-138, PRD-REQ-141, PRD-REQ-142, PRD-NFR-002. Проверки: TS-TEST-001, TS-TEST-012, TS-TEST-015.

### 4.3. Level 1 — определения и создание окон

#### `WindowConfigCompiler`

**Пути:**

- template source: `src/ReplicatedStorage/Client/UI/Config/TemplateWindowConfig.luau`;
- derived-project source: `src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau`;
- template typed definitions: `src/ReplicatedStorage/Client/UI/Config/Definitions/<DefinitionName>.luau`;
- derived typed definitions: `src/ReplicatedStorage/Project/Client/UI/Definitions/<DefinitionName>.luau`;
- compiler/types: `src/ReplicatedStorage/Client/UI/Config/WindowConfigCompiler.luau` и `WindowTypes.luau`.

Reusable template **не содержит** exact derived path. `ClientManifest` проверяет только этот fixed path без scanning: полное отсутствие `src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau` всегда означает empty derived authoring sequence, после чего compiler публикует тот же один merged frozen `WindowConfig`. Runtime не отличает template от derived repository и не использует name, folder-presence, cloud identity либо новый marker/detector; отсутствие path никогда само по себе не является bootstrap failure. В initialized derived repository обязательность exact UTF-8 `--!strict` ModuleScript проверяют только project-initialization rule/documentation/skill и repository validator до implementation/build. Это единственный обязательный project-owned window-definition source boundary; optional action source отдельно ограничен одним exact path в §4.6.

Каждая authoring запись содержит `WindowId`, positive safe-integer `AssetId`, repo-owned `CreateView` factory, `TryCastView`, обязательный typed adapter `InitializeView`, `LifecyclePolicy = "Destroy" | "Pool"`, `VisibilityPolicy = "HideBelow" | "KeepBelow"`, `BackgroundPolicy = "None" | "Absorb" | "CloseOnActivate"`, optional `Preload`, а при `Pool` — существующий `PoolOptions` с `MaxActive` и `MaxRetained`. `WindowId` и `AssetId` не объединяются; `TemplateId` отсутствует.

Каждое конкретное окно обязано иметь ровно один canonical typed definition ModuleScript в соответствующей owner-specific `Definitions` directory из списка выше. Этот ModuleScript в `--!strict` создаёт и возвращает сам один `WindowDefinition<TView, TViewModel>` table. Соответствующий `TemplateWindowConfig` либо `DerivedWindowConfig` обязан напрямую `require`-ить его и вставлять exact returned value в duplicate-preserving sequence. Typed caller обязан `require`-ить тот же per-window ModuleScript напрямую; он не индексирует heterogeneous sequence и не собирает record повторно. `require` cache, authoring sequence, compiler index и typed caller таким образом видят один и тот же table object; compiler freeze-ит этот object in place при atomic publish. Per-window ModuleScript — не второй config/registry, не wrapper, не copy и не runtime lookup API.

Схематичный authoring/caller example ниже показывает type/identity contract, но не добавляет shipped sample window:

```lua
-- Definitions/ExampleWindow.luau
local definition: WindowDefinition<ExampleWindowView, ExampleViewModel> = {
	-- exact required fields, including InitializeView
}
return definition

-- TemplateWindowConfig.luau or DerivedWindowConfig.luau
local ExampleWindow = require(script.Parent.Definitions.ExampleWindow)
return { ExampleWindow } -- exact returned table, duplicate-preserving sequence

-- typed domain caller
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ExampleWindow = require(ReplicatedStorage.Client.UI.Config.Definitions.ExampleWindow)
return ui:AddWindowTypedAsync(ExampleWindow, model)
```

Оба authoring module возвращают dense duplicate-preserving sequences exact definition tables, а не maps: это сохраняет возможность диагностировать два одинаковых `WindowId` внутри одного source. Compiler сначала проверяет shape обеих sequences, каждую запись, duplicate within/between sources и policy combinations без mutation input. Только после полного успеха он замораживает каждый `PoolOptions`, затем каждую exact definition, объединённую ordered sequence и lookup index внутри **одного** `WindowConfig`. Canonical definition table identity является typed API identity и содержит value-level `TryCastView` вместе с `InitializeView: (view: TView, viewModel: TViewModel) -> UiVoidResult`; второго registry/manifest/config нет. Heterogeneous `WindowConfig` хранит exact те же definition tables через private opaque `ErasedWindowDefinition`: это только локальное type erasure, не runtime wrapper, копия либо отдельная definition identity. Compiler/navigator выполняют erasure/recovery только внутри UI implementation; public typed surface не содержит `any`, а runtime identity comparison всегда использует исходную canonical table. Никакого runtime mutation API или результата для caller mutation не существует.

**Не владеет:** cloud fetch, pool, stack, instance lifecycle или ViewModel retention.

#### `WindowAssetLoader`

**Путь:** `src/ReplicatedStorage/Client/UI/WindowAssetLoader.luau`.

**Dependencies:** injected Roblox asset backend exposing `LoadAssetAsync`, existing `ContentPreloader`, clock/scheduler и logger. Production backend вызывает только `AssetService:LoadAssetAsync(definition.AssetId)` внутри `xpcall`; caller никогда не передаёт arbitrary AssetId.

**Фазы одной physical attempt:** load latest accessible asset version -> проверить returned wrapper -> найти ровно один `GuiObject` root canonical shape -> рекурсивно reject любой `LuaSourceContainer` -> выполнить существующий anonymous `ContentPreloader:Preload({ root }, { FailurePolicy = "Fail" })` -> ещё раз проверить loader-owned attempt generation -> принять root как session-local canonical template.

Loader хранит по `WindowId` не более одной unsettled physical attempt, её монотонную generation и waiters. Concurrent eager/open callers присоединяются к этой attempt. Timeout или destroy инвалидирует принятие результата, но не пытается отменить `LoadAssetAsync`/`Preload`: attempt помечается abandoned и остаётся единственной physical attempt, пока фактически не settle. Новый caller сначала присоединяется/ожидает её settle и не запускает параллельную замену; abandoned result всегда уничтожает owned wrapper/root carrier, очищает slot и только затем, если deadline нового caller ещё допускает, создаётся следующая generation. Failed settled attempt также не кешируется. Это предотвращает unbounded physical retries без изменения `ContentPreloader`, eviction или cancellation API.

Успешный current non-abandoned result публикует cache record только после всех фаз и generation check. Cache живёт до `UiSystem:Destroy`, не обновляется по `AssetVersionId` и не повторяет cloud load/preload; clone factory всегда клонирует canonical template синхронно. Каждая yielding continuation после deadline или destroy сверяет loader generation. Stale/abandoned result не заполняет cache, не создаёт pool/view, уничтожает owned carrier и публикует один bounded diagnostic.

`Preload = true` запускает по одной attempt на definition параллельно при `UiSystem:Initialize`. Все они получают один startup cutoff `startedAt + 3`; initialize ждёт settle всех attempts либо cutoff. Failure/timeout логируется на definition, но не ломает successful UI initialization. После timeout следующий `Open` не создаёт второй physical call поверх ещё unsettled non-cancellable attempt: он ждёт её settle/disposing в пределах своего deadline и затем повторяет незавершённые фазы новой generation. `Preload ~= true` откладывает все yielding phases до первого `Open`.

**Не владеет:** `AssetRegistry`, asset ownership verification, free-asset setting, stack, pool leases или view code.

#### `WindowPoolOwner`

**Путь:** `src/ReplicatedStorage/Client/UI/WindowPoolOwner.luau`.

После успешного canonical template каждый pooled definition получает ровно один homogeneous `Pool<PooledWindowRecord, WindowAcquireContext>` с id `Ui.Window/<WindowId>` через injected client `PoolModule:CreatePool`, передавая frozen authoring `PoolOptions` без изменения. Record содержит конкретный view/root, минимальный `ReuseState = "clean" | "dirty" | "failed"` и optional identity-only `CurrentUseToken`. Factory синхронно клонирует template, вызывает repo-owned `CreateView(root, frozenConstructionContext)` и возвращает `clean` record без use token, что сохраняет существующий `Warmup(Create -> Release)` contract.

Adapter `Acquire` принимает только `clean` record, создаёт новый opaque UI use token, ставит `dirty` и оставляет root off-tree с `Parent = nil` после отсоединения от non-rendering pool parent. Он не parent-ит candidate в `WindowHost`. Navigator хранит exact pool lease и UI use token. После успешного protected UI `Clear` только exact current token может убрать token и поставить `clean`; stale completion не может очистить новое использование. Ошибка `Clear` ставит `failed`. Adapter `Release` принимает только `clean`/no-token record и переводит root в non-rendering pool parent; при `dirty`/`failed` он синхронно raises, после чего **существующий** `Pool:TryReleaseToPool` удаляет active lease и вызывает adapter `Destroy`. Adapter `Destroy` окончательно destroy-ит view/root и терпит partial state. Никакого нового pool state, lease operation или adapter callback не вводится.

Pool owner не warmup-ит до успешного preload и не выполняет yielding work внутри adapter. Он хранит typed pool references, а не ищет type через `PoolModule:GetPool`. `UiSystem:Destroy` удаляет каждый owned pool штатным `RemovePool`, invalidating active/quarantined leases; общие `Pool:Clear`, `PoolModule:ClearPool` и `ClearAllPools` не меняются.

#### Взаимодействие уровня

Compiler публикует definitions атомарно. Loader принимает только canonical definition, а pool owner создаёт concrete pool только после template readiness. Destroy definition создаёт новый off-tree view/clone на каждое открытие; Pool definition получает/возвращает только generation lease с off-tree record. Любой candidate остаётся `Parent = nil` через constructor/acquire и `InitializeView -> Initialize`; ни factory, ни pool adapter, ни view не решают, когда он попадёт в `WindowHost` или когда destroy/release произойдёт.

**TS-REQ-002 — authoring config и typed definition.** Exact paths, duplicate-preserving validation, direct binding и один atomically published frozen runtime config обязательны. Источники: PRD-REQ-009, PRD-REQ-010, PRD-REQ-011, PRD-REQ-012, PRD-REQ-013, PRD-REQ-014, PRD-REQ-099, PRD-REQ-100, PRD-REQ-146, PRD-REQ-147, PRD-REQ-150, PRD-REQ-201, PRD-REQ-202, PRD-NFR-001. Проверки: TS-TEST-002, TS-TEST-003, TS-TEST-010, TS-TEST-014.

**TS-REQ-003 — cloud load, validation, preload и cache.** Описанные allowlist, attempt identity, retry и stale-result rules обязательны. Runtime не заявляет owner verification. Mandatory `TS-EVIDENCE-LOCAL-FIXTURE-001` доказывает canonical config/loading contract без cloud; отдельный mandatory read-only `TS-EVIDENCE-ALLOWINSERT-001` доказывает exact-place `AllowInsertFreeAssets=false` без AssetId или cloud mutation; `TS-SMOKE-CLOUD-001` условен только при уже одобренном external fixture/AssetId по §8.2 и §12.1. Источники: PRD-REQ-015, PRD-REQ-037, PRD-REQ-148, PRD-REQ-149, PRD-REQ-158, PRD-REQ-159, PRD-REQ-160, PRD-REQ-161, PRD-REQ-196. Проверки: TS-TEST-003, TS-TEST-011, TS-TEST-012, TS-TEST-014, TS-TEST-016.

**TS-REQ-004 — pool integration.** Каждый WindowId имеет отдельный existing-API pool, generation lease и configured budgets; asset loading/await не входит в adapter, а Acquire возвращает off-tree record без parenting в `WindowHost`. Источники: PRD-REQ-014, PRD-REQ-015, PRD-REQ-016, PRD-REQ-074, PRD-REQ-075, PRD-REQ-076, PRD-REQ-077, PRD-REQ-152. Проверки: TS-TEST-002, TS-TEST-007, TS-TEST-011.

### 4.4. Level 1 — оконная навигация

#### `UiSyncHookGuard`

**Путь:** `src/ReplicatedStorage/Client/UI/Internal/UiSyncHookGuard.luau`; это stateless private helper, а не service, scheduler, timeout owner или public API.

Guard даёт одну минимальную protected non-yield primitive для `Initialize`, root/recursive `Clear`, concrete `OnClear`, `Pause` и `Resume`. Каждый invocation создаёт отдельную inspectable coroutine, тело которой вызывает hook внутри `xpcall` с bounded traceback handler; guard вызывает `coroutine.resume` ровно один раз. `Success` возможен только когда resume и `xpcall` успешны и `coroutine.status(thread) == "dead"`. Hook exception даёт internal `Error`; returned `UiVoidResult` остаётся обычным return value и интерпретируется владельцем phase.

Если после единственного resume thread имеет `suspended`, hook нарушил non-yield contract. Guard фиксирует только bounded phase/trace, немедленно вызывает `coroutine.close(thread)`, требует его success, возвращает internal `Yielded` и отбрасывает reference. Closed thread переходит в `dead`, его stack очищается, и ни guard, ни UI owner никогда не хранят и не resume-ят эту continuation. Неожиданный failed `coroutine.close` является той же phase failure/invariant diagnostic и не расширяет public errors. Primitive не создаёт task, connection, retry, poll, timer или retained coroutine collection.

Phase mapping использует только уже определённые recovery branches: `InitializeView -> Initialize` exception/yield даёт `InitializeFailed` и configured candidate cleanup; root/child `Clear` и `OnClear` exception/yield даёт aggregate `CleanupFailed`, но не подавляет sibling/resource cleanup; `Pause`/`Resume` exception/yield даёт тот же bounded custom-hook developer diagnostic с `Phase` и `Reason = "Yielded"`, но не отменяет base state/event. Поскольку sync continuation уже closed, она не требует нового quarantine state: destroy candidate уничтожается, failed pooled cleanup идёт через существующий `failed -> TryReleaseToPool -> adapter Destroy` path, а existing quarantine остаётся только для фактически продолжающихся optional asynchronous `Open`/`Close` hooks.

**Не владеет:** hook lifecycle, UI state, recovery policy, scheduler или diagnostics transport; owner phase сам интерпретирует три internal outcomes.

#### `WindowNavigator`

**Путь:** `src/ReplicatedStorage/Client/UI/WindowNavigator.luau`.

**Owned state:** ordered stack entries, current operation gate/generation/deadline, next operation generation, handle registrations, visibility snapshot derived only for event delta, quarantine records и references to config/loader/pools/root event stream/logger. Stack entry содержит definition, view, optional pool+lease, handle generation, base state `Active | Paused`, applied visibility и только system pause/transition token handles, которые navigator получил от blocker данного view. Navigator не владеет per-view token registry, sink/effective state, navigation baselines, links, last selection или focus bookkeeping.

**Internal/public operations:** navigator surface injected в `BaseWindowView` is narrow and verifies exact caller view+generation. It exposes PRD-named universal/typed Add, own Close и replacement overloads; external systems see the same `UiSystem:AddWindow*` names only on empty stack.

Обе typed operations потребляют association из exact canonical `WindowDefinition<TView, TViewModel>`, полученного caller-ом прямым `require` того же per-window ModuleScript: после canonical identity check и `TryCastView` navigator ровно один раз вызывает `definition.InitializeView(concreteView, viewModel)` через `UiSyncHookGuard` с phase `Initialize` и обрабатывает returned `UiVoidResult` в существующей preparation branch. Обязательное function field делает несовместимую пару definition/model Luau type error до runtime; generic inference не может отбросить `TViewModel` как phantom, а public signature не использует `any`. Universal operations по `WindowId` принимают `unknown`, получают ту же canonical definition из frozen config и вызывают тот же adapter через private erased boundary и ту же guard primitive; concrete `BaseWindowView:Initialize(unknown)` остаётся единственным runtime owner проверки значения. Adapter передаёт model без проверки, преобразования или хранения ровно в один вызов `view:Initialize(viewModel)` и возвращает его `UiVoidResult`; он не создаёт второго validator/owner/config/registry.

Admission order is deterministic:

1. If request is the same window and that window currently executes `Open`/`Close`, return typed `NoOp` immediately. Parameterless `CloseWindowAsync` представляет эту ветку отдельной `UiCloseResult` branch `NoOp`; это не `Success`, не `Error` и не подтверждение lifecycle.
2. If any other stack-changing operation owns gate, return `Busy` immediately; no queue.
3. Validate caller authority: empty-stack facade for first window, otherwise exact current Active Window generation; non-top/external call returns `NotActiveWindow`.
4. Reject duplicate `WindowId` anywhere in stack before config/load/acquire.
5. Reserve one operation generation and absolute deadline `now + 3` covering load, preload, prepare and transition hooks.

Every post-yield commit checks gate owner, generation and deadline. Timeout invalidates generation, performs synchronous base recovery, releases gate and returns `Timeout` exactly at deadline. Late continuation may dispose its owned resources but cannot alter stack/handles/lifecycle events, acquire or release navigator system handles, or request blocker/navigation-registry state changes. Arbitrary custom hook side effects are not rolled back.

#### Add flow

Prepare off-tree B through `UiSyncHookGuard` phase `Initialize` around `definition.InitializeView(B, viewModel)`, которое ровно один раз делегирует `B:Initialize(viewModel)`. Before adding B, current A (if any) completes base transition to Paused: navigator obtains and holds A's pause-token handle from A's `WindowInputBlocker`, commands A's `WindowNavigationRegistry` to apply Paused eligibility, invokes `Pause()` once через ту же guard primitive and emits `ui.window.paused`; custom exception/yield is diagnostic only. После final generation/deadline check navigator одним non-yielding commit parent-ит B root в `WindowHost`, добавляет B последней stack entry и помечает Active; до этого commit B не рендерится и не имеет stack authority. Navigator получает от B blocker transition-token handle, хранит его, commands B navigation registry Active и вызывает optional `Open` within remaining deadline. Success emits `ui.window.opened`, releases only that transition handle through B blocker, performs one final visibility recomputation, and returns handle. Ordinary failure removes B, invalidates handle/generation, commands its navigation registry inactive, releases navigator-owned transition handle, performs forced cleanup, restores original stack, commands A navigation registry Active, resumes A exactly once через guard and releases A's navigator-held pause handle through A blocker, recomputes visibility once, then returns typed error. Timed-out pooled B follows quarantine; destroy B follows immediate destroy cleanup.

#### Close flow

Only top B may close. A parameterless repeat while B already executes `Open`/`Close` returns `UiCloseResult` branch `NoOp` immediately and performs nothing else. Otherwise B never receives `Pause`; navigator obtains and holds B's transition-token handle from B's blocker before optional `Close`, which runs within remaining deadline. On success or hook failure/timeout, B is removed, its handle invalidated, its navigation registry commanded inactive и navigator releases only its own system transition handle through B blocker. `ui.window.closed` is published with B's exact still-live root `UIElementId` after removal/base closed state but **before** identity unregister and `Clear`; only then does cleanup retire the ID. Ordinary success/error performs UI cleanup and lifecycle; timeout pooled B quarantines, while timeout destroy B is synchronously Clear/destroyed. Remaining A becomes Active immediately, navigator commands A navigation registry Active, `Resume()` runs once, only A's navigator-held pause handle is released through A blocker, `ui.window.resumed` fires, then one visibility recomputation may emit show. Close without next definition returns `UiCloseResult`, never another handle; its `NoOp` is distinct from completed close `Success` and `Error`.

#### Replacement flow

Prepare B completely with root `Parent = nil` and without stack mutation. B remains off-tree/non-rendering throughout A's possibly yielding `Close`. Preparation failure cleans B and leaves A/prefix/visibility unchanged. Then run Close A and remove it; A is never restored after removal. После same-generation check navigator одним non-yielding commit parent-ит B в `WindowHost`, добавляет его над неизменённым lower prefix и помечает Active, затем starts Open; no intermediate visibility recomputation occurs. Success returns B handle after one final recomputation. If Close A fails/times out, A remains removed, still-off-tree prepared B is cleaned, lower prefix top resumes, one recomputation runs, and error returns. If Open B fails/times out after A removal, B is cleaned/quarantined, A remains removed, lower prefix top resumes, one recomputation runs, and error returns. Every such lower-prefix resume commands that view's navigation registry Active and releases only its navigator-held pause handle through its blocker. Lower entries whose Active/visible state did not change receive no intermediate hooks/events.

#### Visibility and lifecycle order

Visibility is a pure function of final stack: scan from top downward to the first `HideBelow`; that entry and suffix above it are visible, lower prefix hidden; without `HideBelow` all entries visible. Only changed visibility emits `ui.window.shown`/`ui.window.hidden`. Every lifecycle event carries the exact root `UIElementId` currently registered for that view plus `WindowId`. Required ordering is applied-state order: paused before hidden; closed removed top before unregister/Clear and before resumed lower top; resumed before shown. A missing/mismatched live root registration at publication emits one developer diagnostic `UiLifecycleIdentityInvariant`, skips that invalid event and continues the already-defined navigation/cleanup path; it does not start a recovery machine. Failed pre-mutation requests emit no lifecycle confirmation. Failed Open never emits opened/closed for the temporary view. Custom Pause/Resume failure never suppresses an otherwise valid already-applied base-state event.

#### `WindowHandle<TView>`

**Путь:** `src/ReplicatedStorage/Client/UI/WindowHandle.luau`.

Immutable handle stores navigator registration key, `WindowId`, view witness и generation, not raw ownership. `IsValid`, `IsActiveWindow` и `GetView` each query registration+generation. Paused handle stays valid and returns concrete view; only `IsActiveWindow` is false. After removal/Clear/destroy/release/quarantine entry, view access returns `StaleHandle`. A stale handle never touches a later lease generation.

```lua
WindowId: WindowId
IsValid(self) -> boolean
IsActiveWindow(self) -> boolean
GetView(self) -> ViewResult<TView>
```

#### Quarantine ownership

On timeout of a continuing pooled `Open`/`Close` hook, navigator immediately removes stack/handle authority, commands the navigation registry inactive, releases its transition handle through the blocker, and reparents the non-visible/non-interactable root to a non-rendering `Folder` owned by navigator outside `UiRoot` hosts. Because the generation is no longer live, blocker owns setting its sink to `None`; its remaining manual handles stay in its registry until delayed `Clear`. Quarantine retains exact pool+lease+UI use token+hook completion, not token-registry or focus ownership. No UI `Clear` or `Release` occurs while hook runs. Completion callback rechecks quarantine identity and exact UI use token, performs protected UI cleanup, marks `clean` or `failed`, then calls normal `TryReleaseToPool`; cleanup/adapter failure lets existing pool behavior destroy/invalidate the object. A never-completing hook keeps the `dirty` record and active lease counted against `MaxActive` until `UiSystem:Destroy` removes the owned pool. Quarantine never appears through public API or presentation events.

Destroy-policy timeout does not use quarantine: after base recovery navigator immediately disables/detaches, runs protected `Clear`, destroys root/controller even while stale hook continuation may finish later, ignores that result and promises no rollback of its custom side effects.

**Не владеет:** cloud owner policy, view-specific transition visuals, custom runtime timer behavior, pool core or domain event decisions.

#### Взаимодействие уровня

`BaseWindowView` requests; `WindowNavigator` decides authority/orchestrates; loader/pool owner prepare; concrete view owns optional visual hook; root controller owns presentation parent; event stream reports applied state. Exactly one primary owner exists for every stack mutation.

**TS-REQ-005 — stack, authority и operation gate.** Одна operation, top-only authority, duplicate/no-op/busy ordering, generation/deadline и no Back/history обязательны; parameterless Close использует exact `UiCloseResult` с отдельной `NoOp` branch. Источники: PRD-REQ-017, PRD-REQ-064, PRD-REQ-065, PRD-REQ-066, PRD-REQ-139, PRD-REQ-140, PRD-REQ-156, PRD-REQ-163, PRD-REQ-164, PRD-REQ-165, PRD-REQ-166, PRD-REQ-167, PRD-REQ-174, PRD-REQ-175. Проверки: TS-TEST-003, TS-TEST-005, TS-TEST-009, TS-TEST-010.

**TS-REQ-006 — stack visibility и Active/Paused lifecycle.** Visibility всегда вычисляется из final stack; Pause/Resume и events следуют фактической смене active state. Источники: PRD-REQ-018, PRD-REQ-019, PRD-REQ-020, PRD-REQ-021, PRD-REQ-022, PRD-REQ-027, PRD-REQ-084, PRD-REQ-085, PRD-REQ-086, PRD-REQ-177, PRD-REQ-181, PRD-REQ-182, PRD-REQ-183, PRD-REQ-184, PRD-REQ-185, PRD-REQ-186, PRD-REQ-187, PRD-REQ-188, PRD-REQ-189, PRD-REQ-190, PRD-REQ-191, PRD-REQ-192, PRD-REQ-193, PRD-REQ-194, PRD-REQ-195, PRD-REQ-199, PRD-REQ-200, PRD-NFR-003. Проверки: TS-TEST-004, TS-TEST-005, TS-TEST-008, TS-TEST-009.

**TS-REQ-007 — failure recovery, cleanup и quarantine.** Failure branches выше являются нормативными; closed current window не восстанавливается. Navigator освобождает только свои system handles, а blocker/navigation registry очищают собственное per-view состояние. Источники: PRD-REQ-067, PRD-REQ-068, PRD-REQ-139, PRD-REQ-143, PRD-REQ-144, PRD-REQ-145, PRD-REQ-153, PRD-REQ-154, PRD-REQ-168, PRD-REQ-169, PRD-REQ-172, PRD-REQ-173, PRD-REQ-175, PRD-REQ-176. Проверки: TS-TEST-007, TS-TEST-009, TS-TEST-011.

**TS-REQ-008 — handle contract.** Generation checks, canonical definition↔ViewModel association и typed/universal return shapes обязательны. Источники: PRD-REQ-178, PRD-REQ-201, PRD-REQ-202, PRD-REQ-203. Проверки: TS-TEST-010.

### 4.5. Level 1 — input blocking и gamepad navigation

#### `WindowInputBlocker`

**Путь:** `src/ReplicatedStorage/Client/UI/WindowInputBlocker.luau`; один instance принадлежит одному `BaseWindowView` generation.

`WindowInputBlocker` единолично владеет per-view token registry, validity/behavior всех выданных active/inert/stale token handles, current sink binding, его observers и effective-blocking boolean этого view generation. Manual consumer получает только self-release `UiInputBlockHandle` через inherited `BaseWindowView:AcquireInputBlock()`; этот surface не раскрывает blocker, registry или effective state. Caller handle владеет только своей reference и обязан вызвать `Release()`; это не передаёт ему registry state. При `Initialize` controller проверяет direct child `ObjectValue` с exact name `BlockObjectRef`, его current `Value` и принадлежность sink exact current window root/generation. Он подписывается только на replacement/removal direct ref, `Value` change и ancestry текущего sink; глобального descendant watcher, geometry/Z polling или изменения общего `Signal` нет. Missing ref, nil value, non-`GuiObject` value, sink вне current root либо stale window generation не являются initialization error и дают inert binding. При ref/value/ancestry change прежний current-owned sink немедленно получает `InputSink = None`; новый sink становится пригодным только после той же ownership/generation проверки и получает `All` лишь при tracked active token.

`AcquireInputBlock` для exact live view generation при текущем пригодном sink создаёт отдельный tracked manual token и возвращает generation-bound handle. Если view generation уже stale/clearing либо sink отсутствует/непригоден в момент acquire, method возвращает permanently inert handle, который не входит в token set и не оживает при позднем появлении sink. Tracked token остаётся логически активным при временно nil/malformed `Value`: effective blocking исчезает, но при следующем valid value применяется к новому sink до release. Только blocker-owned release снимает соответствующий token из registry; `UiInputBlockHandle:Release()` synchronous/idempotent, а double, inert или stale-generation release — no-op и не затрагивает replacement generation. До teardown `Clear` освобождает все outstanding manual tokens, ставит current sink в `None`, disconnect-ит value/root/sink observers, очищает registry и инвалидирует все handles.

System-owned pause и transition tokens используют тот же blocker contract. `WindowNavigator` владеет только references/release obligation полученных им system handles: `Resume` освобождает его pause handle, successful/failed transition — его transition handle; navigator не перечисляет и не мутирует registry/handle validity, поэтому manual handles сохраняются. При изменении effective boolean blocker вызывает ровно один injected synchronous `OnEffectiveBlockingChanged(isBlocked)` текущей window binding; composition `BaseWindowView` передаёт это значение своему `WindowNavigationRegistry`, а не переносит token/focus ownership в navigator. Ошибка callback диагностируется как developer invariant и не создаёт watcher, polling или recovery state machine.

#### `BackgroundController`

Optional direct `Background` — exact-name `GuiButton`, подключённый только через Roblox `Activated`. Для `Absorb`/`CloseOnActivate` authoring validator и `Initialize` требуют его принадлежность current root и проверяют authored full-root geometry/Z placement один раз; для ref/root replacement соответствующая проверка повторяется в момент bind. Runtime не опрашивает geometry/Z и не добавляет `UserInputService`, `ContextActionService` или global interceptor. При `Absorb` `Activated` заканчивается без action; при `CloseOnActivate` незаблокированный Active Window просит собственный Close. `BackgroundPolicy = "None"` допускает отсутствие Background и не подключает handler. Paused, non-top или effectively blocked handler ничего не публикует и не закрывает. `InputSink = All` поглощает input независимо от Background и не пропускает его нижним hosts/world.

#### `WindowNavigationRegistry`

**Путь:** `src/ReplicatedStorage/Client/UI/WindowNavigationRegistry.luau`.

`WindowNavigationRegistry` единолично владеет per-view navigation baselines, frozen overrides, current default, membership/links, last-selected и focus bookkeeping для своего view generation. `BaseWindowView:ConfigureNavigation(defaultElement, overrides)` вызывается синхронно во время `Initialize`. `defaultElement` optional только когда у окна нет `UINavigationEnabled` descendants; `overrides` — dense sequence `{ From, Direction = "Up" | "Down" | "Left" | "Right", To }`. Registry проверяет, что initial default, `From` и `To` принадлежат live hierarchy того же current window и navigation-enabled; duplicate override одного `From`/direction rejected. Он копирует и замораживает authored overrides, а current default инициализирует этой ссылкой либо nil для initial zero-eligible window. Initial descendants и каждый runtime subtree delta поступают только через принадлежащую `BaseWindowView` binding transaction: registry до commit проверяет полный post-state, для добавляемых eligible members сохраняет authored `Selectable`, `Interactable` и exact `NextSelection*`, а при removal восстанавливает эти baselines и удаляет их membership/links. Roblox default automatic navigation работает по текущему registered membership, когда active override для направления отсутствует; frozen explicit override применяется только пока exact `From` и `To` registered и имеет приоритет. Removal любого endpoint делает этот override dormant и возвращает направление к authored/automatic resolution; rebind тех же exact members применяет его снова. Fallback search и service lookup запрещены.

Только незаблокированный Active Window включён. Navigator сообщает registry только orchestrated Active/Paused change; blocker callback сообщает только effective boolean. Registry из этих двух inputs сохраняет/восстанавливает собственный baseline, ставит `Selectable=false`, `Interactable=false`, временно исключает links и очищает `GuiService.SelectedObject`, если selection принадлежит окну. При Active и `isBlocked = false` registry восстанавливает baseline и выбирает last valid registered element, иначе current required registered default; fallback search запрещён. Navigator не хранит baseline/links/last-selected и не выбирает focus напрямую. Initial Window with eligible descendants обязан иметь принадлежащий ему valid default; иначе `Initialize` возвращает `InvalidDefaultNavigation`. Для runtime `0 -> nonzero` eligible transition overload `AddNestedUiElement(child, nominatedDefault)` обязателен: nomination должна быть exact eligible member добавляемого subtree и valid в staged post-state, а registry atomically делает её current default вместе с membership. Missing/invalid nomination возвращает `InvalidDefaultNavigation` и не меняет default или иерархии; nomination вне этого transition также rejected failure-atomically, поэтому обычный non-transition attach сохраняет простой one-argument call и прежний current default. Если removal subtree содержит current default и staged post-state сохраняет eligible members, обязателен overload `RemoveNestedUiElement(child, nominatedReplacementDefault)`: nominee должна оставаться exact eligible member того же view generation после detach, а registry заменяет current default в том же commit. Missing/invalid nominee возвращает `InvalidDefaultNavigation`; nomination вне этого case также rejected failure-atomically, поэтому обычные removal сохраняют one-argument call. Removal всех eligible members разрешён, оставляет selection nil и current default dormant; следующий `0 -> nonzero` transition снова требует nomination, которая может быть той же exact ссылкой. При successful add текущий valid selection сохраняется, а при nil selection выбирается valid last-selected, иначе current default. При successful removal selected/last-selected removed members и их override links забываются; valid remaining selection/last-selected сохраняется, иначе при Active/unblocked выбирается nominated/current default, а при Paused/blocked selection остаётся nil до обычного restoration trigger. `Clear` registry очищает принадлежащий view selection, восстанавливает authored GUI baseline для возможного pool reuse и забывает default/membership/links/last-selected.

**TS-REQ-009 — token, Background и action authority.** `WindowInputBlocker` является единственным owner per-view token registry, handle validity/behavior, sink binding и effective state; navigator владеет только references/release obligation полученных им system handles. Источники: PRD-REQ-023, PRD-REQ-024, PRD-REQ-025, PRD-REQ-026, PRD-REQ-027, PRD-REQ-069, PRD-REQ-070, PRD-REQ-071, PRD-REQ-072, PRD-REQ-073, PRD-REQ-127, PRD-REQ-180, PRD-REQ-197, PRD-REQ-198, PRD-REQ-204. Проверки: TS-TEST-006, TS-TEST-008, TS-TEST-013.

**TS-REQ-010 — navigation eligibility и focus.** `WindowNavigationRegistry` является единственным owner per-view baselines/links/last selection/focus bookkeeping; navigator только orchestrates Active/Paused commands, blocker callback поставляет effective state. Источники: PRD-REQ-034, PRD-REQ-035, PRD-REQ-081, PRD-REQ-082, PRD-REQ-083, PRD-REQ-103, PRD-REQ-104, PRD-REQ-105, PRD-REQ-106. Проверки: TS-TEST-006, TS-TEST-007, TS-TEST-013.

### 4.6. Level 1 — controller hierarchy и UI events

#### `BaseUiElement`

**Путь:** `src/ReplicatedStorage/Client/UI/Elements/BaseUiElement.luau`.

Constructor принимает только represented root, authored/static or composite `UIElementId`, `UINavigationEnabled` и frozen `UiElementContext`. Context не раскрывает registry object: он содержит три narrow callbacks для atomic subtree claim, exact-owner release и root delivery. Это тот же context, который composition root передаёт project HUD/toast roots; он не создаёт их lifecycle facade. Owned state: final runtime identity, direct `NestedUiElements`, direct-parent callback, optional read-only `WindowElementBinding`, owned connections/resources и `fresh | initialized | clearing | cleared`. Reusable element создаётся без знания окна; только attach под `BaseWindowView` связывает его с единственным binding exact current view generation, а detach снимает binding. Project HUD/toast hierarchy продолжает использовать только injected `UiElementContext`, не получает window binding и не приобретает window lifecycle owner.

```lua
AddNestedUiElement(self, child: BaseUiElement) -> UiVoidResult
AddNestedUiElement(self, child: BaseUiElement, nominatedDefault: GuiObject) -> UiVoidResult
RemoveNestedUiElement(self, child: BaseUiElement) -> UiVoidResult
RemoveNestedUiElement(self, child: BaseUiElement, nominatedReplacementDefault: GuiObject) -> UiVoidResult
```

`AddNestedUiElement` stages весь child subtree: identity claims, parent/bubbling links, binding assignments и every `UINavigationEnabled` member. Для window hierarchy принадлежащий `BaseWindowView` binding coordinator сначала без mutation валидирует полный identity/navigation post-state, включая default invariant. One-argument overload остаётся обычным path; two-argument overload используется ровно для `0 -> nonzero` eligible transition и требует, чтобы `nominatedDefault` представлял eligible controller внутри добавляемого subtree и принадлежал staged post-state exact current window generation. Затем existing `UiElementContext:ClaimSubtree` и заранее проверенный non-yielding navigation publish выполняются до единого observable attach дочернего списка, parent callback, read-only bindings и, для этого transition, current default. После начала commit остаются только infallible table/property publishes; missing/invalid nomination либо иной typed validation error оставляет identity claims, parent/bubbling, navigation membership/default и child bindings полностью неизменёнными.

`RemoveNestedUiElement` тем же образом stages exact owners, claims, removed/remaining eligible members, affected overrides, last selection и post-state default. One-argument overload остаётся для removal, которое не удаляет current default либо оставляет zero eligible members. Только когда removed subtree содержит current default и post-state остаётся nonzero, overload с `nominatedReplacementDefault` обязателен; nominee должна принадлежать exact same-generation staged post-state, находиться вне removed subtree и быть eligible. После полной validation один non-yielding commit заменяет current default, очищает removed membership/override/last-selection state, прекращает bubbling, освобождает exact claims, снимает bindings и отсоединяет parent. Missing/invalid nominee либо другая validation failure оставляет default, navigation state, identity и bubbling полностью прежними. Removal не означает automatic Clear unless caller owns deletion. Fallback search, отдельный reconfigure API, новый общий state machine или public config mutation API не вводятся.

`WindowElementBinding:CanEmitAction()` является единственным window-specific capability, доступным reusable nested handler. Он синхронно возвращает true только когда narrow navigator authority считает exact bound view generation Active/not Paused и его blocker сообщает `effective=false`; stale, clearing или detached binding возвращает false. Binding не раскрывает `WindowId`, concrete view, navigator/blocker/navigation owners либо mutable state. Каждый window-bound base handler вызывает это решение до создания envelope; false завершает handler без event, bubbling или UI-flow mutation. Только после true `EmitAction` создаёт один envelope и синхронно вызывает direct parent `_ReceiveOwnedEvent` without yield. Every parent may synchronously enrich declared payload values, must forward exactly once and cannot stop bubbling; parent bubbling не заменяет pre-emission guard. Reusable children никогда не хранят `WindowId`.

`Clear` method is final/non-overridable, idempotent within one use и synchronous: mark clearing, snapshot direct children, invoke every child `Clear` через separate `UiSyncHookGuard`, так же invoke concrete `OnClear`, disconnect all owned resources, unregister all IDs, detach parent, invalidate action/owned-resource state, mark cleared, then raise one aggregate cleanup error if any step failed. Root `Clear` на cleanup caller boundary также проходит через эту же primitive. Exception либо один yield любого child/`OnClear` немедленно closes только его coroutine, добавляет bounded failure в aggregate и не suppress-ит sibling/resource cleanup. `BaseWindowView` uses `OnClear` to invoke its blocker/navigation cleanup, so generic `BaseUiElement` не становится token/focus owner. Для pooled object следующий `Initialize` явно начинает новое use generation из `cleared`, заново создаёт runtime hierarchy/resources и заявляет IDs; старые resources/claims не восстанавливаются, а handles прежнего blocker generation остаются недействительными.

#### `BaseWindowView`

**Путь:** `src/ReplicatedStorage/Client/UI/Windows/BaseWindowView.luau`.

Specializes `BaseUiElement`, owns `WindowId`, validated root GUI, lifetime своих blocker/navigation controllers, one UI-internal per-generation `WindowElementBinding`, current ViewModel-derived state и optional hooks. `BaseWindowView` binding coordinator only composes atomic element attach/detach across existing identity and navigation owners; он не владеет их registries. Blocker owns token registry/handle validity/sink/effective state; navigation registry owns navigation/focus bookkeeping; injected narrow navigator owns stack orchestration and only references/release obligation своих system-token handles. `CreateView` получает только root и небольшой frozen `WindowConstructionContext = { Navigator, Elements }`; это не service locator и не расширяемый service bag.

```lua
Initialize(self, viewModel: unknown) -> UiVoidResult -- sync, non-yielding, every opening
Pause(self) -> ()                         -- sync default no-op, no parameters
Resume(self) -> ()                        -- sync default no-op, no parameters
Open(self) -> ()                          -- optional awaitable
Close(self) -> ()                         -- optional awaitable
AcquireInputBlock(self) -> UiInputBlockHandle
ConfigureNavigation(self, defaultElement: GuiObject?, overrides: { NavigationOverride }) -> UiVoidResult
AddWindowAsync(self, windowId: WindowId, viewModel: unknown) -> UiValueResult<WindowHandle<BaseWindowView>>
AddWindowTypedAsync<TView, TViewModel>(self, definition: WindowDefinition<TView, TViewModel>, viewModel: TViewModel) -> UiValueResult<WindowHandle<TView>>
CloseWindowAsync(self) -> UiCloseResult
CloseWindowAsync(self, nextWindowId: WindowId, nextViewModel: unknown) -> UiValueResult<WindowHandle<BaseWindowView>>
CloseWindowTypedAsync<TView, TViewModel>(self, definition: WindowDefinition<TView, TViewModel>, viewModel: TViewModel) -> UiValueResult<WindowHandle<TView>>
```

`Initialize` сам проверяет concrete ViewModel, возвращает `UiVoidResult` и копирует/сохраняет нужные поля только в `Success`; `UiSystem` не хранит input afterward. Definition adapter не повторяет эту проверку и только возвращает результат своего единственного вызова `view:Initialize(viewModel)`. Nil является explicit model для no-input window. Constructor выполняется один раз на новый object; pooled re-acquire пропускает constructor, но снова проходит `InitializeView -> Initialize` off-tree до stack add. Initial nested hierarchy проходит ту же binding transaction до успешного завершения `Initialize`; candidate всё ещё остаётся off-tree/non-rendering. `Pause`/`Resume` не получают reason/visibility/neighbor/context. `AcquireInputBlock` только делегирует manual acquire owned blocker-у и не раскрывает его. `BaseWindowView:Clear` сначала инвалидирует current binding generation, затем через blocker owner API освобождает все outstanding manual tokens/инвалидирует их handles и очищает navigation registry до завершения inherited recursive cleanup; поэтому любой surviving handler уже получает false, late release не влияет на reuse, а dynamic membership не переживает use generation. Concrete hooks не должны spawn detached mutations.

Window boundary enriches already-authorized bubbled event exact `WindowId`; base handlers используют только `WindowElementBinding:CanEmitAction()`. Custom methods через valid paused handle разрешены, но inherited action/navigation helpers still reject.

#### `UiElementIdentityRegistry`

**Путь:** `src/ReplicatedStorage/Client/UI/UiElementIdentityRegistry.luau`.

Per-`UiSystem` registry maps live final `UIElementId` to controller, но доступен consumers только через narrow `UiElementContext`. Static ID is author-supplied. Repeated runtime item ID имеет injective byte-length-prefixed representation `ui.runtime/<pathByteLength>:<stableHierarchyPath>/<keyByteLength>:<stableEntityKey>`; length считается оператором Luau `#` по exact bytes, а непустые UTF-8 components не декодируются delimiter-ом. Automatic suffix и separate `UIInstanceId` запрещены. Каждый component ограничен 256 bytes, итоговый ID — 544 bytes; превышение даёт `InvalidUIElementId` до registration. Staged subtree registration validates internal and live collisions before publishing all entries atomically. Clear/remove unregister exact controller identity, never another generation.

#### `UiRootEventStream`

**Путь:** `src/ReplicatedStorage/Client/UI/UiRootEventStream.luau`.

Root receives fully enriched envelope synchronously and calls existing `CommunicationSerialize.inspect(envelope, { MaxBytes = CommunicationConfig.MaxSingleMessageEstimatedBytes })`. Допустимы ровно value types существующего serializer; его встроенные bounded depth/node/issue defaults остаются в силе. UI дополнительно проверяет exact envelope fields, action/catalog membership и ID byte limits, но не копирует adversarial traversal и не создаёт serializer. После успеха root shallow-freezes owned envelope и вызывает private repo `Signal:Fire`. `Fire` scheduling is the boundary: ownership bubbling is complete before publication, но subscribers получают только `UiEventSource:Connect/Once`, обязаны считать envelope/payload read-only и не могут полагаться на listener completion order. UI не deep-copy/freeze arbitrary payload и не определяет результат out-of-contract subscriber mutation.

Envelope fields: `ActionId`, exact live `UIElementId`, optional `WindowId`, optional universal `Payload`. TextBox text never enters payload. Lifecycle events use the same catalog/stream and exact live root ID; `ui.window.paused`/`ui.window.resumed` payload contains only `WindowId` at envelope level, no reason/neighbor/visibility/depth/custom fields. `ui.window.closed` fires before root unregister/Clear as defined in §4.4.

#### Base action catalog и controllers

**Пути:** template source `src/ReplicatedStorage/Client/UI/Actions/UiActionIds.luau`, optional derived source `src/ReplicatedStorage/Project/Client/UI/DerivedUiActionIds.luau`, UI-owned compiler `src/ReplicatedStorage/Client/UI/Actions/UiActionCatalog.luau` и controllers `src/ReplicatedStorage/Client/UI/Elements/Controllers/*.luau`.

Оба source являются duplicate-preserving dense sequences `{ Name, Id }`. Template constants use lowercase `ui.*`: `ui.pointer.entered`, `ui.pointer.exited`, `ui.button.activated`, `ui.textbox.focused`, `ui.textbox.unfocused`, `ui.textbox.confirmed`, `ui.form.submitted`, `ui.form.cancelled`, `ui.window.opened`, `ui.window.paused`, `ui.window.resumed`, `ui.window.shown`, `ui.window.hidden`, `ui.window.closed`. Optional exact derived path may be absent и тогда означает empty source; если он присутствует, только `game.*` accepted. `UiSystem:Initialize` валидирует обе sequences, duplicate `Name`/`Id`, namespace и lowercase dot notation во временных indexes, затем атомарно замораживает definitions и один `UiActionCatalog` с `ByName`/`ById`. Ни generic config infrastructure, ни shared subsystem, ни runtime mutation API не меняются.

Concrete base controllers cover `Frame`, `TextLabel`/text presentation, `ImageLabel`/image presentation, `TextButton`/`ImageButton`, `TextBox`, form и `ScrollingFrame`. They publish only listed semantic actions, not raw movement/scroll/text-change streams. Form owns field references and reads current TextBox values directly for form logic; root event contains no text.

#### Взаимодействие уровня

Window-bound child handler -> read-only `WindowElementBinding:CanEmitAction()` -> synchronous parent ownership chain -> `BaseWindowView` adds `WindowId` -> root catalog/`CommunicationSerialize` validation -> private repo Signal schedules `Connect`/`Once` subscribers. Identity context и navigation registry входят в одну per-window subtree binding transaction до observable attach/detach; они сохраняют собственное state ownership. Navigator alone publishes lifecycle confirmations.

**TS-REQ-011 — controller hierarchy, identity и Clear.** Источники: PRD-REQ-031, PRD-REQ-032, PRD-REQ-033, PRD-REQ-036, PRD-REQ-038, PRD-REQ-039, PRD-REQ-040, PRD-REQ-041, PRD-REQ-042, PRD-REQ-043, PRD-REQ-044, PRD-REQ-074, PRD-REQ-076, PRD-REQ-077, PRD-REQ-090, PRD-REQ-091, PRD-REQ-092, PRD-REQ-093, PRD-REQ-115, PRD-REQ-116, PRD-REQ-117, PRD-NFR-004, PRD-NFR-006. Проверки: TS-TEST-007, TS-TEST-013.

**TS-REQ-012 — bubbling и root Signal.** Источники: PRD-REQ-045, PRD-REQ-046, PRD-REQ-047, PRD-REQ-048, PRD-REQ-049, PRD-REQ-051, PRD-REQ-053, PRD-REQ-084, PRD-REQ-085, PRD-REQ-086, PRD-REQ-087, PRD-REQ-088, PRD-REQ-089, PRD-REQ-109, PRD-REQ-110, PRD-NFR-005. Проверки: TS-TEST-008, TS-TEST-013.

**TS-REQ-013 — base controllers/actions.** Источники: PRD-REQ-054, PRD-REQ-055, PRD-REQ-056, PRD-REQ-057, PRD-REQ-058, PRD-REQ-059, PRD-REQ-060, PRD-REQ-078, PRD-REQ-079, PRD-REQ-080, PRD-REQ-111, PRD-REQ-112, PRD-REQ-113, PRD-REQ-114. Проверки: TS-TEST-013.

### 4.7. Level 1 — authoring contract

#### Canonical data-only window template

**Путь:** `.agents/templates/window-authoring/WindowTemplate.model.json`.

Template root is one `Frame` with named controlled-content container, optional `Background` slot и optional direct `ObjectValue` `BlockObjectRef` pointing to a full-screen transparent `GuiObject` InputSink above interactive content. JSON tree contains no `LuaSourceContainer`. It is an authoring seed/validation fixture, not runtime executable code and not a precreated window under `StarterGui`.

#### Repo-local window-authoring skill

**Путь:** `.agents/skills/window-authoring/SKILL.md`.

Skill requires copying the data-only shape into a project-owned cloud GUI asset, setting asset permissions, keeping `AllowInsertFreeAssets=false`, creating repo-owned concrete `BaseWindowView`, defining ViewModel/runtime witness и один canonical typed per-window definition ModuleScript по owner-specific exact convention §4.3, adding exact returned table to the correct duplicate-preserving authoring sequence, requiring that same module directly from every typed caller, optionally adding project actions only at the exact derived action path, and running focused config/prefab/API/lifecycle/pool/event/navigation checks. Skill запрещает copy/wrapper/lookup вместо same table identity, distinguishes template authoring from derived authoring and never creates `DerivedWindowConfig` in reusable template.

#### Repo-local derived-project initialization skill

**Future implementation paths:** `.agents/skills/project-initialize/SKILL.md` и обязательный по repository skill convention companion `.agents/skills/project-initialize/agents/openai.yaml`. Оба сейчас отсутствуют и создаются только implementation этой feature; никаких иных project-initialization skills, scripts или tooling artifacts UI scope не добавляет. Companion содержит только skill discovery/interface metadata и не владеет initialization logic.

`project-initialize` остаётся orchestration surface существующего derived-project initialization workflow. Его UI-specific step следует `.agents/rules/project-initialization.md` и соответствующей documentation: только в derived repository создаёт exact `src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau` как UTF-8 `--!strict` ModuleScript с valid duplicate-preserving sequence (empty allowed), затем требует successful `scripts/validate-repository-layout.ps1` до implementation/build. Skill и validator проверяют один exact path и не создают альтернативный config/registry/manifest, runtime marker либо repository-kind detector.

#### Derived-project initialization and merge enforcement

Implementation creates `.agents/skills/project-initialize/SKILL.md` plus its required `agents/openai.yaml`, updates `.agents/rules/project-initialization.md`, `.agents/rules/template-updates.md`, relevant initialization documentation и `scripts/validate-repository-layout.ps1` so that:

- reusable template rejects presence of `src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau`;
- an initialized derived repository requires that exact UTF-8 `--!strict` ModuleScript and an empty valid definition sequence is allowed; absence fails repository validation before implementation/build, never `UiSystem` runtime;
- `project-initialize` creates and validates it before first source change/bootstrap and records the new project-owned path in project initialization evidence without treating it as a template-owned divergence;
- upstream merge always preserves the project file, and stops if upstream ever introduces the reserved `src/ReplicatedStorage/Project/` namespace or same path;
- config compiler and authoring skill reference only the exact path; no alternate config, registry or fallback file is accepted.

Optional `src/ReplicatedStorage/Project/Client/UI/DerivedUiActionIds.luau` не является обязательным derived initialization artifact и потому не создаётся пустым: если project нужны `game.*` actions, authoring skill создаёт только этот exact path; template и validator запрещают альтернативные action-source paths.

Implementation documentation cascade ограничен UI-owned contract: новая `.agents/rules/ui.md` и route в `.agents/rules/index.md`; один новый template ADR и `docs/adr/template/README.md`; `docs/UiSystem.md`, `docs/InitializationAndSaveSystem.md`, `docs/TestCoverage.md` и только реально затронутые `README.md`; targeted edits `.agents/rules/project-initialization.md`, `.agents/rules/template-updates.md`, `scripts/validate-repository-layout.ps1`, `.agents/skills/window-authoring/SKILL.md`, `.agents/skills/project-initialize/SKILL.md`, `.agents/skills/project-initialize/agents/openai.yaml` и `.agents/templates/window-authoring/WindowTemplate.model.json`. Другие skills, subsystem rules/docs/ADRs не переписываются без отдельной фактической boundary change.

**TS-REQ-014 — authoring support и derived enforcement.** Источники: PRD-REQ-061, PRD-REQ-062, PRD-REQ-063, PRD-REQ-099, PRD-REQ-100. Проверки: TS-TEST-014, TS-TEST-016.

## 5. Data models и invariants

### 5.1. Canonical types

```lua
type UiError = {
	Code: string,
	WindowId: string?,
	OperationGeneration: number?,
	Phase: string?,
}

type UiValueResult<T> =
	{ Kind: "Success", Value: T }
	| { Kind: "NoOp" }
	| { Kind: "Error", Error: UiError }

type UiVoidResult =
	{ Kind: "Success" }
	| { Kind: "Error", Error: UiError }

type UiCloseResult =
	{ Kind: "Success" }
	| { Kind: "NoOp" }
	| { Kind: "Error", Error: UiError }

type UiInputBlockHandle = {
	Release: (self: UiInputBlockHandle) -> (),
}

type ViewResult<TView> =
	{ Kind: "Success", Value: TView }
	| { Kind: "Error", Error: UiError }

type UiEventSource<T...> = {
	Connect: (self: UiEventSource<T...>, listener: (T...) -> ()) -> DisconnectableConnection,
	Once: (self: UiEventSource<T...>, listener: (T...) -> ()) -> DisconnectableConnection,
}

type UiRootEvent = {
	ActionId: string,
	UIElementId: string,
	WindowId: string?,
	Payload: SerializableValue?,
}

type UiElementClaim = {
	UIElementId: string,
	Owner: BaseUiElement,
}

type WindowConstructionContext = {
	Navigator: WindowNavigatorPort,
	Elements: UiElementContext,
}

type UiElementContext = {
	ClaimSubtree: (self: UiElementContext, claims: { UiElementClaim }) -> UiVoidResult,
	ReleaseSubtree: (self: UiElementContext, claims: { UiElementClaim }) -> UiVoidResult,
	DeliverToRoot: (self: UiElementContext, event: UiRootEvent) -> UiVoidResult,
}

type WindowElementBinding = {
	CanEmitAction: (self: WindowElementBinding) -> boolean,
}

type NavigationOverride = {
	From: GuiObject,
	Direction: "Up" | "Down" | "Left" | "Right",
	To: GuiObject,
}

type WindowDefinition<TView, TViewModel> = {
	WindowId: string,
	AssetId: number,
	CreateView: (root: GuiObject, context: WindowConstructionContext) -> TView,
	TryCastView: (view: BaseWindowView) -> TView?,
	InitializeView: (view: TView, viewModel: TViewModel) -> UiVoidResult,
	LifecyclePolicy: "Destroy" | "Pool",
	VisibilityPolicy: "HideBelow" | "KeepBelow",
	BackgroundPolicy: "None" | "Absorb" | "CloseOnActivate",
	Preload: boolean?,
	PoolOptions: PoolOptions?,
}

type ErasedWindowDefinition = unknown -- private opaque type-only storage; runtime value is the exact canonical definition table

type WindowConfig = {
	Definitions: { ErasedWindowDefinition },
	ByWindowId: { [string]: ErasedWindowDefinition },
}

type PooledWindowRecord = {
	View: BaseWindowView,
	Root: GuiObject,
	ReuseState: "clean" | "dirty" | "failed",
	CurrentUseToken: UiUseToken?,
}
```

`UiValueResult<T>` всегда несёт non-optional `Value` только в ветке `Success`; его `NoOp` применяется к same-window Add/replacement и не притворяется успешным handle. `UiVoidResult` имеет только `Success`/`Error` и никогда не несёт `Value`. Parameterless `CloseWindowAsync` использует отдельный `UiCloseResult`: `Success` означает завершённое закрытие, `NoOp` — немедленно отвергнутый repeat Open/Close того же переходящего окна без lifecycle confirmation, `Error` — завершённую failure branch. `NoOp` не является ни успехом, ни ошибкой. `WindowHandle:GetView()` возвращает `ViewResult<TView>` без `NoOp`. `UiInputBlockHandle` содержит только idempotent `Release`; exact view generation остаётся opaque и никакой read/mutation surface blocker state отсутствует. Это полные result unions для public UI API, и исключения через этот API наружу не используются; только `UiInitializationCommand` адаптирует initialization `Error` к требуемому runner throw. Authoring sources сохраняют duplicates как sequences; после общей успешной компиляции `PoolOptions`, definitions, ordered `Definitions`, `ByWindowId` и сам `WindowConfig` рекурсивно замораживаются до единственного atomic publish. `PoolOptions` обязателен ровно для `Pool` и запрещён для `Destroy`; mutation API и caller-mutation outcome отсутствуют. `WindowId`, `UIElementId`, `UIActionId` — непустые namespace-safe строки; duplicate rules fail closed. `AssetId` — positive integer within Roblox safe integer range. Persisted UI state не вводится.

### 5.2. State invariants

**TS-REQ-015 — window creation order и ViewModel lifetime.** First issue order: canonical template ready -> off-tree clone/factory constructor -> protected synchronous off-tree `definition.InitializeView(view, viewModel)` -> its one exact `view:Initialize(viewModel)` delegation -> same-generation non-yielding parent-to-`WindowHost` plus stack add/Active commit -> optional `Open` -> final visibility -> handle. Pooled issue skips constructor, retains its existing generation lease and repeats the same off-tree adapter/`Initialize`; replacement candidate remains off-tree through preparation and the old window's `Close`. Nil/no-input и typed mismatch follow the same boundary. `UiSystem` discards ViewModel reference after successful `Initialize`; `Clear` removes view-owned runtime copy. Источники: PRD-REQ-151, PRD-REQ-152, PRD-REQ-153, PRD-REQ-162, PRD-REQ-179. Проверки: TS-TEST-010, TS-TEST-011.

**TS-REQ-016 — uniqueness и immutability.** At most one live stack entry per `WindowId`; one live controller per final `UIElementId`; runtime config/cache templates immutable; no auto suffix/implicit override. Источники: PRD-REQ-012, PRD-REQ-033, PRD-REQ-091, PRD-REQ-092, PRD-REQ-093, PRD-REQ-115, PRD-REQ-116, PRD-REQ-117, PRD-REQ-146, PRD-REQ-147, PRD-REQ-159, PRD-REQ-196. Проверки: TS-TEST-002, TS-TEST-003, TS-TEST-013.

**TS-REQ-017 — resource bounds.** One stack-changing operation, one active lease per live pooled entry/quarantine, configured `MaxActive`/`MaxRetained`, one asset cache entry per successfully prepared WindowId, one bounded diagnostic per failure/late result. На `WindowId` существует не более одной unsettled physical asset attempt; anonymous preload не создаёт sticky request record, а следующая generation не стартует, пока предыдущая non-cancellable attempt не settle и её carrier не уничтожен. UI не удерживает stale carrier/view и не создаёт перекрывающиеся retry attempts. Источники: PRD-REQ-014, PRD-REQ-015, PRD-REQ-075, PRD-REQ-159, PRD-REQ-160, PRD-REQ-161, PRD-REQ-175, PRD-REQ-196, PRD-NFR-002. Проверки: TS-TEST-007, TS-TEST-009, TS-TEST-011.

## 6. Диаграмма

```mermaid
sequenceDiagram
    participant Caller as Active Window / empty-stack caller
    participant Nav as WindowNavigator
    participant Loader as WindowAssetLoader
    participant Preload as ContentPreloader
    participant Pool as WindowPoolOwner
    participant Definition as canonical WindowDefinition
    participant View as BaseWindowView
    participant Root as UiRootEventStream

    Caller->>Nav: Add / Close / replacement
    Nav->>Nav: authority, duplicate, gate, generation, deadline
    Nav->>Loader: prepare canonical template
    Loader->>Preload: anonymous Preload({root}, Fail)
    Preload-->>Loader: result or late result
    Loader-->>Nav: cached template / typed error
    Nav->>Pool: acquire record lease or create destroy-view
    Pool-->>Nav: off-tree record + lease + UI use token
    Nav->>Definition: InitializeView(View, ViewModel) while off-tree
    Definition->>View: Initialize(same ViewModel)
    View-->>Definition: UiVoidResult
    Definition-->>Nav: same UiVoidResult
    Nav->>View: Pause / Close old top per operation
    Nav->>Nav: generation check; parent + stack Active commit
    Nav->>View: Open active candidate
    View-->>Nav: transition completion
    Nav->>Nav: generation check + final visibility
    Nav->>Root: applied lifecycle events
    Nav-->>Caller: success handle / no-op / typed error
```

## 7. Behaviour flows

### 7.1. Initialization

1. Manifest initializes Assets/startup preload/pooling/players through existing commands.
2. `UiInitializationCommand` asks `UiSystem` to validate/merge/freeze both window-definition sequences and, separately, template plus optional exact-path action sequences atomically, then unwraps its `UiVoidResult`.
3. `UiRootController` creates/validates one root off-tree and commits it.
4. `WindowNavigator`, identity/event/navigation owners initialize; no window is created.
5. All `Preload=true` definitions start concurrently; `UiSystem` waits until all settle or one three-second startup cutoff. Failure is diagnostic and retryable, not bootstrap fatal.
6. Structural/config `Error` tears down candidate root/services; command throws `UiInitializationFailed:<Code>`, existing runner stops with failed `UI` command, and client bootstrap sets `ClientInitializationFailed` without `ClientInitialized` or usable partial UI service. Eager delivery failure does not enter this branch.

### 7.2. External first window and later domain event

Empty-stack client system calls `UiSystem:AddWindowAsync` or `UiSystem:AddWindowTypedAsync`. Nonempty-stack external call fails `NotActiveWindow`. Domain system publishes its own domain event without stack effect; subscribed Active Window decides whether to call inherited Add/Close/replacement helper. This preserves causal authority without moving domain logic into UI.

### 7.3. Cleanup containment

Navigator invalidates public handle/stack authority, commands the view navigation registry inactive and releases only navigator-held pause/transition handles through that view's blocker before cleanup. `BaseWindowView:Clear` then invalidates its `WindowElementBinding` generation, makes its blocker release every outstanding manual token before sink/controller teardown, set the sink to `None`, clear its per-view token registry/invalidate every manual/inert/stale `UiInputBlockHandle`, and makes its navigation registry restore baselines and clear selection/default/links/membership/last-selected, including dynamically registered members; inherited `BaseUiElement:Clear` attempts every nested/resource step and aggregates failures. Thus no child can emit through a failed sibling cleanup, late/double handle release is a no-op, and no binding/navigation membership survives pool reuse. Navigator never mutates either controller's internal registry. For destroy policy navigator always attempts final destroy even when Clear failed. For pool policy exact current UI use token marks the record `clean` only after successful complete Clear; Clear failure marks it `failed`. Navigator then routes the exact active lease through existing `TryReleaseToPool`; adapter accepts only `clean`/no-token, while `dirty`/`failed` raises so existing Pool behavior destroys the object and invalidates the lease. Returned operation is `CleanupFailed` if any cleanup/destroy/release step failed, but stack recovery remains committed and inaccessible objects are never reissued.

### 7.4. Timeout

Deadline callback invalidates operation generation first, commands the affected navigation registry inactive, releases navigator-held transition handle through the affected blocker, then executes remaining base recovery synchronously and releases gate/returns. Destroy view is immediately cleared/destroyed. Pooled view whose transition hook still runs is detached/quarantined with its active lease; its blocker owns disabling the now-nonlive sink and retains any manual handles until delayed Clear. When hook eventually settles, only quarantine cleanup may run; stale transition continuation cannot publish or commit. A never-settling hook intentionally consumes one active lease until UI teardown.

## 8. Implementation constraints

### 8.1. Failure taxonomy и observability

**TS-REQ-018 — typed errors.** Stable codes include at least `UiRootMalformed`, `WindowConfigMalformed`, `DuplicateWindowId`, `UnknownWindowId`, `ActionCatalogMalformed`, `AssetLoadFailed`, `PrefabMalformed`, `InvalidBackground`, `ForbiddenExecutableDescendant`, `ContentPreloadFailed`, `ViewFactoryFailed`, `ViewModelMismatch`, `TypedDefinitionMismatch`, `InitializeFailed`, `NotActiveWindow`, `NotTopWindow`, `Busy`, `Timeout`, `OpenFailed`, `CloseFailed`, `StaleHandle`, `InvalidDefaultNavigation`, `InvalidUIElementId`, `DuplicateUIElementId`, `PayloadNotSerializable`, `CleanupFailed`. Error payloads never contain instances, ViewModel/user text or arbitrary hook data. `UiCloseResult` branch `NoOp` не содержит `UiError`, не логируется как failure и не считается `Success`; `UiLifecycleIdentityInvariant` является bounded developer diagnostic, а не отдельной recovery/result branch. `UiInitializationFailed:<UiError.Code>` является только stable command diagnostic для existing runner, не новым `UiError` code/result branch и не public UI exception. Источники: PRD-REQ-128, PRD-REQ-147, PRD-REQ-148, PRD-REQ-149, PRD-REQ-168, PRD-REQ-169, PRD-REQ-189. Проверки: TS-TEST-002, TS-TEST-007, TS-TEST-009, TS-TEST-010, TS-TEST-015.

Sync hook exception/yield не добавляет public result code: Initialize uses existing `InitializeFailed`, Clear/OnClear uses existing aggregate `CleanupFailed`, а Pause/Resume используют тот же bounded custom-hook developer diagnostic с `Phase` и `Reason`, который уже требуется для isolated hook failure. Это не вводит новую recovery branch или public API.

Logger records bounded one-line diagnostics with `WindowId`, operation generation, phase, error code, attempt ordinal, lifecycle policy and `Quarantined` boolean. It never logs TextBox content or complete payload/ViewModel. Expected injected failures are asserted by tests; unexpected warnings/errors fail release. Metrics are logs/counters only; analytics remains outside feature.

### 8.2. Security and trust

**TS-REQ-019 — cloud trust boundary.** Only frozen definition `AssetId` reaches `AssetService`. Loader rejects unexpected wrapper/root shape and every `LuaSourceContainer`; returned model remains sandboxed and no capability is granted. Repo-owned source supplies every constructor/factory/controller. Runtime neither loads arbitrary input nor claims ownership verification. `AllowInsertFreeAssets` is an Experience deployment setting, not runtime-readable authority; mandatory `TS-EVIDENCE-ALLOWINSERT-001` therefore observes it read-only in the exact selected published place independently of any AssetId or cloud load. Источники: PRD-REQ-009, PRD-REQ-037, PRD-REQ-148, PRD-REQ-149. Проверки: TS-TEST-012, TS-TEST-014, TS-TEST-016.

**`TS-EVIDENCE-LOCAL-FIXTURE-001` — mandatory local contract evidence.** The single checked-in data-only GUI fixture is `src/ReplicatedStorage/Client/UI/TestFixtures/WindowAssetFixture.model.json`, mapped at runtime as `ReplicatedStorage.Client.UI.TestFixtures.WindowAssetFixture`; its one canonical test definition is `src/ReplicatedStorage/Client/UI/Config/Definitions/WindowAssetFixtureDefinition.luau` with fixed test-only `WindowId = "ui.test.window-asset-fixture"` and positive allowlisted `AssetId = 1001`. Both `UiSystemTestRunner` and the client Play setup direct-require that exact definition table, place it as the sole entry of a duplicate-preserving `TemplateWindowConfig`-shaped sequence, compile it through the production `WindowConfigCompiler`, and pass the exact frozen `ByWindowId` value to the production `WindowAssetLoader`. The injected local `AssetBackend:LoadAssetAsync` asserts exact `1001` and returns only `WindowAssetFixture:Clone()`; loader still performs wrapper/root validation, recursive executable rejection, anonymous production `ContentPreloader` call and cache reuse.

The exact client composition owner is test-only ModuleScript `src/ReplicatedStorage/Client/UI/TestFixtures/WindowAssetFixturePlaySetup.luau`. In the explicitly selected Play client, the existing Studio client-execution boundary calls `require(ReplicatedStorage.Client.UI.TestFixtures.WindowAssetFixturePlaySetup).start()`; returned local session owns the isolated test host, production loader instance, fixture clones, connections and focus snapshot, exposes no Remote or production service registration, and its mandatory `Finish()` performs assertions plus failure-safe cleanup before returning bounded evidence. No auto-running `LocalScript`, server/client bridge, second bootstrap, second config or alternate loader exists. These fixture/setup artifacts are test inputs only: production `ClientManifest` and manifest-owned `UiSystem` are not replaced or mutated, default production `TemplateWindowConfig` stays empty, and production `AssetService:LoadAssetAsync(definition.AssetId)` capability is unchanged.

**`TS-EVIDENCE-ALLOWINSERT-001` — mandatory read-only exact-place evidence.** Operator follows repository identity rules to select the exact already-published canonical Studio instance, proves its nonzero `game.PlaceId`/`game.GameId` match recorded top-level IDs and `servePlaceIds`, opens Experience Settings read-only and records the visible disabled “Allow Loading Third Party Assets”/`AssetService.AllowInsertFreeAssets=false` state, UTC time and reviewer. This gate requires no approved AssetId, performs no load, save, publish, attachment or setting mutation, and fails closed if the selected identity or disabled state cannot be observed exactly.

**`TS-SMOKE-CLOUD-001` — conditional external smoke.** If an external GUI fixture and its exact `AssetId` have already been explicitly approved, one positive load MAY additionally run with the production backend in that exact selected published place. Without such prior approval, this smoke is reported as `not run: no approved external fixture/AssetId` and is not a release failure; no AssetId, approval or successful result may be fabricated. Asset denial, malformed wrapper/root and executable-descendant branches remain deterministic local injected-fixture cases rather than additional cloud assets.

### 8.3. Compatibility, rollout и cleanup

**TS-REQ-020 — compatibility.** Public modules keep `--!strict`; no new external dependency, remote, persistence or bootstrap. Existing `PoolModule`, `ContentPreloader`, `Signal`, `PlayersModule`, `CommunicationSerialize`, `AssetRegistry`, loading UI and pool Clear APIs preserve behavior. Release target is PC, touch/mobile and gamepad/console. Documentation/rule work ограничено перечнем §4.7; neighboring subsystem rules, APIs и docs не меняются только ради UI. Источники: PRD-REQ-004, PRD-REQ-037, PRD-REQ-123, PRD-REQ-129, PRD-REQ-130. Проверки: TS-TEST-012, TS-TEST-015.

Rollout order: types/config compiler -> controller hierarchy/events -> root/composition -> loader/pools -> navigator/focus -> authoring assets/rules/validators -> tests/docs -> mandatory `TS-EVIDENCE-LOCAL-FIXTURE-001` -> mandatory local client/device `TS-TEST-012` -> mandatory read-only `TS-EVIDENCE-ALLOWINSERT-001` -> conditional `TS-SMOKE-CLOUD-001` only when an approved external fixture/AssetId already exists. Default production `TemplateWindowConfig` remains empty; therefore integrating subsystem does not display a window until an explicit production definition is authored/requested.

`UiSystem:Destroy` invalidates gate/window handles, releases navigator-held system token handles through their blockers, clears views in reverse so each blocker invalidates its own remaining token handles and each navigation registry clears its own focus bookkeeping, force-removes owned pools (including quarantines), destroys cached templates/root signal/root GUI and aggregates failures. It is idempotent and not invoked on respawn. No data migration is required; derived-project initialization creates the single new project-owned config path.

## 9. Обязательный подход

- Все modules из UI bounded context сохраняют `--!strict` и constructor injection.
- Все source execution остаётся в едином client bootstrap/manifest.
- Все yielding cloud/preload/transition boundaries используют injected clock/scheduler in tests и generation recheck in production.
- Все synchronous lifecycle hooks (`Initialize`, root/recursive `Clear`, `OnClear`, `Pause`, `Resume`) вызываются через один private `UiSyncHookGuard`: inspectable coroutine, `xpcall`, ровно один `resume`, success только при `dead`, immediate `coroutine.close` при `suspended`; continuation не хранится и не resume-ится.
- `WindowNavigator` единолично владеет stack orchestration, operation/handle generations, Active/Paused/visibility commits и lifecycle confirmations; из blocking он только хранит и освобождает полученные им system pause/transition handles.
- Каждый `WindowInputBlocker` единолично владеет per-view token registry, handle validity/behavior, sink binding и effective-blocking state; каждый `WindowNavigationRegistry` — per-view baselines/links/last selection и focus bookkeeping. `BaseWindowView` владеет lifecycle обоих controllers; navigator только сообщает им orchestrated state changes и владеет references/release obligation своих system pause/transition handles.
- Manual blocking доступен concrete window только как inherited `BaseWindowView:AcquireInputBlock()` и generation-safe self-release `UiInputBlockHandle`; blocker/registry/effective state наружу не раскрываются.
- Один per-generation `WindowElementBinding` принадлежит `BaseWindowView`, atomically связывает/отвязывает identity, parent bubbling и dynamic navigation membership и раскрывает reusable handler только read-only `CanEmitAction()`; registry state остаётся у существующих owners.
- Конкретные pool adapters принадлежат `WindowPoolOwner`; UI cleanup выполняется до normal Release, а contaminated object не возвращается в available set.
- Ownership bubbling остаётся синхронным direct-call chain; repo Signal используется ровно на root publication boundary.
- Window/action authoring сохраняет duplicates в sequences; UI startup единым commit публикует frozen config/catalog, а public mutation surface отсутствует.
- Event surface повторяет `PlayersModule` shape `Connect`/`Once`; project HUD/toast получают hosts и narrow frozen `UiElementContext` только через manifest composition.
- Event envelope проходит существующий `CommunicationSerialize.inspect`; UI добавляет только собственные shallow schema/catalog/ID checks.

## 10. Запрещённые решения

- Standalone startup `Script`/`LocalScript`, второй bootstrap или filesystem-discovered initialization.
- Runtime owner verification, arbitrary AssetId, `InsertService` fallback, executable cloud prefab, capability widening или `AllowInsertFreeAssets=true`.
- Второй runtime window config/registry/manifest, `TemplateId`, phantom-generic typed API без canonical definition identity.
- Global heterogeneous pool, release by raw object, `DiscardLease`, изменение pool adapter/core/Clear contracts или await inside adapter.
- Очередь stack operations, Back/history, восстановление уже удалённого replaced window, intermediate visibility recompute или generic rollback custom hook effects.
- Universal HUD controller/registry/lifecycle и toast queue/timer/lifecycle.
- Bubbling через asynchronous Signal на каждом уровне, хранение `WindowId` в reusable child или публикация TextBox text/raw high-frequency input.
- Auto suffix duplicate UI IDs, mandatory `UIInstanceId`, Character-driven reset или global input overlay при отсутствии Background/InputSink geometry.
- Generic config framework, alternate/fallback action source, новый serializer, deep adversarial validator или caller-mutation recovery contract.
- Named/sticky ContentPreloader request, изменение/eviction/cancellation его API либо новый overlapping physical retry при unsettled non-cancellable attempt.
- Global descendant/input watcher, continuous geometry/Z polling, изменение общего `Signal`, service locator или fallback navigation search.
- Новый Remote, standalone test `LocalScript`, Studio bridge или exhaustive Cartesian/platform test matrix для UI verification.

## 11. Assumptions и открытые вопросы

### Assumptions

- **ASSUMP-001:** Production client environment exposes the PRD-approved `AssetService:LoadAssetAsync` boundary. Backend exception/availability failure is handled as `AssetLoadFailed`; no alternate loader is introduced.
- **ASSUMP-002:** `Enum.ScreenInsets.CoreUISafeInsets` remains the repository-selected interpretation of “platform safe area”; it includes interactive Core UI/device obstructions and updates engine-side without a custom viewport poller.

### Accepted residual risks

- Roblox не предоставляет cancellation для уже начатого `LoadAssetAsync`/content preload: зависшая physical attempt блокирует новую attempt того же `WindowId` до settle или `UiSystem:Destroy`. Это сознательный bounded-resource tradeoff против unbounded overlapping retries.
- Runtime не может доказать asset owner или Experience setting; `TS-EVIDENCE-LOCAL-FIXTURE-001` не выдаётся за такое доказательство. `TS-EVIDENCE-ALLOWINSERT-001` отдельно и обязательно доказывает только read-only exact-place setting state без AssetId/cloud load, а `TS-SMOKE-CLOUD-001` остаётся conditional deployment evidence при уже одобренном external fixture/AssetId; отсутствие такого одобрения не блокирует release.
- Local `Connect`/`Once` subscribers считаются trusted и обязаны не мутировать envelope/payload. UI shallow-freezes owned envelope, но не deep-copy/freeze произвольный сериализуемый payload; поведение нарушившего этот contract subscriber не определяется.

### Open Questions

Неразрешённых product/scope/boundary/ownership вопросов нет. Assumptions и принятые residual risks выше являются platform/implementation constraints и не расширяют product behavior.

## 12. Детерминированная верификация

### 12.1. Suites и gates

Добавляется только server-side ModuleScript `src/ServerScriptService/Tests/UiSystemTestRunner.luau`, использующий существующий `TestHarness`, fresh module instances, injected fake clock/scheduler/asset backend/content preloader/GuiService и failure-safe cleanup scope. Он регистрируется в существующем `AllTestsRunner`; Remote, standalone `LocalScript` и test bridge не создаются. Каждая строка §12.2 реализуется representative deterministic partitions по значимым boundary classes (`Success`/`NoOp`/`Error`, current/stale generation, valid/missing/malformed reference), а не полным Cartesian произведением состояний, platforms и failure timings. UI suite не обращается к real cloud.

**TS-STATIC-001 — typed navigation evidence gate.** Это отдельный static-type gate, а не runtime case `TS-TEST-010`. Он использует Roblox Studio Script Analysis либо уже доступный project Luau analysis; новый analyzer/dependency не устанавливается. Если обе границы недоступны, gate остаётся blocked и не заменяется Rojo build: `rojo build` не является Luau type-check oracle.

Gate временно помещает в mapped UI source три small `--!strict` fixtures, не входящие в production commit: one positive fixture с direct-require canonical definitions и корректными `AddWindowTypedAsync`/`CloseWindowTypedAsync` calls, отдельный Add-negative и отдельный replacement-negative. Negative fixtures добавляются и анализируются по одному: каждая передаёт model окна B с canonical definition окна A в exact marked argument line. Exact oracle для positive fixture — zero diagnostics; для каждой negative fixture — ровно один type-mismatch diagnostic на marked call, который идентифицирует incompatible argument #2 (`BViewModel` не assignable to `AViewModel`), и zero unrelated production diagnostics. Evidence фиксирует analyzer/Studio version, fixture path/hash, marked line и raw diagnostic text; версионное wording не скрывается за paraphrase.

После снятия evidence оба negative fixtures и positive fixture обязательно remove/revert-ятся. Analysis запускается ещё раз на ordinary tree и должен иметь zero introduced diagnostics; `git status`/дифф доказывают отсутствие fixtures до обычных runtime/repository/Rojo gates. Источники: PRD-REQ-166, PRD-REQ-201, PRD-REQ-202, PRD-REQ-203, PRD-NFR-001, PRD-AC-100, PRD-AC-102.

После implementation обязательны:

1. `TS-STATIC-001` с mandatory fixture cleanup/reanalysis evidence.
2. Focused `UiSystemTestRunner`, затем один existing `AllTestsRunner` release pass; оба завершаются с `failed = 0`.
3. `scripts/validate-repository-layout.ps1`, targeted UI authoring/config fixtures, feature workflow validators, `git diff --check` и Rojo build во временный path; Rojo result не выдаётся за static-type evidence.
4. `TS-TEST-012` в уже открытой и явно выбранной canonical Studio instance использует один fresh local Play и одно выбранное client/device-emulation target. Existing Studio client-execution boundary вызывает exact `WindowAssetFixturePlaySetup.start()` path из `TS-EVIDENCE-LOCAL-FIXTURE-001`; setup напрямую требует `WindowAssetFixtureDefinition`, подаёт `{ definition }` как единственную `TemplateWindowConfig`-shaped sequence в canonical `WindowConfigCompiler`, затем передаёт exact frozen definition и injected clone-only backend в production `WindowAssetLoader`. Никакой второй config/loader, Remote, standalone `LocalScript` или test bridge не создаётся; production `ClientManifest`/`UiSystem` не заменяются. Checklist наблюдает: (a) ordinary server/client bootstrap и `ClientInitialized=true`; (b) один production `UiRoot`, три пустых/упорядоченных hosts и сохранение root после respawn; (c) local loader возвращает exact data-only fixture template, повторный запрос использует cache, а два clone roots различны; (d) fixture-owned isolated test host выполняет open/close presentation, `Background.Activated`, blocker effective-state change, pointer activation и один gamepad default/override focus route в одном emulated safe-area viewport без parenting в production `WindowHost`; (e) mandatory session `Finish()` оставляет production hosts/selection без fixture descendants и server/client Output без unexpected diagnostics. Evidence фиксирует selected Studio/client identity, device profile, fixture/setup/definition hashes, exact frozen `WindowId`/`AssetId`, load/preload/cache counters и observable checklist results.
5. `TS-TEST-016`/`TS-EVIDENCE-LOCAL-FIXTURE-001` в `UiSystemTestRunner`: тот же checked-in fixture и exact direct-required definition проходят canonical compile и production `WindowAssetLoader` через injected clone-only backend; проверяются `WindowId`/allowlisted `AssetId`, exact definition identity, wrapper/root, recursive data-only rejection, anonymous content preload, cache reuse и cleanup без network/external asset.
6. `TS-EVIDENCE-ALLOWINSERT-001`: mandatory read-only observation `AllowInsertFreeAssets=false` в exact selected published place; gate не требует AssetId и не выполняет load или cloud mutation.
7. `TS-SMOKE-CLOUD-001`: только при уже отдельно approved external fixture/AssetId выполняется один positive production-backend cloud load. Без approval результат `not run: no approved external fixture/AssetId` не является failure; AssetId и результат не выдумываются.

### 12.2. Traceable representative acceptance partitions

| Test ID | Deterministic observable contract | Source acceptance |
|---|---|---|
| TS-TEST-001 | One `UiRoot`, three ordered hosts, empty `WindowHost`, loading UI separate, atomic malformed-host failure, host/context injection without HUD/toast registry, safe-area/respawn behavior | PRD-AC-001, PRD-AC-036, PRD-AC-038, PRD-AC-040, PRD-AC-041, PRD-AC-042, PRD-AC-048, PRD-AC-050 |
| TS-TEST-002 | Duplicate-preserving authoring sequences; total absence of exact `DerivedWindowConfig` path succeeds as empty source without runtime repository-kind detection; present valid source joins one atomic merge; each config sequence and typed caller direct-require the same per-window module, `rawequal(sourceEntry, callerDefinition)` and `rawequal(frozenByIdEntry, callerDefinition)` are true, while an equal-field copy has different identity; exact nested frozen definitions/PoolOptions/index, duplicate/malformed rejection and no mutation API | PRD-AC-028, PRD-AC-053, PRD-AC-054 |
| TS-TEST-003 | Duplicate stack ID before load/acquire; reentrant same-window Add/replacement returns value `NoOp`; parameterless repeat Close returns `UiCloseResult` branch `NoOp`; neither waits, confirms lifecycle, creates a second instance/lease/transition nor changes the original completion | PRD-AC-003, PRD-AC-049 |
| TS-TEST-004 | Pure final-stack visibility, KeepBelow/HideBelow pause/show/hide order, top-only close and no intermediate lower-prefix events | PRD-AC-004, PRD-AC-005, PRD-AC-015, PRD-AC-074, PRD-AC-080, PRD-AC-081, PRD-AC-082, PRD-AC-083, PRD-AC-088, PRD-AC-098 |
| TS-TEST-005 | Add/Close/replacement happy paths, lower-prefix preservation, one final recompute, empty-stack first authority and non-top/external rejection | PRD-AC-060, PRD-AC-065, PRD-AC-066, PRD-AC-071, PRD-AC-078 |
| TS-TEST-006 | Concrete view acquires two independent manual blocks only through `BaseWindowView:AcquireInputBlock()` and self-releases their `UiInputBlockHandle`s; valid/missing ref, last-release, double/stale generation partitions prove blocker-only registry ownership without exposing effective state. Also composes navigator state/read-only binding action rejection with optional GuiButton Background, and covers dynamic eligible bind/unbind: successful `0 -> nonzero` nominated default; successful removal of current default with same-generation eligible replacement; missing/removed/foreign/non-eligible replacement rollback; automatic links, override cleanup/dormancy/rebind and deterministic last/default/nil focus restoration | PRD-AC-006, PRD-AC-007, PRD-AC-008, PRD-AC-017, PRD-AC-018, PRD-AC-019, PRD-AC-022, PRD-AC-030, PRD-AC-095, PRD-AC-096, PRD-AC-097, PRD-AC-104 |
| TS-TEST-007 | Idempotent recursive Clear after dynamic attach/remove; deterministic child `Clear` and recursive `OnClear` one-yield fixtures capture their own thread, prove guard returns `CleanupFailed`, explicit later `coroutine.resume(capturedThread)` fails and post-yield mutation stays zero, while sibling/resource cleanup still completes; navigator releases only its system handles; public-view outstanding manual handles are released/invalidated before blocker sink teardown and their late `Release()` is a no-op; binding generation rejects actions and navigation registry restores/removes every dynamic member/default and clears focus bookkeeping even when one child cleanup fails; exact UI use-token safety; `clean`/`dirty`/`failed` release partitions; sibling cleanup and contaminated-record destruction | PRD-AC-009, PRD-AC-013, PRD-AC-020, PRD-AC-067, PRD-AC-069, PRD-AC-076 |
| TS-TEST-008 | Pause/Resume default/override, base authority independent of blocker, isolated hook error, plus separate deterministic Pause and Resume one-yield fixtures whose captured closed threads reject explicit later resume and never execute post-yield mutation; base state/event and bounded developer diagnostic remain phase-appropriate; all opened/paused/resumed/shown/hidden/closed events only after applied state with exact live root `UIElementId`, no confirmation for rejected pre-mutation request, closed-before-unregister/Clear, one invariant diagnostic and custom paused method access | PRD-AC-023, PRD-AC-079, PRD-AC-085, PRD-AC-086, PRD-AC-091, PRD-AC-092, PRD-AC-093, PRD-AC-099 |
| TS-TEST-009 | One absolute deadline, Busy, transition token, stale continuation suppression, ordinary error vs pooled quarantine vs destroy timeout, never-ending lease | PRD-AC-039, PRD-AC-051, PRD-AC-059, PRD-AC-072, PRD-AC-084, PRD-AC-089, PRD-AC-103 |
| TS-TEST-010 | Runtime-only universal/typed Add/replacement value results, direct-required canonical definition identity/cast, concrete ViewModel/nil, valid/stale handles; equal-field copied definition fails identity, universal wrong-`unknown` values reach the concrete view's runtime `ViewModelMismatch`, and a deterministic Initialize one-yield fixture returns `InitializeFailed`, cleans the candidate, rejects explicit later resume of the captured closed thread and never executes post-yield mutation; parameterless Close returns exact `UiCloseResult` `Success`/`NoOp`/`Error` branches and never returns another handle. Compile-time mismatch evidence belongs only to `TS-STATIC-001` | PRD-AC-057, PRD-AC-064, PRD-AC-065, PRD-AC-075, PRD-AC-077, PRD-AC-090, PRD-AC-100, PRD-AC-101, PRD-AC-102 |
| TS-TEST-011 | Empty `WindowHost` known-window clone or homogeneous pool lease from a pool created with canonical `MaxActive`/`MaxRetained`; candidate stays `Parent=nil` through constructor/acquire, Initialize and replacement preparation, then parents only with stack/Active commit. Representative config/asset/prefab/preload/cast/Initialize pre-stack failures preserve stack/visibility and, whenever a candidate exists, clean it via configured lifecycle; also anonymous single-flight preload, cache and pooled reuse order | PRD-AC-002, PRD-AC-016, PRD-AC-055, PRD-AC-056, PRD-AC-058, PRD-AC-061, PRD-AC-062, PRD-AC-063, PRD-AC-070, PRD-AC-073, PRD-AC-087, PRD-AC-094 |
| TS-TEST-012 | One fresh selected canonical local Play and one client/device-emulation target invoke `src/ReplicatedStorage/Client/UI/TestFixtures/WindowAssetFixturePlaySetup.luau` only through the existing Studio client-execution boundary. `start()` direct-requires `WindowAssetFixtureDefinition`, compiles its sole `TemplateWindowConfig`-shaped sequence with canonical `WindowConfigCompiler`, and passes the exact frozen definition plus `TS-EVIDENCE-LOCAL-FIXTURE-001` clone-only backend to production `WindowAssetLoader`; the returned session's mandatory `Finish()` owns assertions and cleanup. No production manifest/service replacement, second config/loader, Remote, standalone `LocalScript` or bridge exists. Observables are ordinary bootstrap/one production root/three empty ordered hosts, respawn persistence, exact fixture load/preload/cache counters and two distinct clones, isolated-host open/close presentation, Background/blocker/pointer behavior, one gamepad default/override focus route, one safe-area change, complete fixture/focus teardown and no unexpected server/client diagnostics | PRD-AC-036, PRD-AC-041, PRD-AC-042, PRD-AC-048 |
| TS-TEST-013 | Base controllers and dynamic add/remove commit identity claims, parent bubbling, per-window read-only binding and eligible navigation state together or not at all: `0 -> nonzero` add commits nominated default, while removal of current default with remaining eligible members commits nominated replacement plus membership/override/last-selection cleanup. Missing/invalid add or replacement nomination leaves every staged surface unchanged. Attached Active/unblocked handler bubbles once, while Paused/blocked/stale/detached handler publishes nothing and never sees `WindowId` or owners. Also covers atomic/injective byte-length IDs, exact action-source merge/catalog, existing serializer bounds, serializable/no-text payload, unchanged HUD/toast context path and `Connect`/`Once`-only non-blocking root listeners | PRD-AC-010, PRD-AC-011, PRD-AC-012, PRD-AC-021, PRD-AC-024, PRD-AC-025, PRD-AC-032, PRD-AC-033, PRD-AC-034 |
| TS-TEST-014 | Data-only window template/authoring skill and exact future `project-initialize` `SKILL.md` plus required `agents/openai.yaml`; no LuaSourceContainer/LocalScript; template absence of derived config is valid, while initialized-derived missing exact path is rejected by repository validation before implementation/build, not UiSystem runtime; one canonical config mapping, targeted derived creation/preservation and frozen allowlists | PRD-AC-014, PRD-AC-028, PRD-AC-055 |
| TS-TEST-015 | Clean manifest/bootstrap composition, one root service, player lifetime and narrow HUD/toast host plus `UiElementContext` injection. Focused fake `UiSystem:Initialize` `Success` returns from `UI` command; `Error` is unwrapped to stable `UiInitializationFailed:<Code>`, makes existing runner fail `CommandId = "UI"`, yields client `ClientInitializationFailed` without `ClientInitialized`, skips later commands and exposes no usable partial UI service | PRD-AC-001, PRD-AC-038, PRD-AC-040, PRD-AC-041, PRD-AC-050 |
| TS-TEST-016 | Mandatory automated `UiSystemTestRunner`/`TS-EVIDENCE-LOCAL-FIXTURE-001` uses checked-in data-only `src/ReplicatedStorage/Client/UI/TestFixtures/WindowAssetFixture.model.json` and direct-required `src/ReplicatedStorage/Client/UI/Config/Definitions/WindowAssetFixtureDefinition.luau`. The sole `TemplateWindowConfig`-shaped sequence is compiled by canonical `WindowConfigCompiler`; its exact frozen definition (`WindowId = "ui.test.window-asset-fixture"`, allowlisted `AssetId = 1001`) is loaded by production `WindowAssetLoader` through the injected backend that asserts `1001` and returns only a fixture clone. Observable assertions cover exact definition identity, wrapper/root shape, recursive absence/rejection of `LuaSourceContainer`, anonymous production content preload, cache reuse, distinct clones and cleanup. Default production `TemplateWindowConfig` remains empty and production `AssetService:LoadAssetAsync(definition.AssetId)` is unchanged. Mandatory `TS-EVIDENCE-ALLOWINSERT-001` separately records read-only exact-place `AllowInsertFreeAssets=false` without AssetId/load/mutation. `TS-SMOKE-CLOUD-001` is conditional only on an already-approved external fixture/AssetId; without approval it is not run, does not fail release and is never fabricated | PRD-AC-055 |

### 12.3. Functional requirements coverage manifest

| Technical owner | Semantically realized source requirements | Verification |
|---|---|---|
| TS-REQ-001 | PRD-REQ-001, PRD-REQ-002, PRD-REQ-003, PRD-REQ-004, PRD-REQ-005, PRD-REQ-006, PRD-REQ-007, PRD-REQ-008, PRD-REQ-096, PRD-REQ-097, PRD-REQ-123, PRD-REQ-125, PRD-REQ-128, PRD-REQ-129, PRD-REQ-130, PRD-REQ-131, PRD-REQ-138, PRD-REQ-141, PRD-REQ-142 | TS-TEST-001, TS-TEST-012, TS-TEST-015 |
| TS-REQ-002 | PRD-REQ-009, PRD-REQ-010, PRD-REQ-011, PRD-REQ-012, PRD-REQ-013, PRD-REQ-014, PRD-REQ-099, PRD-REQ-100, PRD-REQ-146, PRD-REQ-147, PRD-REQ-150, PRD-REQ-201, PRD-REQ-202 | TS-TEST-002, TS-TEST-003, TS-TEST-010, TS-TEST-014 |
| TS-REQ-003 | PRD-REQ-015, PRD-REQ-037, PRD-REQ-148, PRD-REQ-149, PRD-REQ-158, PRD-REQ-159, PRD-REQ-160, PRD-REQ-161, PRD-REQ-196 | TS-TEST-003, TS-TEST-011, TS-TEST-012, TS-TEST-014, TS-TEST-016 |
| TS-REQ-004 | PRD-REQ-014, PRD-REQ-015, PRD-REQ-016, PRD-REQ-074, PRD-REQ-075, PRD-REQ-076, PRD-REQ-077, PRD-REQ-152 | TS-TEST-002, TS-TEST-007, TS-TEST-011 |
| TS-REQ-005 | PRD-REQ-017, PRD-REQ-064, PRD-REQ-065, PRD-REQ-066, PRD-REQ-139, PRD-REQ-140, PRD-REQ-156, PRD-REQ-163, PRD-REQ-164, PRD-REQ-165, PRD-REQ-166, PRD-REQ-167, PRD-REQ-174, PRD-REQ-175 | TS-TEST-003, TS-TEST-005, TS-TEST-009, TS-TEST-010 |
| TS-REQ-006 | PRD-REQ-018, PRD-REQ-019, PRD-REQ-020, PRD-REQ-021, PRD-REQ-022, PRD-REQ-027, PRD-REQ-084, PRD-REQ-085, PRD-REQ-086, PRD-REQ-177, PRD-REQ-181, PRD-REQ-182, PRD-REQ-183, PRD-REQ-184, PRD-REQ-185, PRD-REQ-186, PRD-REQ-187, PRD-REQ-188, PRD-REQ-189, PRD-REQ-190, PRD-REQ-191, PRD-REQ-192, PRD-REQ-193, PRD-REQ-194, PRD-REQ-195, PRD-REQ-199, PRD-REQ-200 | TS-TEST-004, TS-TEST-005, TS-TEST-008, TS-TEST-009 |
| TS-REQ-007 | PRD-REQ-067, PRD-REQ-068, PRD-REQ-139, PRD-REQ-143, PRD-REQ-144, PRD-REQ-145, PRD-REQ-153, PRD-REQ-154, PRD-REQ-168, PRD-REQ-169, PRD-REQ-172, PRD-REQ-173, PRD-REQ-175, PRD-REQ-176 | TS-TEST-007, TS-TEST-009, TS-TEST-011 |
| TS-REQ-008 | PRD-REQ-178, PRD-REQ-201, PRD-REQ-202, PRD-REQ-203 | TS-TEST-010 |
| TS-REQ-009 | PRD-REQ-023, PRD-REQ-024, PRD-REQ-025, PRD-REQ-026, PRD-REQ-027, PRD-REQ-069, PRD-REQ-070, PRD-REQ-071, PRD-REQ-072, PRD-REQ-073, PRD-REQ-127, PRD-REQ-180, PRD-REQ-197, PRD-REQ-198, PRD-REQ-204 | TS-TEST-006, TS-TEST-008, TS-TEST-013 |
| TS-REQ-010 | PRD-REQ-034, PRD-REQ-035, PRD-REQ-081, PRD-REQ-082, PRD-REQ-083, PRD-REQ-103, PRD-REQ-104, PRD-REQ-105, PRD-REQ-106 | TS-TEST-006, TS-TEST-007, TS-TEST-013 |
| TS-REQ-011 | PRD-REQ-031, PRD-REQ-032, PRD-REQ-033, PRD-REQ-036, PRD-REQ-038, PRD-REQ-039, PRD-REQ-040, PRD-REQ-041, PRD-REQ-042, PRD-REQ-043, PRD-REQ-044, PRD-REQ-074, PRD-REQ-076, PRD-REQ-077, PRD-REQ-090, PRD-REQ-091, PRD-REQ-092, PRD-REQ-093, PRD-REQ-115, PRD-REQ-116, PRD-REQ-117 | TS-TEST-007, TS-TEST-013 |
| TS-REQ-012 | PRD-REQ-045, PRD-REQ-046, PRD-REQ-047, PRD-REQ-048, PRD-REQ-049, PRD-REQ-051, PRD-REQ-053, PRD-REQ-084, PRD-REQ-085, PRD-REQ-086, PRD-REQ-087, PRD-REQ-088, PRD-REQ-089, PRD-REQ-109, PRD-REQ-110 | TS-TEST-008, TS-TEST-013 |
| TS-REQ-013 | PRD-REQ-054, PRD-REQ-055, PRD-REQ-056, PRD-REQ-057, PRD-REQ-058, PRD-REQ-059, PRD-REQ-060, PRD-REQ-078, PRD-REQ-079, PRD-REQ-080, PRD-REQ-111, PRD-REQ-112, PRD-REQ-113, PRD-REQ-114 | TS-TEST-013 |
| TS-REQ-014 | PRD-REQ-061, PRD-REQ-062, PRD-REQ-063, PRD-REQ-099, PRD-REQ-100 | TS-TEST-014, TS-TEST-016 |
| TS-REQ-015 | PRD-REQ-151, PRD-REQ-152, PRD-REQ-153, PRD-REQ-162, PRD-REQ-179 | TS-TEST-010, TS-TEST-011 |
| TS-REQ-016 | PRD-REQ-012, PRD-REQ-033, PRD-REQ-091, PRD-REQ-092, PRD-REQ-093, PRD-REQ-115, PRD-REQ-116, PRD-REQ-117, PRD-REQ-146, PRD-REQ-147, PRD-REQ-159, PRD-REQ-196 | TS-TEST-002, TS-TEST-003, TS-TEST-013 |
| TS-REQ-017 | PRD-REQ-014, PRD-REQ-015, PRD-REQ-075, PRD-REQ-159, PRD-REQ-160, PRD-REQ-161, PRD-REQ-175, PRD-REQ-196, PRD-NFR-002 | TS-TEST-007, TS-TEST-009, TS-TEST-011 |
| TS-REQ-018 | PRD-REQ-128, PRD-REQ-147, PRD-REQ-148, PRD-REQ-149, PRD-REQ-168, PRD-REQ-169, PRD-REQ-189 | TS-TEST-002, TS-TEST-007, TS-TEST-009, TS-TEST-010, TS-TEST-015 |
| TS-REQ-019 | PRD-REQ-009, PRD-REQ-037, PRD-REQ-148, PRD-REQ-149 | TS-TEST-012, TS-TEST-014, TS-TEST-016 |
| TS-REQ-020 | PRD-REQ-004, PRD-REQ-037, PRD-REQ-123, PRD-REQ-129, PRD-REQ-130 | TS-TEST-012, TS-TEST-015 |

### 12.4. Quality requirements coverage manifest

| Source | Реализация | Verification |
|---|---|---|
| PRD-NFR-001 | `--!strict` для всех public UI modules; typed definitions/handles/results | TS-TEST-002, TS-STATIC-001 |
| PRD-NFR-002 | Явные owners для hosts, windows, controller resources и quarantine | TS-TEST-001, TS-TEST-007 |
| PRD-NFR-003 | Pure final-stack visibility function | TS-TEST-004 |
| PRD-NFR-004 | Final idempotent aggregate `Clear` | TS-TEST-007 |
| PRD-NFR-005 | One root semantic stream, no analytics implementation | TS-TEST-013 |
| PRD-NFR-006 | Reusable base controllers не хранят `WindowId`; enrichment at window boundary | TS-TEST-013 |

### 12.5. Acceptance coverage audit rule

Validator extracts unique `PRD-REQ-*`, `PRD-NFR-*`, `PRD-AC-*` from approved PRD and requires exact set equality with IDs referenced by this specification. It also requires every `TS-REQ-*` to name at least one `TS-TEST-*`, every `TS-TEST-*` to name source acceptance IDs, and rejects range shorthand. Expected counts for source revision 3 are exactly 175 functional requirements, 6 quality requirements and 91 acceptance criteria.
