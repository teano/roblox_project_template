---
document_type: product-requirements
status: approved
revision: 3
language: Russian
approved_at: 2026-08-21T10:10:53.2835529Z
---

# Product Requirements

## Product Outcome

Создать клиентскую UI-систему Roblox, которая централизованно управляет окнами, предоставляет выделенные слои для HUD и внутриигровых уведомлений, поддерживает динамическое создание окон и предоставляет единый поток осмысленных пользовательских UI-событий.

Система должна позволить будущему модулю аналитики подписаться на корень интерфейса и получать события вложенных UI-элементов без индивидуальной подписки на каждый элемент. Реализация аналитики в эту feature не входит.

## Target Audience

- Разработчики окон, project-specific HUD-контроллеров и систем внутриигровых уведомлений.
- Разработчики UI-представлений и переиспользуемых UI-элементов.
- Авторы будущих клиентских подсистем, которым нужен единый поток UI-событий.
- Агенты, создающие и настраивающие окна по правилам репозитория.

## Core Gameplay Loop

Project-specific HUD-контроллер размещает принадлежащее ему представление в HudHost и самостоятельно управляет его lifecycle. При пустом стеке клиентская игровая система может запросить первое окно; после этого только текущее Active Window причинно инициирует добавление, замену или закрытие окна, а внешние игровые системы сообщают ему изменения через принадлежащие им domain events. Конкретная игровая система может разместить принадлежащее ей внутриигровое уведомление в выделенном toast-слое. UI-система применяет правила window-подсистемы и предоставляет HUD- и toast-слои, не принимая на себя lifecycle их конкретного содержимого. Осмысленные действия игрока детерминированно всплывают по цепочке владельцев до `UiRoot`, после чего публикуются заинтересованным клиентским системам через общий repo Signal.

## Release Target

Первая версия должна поддерживать Roblox-клиенты на ПК, мобильных устройствах и консолях или в режиме геймпадного управления.

## Scope

### In Scope

- Один клиентский корень игрового интерфейса с тремя специализированными host-контейнерами.
- Оконная подсистема под координацией `UiSystem`, выделенный `HudHost` для project-specific HUD-контроллеров и выделенный `ToastHost` для уведомлений конкретных игровых систем.
- Динамическое создание окон по единому runtime-конфигу, объединённому из template-owned и derived-project authoring-конфигов.
- Стек окон с двумя политиками влияния на видимость нижележащих окон.
- Явные политики жизненного цикла окна и `Background`.
- Token-based блокировка взаимодействия с окном только при наличии опционального `BlockObjectRef`; без него все операции с blocking tokens полностью инертны.
- Иерархия контроллеров UI-элементов, динамические вложенные элементы и рекурсивная очистка.
- Детерминированное всплытие типизированных событий от вложенных UI-элементов до общего корня с последующей публикацией через repo Signal.
- Глобальные идентификаторы действий и базовые контроллеры распространённых Roblox GUI-элементов.
- Заготовка окна и локальный skill с правилами авторинга и конфигурирования окон.
- Явная граница владения, при которой project-specific HUD-контроллеры самостоятельно управляют содержимым `HudHost`.
- Простой toast-слой без универсальной очереди, таймеров и политики жизненного цикла конкретных уведомлений.
- Координация optional asynchronous Open и Close transitions с единым трёхсекундным ограничением времени navigation operation и условной блокировкой ввода на время перехода.
- Привязанный к Player жизненный цикл UI, не зависящий от respawn или замены Character.
- Распределение ответственности за safe area между host-контейнерами и конкретными UI-представлениями.
- Поддержка первой версии на ПК, мобильных устройствах и консолях или в режиме геймпадного управления.

### Out of Scope

- Реализация аналитической системы и отправка аналитики во внешние сервисы.
- Серверная бизнес-логика, инициируемая UI.
- Конкретный визуальный дизайн игровых окон, HUD и уведомлений.
- UI ранней загрузки из `ReplicatedFirst`; он остаётся отдельным от игрового `UiRoot`.
- Предварительное создание всех игровых окон в `StarterGui`.
- Автоматическая очистка или повторная инициализация всей UI-системы при respawn или замене Character.
- Универсальная очередь, FIFO-планирование, лимиты видимости, таймеры или единая lifecycle-политика для toast-уведомлений.
- Универсальный HudController, HUD-подсистема, HudId, runtime-реестр HUD или общий HUD lifecycle API с операциями Add, Remove, Show и Hide.
- Операция Back, история ранее закрытых окон и автоматическое восстановление окна из такой истории.
- Изменение логики, публичного API, adapter-контракта либо контрактов существующих операций Pool:Clear, PoolModule:ClearPool и ClearAllPools.
- Обобщённый rollback произвольных side effects, выполненных custom transition hook или внешней asynchronous операцией.

## Terminology

- **`UiRoot`** — общий клиентский корень игрового интерфейса после ранней загрузки.
- **Host** — непосредственный контейнер внутри `UiRoot`, граница размещения содержимого с явно определённым владельцем.
- **`HudHost`** — выделенный слой, в котором project-specific HUD-контроллеры размещают принадлежащие им представления.
- **`ToastHost`** — выделенный слой, в котором конкретные игровые системы размещают принадлежащие им внутриигровые уведомления.
- **`WindowHost`** — контейнер окон, участвующих в едином стеке.
- **Window** — представление, управляемое оконной подсистемой и идентифицируемое `WindowId`.
- **`WindowId`** — уникальный логический идентификатор типа окна внутри оконной системы.
- **`TemplateWindowConfig`** — template-owned типизированный authoring-конфиг определений окон, поставляемых шаблоном.
- **`DerivedWindowConfig`** — типизированный authoring-конфиг, который обязательная инициализация производного проекта создаёт в project-owned namespace и по пути, отсутствующему в upstream-шаблоне; reusable template не поставляет этот файл.
- **`WindowConfig`** — один канонический неизменяемый runtime-конфиг, атомарно сформированный слиянием TemplateWindowConfig и DerivedWindowConfig; его запись связывает WindowId с разрешённым authoring allowlist cloud AssetId data-only GUI-prefab, repo-owned Rojo-synchronized классом или factory BaseWindowView и политиками окна.
- **`WindowDefinition(TView, TViewModel)`** — каноническая замороженная запись runtime WindowConfig с типами конкретного view и его ViewModel и value-level runtime witness для безопасной проверки view.
- **ViewModel** — конкретная модель данных одного открытия окна, тип и интерпретацию которой определяет соответствующий конкретный BaseWindowView.
- **`WindowHandle`** — generation-safe результат успешного открытия, предоставляющий доступ к конкретному BaseWindowView только пока соответствующее поколение окна остаётся действительным независимо от его текущего Active или Paused состояния.
- **Active Window** — последний элемент стека, становящийся Active немедленно после добавления и являющийся единственным окном, имеющим право инициировать добавление, замену или закрытие окна; во время его Open новая операция со стеком отклоняется operation gate, а пользовательский ввод блокируется transition token только при наличии BlockObjectRef.
- **Paused Window** — остающееся открытым неверхнее окно стека, которое не принимает пользовательский ввод и не имеет права инициировать изменение оконного стека независимо от своей видимости.
- **Open** — операция перехода окна из закрытого состояния в открытое; успешная операция завершается только после полного завершения соответствующего перехода, а timeout завершается по отдельному deadline и quarantine-контракту.
- **Close** — операция перехода окна из открытого состояния в закрытое; успешная операция завершается только после полного завершения соответствующего перехода, а timeout завершается по отдельному deadline и quarantine-контракту.
- **`UIElementId`** — глобально уникальный идентификатор конкретного UI-элемента. Он не определяет возможность навигации.
- **`UINavigationEnabled`** — отдельный признак участия элемента в пользовательской навигации.
- **`BaseUiElement`** — базовый контроллер UI-элемента.
- **`BaseWindowView`** — специализация `BaseUiElement` для корня окна.
- **Direct nested element** — непосредственно вложенный контроллер в списке `NestedUiElements`; его потомки остаются вложенными уже относительно него.
- **HideBelow** — политика окна, скрывающая окна ниже него в стеке.
- **KeepBelow** — политика окна, не меняющая видимость окон ниже него.
- **`UIActionId`** — идентификатор осмысленного UI-действия в глобальном каталоге.
- **`BlockObjectRef`** — опциональный ObjectValue корня окна, ссылающийся на полноэкранный прозрачный GuiObject, используемый как InputSink; при наличии подходящего объекта и хотя бы одного активного blocking token режим InputSink равен All, а при отсутствии tokens — None. Наличие, отсутствие и текущее значение BlockObjectRef не участвуют в инициализации окна; без доступного подходящего объекта token acquire и release полностью инертны и окно ничего не блокирует.
- **Clear** — синхронная рекурсивная очистка контроллера и принадлежащих ему ресурсов без принятия решения об уничтожении или возврате корневого окна в пул.
- **Quarantined pooled window** — окно и его активная generation lease после timeout custom transition hook, исключённые из доступного состояния и запрещённые к повторной выдаче до фактического завершения hook, после которого выполняются UI Clear и штатный Release.

## Functional Requirements

### Root and Ownership

- PRD-REQ-001: Игровой интерфейс клиента MUST иметь один общий UiRoot.
- PRD-REQ-002: UiRoot MUST содержать три функциональных host-контейнера: HudHost, ToastHost и WindowHost.
- PRD-REQ-003: Визуальный порядок host-контейнеров снизу вверх MUST быть HudHost, ToastHost, WindowHost.
- PRD-REQ-004: UI ранней загрузки из ReplicatedFirst MUST оставаться вне UiRoot.
- PRD-REQ-005: UiSystem MUST координировать window-подсистему, MUST предоставлять HudHost как выделенный слой для project-specific HUD-контроллеров и MUST предоставлять ToastHost как выделенный слой для внутриигровых уведомлений конкретных игровых систем.
- PRD-REQ-006: Только содержимое WindowHost MUST участвовать в стеке окон. HUD и toast-уведомления не являются окнами стека.
- PRD-REQ-007: ToastHost MUST только предоставлять слой отображения и MUST NOT задавать универсальную очередь, FIFO-порядок, лимит видимости, таймер, lifecycle или политику взаимодействия для уведомлений; конкретная игровая система MUST владеть созданными ею toast-уведомлениями.

### Dynamic Windows and Configuration

- PRD-REQ-008: WindowHost MUST быть пуст после инициализации, пока клиентская система явно не запросит открытие окна.
- PRD-REQ-009: Окна MUST асинхронно создаваться только из cloud GUI-prefab, чьи AssetId внесены авторами в разрешённый WindowConfig и доступны проекту по его asset permissions; произвольные и сторонние AssetId MUST быть запрещены, Experience setting AllowInsertFreeAssets MUST оставаться false как authoring и deployment invariant, а runtime MUST NOT заявлять проверку владельца asset.
- PRD-REQ-010: Каждая запись TemplateWindowConfig либо DerivedWindowConfig MUST явно задавать WindowId, положительный разрешённый cloud AssetId data-only GUI-prefab, repo-owned Rojo-synchronized конкретный класс или factory BaseWindowView, политику жизненного цикла, политику видимости нижних окон и политику Background, MAY задавать флаг Preload и MUST задавать существующие PoolOptions с MaxActive и MaxRetained при pool-политике.
- PRD-REQ-011: WindowId MUST оставаться логической идентичностью окна, а AssetId MUST оставаться идентичностью разрешённого authoring-конфигом cloud GUI-resource; канонический runtime WindowConfig MUST однозначно связывать их без отдельного TemplateId и без runtime owner verification.
- PRD-REQ-012: WindowId MUST быть уникален среди всех окон текущего стека; запрос WindowId, уже присутствующего в любой позиции стека, MUST завершаться типизированной ошибкой разработчика до разрешения конфига, cloud-загрузки или создания временного экземпляра.
- PRD-REQ-013: Запрос повторного открытия WindowId, уже находящегося в стеке, MUST NOT менять существующий экземпляр или его ViewModel; повторные Open или Close во время уже выполняющейся операции того же окна регулируются отдельным no-op контрактом.
- PRD-REQ-014: Политика жизненного цикла окна MUST выбираться явно для каждого окна: уничтожить экземпляр после закрытия либо вернуть его через существующий клиентский PoolModule в отдельный homogeneous typed pool этого WindowId. Каждое pooled-определение MUST содержать PoolOptions с существующими MaxActive и MaxRetained, которые передаются штатному CreatePool без изменения PoolModule API или логики.
- PRD-REQ-015: Оконная подсистема MUST асинхронно загрузить и закешировать GUI-template до использования синхронной clone factory конкретного пула, получать pooled-окно только как generation lease, добавлять его в стек, обрабатывать запрос закрытия, удалять из стека и согласно конфигу уничтожать либо освобождать через тот же lease.
- PRD-REQ-016: Окно MUST NOT самостоятельно уничтожать себя или освобождать pool lease.

### Window Stack and Visibility

- PRD-REQ-017: Оконная подсистема MUST поддерживать один упорядоченный стек открытых окон.
- PRD-REQ-018: Каждое окно MUST явно выбирать одну из двух политик видимости: HideBelow или KeepBelow.
- PRD-REQ-019: После успешного AddWindow, CloseWindow или замены и после любого завершённого failure recovery видимость всего стека MUST пересчитываться из его итогового состава. Во время замены префикс стека ниже текущего окна MUST сохранять состав и порядок, а промежуточный пересчёт видимости между удалением текущего окна и результатом Open следующего окна MUST NOT выполняться.
- PRD-REQ-020: Видимая часть стека MUST начинаться с самого верхнего окна с политикой HideBelow; это окно и все окна выше него видимы, а все окна ниже скрыты.
- PRD-REQ-021: Если в стеке нет окна с политикой HideBelow, все окна стека MUST быть видимы.
- PRD-REQ-022: Потерявшее вершину, но остающееся в стеке окно MUST сохранять внутреннее состояние и lifecycle-состояние Open и MUST переходить в Paused независимо от того, остаётся ли оно видимым по политике KeepBelow или скрывается; при возвращении последним элементом стека оно немедленно становится Active Window и проходит Resume без повторного Open, а ввод и focus восстанавливаются только при отсутствии effective blocking.

### Interaction Policies

- PRD-REQ-023: Корень окна MAY содержать ObjectValue BlockObjectRef, ссылающийся на полноэкранный прозрачный GuiObject InputSink, расположенный поверх интерактивного содержимого этого окна.
- PRD-REQ-024: BaseWindowView MUST предоставлять только token-based acquire и release блокировки. При наличии доступного подходящего GuiObject через BlockObjectRef режим InputSink MUST быть All, пока существует хотя бы один token, и None после освобождения последнего token; отсутствие BlockObjectRef либо доступного подходящего объекта MUST делать acquire и release полностью инертными, не создавать effective blocking и ничего не блокировать. BlockObjectRef MUST NOT блокировать, откладывать или завершать ошибкой инициализацию окна.
- PRD-REQ-025: Окно MAY иметь Background, являющийся явным перехватчиком пользовательского ввода для всех расположенных ниже UI-слоёв, включая окна, HUD и toast.
- PRD-REQ-026: Политика Background MUST позволять как минимум два согласованных поведения: поглотить активацию без закрытия окна либо поглотить активацию и запросить закрытие окна при активации фона.
- PRD-REQ-027: Видимое нижнее KeepBelow-окно MUST оставаться в состоянии Paused; его base action handlers и navigation helpers MUST отклонять пользовательские действия по правилу Active/Paused authority независимо от Background и независимо от наличия BlockObjectRef.

### Identifiers and Navigation Eligibility

- PRD-REQ-031: WindowId и UIElementId MUST оставаться разными идентификаторами с разной семантикой.
- PRD-REQ-032: Корневой элемент окна MUST иметь WindowId для оконной системы и UIElementId для иерархии UI-элементов.
- PRD-REQ-033: Каждый UIElementId MUST быть глобально уникальным среди существующих UI-элементов.
- PRD-REQ-034: Наличие UIElementId MUST NOT само по себе включать элемент в пользовательскую навигацию.
- PRD-REQ-035: Участие элемента в навигации MUST задаваться отдельным признаком UINavigationEnabled.

### UI Element Hierarchy and Lifecycle

- PRD-REQ-036: Все объекты UI-представлений системы MUST наследовать BaseUiElement; конкретный объект корня окна MUST наследовать BaseWindowView, который специализирует BaseUiElement. Отдельный обязательный controller между конкретным окном и BaseWindowView MUST NOT вводиться.
- PRD-REQ-037: Cloud GUI-prefab MUST быть data-only моделью; BaseWindowView, его компоненты и весь исполняемый код окна MUST находиться в repo-owned Luau source, синхронизируемом в DataModel через Rojo, и запускаться только через единый клиентский bootstrap без изменения существующих sandbox или capability boundaries.
- PRD-REQ-038: Каждый BaseUiElement MUST хранить список непосредственно вложенных контроллеров NestedUiElements.
- PRD-REQ-039: NestedUiElements MUST заполняться при инициализации и поддерживать динамическое добавление и удаление вложенных контроллеров во время жизни элемента.
- PRD-REQ-040: При добавлении вложенного контроллера родитель MUST начать принимать и пробрасывать его события; после удаления родитель MUST прекратить это делать.
- PRD-REQ-041: Clear MUST рекурсивно вызываться для всех зарегистрированных вложенных контроллеров, включая созданные во время выполнения.
- PRD-REQ-042: Clear MUST быть идемпотентным, синхронным и не допускающим yield.
- PRD-REQ-043: Каждый контроллер во время Clear MUST освобождать принадлежащие ему подписки, соединения и другие ресурсы, если они были созданы его логикой.
- PRD-REQ-044: Clear MUST NOT принимать решение об уничтожении или возврате корневого окна в пул; это решение остаётся за оконной подсистемой.

### UI Events and Bubbling

- PRD-REQ-045: Осмысленное действие вложенного UI-элемента MUST синхронно, явно и без yield передаваться по детерминированной цепочке владения child-to-parent до UiRoot.
- PRD-REQ-046: Каждый промежуточный владелец MUST синхронно передать событие своему непосредственному родителю после принадлежащего ему обогащения и MUST NOT останавливать ownership bubbling.
- PRD-REQ-047: BaseWindowView MUST синхронно обогащать проходящее через границу окна событие соответствующим WindowId; переиспользуемые дочерние элементы MUST NOT хранить WindowId окна.
- PRD-REQ-048: После завершения ownership bubbling UiRoot MUST публиковать итоговое событие через обычный repo Signal с UIActionId, UIElementId и, для событий из окна, WindowId.
- PRD-REQ-049: Итоговый payload события MUST быть сериализуемым и MUST NOT содержать Roblox Instance, функции или другие несериализуемые значения.
- PRD-REQ-051: Подписчики root Signal MUST запускаться по обычному repo Signal contract: yield или ошибка одного подписчика MUST NOT блокировать издателя или запуск остальных, а UI-система MUST NOT гарантировать подписчикам порядок завершения либо наблюдение изменений payload, выполненных другим подписчиком.
- PRD-REQ-053: Будущая аналитика MUST иметь возможность подписаться один раз на поток UiRoot, не подписываясь отдельно на каждый элемент.

### Actions and Base Controllers

- PRD-REQ-054: Система MUST иметь глобальный каталог UIActionId.
- PRD-REQ-055: Шаблон MUST предоставлять базовый каталог общих действий, а производный проект MUST иметь возможность добавить собственный игровой каталог без переопределения шаблонных идентификаторов.
- PRD-REQ-056: Идентификаторы шаблонных действий MUST находиться в пространстве имён ui, а игровые действия проекта — в пространстве имён game; имена MUST использовать lowercase dot notation и именованные константы.
- PRD-REQ-057: BaseUiElement MUST определять только действия, общие для всех подходящих UI-элементов; специализированные контроллеры MUST добавлять более конкретные действия своего типа.
- PRD-REQ-058: Система MUST включать контроллеры для согласованного набора распространённых Roblox GUI-элементов с предустановленными осмысленными действиями пользователя.
- PRD-REQ-059: В глобальный поток MUST попадать основные действия пользователя, а не высокочастотные сырые сигналы и непрерывные изменения.
- PRD-REQ-060: События TextBox, всплывающие до корня, MUST NOT содержать введённый пользователем текст; контроллер формы или окна MUST читать нужное значение непосредственно из поля.

### Authoring Support

- PRD-REQ-061: Репозиторий MUST содержать каноническую data-only заготовку окна с местами для опциональных Background и BlockObjectRef, контролируемого содержимого и без LuaSourceContainer на любой глубине cloud GUI-prefab.
- PRD-REQ-062: Репозиторий MUST содержать локальный skill, объясняющий агенту создание repo-owned Rojo-synchronized конкретного BaseWindowView, объявление ViewModel, назначение идентификаторов, заполнение TemplateWindowConfig в шаблоне либо project-owned DerivedWindowConfig в производном проекте, подключение событий, optional transitions, асинхронной навигации, pooling и правил жизненного цикла.
- PRD-REQ-063: Заготовка и skill MUST предотвращать неоднозначное сопоставление WindowId, authoring-записи, канонической runtime-записи WindowConfig, разрешённого cloud AssetId data-only GUI-prefab и repo-owned конкретного BaseWindowView.

### Top-only Window Closing

- PRD-REQ-064: Штатно закрыть можно только верхнее окно стека.
- PRD-REQ-065: Запрос закрытия любого окна ниже вершины MUST считаться ошибкой разработчика и MUST NOT изменять состав, порядок или видимость стека.

### Window Opening Failure Safety

- PRD-REQ-066: Операции AddWindowAsync и замены MUST сохранять состав и порядок существующего нижнего префикса стека, не выполнять промежуточный пересчёт видимости и после успеха либо failure recovery публиковать только итоговое согласованное состояние; они MUST NOT описываться как глобальная транзакция, возвращающая уже успешно закрытое окно.
- PRD-REQ-067: Любая ошибка незавершённого Open MUST исключить неуспешный view из доступного состояния, не выдавать WindowHandle и применить его configured lifecycle только через существующие операции PoolModule либо destroy policy; UI Clear и lifecycle выполняются синхронно, кроме подтверждённого quarantine-контракта pooled view при timeout продолжающегося transition hook. Успешно закрытое и удалённое заменяемое окно MUST NOT восстанавливаться, а нижний префикс, итоговое верхнее окно и видимость MUST пройти подтверждённый recovery.
- PRD-REQ-068: При неуспешном Open оконная подсистема MUST вернуть вызывающей стороне типизированную ошибку после восстановления стека; обычный failure MUST также завершить UI cleanup до возврата, а timeout продолжающегося transition hook MUST вернуть ошибку на трёхсекундном deadline и отложить UI Clear и штатный Release quarantined pooled lease до фактического завершения hook. UI-система MUST NOT требовать индивидуальной discard-операции для leased generation или изменения PoolModule.

### Window Blocking Tokens

- PRD-REQ-069: При наличии корректного BlockObjectRef каждый независимый источник блокировки окна MUST получать отдельный токен; без BlockObjectRef выдаваемые token handles MUST оставаться полностью инертными.
- PRD-REQ-070: При наличии корректного BlockObjectRef effective blocking MUST оставаться активным и режим InputSink MUST оставаться All, пока существует хотя бы один активный token; при отсутствии активных tokens режим MUST быть None, а без BlockObjectRef effective blocking MUST всегда отсутствовать.
- PRD-REQ-071: При наличии корректного BlockObjectRef освобождение токена MUST снимать только соответствующую ему причину блокировки, и окно MUST разблокироваться только после освобождения последнего активного токена; освобождение инертного token handle MUST быть no-op.
- PRD-REQ-072: Только при наличии корректного BlockObjectRef и хотя бы одного активного blocking token окно MUST игнорировать все пользовательские действия, включая активацию Background; без BlockObjectRef tokens MUST NOT блокировать эти действия. Отдельные правила Active/Paused authority и единственной выполняющейся stack operation MUST действовать независимо от token blocking.
- PRD-REQ-073: Clear или программное закрытие окна MUST инвалидировать все связанные с ним token handles. Последующее освобождение инвалидированного либо инертного token handle MUST быть безопасным no-op и MUST NOT влиять на очищенное либо повторно используемое окно.

### Pooled Window Reset

- PRD-REQ-074: Для окна с pool-политикой синхронный не допускающий yield рекурсивный Clear MUST очищать UI controller state перед освобождением generation lease; он MUST NOT заменять или изменять существующий object-specific Release и reset contract pool adapter.
- PRD-REQ-075: WindowNavigator MUST вызывать UI Clear через защищённую синхронную границу до штатного синхронного Release существующего generation lease; pool adapter MUST NOT выполнять asset loading или awaitable lifecycle work, а UI-система MUST NOT добавлять DiscardLease, изменять adapter или предписывать новый PoolModule failure contract.
- PRD-REQ-076: При следующей выдаче окна из homogeneous typed pool его синхронный Initialize MUST заново сформировать runtime-состояние и вложенную иерархию контроллеров до Open.
- PRD-REQ-077: Повторно выданное окно и новое поколение lease MUST NOT сохранять принадлежащие view подписки, соединения, blocking tokens или runtime-вложенные контроллеры предыдущего использования.

### Initial Base Controllers

- PRD-REQ-078: Первая версия MUST включать базовые контроллеры для Frame, текстового представления, изображения, кнопки, TextBox, формы и скроллируемого контейнера.
- PRD-REQ-079: Контроллер кнопки MUST поддерживать соответствующие кнопочные Roblox GUI-элементы, включая текстовое и графическое представление кнопки.
- PRD-REQ-080: Контроллер формы MUST объединять принадлежащие форме поля и позволять логике формы читать их текущие значения без публикации введённого текста в глобальный поток UI-событий.

### Navigation Resolution

- PRD-REQ-081: Для элементов с UINavigationEnabled система MUST автоматически определять навигационные связи по умолчанию.
- PRD-REQ-082: Окно MUST иметь возможность явно переопределить автоматически определённые навигационные связи.
- PRD-REQ-083: Явно заданная связь MUST иметь приоритет над автоматической связью для того же направления навигации.

### Window Lifecycle Events

- PRD-REQ-084: Оконная подсистема MUST публиковать lifecycle-события окна в тот же поток UiRoot, в котором публикуются пользовательские UI-действия.
- PRD-REQ-085: Lifecycle-события MUST отражать успешное открытие, переход в Paused, завершение Resume вернувшегося Active Window, показ, скрытие и закрытие окна и MUST публиковаться только после фактического применения соответствующего базового состояния оконной подсистемы.
- PRD-REQ-086: BaseWindowView и его вложенные элементы MUST публиковать пользовательские действия и запросы, но MUST NOT самостоятельно подтверждать lifecycle-переходы окна.

### Generic Event Payload

- PRD-REQ-087: UI-событие MAY содержать универсальный вложенный сериализуемый payload без отдельного обязательного Luau-типа для каждого UIActionId.
- PRD-REQ-088: Отправитель и получатель MUST интерпретировать структуру универсального payload по контракту соответствующего UIActionId.
- PRD-REQ-089: Система MUST NOT требовать создания отдельного класса или структуры данных для каждого вида UI-события.

### Runtime UI Element Identity

- PRD-REQ-090: Повторяемый runtime-элемент MUST получать один составной UIElementId, сформированный из его стабильного положения в UI-иерархии и стабильного runtime-ключа представляемой сущности.
- PRD-REQ-091: Создатель повторяемого runtime-элемента MUST предоставить ключ сущности, необходимый для формирования составного UIElementId.
- PRD-REQ-092: Для одной и той же сущности в том же месте UI-иерархии составной UIElementId MUST оставаться стабильным при повторном создании элемента.
- PRD-REQ-093: Система MUST NOT вводить отдельный обязательный UIInstanceId; события MUST использовать итоговый составной UIElementId.

### Physical UI Root

- PRD-REQ-096: UiRoot MUST быть реализован одним клиентским ScreenGui с ResetOnSpawn равным false.
- PRD-REQ-097: HudHost, ToastHost и WindowHost MUST находиться внутри этого ScreenGui и сохранять согласованный визуальный порядок.

### Window Authoring Organization

- PRD-REQ-099: Reusable template MUST поставлять только template-owned TemplateWindowConfig и MUST NOT содержать путь DerivedWindowConfig; обязательная инициализация производного проекта MUST создать DerivedWindowConfig в project-owned namespace и по пути, отсутствующему в upstream, после чего UiSystem MUST слить оба authoring source в один canonical frozen runtime WindowConfig без альтернативного runtime config, manifest или registry.
- PRD-REQ-100: Repo-local agent rules, общий repo-local window-authoring skill и derived-project initialization rule, skill и documentation MUST однозначно требовать создание и проверку project-owned DerivedWindowConfig, чтобы инициализированный производный проект не мог пропустить этот шаг; те же документы MUST определять data-only GUI-prefab, repo-owned Rojo-synchronized concrete BaseWindowView, ViewModel, optional transitions, authoring definition и runtime WindowConfig, AssetId, Preload, pools, идентификаторы, события, typed и universal navigation APIs, lifecycle и обязательные проверки.

### Navigation Focus Restoration

- PRD-REQ-103: Только Active Window без effective blocking MUST участвовать в gamepad navigation graph и MUST запоминать свой последний выбранный UINavigationEnabled descendant; Active/Paused navigation authority MUST применяться независимо от BlockObjectRef.
- PRD-REQ-104: При Pause WindowNavigator MUST временно исключить каждый зарегистрированный UINavigationEnabled descendant этого окна из navigation graph, сделать его non-selectable и non-interactable и очистить GuiService.SelectedObject, если выбранный объект принадлежит этому окну.
- PRD-REQ-105: При Resume WindowNavigator MUST восстановить временно снятые navigation eligibility, selectability, interactability и focus только если окно стало Active и не имеет effective blocking; затем он MUST выбрать последний запомненный допустимый элемент либо настроенный допустимый default без fallback search. Пока сохраняется effective blocking, eligibility MUST оставаться снятой, GuiService.SelectedObject MUST оставаться nil, а восстановление MUST произойти после освобождения последнего effective token.
- PRD-REQ-106: Окно с хотя бы одним UINavigationEnabled element MUST задавать default navigation element; отсутствующий, malformed или не принадлежащий этому окну обязательный default MUST завершать инициализацию типизированной ошибкой разработчика. Окно без UINavigationEnabled elements MUST оставлять GuiService.SelectedObject равным nil.

### Unified Event Identifier Catalog

- PRD-REQ-109: Пользовательские действия и lifecycle-события в общем потоке UiRoot MUST использовать единый глобальный каталог UIActionId.
- PRD-REQ-110: Lifecycle-события MUST использовать те же правила namespace и именованных констант, что и остальные значения UIActionId.

### Standard Base Actions

- PRD-REQ-111: Базовый каталог первой версии MUST содержать действия входа указателя в область UI-элемента и выхода из неё.
- PRD-REQ-112: Контроллер кнопки MUST публиковать осмысленное действие активации.
- PRD-REQ-113: Контроллер TextBox MUST публиковать получение focus, потерю focus и подтверждение ввода без включения введённого текста в корневой payload.
- PRD-REQ-114: Контроллер формы MUST публиковать действия submit и cancel.

### Duplicate UI Element Identity

- PRD-REQ-115: Обнаружение двух существующих UI-элементов с одинаковым итоговым UIElementId MUST считаться ошибкой разработчика.
- PRD-REQ-116: Инициализация затронутой UI-иерархии при дублировании UIElementId MUST завершаться атомарно типизированной ошибкой и MUST NOT оставлять частично зарегистрированную иерархию.
- PRD-REQ-117: Система MUST NOT скрывать дублирование UIElementId автоматическим suffix или игнорированием второго элемента.

### First-release Product Behavior

- PRD-REQ-123: Первая версия MUST поддерживать Roblox-клиенты на ПК, мобильных устройствах и консолях или в режиме геймпадного управления.
- PRD-REQ-125: Конкретная игровая система MUST иметь возможность разместить принадлежащее ей внутриигровое уведомление в ToastHost и самостоятельно управлять его отображением и удалением.
- PRD-REQ-127: На всё время Open или Close transition WindowNavigator MUST удерживать отдельный transition token; он MUST блокировать пользовательский ввод только при наличии корректного BlockObjectRef и MUST быть полностью инертным без него. Независимо от BlockObjectRef единственная выполняющаяся operation MUST заставлять новый stack-запрос немедленно возвращать busy.
- PRD-REQ-128: Если обязательная структура UiRoot повреждена или отсутствует любой обязательный host-контейнер, инициализация UI-системы MUST завершаться типизированной ошибкой и MUST NOT оставлять частично работающее состояние.

### Player-bound Lifecycle and Presentation Policies

- PRD-REQ-129: UiSystem и UiRoot MUST принадлежать жизненному циклу Player и MUST NOT автоматически очищаться, пересоздаваться или повторно инициализироваться из-за respawn либо замены Character.
- PRD-REQ-130: Конкретное UI-представление или его контроллер, имеющие зависимость от Character, MUST самостоятельно владеть необходимой реакцией на character lifecycle, не превращая respawn в общий lifecycle UI-системы.
- PRD-REQ-131: Host-контейнеры UiRoot MUST задавать безопасную экранную область в соответствии с platform safe area, а конкретные HUD-, window- и toast-представления MUST владеть своим внутренним адаптивным layout внутри соответствующего host-контейнера.
- PRD-REQ-138: Host-контейнеры UiRoot MUST автоматически обновлять границы safe area при изменении viewport, ориентации экрана или platform insets, а конкретные представления MUST получать обновлённое доступное пространство для своего внутреннего адаптивного layout.
- PRD-REQ-139: Open MUST выполнять один переход окна из закрытого состояния в открытое, а Close MUST выполнять один переход окна из открытого состояния в закрытое. Успешная navigation operation MUST оставаться выполняющейся до полного завершения соответствующего transition hook; timeout MUST завершить navigation operation и освободить operation gate на трёхсекундном deadline, пока продолжающийся hook и его quarantined pooled view остаются под отдельным отложенным cleanup-контрактом.
- PRD-REQ-140: Пока для окна выполняется Open или Close, любой новый Open или Close того же окна MUST немедленно возвращать типизированный no-op результат и MUST NOT ожидать исходную операцию, перезапускать, прерывать, разворачивать или ставить в очередь текущий переход.
- PRD-REQ-141: UiSystem MUST NOT определять универсальный HudController, HUD-подсистему, HudId, runtime-реестр HUD или общий HUD lifecycle API.
- PRD-REQ-142: Каждый project-specific HUD-контроллер MUST получать HudHost через явную клиентскую композицию и MUST самостоятельно владеть созданием или получением своего представления, его runtime-состоянием, отображением, подписками и очисткой.
- PRD-REQ-143: Конкретный BaseWindowView MAY предоставлять optional awaitable transition hooks для Open и Close; наличие этих hooks MUST NOT быть обязательным условием корректного окна.
- PRD-REQ-144: Если соответствующий transition hook существует, WindowNavigator MUST ожидать его завершения в пределах единого абсолютного deadline операции ровно 3 секунды; если hook отсутствует, операция MUST завершать переход без дополнительного ожидания. Ошибка hook MUST запускать forced UI cleanup и base-state recovery, а timeout продолжающегося hook MUST запускать base-state recovery и quarantine-контракт pooled view и lease.
- PRD-REQ-145: Конкретное визуальное поведение optional transitions MUST принадлежать соответствующему BaseWindowView и MUST NOT выбираться глобальной animation-системой или задаваться универсальным tween-конфигом оконной подсистемы. Hook MUST NOT запускать detached work, которое продолжает мутировать состояние после завершения операции; framework гарантирует только отсутствие позднего WindowNavigator-owned commit и MUST NOT обещать обобщённый rollback произвольных custom side effects.
- PRD-REQ-146: UiSystem MUST атомарно слить TemplateWindowConfig и DerivedWindowConfig в один канонический runtime WindowConfig и после успешной инициализации MUST заморозить его; UI-система MUST NOT предоставлять runtime API для добавления, удаления или замены definitions, а доступный набор и содержимое definitions MUST оставаться неизменными до завершения текущего UiSystem.
- PRD-REQ-147: Обнаружение одинакового WindowId внутри одного authoring-конфига либо между TemplateWindowConfig и DerivedWindowConfig, а также неполной или malformed записи MUST завершать слияние и инициализацию типизированной ошибкой; система MUST NOT выбирать первое определение, неявно заменять template-определение или публиковать частичный runtime WindowConfig.
- PRD-REQ-148: Оконная подсистема MUST разрешать через асинхронный Roblox asset-loading API только AssetId из frozen WindowConfig, обрабатывать загрузку в защищённой границе и возвращать типизированную ошибку при недоступном, запрещённом authoring allowlist либо malformed asset; принадлежность и permissions MUST быть authoring invariant, AllowInsertFreeAssets MUST оставаться false при authoring и deployment, а runtime owner verification MUST NOT заявляться.
- PRD-REQ-149: Загруженный cloud GUI-prefab MUST содержать ровно один допустимый корень окна, соответствующий канонической data-only заготовке, и MUST рекурсивно отклоняться при наличии любого LuaSourceContainer на любой глубине; весь BaseWindowView и component code MUST разрешаться только из repo-owned Luau source, синхронизируемого через Rojo, без изменения sandbox или capabilities.
- PRD-REQ-150: Каждая каноническая запись runtime WindowConfig MUST быть WindowDefinition(TView, TViewModel) и связывать WindowId непосредственно с разрешённым cloud AssetId, repo-owned Rojo-synchronized конкретным классом или factory BaseWindowView, value-level runtime witness для безопасного cast, всеми политиками окна и PoolOptions с MaxActive и MaxRetained при pool-политике; отдельный обязательный controller layer, registry или второй runtime-конфиг MUST NOT вводиться.
- PRD-REQ-151: Первое создание окна MUST выполняться в порядке constructor, синхронный не допускающий yield Initialize с конкретной ViewModel, добавление в стек, затем Open; конкретный BaseWindowView MUST самостоятельно проверять и интерпретировать требуемый ему тип ViewModel на динамической границе Luau.
- PRD-REQ-152: Повторная выдача pooled-окна MUST пропускать constructor, сохранять generation lease PoolModule и заново выполнить синхронный Initialize с ViewModel текущего открытия до добавления в стек и Open.
- PRD-REQ-153: Асинхронная операция открытия MUST возвращать generation-safe WindowHandle только после успешной cloud-загрузки, content preload, constructor или pool acquire при необходимости, синхронного Initialize, немедленного добавления окна как Active Window и завершения optional Open transition; во время Open transition token MUST блокировать ввод только при BlockObjectRef, а operation gate MUST отклонять новые stack operations всегда.
- PRD-REQ-154: Асинхронная операция Close MUST возвращать успешный результат только после завершения optional Close transition, удаления окна из стека, синхронного UI Clear и применения lifecycle policy через destroy либо существующий PoolModule. При failure операция MUST завершить handle invalidation и base-state recovery без требования нового pool API; timeout продолжающегося transition hook MUST вернуть ошибку на трёхсекундном deadline и удерживать pooled view и lease в quarantine до завершения hook, после чего выполнить UI Clear и штатный Release.
- PRD-REQ-156: Оконная подсистема MUST NOT предоставлять операцию Back, хранить историю закрытых окон или автоматически восстанавливать окно из истории; причинно связанный Add, собственный Close или replacement MUST оставаться явной операцией Active Window.
- PRD-REQ-158: До каждого успешного Open оконная подсистема MUST завершить загрузку и проверку cloud GUI-prefab и preload релевантного content через существующий ContentPreloader; отсутствующий или false Preload MUST выполнять обе yielding-фазы лениво при первом Open, а true MUST начать и ожидать eager-попытку во время инициализации UiSystem в пределах ровно 3 секунд. Ошибка или timeout eager-попытки MUST NOT блокировать успешную инициализацию UiSystem.
- PRD-REQ-159: Успешно загруженный, проверенный и content-preloaded cloud GUI-prefab MUST сохраняться как неизменяемый локальный template, из которого синхронная factory создаёт отдельные клоны; последующие создания окна MUST NOT повторно загружать тот же template из облака или повторять его успешный preload в пределах текущего UiSystem.
- PRD-REQ-160: Ошибка lazy либо eager cloud-загрузки, проверки или content preload MUST NOT кешироваться как постоянный результат; неуспешная lazy-попытка завершает только текущий Open типизированной ошибкой, а после неуспешной eager-попытки следующий независимый Open того же окна MUST выполнить новую попытку до создания экземпляра.
- PRD-REQ-161: Preload равный true MUST запускать eager cloud load, recursive data-only validation и content preload как ожидаемую UiSystem startup operation с ограничением ровно 3 секунды; ошибка или timeout этой eager operation MUST оставить UiSystem инициализированной и доступной, а последующий Open этого окна MUST повторить загрузку, проверку и content preload.
- PRD-REQ-162: Синхронный Initialize MUST вызываться при каждом открытии до добавления окна в стек и Open, включая окна без входных данных; такое окно MUST явно принимать nil как свою ViewModel, а несовместимая ViewModel MUST завершать открытие типизированной ошибкой без частично открытого окна.
- PRD-REQ-163: BaseWindowView MUST получать узкий WindowNavigator через явную композицию и MUST предоставлять наследуемые асинхронные helpers AddWindowAsync, AddWindowTypedAsync, CloseWindowAsync и CloseWindowTypedAsync, делегирующие операции WindowNavigator.
- PRD-REQ-164: CloseWindowAsync без параметров следующего окна MUST закрывать текущий Active Window через WindowNavigator, ожидать его удаление и failure recovery при необходимости, пересчитать итоговую видимость оставшегося стека и возвращать только типизированный результат успеха или ошибки без WindowHandle другого окна.
- PRD-REQ-165: CloseWindowAsync с WindowId и ViewModel следующего окна MUST сначала подготовить следующее окно посредством разрешения конфига и asset, content preload, создания либо pool acquire и синхронного Initialize, не добавляя его в стек; после успешной подготовки операция MUST выполнить Close текущего Active Window, удалить его, добавить и открыть подготовленное окно поверх неизменённого нижнего префикса, затем пересчитать итоговую видимость и вернуть WindowHandle нового окна.
- PRD-REQ-166: Универсальный AddWindowAsync с WindowId и unknown ViewModel MUST добавить и открыть новое окно поверх текущего стека без автоматического закрытия текущего окна и MUST вернуть Result с WindowHandle(BaseWindowView); typed AddWindowTypedAsync MUST принимать канонический WindowDefinition(TView, TViewModel) и TViewModel и возвращать Result с WindowHandle(TView).
- PRD-REQ-167: Helpers BaseWindowView MUST NOT самостоятельно загружать asset, создавать окно, менять стек или подтверждать lifecycle; все изменения и пересчёты видимости MUST выполнять WindowNavigator и оконная подсистема.
- PRD-REQ-168: Каждый WindowHandle MUST быть связан с конкретным поколением одного открытия и соответствующим generation lease при pooled lifecycle и MUST становиться недействительным после удаления окна из стека, Clear, уничтожения или освобождения lease. Close failure MUST также инвалидировать handle при принудительном удалении окна: обычный failure завершает configured lifecycle, а timeout продолжающегося hook оставляет pooled view и активную lease в quarantine без доступа через прежний handle до завершения hook, UI Clear и штатного Release.
- PRD-REQ-169: Использование недействительного WindowHandle MUST завершаться типизированной stale-handle ошибкой и MUST NOT воздействовать на повторно открытое или повторно выданное из пула окно.
- PRD-REQ-172: Если подготовка следующего окна для замены завершается ошибкой, операция MUST синхронно выполнить UI Clear временного view, завершить его lifecycle только через configured destroy policy либо существующие generation-lease операции PoolModule, вернуть типизированную ошибку без handle и оставить текущее окно, нижний префикс и его видимость без изменений.
- PRD-REQ-173: Если после удаления текущего окна Open подготовленного следующего окна завершается ошибкой или timeout, оконная подсистема MUST инвалидировать operation generation, исключить неуспешное окно из доступного состояния, оставить предыдущее окно удалённым, пересчитать видимость сохранённого нижнего префикса, синхронно вызвать Resume его итогового верхнего окна при наличии и восстановить его ввод и focus только при отсутствии effective blocking, после чего вернуть типизированную ошибку без WindowHandle нового окна; при пустом стеке Active Window MUST отсутствовать. Обычная ошибка MUST синхронно выполнить forced UI cleanup через configured lifecycle, а timeout продолжающегося transition hook MUST применить quarantine-контракт к pooled view и lease.
- PRD-REQ-174: При пустом стеке внешняя клиентская система MAY запросить первое окно через UiSystem; при непустом стеке только текущий Active Window MUST владеть причинно-следственным решением и MAY запросить Add, собственный Close или замену через WindowNavigator. Active Window MUST NOT самостоятельно добавлять, удалять, уничтожать или освобождать окна; внешний либо исходящий от неверхнего окна прямой stack-запрос MUST завершаться типизированной ошибкой разработчика без изменения стека. Внешние системы MUST публиковать domain events, а решение о реакции на них MUST принимать подписанное Active Window.
- PRD-REQ-175: WindowNavigator MUST принимать не более одной изменяющей стек операции одновременно и назначать ей один абсолютный deadline ровно 3 секунды и уникальное operation generation; deadline MUST охватывать forward asynchronous cloud load, content preload и optional Open или Close transition. На timeout WindowNavigator MUST инвалидировать generation, исключить затронутое окно из доступного состояния, выполнить base-state recovery и вернуть timeout error на deadline; pooled view и его активная lease MUST оставаться в quarantine и MUST NOT проходить UI Clear, Release или повторную выдачу до фактического завершения продолжающегося hook, после чего MUST выполнить UI Clear и штатный Release. Если hook никогда не завершается, lease MUST оставаться недоступной. Параллельный stack-запрос MUST немедленно возвращать busy без очереди, а late continuation MUST повторно проверить generation и MUST NOT выполнять WindowNavigator-owned commit в stack, handle registration, system tokens, focus, navigation state или lifecycle events. Framework MUST NOT обещать отмену либо rollback произвольных side effects внешней операции или custom hook.
- PRD-REQ-176: Если Close transition текущего окна завершается ошибкой или timeout, WindowNavigator MUST инвалидировать operation generation, удалить текущее окно, инвалидировать его handle, выполнить cleanup подготовленной замены, пересчитать видимость сохранённого нижнего префикса, синхронно вызвать Resume его итогового верхнего окна при наличии и только затем вернуть типизированную ошибку; обобщённый визуальный rollback закрываемого окна MUST NOT выполняться. Обычная ошибка MUST синхронно выполнить UI Clear и configured lifecycle через существующие pool operations либо destroy policy, а timeout продолжающегося hook MUST применить quarantine-контракт к pooled view и lease.
- PRD-REQ-177: Замена MUST публиковать Show и Hide только после одного итогового пересчёта видимости по результату успешного Open либо завершённого failure recovery и MUST NOT пересчитывать видимость или публиковать промежуточные Show и Hide нижнего префикса между удалением текущего окна и итогом следующего Open.
- PRD-REQ-178: WindowHandle MUST быть типизирован как WindowHandle(TView), MUST предоставлять WindowId, IsValid(), IsActiveWindow() и GetView(), возвращающий типизированный Result(TView), и MUST проверять соответствие поколения при каждом IsValid, IsActiveWindow и GetView; IsValid MUST отражать действительность поколения независимо от положения окна в стеке, IsActiveWindow MUST отражать нахождение окна последним элементом стека, а недействительный handle MUST NOT предоставлять concrete view или сообщать об Active Window.
- PRD-REQ-179: UiSystem MUST передавать ViewModel конкретному BaseWindowView только в синхронный Initialize и MUST NOT сохранять исходную ViewModel после его успешного завершения; конкретный BaseWindowView MUST самостоятельно сохранить или скопировать необходимые ему данные и освободить принадлежащее ему runtime-состояние через синхронный Clear.
- PRD-REQ-180: Во время Open либо при любом effective blocking token пользовательский ввод Active Window MUST блокироваться только при наличии корректного BlockObjectRef; navigation helper Paused или иного неверхнего окна MUST завершаться типизированной ошибкой разработчика по отдельному правилу Active/Paused authority и MUST NOT менять стек или видимость.
- PRD-REQ-181: BaseWindowView MUST предоставлять синхронные default no-op hooks Pause и Resume без параметров, а каждый конкретный BaseWindowView MAY независимо переопределить любой из них и реализовать собственное не допускающее yield поведение паузы и восстановления.
- PRD-REQ-182: WindowNavigator MUST вызывать Initialize, Clear, Pause и Resume через защищённую синхронную не допускающую yield границу; visual behavior Pause и Resume MAY принадлежать конкретному окну, а оконная подсистема MUST NOT выполнять общий визуальный rollback при их ошибке.
- PRD-REQ-183: Когда Active Window теряет вершину, но остаётся в стеке, WindowNavigator MUST установить его базовое Paused-состояние и pause token, исключить его navigation graph и синхронно вызвать Pause до добавления следующего окна; когда Paused Window возвращается на вершину, WindowNavigator MUST установить базовое Active-состояние и синхронно вызвать Resume, снять только pause token и восстановить navigation eligibility и focus только если после этого effective blocking отсутствует.
- PRD-REQ-184: Если переход в Paused сопровождается фактическим скрытием окна, Pause либо его изолированный failure recovery MUST завершиться до изменения видимости и публикации Hide; если переход в Active сопровождается восстановлением скрытого окна, Resume либо его изолированный failure recovery MUST завершиться до показа и публикации Show.
- PRD-REQ-185: Pause и Resume MUST зависеть только от итоговой смены Active Window, а Hide и Show — от итоговой смены видимости; замена MUST NOT вызывать промежуточные hooks или visibility events для окон нижнего префикса, итоговый active-статус которых не изменился.
- PRD-REQ-186: Окно, которое закрывается и покидает стек, MUST проходить Close без предварительного вызова Pause; Pause MUST вызываться только для окна, которое теряет вершину, но остаётся открытым в стеке.
- PRD-REQ-187: Новое окно MUST становиться Active Window немедленно после добавления последним элементом стека; до успешного завершения Open и итогового пересчёта видимости operation gate MUST отклонять все новые stack operations, а transition token MUST блокировать пользовательский ввод только при наличии BlockObjectRef. После успеха система MUST снять только этот token и восстановить либо назначить focus только при отсутствии другого effective blocking.
- PRD-REQ-188: Базовое поведение оконной подсистемы для Paused Window MUST ограничиваться поддержанием structural active-state, блокировкой пользовательского ввода и запретом оконной навигации; остановка и восстановление принадлежащих конкретному окну таймеров, обновлений, эффектов, подписок и другой runtime-логики MUST принадлежать его optional override Pause и Resume.
- PRD-REQ-189: Ошибка custom Pause либо Resume MUST быть изолирована и зарегистрирована как диагностическая ошибка разработчика, MUST NOT отменять или повреждать изменение стека и MUST NOT препятствовать применению базового состояния Paused либо Active, token bookkeeping и navigation safeguards; eligibility и focus MUST восстанавливаться только при отсутствии effective blocking.
- PRD-REQ-190: Если AddWindowAsync вызвал Pause прежнего Active Window, но Open нового Active Window завершился ошибкой или timeout, оконная подсистема MUST инвалидировать operation generation, исключить неуспешное окно из доступного состояния, восстановить прежний стек, пересчитать его итоговую видимость, синхронно вызвать Resume прежнего окна и вернуть ему ввод и допустимый focus только при отсутствии effective blocking, после чего вернуть типизированную ошибку. Обычная ошибка MUST синхронно выполнить forced UI cleanup неуспешного окна через configured lifecycle, а timeout продолжающегося hook MUST применить quarantine-контракт к pooled view и lease.
- PRD-REQ-191: WindowNavigator MUST вызывать Pause ровно один раз при каждом фактическом переходе окна Active в Paused и Resume ровно один раз при каждом фактическом переходе Paused в Active; пересчёт стека, не изменивший active-статус окна, MUST NOT повторно вызывать эти hooks.
- PRD-REQ-192: При AddWindowAsync прежний Active Window, остающийся в стеке, MUST завершить Pause либо его изолированный failure recovery до добавления нового окна; после добавления новое окно немедленно становится Active, но остаётся без пользовательского ввода и stack operations на протяжении Open transition.
- PRD-REQ-193: Действительный WindowHandle Paused Window MUST сохранять IsValid() равным true и MUST разрешать GetView(); IsActiveWindow() MUST возвращать false, а любые navigation helpers полученного view MUST продолжать проверять Active Window и отклонять изменение стека.
- PRD-REQ-194: После применения базового состояния Paused оконная подсистема MUST публиковать ui.window.paused, а после применения базового Active-состояния через Resume MUST публиковать ui.window.resumed в общем потоке UiRoot; диагностическая ошибка custom hook MUST NOT отменять соответствующее событие уже применённого базового состояния.
- PRD-REQ-195: Действительный handle Paused Window MUST позволять вызывающей системе программно вызывать custom-методы concrete view; базовая оконная подсистема MUST ограничивать только пользовательский ввод и оконную навигацию, а допустимость и эффект остальных custom-команд в Paused состоянии MUST определять конкретное окно.
- PRD-REQ-196: При первой загрузке доверенного project-owned cloud GUI-prefab в пределах текущего UiSystem оконная подсистема MUST разрешать по AssetId актуальную доступную версию asset, MUST сохранять успешно проверенный и content-preloaded template до завершения текущего UiSystem и MUST NOT требовать AssetVersionId в WindowConfig или обновлять закешированный template в течение этой сессии.
- PRD-REQ-197: Базовая оконная подсистема MUST выдавать Paused Window отдельный system-owned pause token, совместимый с остальными tokens и полностью инертный без BlockObjectRef; независимо от token Paused-state authority MUST отклонять base actions и window navigation. Resume MUST освобождать только pause token и MUST NOT освобождать ручные, transition или иные независимо выданные tokens.
- PRD-REQ-198: При отсутствии Background у Active Window оконная подсистема MUST NOT устанавливать глобальный перехватчик ввода над всеми нижними слоями; ввод через точку, где отсутствует геометрия Background, любого другого GuiObject WindowHost и любого включённого InputSink, MAY достигать интерактивного HUD или toast. InputSink Paused Window в режиме All через BlockObjectRef MUST поглощать попавший в него ввод без реакции, публикации действия, запроса закрытия или пропускания ввода ниже.
- PRD-REQ-199: Lifecycle-события одного изменения стека MUST публиковаться в строгом порядке фактически применённых состояний: ui.window.paused перед событием скрытия того же окна, событие закрытия удаляемого верхнего окна перед ui.window.resumed восстановленного окна, а ui.window.resumed перед событием его показа.
- PRD-REQ-200: События ui.window.paused и ui.window.resumed MUST использовать обычный lifecycle payload с WindowId и MUST NOT добавлять причину перехода, WindowId соседнего окна, итоговую видимость, глубину стека или определяемую конкретным окном структуру.
- PRD-REQ-201: Канонический замороженный WindowDefinition(TView, TViewModel) из runtime WindowConfig MUST содержать value-level runtime witness TryCastView либо эквивалентный class token для безопасной проверки concrete view; typed navigation operation MUST проверить identity определения и cast до изменения стека, а mismatch MUST выполнить configured UI cleanup временного экземпляра и вернуть типизированную ошибку.
- PRD-REQ-202: Typed navigation API MUST принимать сам канонический WindowDefinition(TView, TViewModel), а не только WindowId с phantom generic; оно MUST использовать тот же runtime WindowConfig и MUST NOT создавать второй registry, config или независимый источник definitions.
- PRD-REQ-203: CloseWindowAsync с параметрами следующего WindowId и unknown ViewModel MUST возвращать WindowHandle(BaseWindowView) нового окна, а CloseWindowTypedAsync с каноническим WindowDefinition(TView, TViewModel) и TViewModel MUST возвращать WindowHandle(TView); обе формы MUST выполнять один и тот же replacement lifecycle WindowNavigator.
- PRD-REQ-204: Каждый base action handler MUST перед обработкой пользовательского действия проверять, что его окно является Active Window и не находится в Paused; при наличии BlockObjectRef handler MUST также отклонять действие при effective blocking, а без BlockObjectRef tokens MUST не влиять на handler. Отклонённый handler MUST завершаться без публикации действия и без изменения UI flow.

## Quality Requirements

- PRD-NFR-001: Публичные Luau-модули UI-системы MUST сохранять строгую типизацию --!strict.
- PRD-NFR-002: Владение жизненным циклом MUST быть однозначным: содержимым HudHost владеют project-specific HUD-контроллеры, содержимым ToastHost — создавшие его игровые системы, содержимым WindowHost и корневыми окнами — оконная подсистема, собственными ресурсами контроллера — сам контроллер.
- PRD-NFR-003: Пересчёт видимости MUST зависеть от текущего стека и политик его окон, а не от сохранённого снимка прежней видимости.
- PRD-NFR-004: Двойной Clear одного и того же контроллера MUST быть безопасным.
- PRD-NFR-005: Событийный контракт MUST оставаться пригодным для будущей аналитики, не включая реализацию аналитики в UI-систему.
- PRD-NFR-006: Ни один базовый UI-контроллер MUST NOT зависеть от конкретного окна, в котором он переиспользуется.

## Acceptance Criteria

- PRD-AC-001: После инициализации существует один UiRoot ScreenGui с ResetOnSpawn false и HudHost, ToastHost и WindowHost в порядке HUD ниже toast, toast ниже окон; ранний loading UI не является их дочерним элементом.
- PRD-AC-002: При пустом WindowHost запрос известного WindowId динамически клонирует окно либо получает generation lease из отдельного homogeneous typed pool этого WindowId, созданного штатным CreatePool с MaxActive и MaxRetained из PoolOptions канонического определения окна.
- PRD-AC-003: Запрос WindowId, уже присутствующего в любой позиции стека, возвращает типизированную ошибку разработчика до cloud load и не создаёт второй экземпляр или pool lease; повторный Open или Close уже переходящего окна остаётся no-op по переходному контракту.
- PRD-AC-004: При стеке KeepBelow, HideBelow, KeepBelow, HideBelow, KeepBelow, HideBelow видим верхний HideBelow; после его закрытия пересчёт показывает предыдущий HideBelow и находившийся над ним KeepBelow. Последующие закрытия каждый раз дают результат по текущему стеку, а не по сохранённой прежней видимости.
- PRD-AC-005: При добавлении B поверх A окно A получает Pause и перестаёт принимать ввод независимо от политики B; при HideBelow оно после Pause скрывается, а при KeepBelow остаётся видимым в состоянии Paused. После удаления B окно A немедленно является Active Window, получает Resume и при необходимости показывается без повторного Open.
- PRD-AC-006: При корректном BlockObjectRef два token acquire переводят полноэкранный прозрачный GuiObject InputSink в режим All до последнего из двух соответствующих release, после чего режим становится None; без BlockObjectRef те же acquire и release полностью инертны, effective blocking отсутствует и окно ничего не блокирует.
- PRD-AC-007: Background Active Window с политикой поглощения не пропускает активацию к нижним окнам, HudHost или ToastHost; вариант с закрытием дополнительно отправляет запрос собственного Close. InputSink Paused Window в режиме All через BlockObjectRef поглощает ввод, но не реагирует, не публикует действие и не пропускает ввод ниже.
- PRD-AC-008: Окно инициализируется одинаково при отсутствующем BlockObjectRef, nil Value и доступном подходящем GuiObject; только последний вариант способен создать effective blocking, а в остальных token acquire и release полностью инертны.
- PRD-AC-009: Динамически добавленный вложенный контроллер начинает передавать события родителю, после удаления перестаёт, а при очистке активной иерархии получает рекурсивный Clear ровно в рамках идемпотентного контракта.
- PRD-AC-010: Действие вложенного элемента синхронно проходит явную ownership chain child-to-parent, получает WindowId ровно при прохождении BaseWindowView и после полного обогащения публикуется UiRoot через repo Signal с UIActionId, UIElementId и правильным WindowId, которого дочерний элемент не хранит.
- PRD-AC-011: Yield или ошибка одного подписчика UiRoot Signal не блокирует издателя и не подавляет запуск остальных подписчиков; тест не предполагает порядок завершения listeners или передачу изменений payload от одного listener другому.
- PRD-AC-012: Глобальный поток не публикует высокочастотные сырые сигналы и не передаёт введённый текст TextBox; контроллер формы может прочитать значение поля для своей логики.
- PRD-AC-013: Окно с destroy policy после Close синхронно очищается и уничтожается; окно с pool policy после UI Clear освобождается по generation lease штатной операцией существующего homogeneous pool его WindowId, а stale lease не может освободить новое поколение. UI-система не добавляет DiscardLease, не меняет pool adapter и не меняет контракты Pool:Clear, PoolModule:ClearPool или ClearAllPools.
- PRD-AC-014: Каноническая data-only заготовка и repo-local skill позволяют связать разрешённый cloud GUI-prefab без LuaSourceContainer на любой глубине с repo-owned Rojo-synchronized BaseWindowView без отдельного TemplateId или автономного LocalScript.
- PRD-AC-015: Запрос закрытия верхнего окна удаляет его и пересчитывает видимость оставшегося стека; запрос закрытия нижнего окна распознаётся как ошибка разработчика и оставляет стек без изменений.
- PRD-AC-016: Ошибка config, разрешённого asset, prefab structure, content preload, cast или Initialize до изменения стека синхронно выполняет UI Clear временного окна и его configured lifecycle только штатными destroy либо PoolModule operations, возвращает типизированную ошибку без handle и оставляет существующий стек и его видимость неизменными.
- PRD-AC-017: При корректном BlockObjectRef два независимых источника удерживают blocking tokens одного окна; освобождение первого сохраняет effective blocking и режим InputSink All, а освобождение второго переводит InputSink в None. Без BlockObjectRef оба tokens полностью инертны.
- PRD-AC-018: При корректном BlockObjectRef effective blocking заставляет base action handlers и Background завершаться без публикации действия, закрытия окна или изменения flow; без BlockObjectRef tokens не блокируют эти действия. Navigation helper Paused Window отклоняется отдельно по Active/Paused authority в обоих случаях.
- PRD-AC-019: После Clear или программного закрытия заблокированного окна все ранее выданные токены становятся неактивными; их позднее освобождение не вызывает ошибку и не меняет состояние повторно открытого или полученного из пула окна.
- PRD-AC-020: После закрытия pooled-окна его повторная выдача с новым generation lease и синхронный Initialize не восстанавливают подписки, соединения, blocking tokens или runtime-вложенные контроллеры предыдущего использования.
- PRD-AC-021: Первая версия предоставляет наследуемые от BaseUiElement контроллеры для Frame, текста, изображения, кнопок, TextBox, формы и скроллируемого контейнера; значение TextBox доступно форме, но не публикуется в корневом событии.
- PRD-AC-022: Элементы с UINavigationEnabled получают автоматические связи по умолчанию, а заданное окном переопределение заменяет автоматическую связь только в указанном направлении.
- PRD-AC-023: После фактически применённого открытия, перехода в Paused, перехода в Active через Resume, изменения видимости и закрытия оконная подсистема публикует соответствующее lifecycle-событие через общий UiRoot Signal; отвергнутый до изменения состояния запрос не публикует подтверждающее событие.
- PRD-AC-024: Два разных UIActionId могут использовать один универсальный тип payload с разной документированной структурой, и подписчик выбирает способ чтения по идентификатору действия без отдельного класса payload.
- PRD-AC-025: Два клона одного UI-шаблона, созданные для разных runtime-сущностей, получают разные составные UIElementId; повторное создание клона для той же сущности в том же месте иерархии воспроизводит прежний ID.
- PRD-AC-028: Reusable template содержит TemplateWindowConfig и не содержит путь DerivedWindowConfig; обязательная инициализация производного проекта по правилам, skill и initialization documentation создаёт DerivedWindowConfig в project-owned namespace отсутствующего upstream пути, после чего оба source сливаются в один frozen runtime WindowConfig без альтернативного config, manifest или registry.
- PRD-AC-030: Pause окна исключает все его UINavigationEnabled descendants из navigation graph, временно снимает их selectability и interactability и очищает принадлежащий ему GuiService.SelectedObject. Resume восстанавливает свойства и допустимый last-selected либо default focus без fallback search только при отсутствии effective blocking; при сохраняющемся manual token eligibility остаётся снятой и SelectedObject nil до последнего release.
- PRD-AC-032: Подписчик общего потока получает значения одного каталога UIActionId как для пользовательского действия, так и для lifecycle-события окна.
- PRD-AC-033: Базовые контроллеры публикуют вход/выход указателя, активацию кнопки, focus/unfocus/подтверждение TextBox и submit/cancel формы, не публикуя введённый текст.
- PRD-AC-034: Два элемента с одинаковым итоговым UIElementId приводят к типизированной ошибке инициализации; ни один частично зарегистрированный элемент затронутой иерархии не остаётся доступным системе.
- PRD-AC-036: На ПК, мобильном устройстве и консоли или при геймпадном управлении клиент успешно инициализирует UiRoot, выполняет основные операции окон и предоставляет доступные HudHost и ToastHost.
- PRD-AC-038: Конкретная игровая система размещает принадлежащее ей внутриигровое уведомление в ToastHost и самостоятельно показывает и удаляет его без участия универсальной toast-очереди, таймера или lifecycle-контроллера UiSystem.
- PRD-AC-039: Во время optional Open или Close transition отдельный transition token блокирует пользовательский ввод только при доступном подходящем GuiObject через BlockObjectRef, а без него инертен; operation gate всегда возвращает busy новому stack-запросу. Переход завершается после hook в пределах 3 секунд; обычная ошибка завершает forced UI cleanup и base-state recovery, а timeout возвращается на deadline после base-state recovery и помещает pooled view и lease в quarantine до фактического завершения hook.
- PRD-AC-040: При отсутствующем обязательном host-контейнере инициализация UI-системы возвращает типизированную ошибку; ни одна из UI-подсистем не остаётся доступной в частично инициализированном состоянии.
- PRD-AC-041: После respawn или замены Character продолжают существовать те же UiSystem и UiRoot, а активные окна и содержимое HudHost и ToastHost не очищаются и не пересоздаются автоматически самой UI-системой; только Character-зависимые представления выполняют собственную необходимую реакцию.
- PRD-AC-042: На устройстве с platform safe area каждый host-контейнер ограничивает содержимое безопасной экранной областью, а конкретное представление может независимо адаптировать свой внутренний layout внутри неё.
- PRD-AC-048: После изменения viewport, ориентации экрана или platform insets host-контейнеры обновляют safe area без повторной инициализации UiRoot, а вложенные представления получают новые доступные границы.
- PRD-AC-049: Любой новый Open или Close того же окна во время выполняющегося Open либо Close немедленно возвращает типизированный no-op результат, не ожидает исходную операцию, не перезапускает, не прерывает и не разворачивает текущий переход, не создаёт дополнительный переход или экземпляр окна и не изменяет завершение исходной операции.
- PRD-AC-050: Project-specific HUD-контроллер получает HudHost через явную клиентскую композицию, размещает в нём принадлежащее ему представление и самостоятельно управляет его отображением и очисткой без регистрации HudId или вызова общего HUD lifecycle API в UiSystem.
- PRD-AC-051: Окно с optional transition hook успешно завершает Open или Close только после hook в пределах общего трёхсекундного operation deadline; окно без hook не добавляет asynchronous ожидание, а hook не запускает detached mutations после операции. Timeout возвращает ошибку на deadline, а pooled view не переиспользуется до завершения hook и последующих UI Clear и штатного Release.
- PRD-AC-053: После успешного слияния и инициализации runtime WindowConfig и его definitions заморожены, UI-система не предоставляет runtime API для их добавления, удаления или замены, а доступный набор и содержимое definitions остаются неизменными до завершения текущего UiSystem.
- PRD-AC-054: Duplicate WindowId внутри одного authoring source либо между TemplateWindowConfig и DerivedWindowConfig, а также запись без обязательного поля, включая MaxActive или MaxRetained у pooled-определения, приводят к типизированной ошибке инициализации без частичного runtime WindowConfig.
- PRD-AC-055: При AllowInsertFreeAssets=false для известного WindowId оконная подсистема асинхронно загружает только AssetId из authoring allowlist frozen WindowConfig без runtime owner verification, проверяет единственный GUI-root и рекурсивное отсутствие любого LuaSourceContainer, preloads content через ContentPreloader и возвращает типизированную ошибку без изменения стека при неудаче.
- PRD-AC-056: При первом успешном открытии наблюдаемый порядок равен cloud load и content preload при необходимости, constructor, синхронный Initialize без yield, немедленное добавление окна как Active Window, optional Open transition, итоговый пересчёт видимости и возврат действительного WindowHandle(BaseWindowView); operation gate блокирует новые stack operations, а ввод блокируется только при BlockObjectRef.
- PRD-AC-057: Два конкретных окна принимают разные типы ViewModel и самостоятельно проверяют их на динамической границе; несовместимая модель завершает Open типизированной ошибкой без частично открытого окна.
- PRD-AC-058: Повторное открытие pooled-окна получает новое поколение lease из homogeneous pool этого WindowId, не вызывает constructor повторно, выполняет Initialize с новой ViewModel до добавления в стек и не сохраняет модель предыдущей выдачи.
- PRD-AC-059: Асинхронное открытие возвращает действительный WindowHandle только после состояния Open. Успешное асинхронное закрытие возвращается только после состояния Closed и применения lifecycle policy; обычная ошибка возвращается после forced UI cleanup удалённого окна и base-state recovery, а timeout продолжающегося hook возвращается на трёхсекундном deadline после base-state recovery и оставляет pooled view и lease в quarantine до завершения hook.
- PRD-AC-060: Replacement A на B сначала загружает, preloads, создаёт или acquires и синхронно инициализирует B без изменения стека, затем закрывает и удаляет A, добавляет B поверх неизменённого нижнего префикса и немедленно делает его Active на время Open; operation gate возвращает busy, а ввод блокируется только при BlockObjectRef. Видимость пересчитывается один раз после успеха или failure recovery.
- PRD-AC-061: При Preload true eager cloud load, recursive validation и relevant content preload начинаются и ожидаются во время инициализации UiSystem не более 3 секунд; их error или timeout не блокирует успешную инициализацию UiSystem и не создаёт постоянный failure cache, а следующий Open повторяет все незавершённые фазы до создания окна. При отсутствующем или false флаге фазы откладываются до первого Open.
- PRD-AC-062: После первой успешной cloud-загрузки и content preload два последовательных создания непуленного окна используют разные клоны одного кешированного template без повторного cloud load или preload.
- PRD-AC-063: Первая неуспешная lazy cloud-загрузка, проверка или content preload возвращает ошибку без изменения стека и постоянного failure cache, а следующий независимый Open выполняет новую попытку; неуспешная eager-попытка также не создаёт failure cache и повторяется при следующем Open.
- PRD-AC-064: Окно без входных данных получает Initialize с nil перед Open; окно с конкретной ViewModel отвергает несовместимую модель типизированной ошибкой до изменения стека.
- PRD-AC-065: CloseWindowAsync без параметров делегирует WindowNavigator закрытие текущего верхнего окна, после чего видимость оставшихся окон соответствует пересчитанному стеку, прежний WindowHandle недействителен, а результат содержит только типизированный успех или ошибку без handle другого окна.
- PRD-AC-066: AddWindowAsync после Pause прежнего top добавляет новое окно поверх текущего стека и немедленно делает его Active, сохраняет нижний префикс и выполняет итоговый пересчёт видимости после успеха или recovery; operation gate отклоняет stack operations, а transition token блокирует ввод только при BlockObjectRef.
- PRD-AC-067: После закрытия pooled-окна его прежние WindowHandle и generation lease недействительны; повторная выдача того же объекта создаёт новое поколение, на которое старые handle и lease не могут воздействовать.
- PRD-AC-069: Ошибка подготовки B до изменения стека синхронно выполняет UI Clear и configured lifecycle временного B через существующие pool operations либо destroy policy и оставляет A, нижний префикс и видимость неизменными.
- PRD-AC-070: Если A уже удалено, а Open B завершается ошибкой или timeout, operation generation инвалидируется, B исключается из доступного состояния, A остаётся удалённым, видимость нижнего префикса пересчитывается, его top C получает синхронный Resume и восстанавливает ввод и focus только без effective blocking, после чего возвращается ошибка без handle B; при отсутствии C стек остаётся пустым. Обычная ошибка завершает forced UI cleanup B, а timeout продолжающегося hook помещает pooled B и lease в quarantine до завершения hook, UI Clear и штатного Release.
- PRD-AC-071: UiSystem успешно открывает первое окно по запросу внешней клиентской системы при пустом стеке; при непустом стеке прямой запрос внешней системы или неверхнего окна возвращает ошибку, а текущее Active Window может запросить Add, собственный Close или replacement после полученного domain event.
- PRD-AC-072: Одна navigation operation владеет одним трёхсекундным deadline и generation; другой stack-запрос получает busy без очереди, а late completion не выполняет WindowNavigator-owned commit благодаря stale-generation check. Timed-out pooled view и lease не проходят UI Clear, Release или повторную выдачу до фактического завершения hook; произвольные custom side effects framework не откатывает.
- PRD-AC-073: Если B подготовлено для replacement A, но Close transition A завершается ошибкой или timeout, generation инвалидируется, A удаляется из стека, нижний префикс сохраняет порядок, его top получает Resume и focus только без effective blocking, видимость пересчитывается и возвращается типизированная ошибка. Обычная ошибка выполняет forced UI cleanup A и B через configured lifecycle; timeout продолжающегося hook применяет quarantine-контракт к каждому затронутому pooled view, а остальные prepared views проходят обычный cleanup.
- PRD-AC-074: Во время replacement нижний префикс не меняет состав или порядок и не получает промежуточные Show или Hide между удалением A и итогом Open B; один пересчёт и соответствующие events выполняются после успешного Open либо завершённого recovery.
- PRD-AC-075: Действительный WindowHandle(ConcreteWindowView) возвращает правильный WindowId, true из IsValid и concrete view из GetView как в Active, так и в Paused состоянии; IsActiveWindow true только для последнего элемента стека, а после удаления тот же handle возвращает false и stale-handle result без доступа к повторно выданному view.
- PRD-AC-076: Ошибка или timeout Close принудительно удаляет закрываемое окно и инвалидирует ранее выданный WindowHandle. Обычная ошибка выполняет UI Clear и configured lifecycle через существующие pool operations либо destroy policy; timeout продолжающегося hook помещает pooled view и lease в quarantine до завершения hook, UI Clear и штатного Release, поэтому прежний handle не предоставляет view ни до, ни после cleanup.
- PRD-AC-077: После успешного синхронного Initialize UiSystem не сохраняет переданную ViewModel; конкретное окно продолжает работу только с сохранёнными им данными, а Clear удаляет принадлежащее окну runtime-состояние.
- PRD-AC-078: При стеке A, B только B может запросить Add, собственный Close или replacement; такой запрос от A или внешней системы возвращает типизированную ошибку и оставляет стек неизменным, тогда как domain event внешней системы сам по себе стек не меняет.
- PRD-AC-079: Конкретное окно переопределяет Pause для остановки принадлежащей ему runtime-логики и Resume для её восстановления, тогда как другое окно без override корректно использует синхронные default no-op реализации BaseWindowView.
- PRD-AC-080: При добавлении KeepBelow-окна B поверх A hook Pause окна A синхронно завершается до добавления B; B немедленно становится Active, operation gate занят, а его ввод блокируется transition token только при BlockObjectRef; A остаётся видимым и Paused. После удаления B Resume окна A завершается до восстановления focus и ввода только без effective blocking.
- PRD-AC-081: При добавлении HideBelow-окна B hook Pause окна A завершается до скрытия и события Hide; после закрытия B hook Resume окна A завершается до показа и события Show, а focus и ввод восстанавливаются только без effective blocking.
- PRD-AC-082: При замене A на B нижнее окно C, остающееся Paused до и после успешной операции, не получает промежуточных Pause, Resume, Hide или Show, а нижний префикс сохраняет состав и порядок.
- PRD-AC-083: При закрытии верхнего окна B его custom Pause не вызывается; после удаления B остающееся последним окно A немедленно является Active, получает синхронный Resume и снятие pause token, а navigation eligibility, focus и ввод восстанавливаются только если effective blocking отсутствует.
- PRD-AC-084: Сразу после добавления нового B IsActiveWindow возвращает true и operation gate отклоняет новые stack operations; transition token блокирует ввод, base action handlers и focus только при BlockObjectRef. После успешного Open снимается только transition token, а focus назначается только без effective blocking.
- PRD-AC-085: Для Paused Window базовые action handlers и AddWindowAsync гарантированно отклоняются по Active/Paused authority независимо от BlockObjectRef, но его таймер продолжает работать при default no-op Pause и останавливается только тогда, когда конкретное окно переопределяет Pause соответствующим поведением.
- PRD-AC-086: Искусственная ошибка синхронного custom Pause диагностируется, но прежнее окно всё равно получает base Paused state, pause token и исключение из navigation graph; ошибка custom Resume сохраняет базовое Active-состояние, а eligibility и ввод возвращаются только без effective blocking.
- PRD-AC-087: Если A получает Pause перед добавлением B, но Open B завершается ошибкой или timeout, generation инвалидируется, B исключается из доступного состояния, A получает ровно один Resume и возвращает ввод и допустимый focus только без effective blocking, а стек и итоговая видимость совпадают с состоянием до AddWindowAsync. Обычная ошибка выполняет forced UI cleanup B через configured lifecycle, а timeout продолжающегося hook применяет quarantine-контракт к pooled B и lease.
- PRD-AC-088: При последовательности Add B, неизменяющий active-статусы пересчёт, Close B окно A получает один Pause и один Resume; промежуточный пересчёт не вызывает дополнительные hooks.
- PRD-AC-089: Во время Open transition добавленного B прежнее окно A уже Paused, его base handlers и navigation отклонены по Paused authority; B уже является Active Window, operation gate занят, а transition token блокирует его ввод и focus только при BlockObjectRef.
- PRD-AC-090: Handle окна A после добавления B возвращает true из IsValid(), false из IsActiveWindow() и concrete view из GetView(), но вызов AddWindowAsync через полученный Paused view возвращает типизированную ошибку разработчика без изменения стека.
- PRD-AC-091: После перехода A в базовое состояние Paused общий поток UiRoot получает ui.window.paused с WindowId A, а после Resume и применения Active-состояния получает ui.window.resumed; искусственная ошибка соответствующего custom hook диагностируется, но не подавляет событие применённого базового состояния.
- PRD-AC-092: Через действительный handle Paused окна вызывающая система успешно вызывает его custom-метод, тогда как AddWindowAsync того же view отклоняется проверкой Active Window; результат custom-метода определяется самим конкретным окном.
- PRD-AC-093: Concrete BaseWindowView переопределяет parameterless Pause и Resume, и WindowNavigator вызывает их без передачи visibility, reason, WindowId соседнего окна или другого context.
- PRD-AC-094: Две попытки создать одно окно в пределах одного UiSystem после первой успешной cloud-загрузки и content preload используют клоны одной закешированной актуальной версии template без повторного разрешения или preload; новый UiSystem снова разрешает актуальную доступную версию по тому же AssetId.
- PRD-AC-095: При корректном BlockObjectRef у окна A одновременно активны ручной blocking token и system-owned pause token; после Resume освобождается только pause token, поэтому effective blocking и режим InputSink All сохраняются до release ручного token, eligibility и focus не восстанавливаются раньше. Без BlockObjectRef оба tokens инертны.
- PRD-AC-096: У Active Window без Background ввод через точку, где отсутствует геометрия любого GuiObject WindowHost и включённого InputSink, достигает интерактивного элемента HudHost или ToastHost.
- PRD-AC-097: Ввод, попавший в InputSink Paused Window в режиме All через BlockObjectRef, не вызывает его действие или закрытие и не достигает расположенного ниже окна, HUD или toast; без BlockObjectRef tokens инертны, а base handlers и navigation Paused Window отдельно отклоняются по Paused authority.
- PRD-AC-098: При скрытии A после добавления B поток UiRoot получает ui.window.paused A до события скрытия A; при закрытии B поток сначала получает событие закрытия B, затем ui.window.resumed A и только после него событие показа A.
- PRD-AC-099: Payload ui.window.paused и ui.window.resumed содержит WindowId соответствующего окна и не содержит reason, соседний WindowId, visibility, stack depth или определяемые конкретным окном дополнительные поля.
- PRD-AC-100: Universal AddWindowAsync с WindowId и unknown ViewModel возвращает WindowHandle(BaseWindowView), тогда как AddWindowTypedAsync с каноническим WindowDefinition(TView, TViewModel) и TViewModel после value-level runtime-witness проверки возвращает WindowHandle(TView) без второго config или registry.
- PRD-AC-101: Typed definition с неверной identity либо failing TryCastView отклоняется до изменения стека; временный экземпляр проходит configured UI cleanup, а вызывающая сторона получает typed mismatch error без WindowHandle.
- PRD-AC-102: Universal replacement возвращает WindowHandle(BaseWindowView), typed replacement через CloseWindowTypedAsync возвращает WindowHandle(TView), и обе формы сохраняют один lifecycle и failure contract WindowNavigator.
- PRD-AC-103: После истечения единого трёхсекундного navigation deadline late completion async load, preload, Open или Close с устаревшей generation не выполняет WindowNavigator-owned commit в stack, handle registration, system tokens, focus, navigation state или lifecycle events; base recovery завершается перед timeout error, а timed-out pooled view и lease остаются недоступными до завершения hook, последующих UI Clear и штатного Release. Если hook не завершается, lease не возвращается в пул; generic rollback custom side effects не гарантируется.
- PRD-AC-104: При BlockObjectRef base action handler Active Window с effective blocking token и handler любого Paused Window завершаются без публикации действия; без BlockObjectRef tokens не блокируют handler, но Paused authority продолжает действовать. Незаблокированный Active Window публикует действие через ownership bubbling и затем через обычный UiRoot repo Signal.

## Assumptions

## Open Questions

## Risks
