---
document_type: product-requirements
status: approved
revision: 3
language: Russian
approved_at: 2026-08-07T10:19:29.427Z
---

# Product Requirements

## Product Outcome

Дать разработчику единый безопасный интерфейс воспроизведения аудио без
ручного создания, связывания и очистки Roblox audio-объектов для каждого
запроса. Игрок должен получать отзыв без сетевой задержки для собственных
действий, слышать общие события других игроков и воспринимать пространственные
источники из правильной точки мира. Ordinary sounds и Music должны быть
разделены на две подсистемы с разными публичными API, состоянием, политиками
пулов и жизненным циклом, но использовать общий каталог аудио и общий mix graph.

## Target Audience

- Разработчики игр на основе шаблона, которые вызывают музыку и звуковые
  эффекты из игрового и UI-кода.
- Контент-разработчики, которые ведут каталог звуков и их параметры через
  CSV с детерминированной генерацией Luau-конфига.
- Игроки, которым нужны своевременный локальный feedback, согласованные общие
  звуки и корректная пространственная локализация.

## Core Gameplay Loop

1. Игровая система запрашивает ordinary sound, передавая идентификатор, явно
   выбранное семейство доставки и, для пространственного звука, источник
   позиции; либо клиентская система добавляет Music request в LIFO-стек.
2. Соответствующая подсистема разрешает и проверяет идентификатор и параметры
   запроса через общий неизменяемый аудиокаталог.
3. Ordinary sound воспроизводится локально, через штатную server replication
   или, только для one-shot, предиктивно у инициатора с best-effort доставкой
   остальным игрокам.
   Music-подсистема воспроизводит только верхнюю готовую запись своего
   клиентского стека, останавливая нижележащие записи с сохранением позиции.
4. После завершения, остановки, удаления Music entry или ошибки владеющая
   подсистема полностью освобождает ресурсы конкретного воспроизведения и
   возвращает переиспользуемые объекты в принадлежащий ей пул.

## Release Target

Первая версия предназначена для клиент-серверных Roblox-плейсов, создаваемых
на основе этого шаблона. В поставку входят 2D-звуки, пространственные звуки,
клиентская музыка, три режима доставки ordinary sounds, конфигурируемая
маршрутизация и управление жизненным циклом. Локально-серверный режим ограничен
one-shot событиями и не владеет distributed loop state. Основным способом
воспроизвести общий звук для всех игроков является server-all вызов со штатной
репликацией Roblox. Локально-серверный режим остаётся узким дополнительным
инструментом для некритичного one-shot feedback, где важен немедленный звук у
инициатора. Каталог звуков и
routing-конфиг являются статическими,
локальными Luau-таблицами в DataModel, версионируются вместе со сборкой и
применяются только при полной инициализации новой версии игры.

## Scope

### In Scope

- Каталог аудио, генерируемый из CSV в проверяемый Luau ModuleScript.
- Локальные Luau-конфиги параметров звуков, доступных типов плееров, жёстких
  лимитов, routing audio graph, spatial profiles и профилей громкости фейдеров.
- Обычные непространственные звуки.
- Пространственные звуки в заданной точке мира или прикреплённые к конкретному
  позиционируемому объекту.
- Отдельная клиентская Music-подсистема с LIFO-стеком независимых запросов,
  одним steady-state playing track и стратегиями перехода `Instant`,
  `SequentialFade` и `Crossfade` при добавлении и удалении верхней записи.
- Локальное и серверное воспроизведение ordinary sounds, включая one-shot и
  looped варианты; локально-серверное воспроизведение только one-shot ordinary
  sounds.
- Владение пулами и полным жизненным циклом объектов воспроизведения.
- Встроенные категории `UI`, `SFX`, `World`, `Music` и общий уровень `Master`.
- Управление громкостью отдельных категорий и всего результирующего аудио.
- Хранение пользовательских уровней громкости и признаков включения категорий
  через общий жизненный цикл user data, без отдельного аудио-хранилища.
- Разрешение звука по Roblox asset ID и по поддерживаемым каталогом ресурсов
  идентификаторам.

### Out of Scope

- Постоянный отдельный плеер на каждую кнопку, игровой объект или запись
  каталога.
- Передача Roblox `Instance` через сетевой протокол.
- Указание клиентом другого игрока как адресата звукового запроса.
- Проигрывание произвольного неразрешённого asset ID, полученного от клиента,
  остальным игрокам.
- Хранение исходного аудиофайла внутри Luau-конфига или встраивание его байтов
  в `place.rbxl`.
- Ручное управление `AudioPlayer`, `AudioEmitter`, `AudioFader` и `Wire` из
  вызывающих игровых модулей.
- Публичные `Pause`, `Resume` и произвольный `Seek` ordinary sounds. Внутренняя
  остановка и продолжение Music entry с сохранённого `TimePosition` входят в
  обязательный жизненный цикл Music-стека.
- Сохранение активных ordinary playback handles, Music stack, текущей позиции
  трека или другого runtime playback state между игровыми сессиями.
- Выбор gameplay-музыки по локальному или реплицированному серверному состоянию
  внутри Music-подсистемы; это ответственность вызывающей клиентской игровой
  системы.
- Server-all либо client-hybrid Music API, синхронизация музыки между клиентами,
  distributed current-track state, replay и фазовая синхронизация между
  клиентами.
- Looped client-hybrid playback, distributed loop handles, owner desired-state,
  loop snapshot/resync projection и application-level start/stop synchronization.
- Client-hybrid attached playback и любые сетевые ссылки на runtime-объекты.
  В первой версии client-hybrid поддерживает только непространственный и
  point one-shot; attached остаётся только client-local и server-all.
- Полный production-цикл `AudioSystem:Stop() -> Initialize()` внутри одной
  игровой VM. Подсистемы инициализируются один раз на bootstrap; остановка
  конкретных воспроизведений, `StopAllMusic` и очистка частично созданных
  ресурсов после ошибки остаются обязательными.
- Произвольные суммарные ограничения на число строк, размер всего каталога или
  число кандидатов в ресурсной папке до появления измеримой проблемы. Первая
  версия проверяет каждую запись и каждый запрос, но не отклоняет валидный
  каталог только из-за заранее угаданного общего размера.

## Terminology

- **Audio playback feature** — общий L0-контур этой feature: общий каталог,
  локальные конфиги, mix graph и две отдельные runtime-подсистемы.
- **Ordinary sound subsystem** — server/client подсистема для `UI`, `SFX` и
  `World`, владеющая local, server-all и client-hybrid воспроизведением,
  ordinary FIFO и spatial sources. Client-hybrid ветка владеет только
  непространственным и point best-effort one-shot delivery, не поддерживает
  attached-вызовы и не хранит distributed playback state.
- **Music subsystem** — client-only подсистема, владеющая Music request stack,
  переходами, Music handles и Music pool; она не выбирает gameplay-музыку.
- **Music entry** — одна принадлежащая вызывающей системе запись LIFO-стека с
  собственным opaque handle, generation-safe lease, `SoundRef`, состоянием
  загрузки и сохранённым `TimePosition`.
- **Top Music entry** — последняя не удалённая запись стека. После её готовности
  только она может быть steady-state playing track; пока новая top entry
  pending, уже звучавшая нижняя entry может оставаться audible incumbent, но
  другая нижняя pending entry не обходит top.
- **Audible Music incumbent** — единственная entry, которая уже звучит либо
  участвует в переходе, даже если новая structural top entry ещё pending. Она
  может быть non-top; `Stop` и natural `Ended` ветвятся по audible-роли, а не
  только по позиции в стеке.
- **Active pool lease** — выданная и ещё не освобождённая generation lease.
  Остановленная нижняя Music entry остаётся active lease с точки зрения пула,
  хотя её `AudioPlayer` не играет.
- **Ready client** — клиент, подтвердивший точную активную communication
  snapshot epoch и допущенный Communication к обычной доставке.

## Functional Requirements

- `PRD-REQ-001` Система должна загружать упорядоченный каталог звуков,
  представленный сгенерированным из CSV Luau-модулем. Невалидная отдельная
  запись должна быть пропущена с warning, не прерывая игровой bootstrap. Если
  один точный `AssetId`, `AssetKey` или `ResourcePath` объявлен несколькими
  разными записями, соответствующий индекс должен
  детерминированно сохранить первую валидную привязку в порядке исходных строк,
  проигнорировать только конфликтующую последующую привязку и записать warning
  в Log; остальные уникальные идентификаторы последующей записи остаются
  доступными. Полностью нечитаемый каталог должен перевести SFX в безопасный
  no-op режим, а не ломать gameplay.
- `PRD-REQ-002` Каждая строка каталога должна описывать один конкретный вариант
  и содержать стабильные `CueId`, `VariantId` и `PlayerType`. Один `CueId` может
  повторяться в нескольких строках и объединяет их в логическую коллекцию;
  `VariantId` должен быть уникален внутри неё. Вариант должен объявлять хотя бы
  одно скалярное поле `AssetId`, `AssetKey` или `ResourcePath` и может объявлять
  несколько этих типов одновременно. Каждый объявленный идентификатор входит
  в собственный индекс и ведёт к точному варианту, его audio asset ID и типу
  плеера. Строка может опционально задавать `Volume01`, `PlaybackSpeed`,
  `Looping`, `Preload`, `PlaybackRegionStart`, `PlaybackRegionEnd`,
  `LoopRegionStart`, `LoopRegionEnd`, `SpatialProfile`, `Weight` и
  `AllowClientHybrid`.
  Отсутствующие поля получают значения по умолчанию: `Volume01 = 1`,
  `PlaybackSpeed = 1`, `Looping = false`, `Preload = false`, а отсутствующие
  playback/loop regions означают полный трек. `Weight` должен быть конечным
  числом больше нуля; отсутствие либо невалидное значение использует `1` и
  создаёт warning. `AllowClientHybrid` по умолчанию равен false и является
  явным разрешением клиенту запрашивать рассылку варианта; server-all вызовы
  доверенных серверных модулей этим флагом не ограничиваются. Для `Music`
  значение true не разрешает hybrid delivery, игнорируется с warning и не
  исключает вариант из client-local использования. Для типа `World` отсутствие
  `SpatialProfile` выбирает встроенный default spatial profile. Первая валидная
  строка каждого `CueId` задаёт `PlayerType` коллекции. Последующий вариант с
  другим `PlayerType` не входит в случайную коллекцию и создаёт warning, но
  остаётся доступным через собственные уникальные идентификаторы. Первая строка
  также задаёт общую `AllowClientHybrid` policy cue; конфликтующие последующие
  значения игнорируются с warning.
- `PRD-REQ-003` Запрос воспроизведения должен принимать `CueId`, нормализованный
  Roblox asset ID, стабильный `AssetKey` или канонический `ResourcePath`.
  Запрос по `CueId` случайно выбирает один вариант коллекции, а каждый из трёх
  идентификаторов конкретного варианта выбирает именно этот вариант. SFX-каталог
  должен использовать отдельный индекс для каждого типа идентификатора и не
  должен искать шаблонный `AudioPlayer`. Если ни один индекс не разрешает
  переданный идентификатор, система не должна воспроизводить звук или изменять
  пул и должна выдать безопасное предупреждение через общий `Logger`.
- `PRD-REQ-004` Система должна воспроизводить непространственный звук с
  одинаковой слышимостью независимо от позиции и ориентации игрока. Обычный
  вызов не должен принимать мировую позицию или объект-источник.
- `PRD-REQ-005` Система должна воспроизводить пространственный звук из
  переданной мировой позиции через отдельный вариант вызова. Другой отдельный
  вариант должен прикреплять воспроизведение к позиционируемому объекту и
  следовать за ним. Client-local attached принимает локальный `Instance`.
  Server-all attached принимает доверенный server-visible позиционируемый
  `Instance`, создаёт server-owned `AudioEmitter` и требует, чтобы источник был
  доступен штатной репликации Roblox. Client-hybrid attached API в первой
  версии отсутствует; сетевой payload не содержит ссылку на runtime-объект.
  Позиционируемым считается `Attachment`, `Camera` или `PVInstance`. Attached
  wrapper сохраняет emitter под
  pool-owned active parent, устанавливает
  `AudioEmitter.PositionType = Enum.EmitterPositionType.Instance` и
  `PositionInstance = validatedSource`; он не parent-ит pooled emitter внутрь
  source. Неизвестный, неразрешённый,
  неавторизованный или уничтоженный источник даёт предупреждение через общий
  `Logger` и no-op либо
  останавливает уже активную аренду, очищает `PositionInstance` и полностью
  освобождает ресурсы, но никогда не ломает gameplay.
  Point-вызов принимает только позицию и всегда использует ненаправленный
  spatial profile; профиль с направленной `AngleCurve` отклоняет конкретный
  point-вызов с предупреждением через общий `Logger` до получения pool lease.
- `PRD-REQ-006` Ordinary sound subsystem и Music subsystem должны владеть
  только своими конкретными именованными пулами внутри injected side-owned
  `PoolModule`; они не владеют самим registry. Отдельный публичный полный
  `Stop` audio runtime и повторная production-инициализация первой версией не
  предоставляются.
  Сервер владеет отдельными пулами реальных реплицируемых playback wrappers для
  server-all ordinary sounds, а каждый клиент — отдельными ordinary pools для
  client-local и полученных client-hybrid звуков; Music subsystem владеет
  отдельным client-only Music pool.
  Каждый ordinary sound получает отдельную активную аренду и единую
  идемпотентную границу завершения. Эта граница владеет арендой, handle,
  ожиданием готовности и timeout, обработчиками событий, временными связями,
  источником позиции и всеми частично созданными объектами конкретного
  воспроизведения. Естественное завершение, явная остановка, FIFO-вытеснение,
  отмена, ошибка, потеря источника и неготовность обязаны проходить через неё;
  повторный или запоздалый сигнал ничего не освобождает второй раз. После
  закрытия все ресурсы очищены или возвращены в правильный owning pool. Когда
  любой пул типа достигает своего active-лимита,
  owning runtime должен остановить и полностью освободить самое старое ordinary
  playback этого типа **до** вызова нового `Acquire`, после чего использовать
  освобождённый плеер для нового запроса. Pending-аренда учитывается в
  active-лимите owning pool и FIFO с момента выдачи, её handle
  считается активным, а `Stop` отменяет ожидание загрузки и не позволяет
  запустить звук позднее. Событие `Ended` используется только для естественного
  завершения non-looping playback; `Stop`, FIFO и timeout освобождают
  generation-safe аренду напрямую и не зависят от получения `Ended`.
  Server wrapper в idle-состоянии находится под server-only pool parent. Перед
  server `Play()` owning runtime полностью настраивает wrapper и последним
  действием переносит весь активный graph под явно реплицируемого предка. Release
  выполняет `Stop`, отключение/reset, очистку source refs и возврат под idle
  parent. Music pool не использует ordinary FIFO и подчиняется отдельному
  Music stack contract ниже.
- `PRD-REQ-007` Из коробки должны существовать категории воспроизведения
  `UI`, `SFX`, `World` и `Music`, а также общий уровень `Master`. Категория
  `SFX` предназначена для непространственных игровых звуков, не относящихся к
  UI.
- `PRD-REQ-008` Система должна построить и проверить audio graph при
  инициализации на основе явного конфига связей. Отдельный manifest-owned
  AudioGraph subsystem является единственным владельцем persistent graph и
  публикует клиентам только полностью собранную и проверенную generation под
  стабильным runtime-контейнером. Клиент принимает generation только после
  проверки полного ожидаемого состава и при timeout публикует локальный no-op
  audio runtime без скрытого поиска по DataModel или использования
  `AssetRegistry` как runtime locator. Сервер создаёт один постоянный
  реплицируемый mix graph: server-owned 2D sources подключаются к category
  faders `UI` или `SFX`, а category faders — по routing-конфигу к
  `Master`. Каждый server-owned `World` source подключается только к своему
  lease-owned `AudioEmitter`; пространственные потоки смешиваются после их
  восприятия client-owned `AudioListener`, чей выход подключается к `World`,
  затем к `Master`. Persistent category/Master faders и fader-to-fader wires
  принадлежат серверу и реплицируются. `AudioDeviceOutput`, `AudioListener`,
  `Listener -> World` и `Master -> AudioDeviceOutput` принадлежат каждому
  клиенту; сервер не создаёт общий device output. Клиентские local/hybrid
  `UI`/`SFX` sources и client-only Music sources подключаются к локальным
  репликам соответствующих category faders. Каждый client-local/hybrid `World`
  source подключается только к собственному `AudioEmitter` и попадает в
  `World` fader исключительно через общий client-owned listener; прямой
  source-to-`World` либо source-to-`Master` wire запрещён. Разные
  World sources не смешиваются до сохранения отдельных emitter-позиций. SFX
  emitters и listener используют private interaction group, исключающий
  двойной вывод через default listener и смешивание с unrelated audio.
- `PRD-REQ-009` Каждый клиент должен иметь отдельный bounded LIFO-стек Music
  entries. В steady state играет не более одной записи: готовая top entry либо
  прежняя audible incumbent, пока более новая top entry ожидает readiness.
  Каждая нижняя готовая запись сохраняет собственную active Music lease, останавливает
  `AudioPlayer` с сохранением текущего `TimePosition` и может быть продолжена с
  этой позиции, когда снова станет верхней. Сохранённая позиция дублируется в
  собственном entry state и не полагается только на engine property. Перед
  каждым resume runtime повторно проверяет `IsReady`: при false entry становится
  bounded pending/reload, после readiness заново проверяет region/`TimeLength`,
  восстанавливает сохранённый `TimePosition` и только затем вызывает `Play()`;
  reload timeout удаляет только эту entry и повторно выбирает верх стека. Во
  время `Crossfade` временно могут
  звучать ровно две соседние записи, но после перехода играет только верхняя.
  Pending entries также занимают stack slot и pool lease. Если достигнут
  `MusicStackMaxDepth`, новый push отклоняется с предупреждением через общий
  `Logger` и не изменяет
  существующий стек или слышимый track; Music не использует FIFO-вытеснение.
- `PRD-REQ-010` Локальный запрос должен воспроизводить звук только на клиенте,
  который его инициировал, без сетевого сообщения.
- `PRD-REQ-011` Server-all вызов доступен только доверенному серверному коду и
  является рекомендуемым обычным способом воспроизвести общий звук для всех
  игроков.
  После валидации он получает аренду из server-owned пула, настраивает
  server-owned `AudioPlayer` и требуемый graph и вызывает `AudioPlayer:Play()`.
  Создание instances, свойства, play/stop state и пространственный источник
  распространяются штатной Roblox replication. SFX не отправляет application
  play command отдельным клиентам, не формирует recipient list и не проверяет
  client readiness. Позднее подключение, streaming и фактический старт на
  клиентах следуют штатному Roblox audio replication без дополнительного replay
  или фазовой компенсации со стороны SFX.
- `PRD-REQ-012` Специализированный локально-серверный запрос для некритичного
  one-shot feedback должен начать локальное воспроизведение у инициатора без
  ожидания round trip, затем отправить на
  сервер компактное намерение. Клиент обязан разрешить любой исходный
  `SoundRef`, включая `FolderPath`, в один точный вариант **до** network send;
  исходный identifier и путь к папке через сеть не передаются. После серверной
  проверки сервер ставит другим ready-клиентам точный `CueId + VariantId` как
  best-effort `Presentation`
  event без acknowledgement, retry или replay. Событие может быть отброшено
  Communication при backpressure; если оно доставлено, получатель исполняет его
  не более одного раза. Инициатор не должен получить дублирующее
  воспроизведение. Сервер обязан определять инициатора из
  доверенного контекста входящего communication-сообщения и исключать именно
  его из списка получателей; клиентский payload не может указывать или
  подменять исключаемого игрока. Если сервер отклоняет намерение, уже начатый
  локальный one-shot не отменяется автоматически и не рассылается остальным.
  Для критического действия вызывающий доменный код должен сначала получить
  серверное решение и только затем инициировать подходящее воспроизведение;
  SFX-система не определяет критичность игрового действия самостоятельно.
  Client-hybrid API принимает только вариант с эффективным `Looping = false`.
  Оно предоставляет только непространственный и point-вызов; attached-вызов
  отсутствует.
  Попытка запросить looped вариант отклоняется с предупреждением через общий
  `Logger` до локального
  acquire и до network send; для loops вызывающая система выбирает client-local
  либо server-all API.
- `PRD-REQ-013` Client-hybrid сеть принимает только каноническую точную пару
  `CueId + VariantId`, выбранную клиентом из общей immutable catalog generation.
  Raw asset ID, `AssetKey`, `ResourcePath` и `FolderPath` остаются только входами
  локального public API и не передаются серверу. Сервер обязан сопоставить
  точную пару с разрешённой записью той же catalog generation, проверить
  `AllowClientHybrid`, player type, effective `Looping`, overrides и point
  position. Неизвестная пара, неподдерживаемый тип, невалидная позиция и
  превышение сетевого или fan-out лимита отклоняются без рассылки и без
  изменения пулов.
- `PRD-REQ-014` Общий communication-модуль используется только для
  client-hybrid ordinary one-shot sounds с
  серверной валидацией, ограничением размера и частоты; отдельный прямой
  gameplay RemoteEvent для SFX не допускается. Каждое hybrid событие использует
  существующую штатную очередь Communication с приоритетом `Presentation`, не
  расширяет Communication protocol новой queue/TTL/freshness возможностью, не
  получает acknowledgement/retry/replay и не входит в snapshot. Backpressure
  может отклонить или вытеснить событие по существующим правилам Presentation.
  Отказ локального `CommunicationClient:Queue` после predicted playback не
  отменяет локальный звук и не запускает retry; он создаёт диагностическую
  запись через общий `Logger`.
  Audio feature не создаёт hybrid `State` messages,
  desired-state registry, owner receipt, distributed playback ID, отдельный
  snapshot `RemoteFunction` или resync handler.
  Server-all ordinary sounds и client-only Music не создают SFX network
  messages, readiness state, snapshot projection или distributed playback
  identity.
- `PRD-REQ-015` Публичный API должен позволять остановить конкретное активное
  воспроизведение через выданный непрозрачный handle, не затрагивая более
  новое использование того же переиспользуемого объекта. Handle первой версии
  предоставляет только проверку активности и `Stop`; основной сценарий —
  one-shot без обязательного сохранения handle вызывающим кодом.
  Server-all loop handle представляет generation-safe server pool lease; его
  `Stop` вызывает `AudioPlayer:Stop()`, освобождает эту аренду, а остановка
  распространяется штатной репликацией. Client-local loop handle останавливает
  только локальную lease. Client-hybrid handle всегда относится к one-shot и
  после fan-out управляет только predicted local playback: его `Stop` не
  отменяет уже отправленное событие у других клиентов. Владелец loop-вызова
  отвечает за хранение и остановку handle.
- `PRD-REQ-016` Локальный startup-конфиг `AudioRuntimeConfig` в
  `ReplicatedStorage.Shared.Configs.Audio` должен перечислять каждый доступный
  тип плеера и жёсткие pool-бюджеты только для поддерживаемых им сторон.
  Server и client initialization непосредственно `require` одну и ту же
  версионируемую Luau-таблицу из DataModel, независимо валидируют её в
  неизменяемую runtime-модель и не используют `ExperienceConfigCatalog`, client
  projection или сетевую доставку конфигурации. Ordinary types объявляют
  `ServerMaxActive`/`ServerMaxRetained` для глобального server-all пула и
  `ClientMaxActive`/`ClientMaxRetained` для local/hybrid пула каждого клиента;
  значение `0/0` явно отключает соответствующую сторону. `Music` объявляет
  только client budget: `ClientMaxActive = MusicStackMaxDepth = 8` и
  `ClientMaxRetained = 2`; server Music budget и pool отсутствуют. Для типа
  также должны быть определены стабильный ID, `SourceVolumeMin`,
  `SourceVolumeMax` и допустимый
  диапазон фактического `PlaybackSpeed`. Source volume должен удовлетворять
  `0 <= Min <= Max <= 10`; встроенные типы по умолчанию используют `0..1`.
  Playback speed должен удовлетворять `0.05 <= Min <= Max <= 20`; встроенные
  типы по умолчанию используют `0.5..2`. Для каждого типа также задаётся
  `LoadTimeoutSeconds` в диапазоне `0.5..30`; стандартные значения равны
  `UI = 2`, `SFX = 3`, `World = 3`, `Music = 15`. Для ordinary types с
  client-hybrid также
  задаются per-type `HybridRatePerSecond` и `HybridBurst`, включая `0/0` как
  отключение режима для типа; значения не могут превышать hard ceilings
  code-owned `AudioSafetyLimits`. Режим воспроизведения и player-to-fader mapping принадлежат
  отдельному static-routing контракту. Server-all
  concurrency ограничивается server pool лимитом типа и его собственным FIFO.
  Встроенные типы для `UI`, `SFX`, `World` и `Music` обязательны. Конфиг может
  настраивать только типы, заранее объявленные в code/static-routing контракте;
  отсутствующая, нечитаемая или невалидная таблица должна преобразоваться
  владеющей подсистемой в frozen disabled-модель и no-op runtime, не отклоняя
  общий gameplay bootstrap. Каждая сторона захватывает одну валидную таблицу
  при инициализации и не изменяет активные типы или лимиты до следующего полного
  bootstrap. Валидатор обязан проверить не только лимит каждого типа, но и
  полную теоретическую сумму active/retained wrappers и их worst-case
  AudioPlayer/AudioEmitter/Wire/anchor cost по каждой стороне. Конфиг, в котором
  отдельные типы валидны, но их сумма превышает code-owned side-wide ceiling,
  целиком переводит audio runtime этой стороны в disabled/no-op до создания
  первого concrete pool или graph object.

  Shipped configurable budgets первой версии:

  | `PlayerType` | `ServerMaxActive` | `ServerMaxRetained` | `ClientMaxActive` | `ClientMaxRetained` | `HybridRatePerSecond` / `HybridBurst` |
  |---|---:|---:|---:|---:|---:|
  | `UI` | 0 | 0 | 24 | 12 | 0 / 0 |
  | `SFX` | 32 | 16 | 32 | 16 | 12 / 16 |
  | `World` | 64 | 32 | 48 | 24 | 12 / 16 |
  | `Music` | — | — | 8 | 2 | — |

  Отдельный code-owned immutable `AudioSafetyLimits` contract, который не
  находится в `Configs` и не меняется authoring-данными, обязан фиксировать
  абсолютные ceilings для валидатора:

  - `MaxPlayerTypes = 32`, `MaxFaders = 32`, `MaxRoutes = 64` и
    `MaxSpatialProfiles = 64`;
  - hard cap `256` для ordinary `MaxActive`, `128` для `MaxRetained` и `16`
    для `MusicStackMaxDepth`;
  - отдельные server/client aggregate active, retained и worst-case graph-object
    ceilings, которым обязана удовлетворять полная сумма всех типов, включая
    Music на клиенте и повышенную стоимость World wrapper;
  - hard cap `30` для `HybridRatePerSecond` и `60` для `HybridBurst`;
  - `HybridAggregateRatePerOwner = 20`, `HybridAggregateBurstPerOwner = 30`,
    `HybridAcceptedRateServer = 128` и `HybridAcceptedBurstServer = 256`;
  - `HybridFanoutRecipientsRateServer = 1024` и
    `HybridFanoutRecipientsBurstServer = 2048`; одна постановка события одному
    получателю расходует один token, а при недостатке tokens для всего текущего
    списка получателей событие целиком отклоняется до первой постановки и не
    создаёт частичную рассылку;
  - `CueId`, `VariantId`, `AssetKey` и `PlayerType` используют case-sensitive
    ASCII grammar из букв, цифр, `.`, `_` и `-`, начинаются с буквы или цифры,
    измеряются в UTF-8 bytes и имеют длину `1..128` для первых трёх и `1..64`
    для `PlayerType`; decimal `AssetId` является положительной строкой цифр
    длиной `1..32` без leading zero, а `rbxassetid://` удаляется до этой
    проверки без преобразования через Luau number; `ResourcePath`/`FolderPath`
    имеют длину не более `512` UTF-8 bytes после нормализации и отклоняют empty,
    leading/trailing/repeated separators, `.`, `..`, управляющие символы и
    ambiguous duplicate matches;
  - `HybridIntentMaxEstimatedBytes = 2048`; intent имеет только exact-shape
    поля из exact client-hybrid DTO contract и не содержит произвольных
    arrays/maps;
  - `HybridWorldCoordinateAbsMax = 1_000_000` для
    каждой finite компоненты client-originated point Position.

  Client-hybrid запрос сначала проходит существующие проверки и бюджеты общего
  Communication, затем точную проверку формы/размера, audio-лимиты инициатора и
  типа, общий server accepted budget и атомарный fan-out budget. Неуспешный
  этап не получает отдельный обход или расширение Communication protocol.
  Диагностика использует общий `Logger` и его существующие ограничения полей и
  строки; SFX не добавляет собственный rate limiter, таблицу retained keys,
  cooldown или LRU-кэш предупреждений.
- `PRD-REQ-017` Простой вызов по ID должен использовать каталог без
  обязательной таблицы опций. Опциональный override может изменять только
  `VolumeMultiplier` от `0` до `2`, `PlaybackSpeedMultiplier` от `0.5` до `2`
  и начальный `TimePosition`. Полученное после умножения значение обязано
  оставаться в startup-диапазоне соответствующего `PlayerType`; иначе только
  конкретный вызов отклоняется с предупреждением через общий `Logger` и no-op.
  Пространственная позиция или прикреплённый объект передаются обязательным
  аргументом соответствующего отдельного варианта вызова и не являются
  универсальными override-полями.
- `PRD-REQ-018` Индекс `CueId` должен поддерживать непустую упорядоченную
  коллекцию взаимозаменяемых вариантов из строк каталога. Ресурсный путь также может разрешаться
  существующим `AssetRegistry` в физический `Folder` под
  `ReplicatedStorage.Assets.Shared.Sounds`; кандидатами становятся все
  экземпляры `Sound` во всём рекурсивном поддереве. Для каждого кандидата
  система должна получить нормализованный `AssetId` из `SoundId`, канонический
  `ResourcePath` из физической иерархии и опциональный `AssetKey` из каталога
  ресурсов, а затем разрешить эти идентификаторы в одну SFX-запись с asset ID
  и `PlayerType`. Если идентификаторы одного физического `Sound` разрешаются в
  разные варианты, этот `Sound` исключается из Folder-кандидатов с warning без
  попытки выбрать идентификатор по приоритету. Хранимый `Sound` является статическим дескриптором ассета и
  не используется как runtime-плеер; runtime `AudioPlayer` не является
  обязательным потомком папки. Ответственность за состав и организацию
  поддерева несёт автор ресурса. При каждом воспроизведении система выбирает
  один допустимый источник случайно пропорционально его `Weight` и, когда
  кандидатов больше одного, не
  повторяет вариант, выбранный непосредственно перед ним.
  Состояние предыдущего выбора хранится независимо для каждого `CueId` и
  каждого канонического Folder-пути; точные identifier-вызовы его не читают и
  не изменяют. Локальный runtime клиента ведёт историю для local- и
  client-hybrid вызовов, а сервер — только для server-all событий.
  В server-all режиме вариант выбирает сервер и назначает одной server-owned
  аренде; recipient DTO и повторный client choice отсутствуют. В hybrid режиме
  инициирующий клиент выбирает вариант, немедленно играет его и отправляет
  точную пару `CueId + VariantId`; сервер проверяет membership,
  `AllowClientHybrid` и остальные ограничения, но не рандомизирует повторно, а
  все остальные получатели воспроизводят ту же точную пару.
- `PRD-REQ-019` Во время клиентской инициализации SFX-система должна собрать
  все уникальные asset IDs записей с `Preload = true`, включая IDs из
  физических `Sound` и config-only вариантов, и выполнить один каталогизированный запрос
  через `ContentPreloader` до публикации своей готовности. Запрос использует
  стабильный `RequestId = "AudioCatalog.Preload.v1"`, `FailurePolicy = "Warn"`
  и отсортированный список уникальных нормализованных IDs; повторное обращение
  с тем же `RequestId` и targets в одном bootstrap обязано переиспользовать
  sticky result, а не запускать несовместимый named request. Инициализация ждёт
  завершения запроса, но отдельные ошибки доставки аудио используют
  best-effort `Warn` policy, остаются видимыми в диагностике и не ломают
  общий client bootstrap.
- `PRD-REQ-020` Однородным pooled resource должен быть универсальный playback
  wrapper, отвязанный от конкретного ассета между арендами. 2D-wrapper содержит
  `AudioPlayer` и его source wire; `World` wrapper дополнительно содержит
  `AudioEmitter`, source-to-emitter wire и anchor для статической мировой точки.
  Persistent category/Master faders, client listener и client device output не
  входят в player pools. После разрешения записи owning runtime выбирает пул по
  `PlayerType`, получает generation-safe аренду и назначает нормализованный
  `ContentId` в актуальное свойство `AudioPlayer.Asset` и параметры только на
  время воспроизведения. Deprecated `AudioPlayer.AssetId` использовать нельзя.
  Release сбрасывает asset, regions, speed,
  volume, looping, position source, emitter profile, callbacks, wires и lease
  context до переиспользования.
- `PRD-REQ-021` SFX-система должна иметь один физический корень звуков
  `ReplicatedStorage.Assets.Shared.Sounds` и один соответствующий канонический
  префикс каталога `Shared/Sounds`. Folder API может принимать путь относительно
  звукового корня, канонический путь AssetRegistry либо полный DataModel-путь к
  этому же корню, но обязано сначала привести его к одному каноническому виду
  и добавить корень не более одного раза. Пустые/запрещённые сегменты, выход
  через `.`/`..`, чужой корень и повторное вхождение
  `Assets/Shared/Sounds` после нормализации должны отклоняться с warning и
  no-op. Сам `Sounds` является Rojo-owned declarative `Folder` под уже
  существующим shared asset root и использует `$ignoreUnknownInstances`; его
  Studio-authored `Sound` descendants принадлежат каноническому `place.rbxl`.
  Отсутствующий либо wrong-class корень переводит audio feature в no-op до
  обращения к `AssetRegistry`, не создавая второй asset root.
- `PRD-REQ-022` CSV-каталог должен иметь плоскую форму «одна строка — один
  вариант» и генерироваться существующим CSV-to-Luau конвертером в режиме
  массива строк. `CueId`, `VariantId`, `PlayerType`, `AssetId`, `AssetKey` и
  `ResourcePath` и `SpatialProfile` должны принудительно сохраняться как строки;
  `Volume01`, `PlaybackSpeed`, `Weight`, `PlaybackRegionStart`,
  `PlaybackRegionEnd`, `LoopRegionStart` и `LoopRegionEnd` должны генерироваться как числа,
  `AllowClientHybrid`/`Looping`/`Preload` — как boolean, а пустые опциональные
  идентификаторы — отсутствовать в таблице строки. Совместимость этой схемы с
  конвертером должна быть покрыта проверкой; если контракт конвертера перестанет
  поддерживать её, необходимая совместимая доработка конвертера и его тестов
  входит в scope этой feature. Authoring contract обязан явно запускать
  `.agents/skills/csv-to-luau/scripts/csv_to_luau.py` сначала с `preview`, затем
  с `apply`, `--mode array`, каноническими source/target paths этой PRD и отдельным
  `--type <header>=<type>` для каждого перечисленного поля. `apply` обязан
  получить из успешного `preview` и передать
  `--expect-source-sha256`, `--expect-target-sha256` и
  `--expect-output-sha256`; hash rejection требует нового preview, а не обхода.
  После генерации повторный `preview` с теми же аргументами обязан вернуть
  `status = "ok"`, нулевой diff и совпадающие target/output hashes;
  Rojo build сам по себе не считается freshness-проверкой CSV.
- `PRD-REQ-023` `Volume01` каждой строки должен быть конечным числом от `0` до
  `1`. Фактический `AudioPlayer.Volume` вычисляется линейным отображением этого
  значения в startup-диапазон источника соответствующего `PlayerType`.
  `PlaybackSpeed` остаётся фактическим множителем, где `1` означает исходную
  скорость, и не является нормализованным значением.
- `PRD-REQ-024` Каждый логический фейдер, включая `Master`, `UI`, `SFX`,
  `World` и `Music`, должен иметь отдельный профиль в локальном
  `AudioRuntimeConfig`:
  `DefaultLevel01`, допустимый gain/dB-диапазон и кривую преобразования. Runtime
  уровень фейдера задаётся числом от `0` до `1`; ноль всегда означает полную
  тишину, а остальные значения преобразуются профилем фейдера. Профиль должен
  удовлетворять `-60 <= MinDb <= MaxDb <= 0`; стандартный профиль каждого
  встроенного фейдера равен `-60..0 dB` и не усиливает сигнал выше исходного.
  Статический
  routing-конфиг определяет только связи player-type-to-fader и
  fader-to-parent-fader, поэтому итоговая громкость является произведением
  уровня источника и всех фейдеров его пути до `Master`. Каждый клиент хранит
  собственные runtime levels и применяет их только к локальным репликам
  persistent faders; сервер после инициализации не перезаписывает эти уровни.
- `PRD-REQ-025` Клиентский API должен предоставлять безопасные операции чтения
  и установки нормализованного уровня фейдера по его стабильному ID. Изменение
  применяется до подключения local `Master -> AudioDeviceOutput` и только к
  audio runtime этого клиента, включая нативно реплицированные server sources;
  другие клиенты и server values не изменяются. Rebind listener после respawn
  сохраняет уровни. Пользовательские настройки принадлежат отдельной клиентской
  domain model и обычному save provider с `Id = "AudioSettings"`,
  `Authority = "Client"`, `ClientSnapshotPolicy = "Include"` и provider-envelope
  `Version = 1`. Его `Data` имеет точную форму без дополнительных полей:
  `Levels = { Master, UI, SFX, World, Music }`, где каждое значение является
  конечным числом `0..1`, и
  `Enabled = { UI, SFX, World, Music }`, где каждое значение boolean.
  `Enabled = false` устанавливает эффективный уровень категории в ноль, не
  стирая сохранённый `Levels` value; изменение уровня выключенной категории
  сохраняет новое значение, а повторное включение применяет именно его.

  Публичный setter сначала проверяет значение, синхронно меняет только эту
  клиентскую domain model и отмечает provider dirty через его существующий
  `MementoChanged`; доставка и сохранение используют штатный client-authority
  `SaveClientPatch`, а не новый audio message или Remote. Серверный counterpart
  заново проверяет полный exact memento перед применением и сохранением.
  Новый профиль, отсутствующий provider и отсутствующие известные поля
  приводятся provider reconciliation к полным defaults: `DefaultLevel01` из
  валидного `AudioRuntimeConfig` либо встроенный безопасный `1` при disabled
  config, и `Enabled = true`. Неизвестное поле, неизвестный/newer envelope
  version, wrong type, NaN, infinity или значение вне диапазона отклоняет весь
  memento. Initial snapshot, replacement snapshot и rollback используют
  существующую атомарную последовательность SaveModule; невалидная замена не
  изменяет текущие уровни или output binding.

  Клиент применяет одну валидированную initial settings generation до
  подключения local output. При disabled/no-op audio runtime provider всё равно
  валидируется и сохраняется, но output не подключается; настройки остаются для
  следующей валидной сборки. Audio feature не создаёт собственный DataStore,
  key, autosave или параллельный профиль. Runtime playback handles, Music stack
  и текущая позиция трека не сохраняются.
- `PRD-REQ-026` Каждая пара `PlaybackRegionStart`/`PlaybackRegionEnd` и
  `LoopRegionStart`/`LoopRegionEnd` должна либо отсутствовать целиком, либо
  содержать конечные числа с `0 <= Start < End`. Отсутствующий playback region
  означает полный трек. После готовности ассета конец каждого заданного региона
  ограничивается фактическим `TimeLength`; если playback region после этого
  пуст, конкретное воспроизведение даёт no-op и warning. `TimePosition` задаётся
  в абсолютных секундах от начала ассета, по умолчанию равен началу эффективного
  playback region и должен попадать внутрь него. Невалидный loop region не
  отменяет звук: система выдаёт warning и использует весь эффективный playback
  region; при `Looping = false` loop region игнорируется.
- `PRD-REQ-027` Публичный вызов не должен yield-ить на загрузке аудио. Он сразу
  возвращает предусмотренный своим API pending handle либо `DispatchResult`,
  после чего owning runtime асинхронно ожидает
  собственный `AudioPlayer.IsReady` не дольше валидированного startup-таймаута:
  сервер для server-all lease, клиент для local/hybrid lease. Успешная
  готовность запускает звук после финальной проверки `TimeLength`; ошибка или
  timeout прекращает pending-состояние, полностью освобождает аренду и создаёт
  предупреждение через общий `Logger`. Server readiness не подтверждает client
  loading; после
  server Play медленный клиент может начать позднее или пропустить короткий
  звук. Критичные к задержке ассеты должны использовать client `Preload`, но SFX
  не вводит acknowledgement или replay. Если `IsReady` уже активного ordinary
  playback меняется с true на false, owning runtime закрывает playback, полностью
  освобождает lease и делает handle неактивным. Если это происходит у audible
  Music entry, она сохраняет позицию, останавливается и становится bounded
  pending reload. Если entry была входящим или выходящим участником активного
  `SequentialFade`/`Crossfade`, runtime синхронно отменяет весь transition,
  инвалидирует его callbacks, исключает неготовую entry из выбора и делает
  единственной audible entry с multiplier `1` самую верхнюю оставшуюся готовую
  запись; при её отсутствии наступает тишина. Последующая readiness затронутой
  entry либо timeout используют обычные generation-safe Music правила и не
  возобновляют отменённый tween.
- `PRD-REQ-028` Публичный play API должен принимать типизированный `SoundRef`,
  содержащий ровно одно из полей `CueId`, `AssetId`, `AssetKey` или
  `ResourcePath`, либо отдельное поле `FolderPath`. `ResourcePath` всегда
  означает точный `Sound`, а `FolderPath` — рекурсивный случайный выбор. Для
  краткой записи должны существовать helper-конструкторы;
  неявное определение вида произвольной строки и приоритет между индексами не
  допускаются.
- `PRD-REQ-029` Каждый client-local и client-hybrid play-вызов должен всегда
  возвращать локальный playback handle. Fail-soft no-op возвращает безопасный
  неактивный handle, у которого проверка активности даёт false, а `Stop` ничего
  не изменяет и не выбрасывает исключение. One-shot hybrid handle управляет
  только немедленным локальным воспроизведением инициатора и после отправки
  intent не отменяет рассылку остальным. Client-hybrid loop handle не существует.
  Все server-all play-вызовы всегда возвращают единый
  `DispatchResult` с `Accepted`, безопасным `ReasonCode` и опциональным
  server lease handle. Отказ возвращает `Accepted = false` без handle; принятый
  one-shot — `Accepted = true` без handle; принятый looped ordinary
  sound — `Accepted = true` с handle, чья активность означает наличие реальной
  server pool lease, а не подтверждённое состояние каждой client replica.
- `PRD-REQ-030` Client API должен разделять local и hybrid delivery явно
  названными семействами, а server API — иметь отдельное server-all семейство.
  Local и server-all семейства имеют отдельные варианты для непространственного
  воспроизведения, статической мировой позиции и attached-source; hybrid имеет
  только непространственный и point one-shot варианты. Универсальный параметр
  delivery mode не допускается. Server `PlayAttached` принимает непосредственно
  server-visible positionable `Instance`, client-local attached — локальный
  `Instance`, а client-hybrid attached API отсутствует.
- `PRD-REQ-031` Первая версия не должна предоставлять массовую остановку обычных
  звуков по cue, player type, bus или папке. Их остановка происходит через
  конкретный handle, FIFO-вытеснение, потерю attached-source или обычное
  завершение конкретного one-shot.
- `PRD-REQ-032` Music должна иметь только client-local непространственные методы
  `PlayMusic` и Music-entry handle; server-all и client-hybrid Music API не
  допускаются.
  Внешняя клиентская игровая система сама определяет выбранный трек по локальному
  либо реплицированному серверному gameplay state и сама решает, когда вызвать
  play или stop. SFX не интерпретирует происхождение state, не выбирает музыку,
  не синхронизирует её между клиентами. Успешный `PlayMusic` добавляет entry в
  конец LIFO-стека и возвращает opaque handle. `handle:Stop()` idempotently
  удаляет именно эту entry. Удаление неслышимой non-top entry не меняет
  playback; удаление audible incumbent, даже если она non-top под pending entry,
  останавливает её и оставляет тишину до готовности structural top; удаление
  top playing entry возобновляет следующую допустимую entry с сохранённого
  `TimePosition`. Отдельный `StopAllMusic` очищает весь стек и предназначен для
  явного общего сброса музыки, а не для закрытия одной игровой системы.
  `PlayMusic` принимает только `SoundRef`, разрешающий `PlayerType = Music`;
  generic client/server/hybrid play отклоняет Music до получения pool lease, а
  Music API — любой другой тип.
- `PRD-REQ-033` Client-hybrid intent и server-created Presentation должны быть
  двумя отдельными versioned exact-shape DTO. Client intent содержит только
  `Version = 1` как точный положительный safe integer literal, канонические
  `CueId + VariantId`, допустимые numeric overrides и
  discriminated `Spatial`, равный ровно `{ Kind = "None" }` либо
  `{ Kind = "Point", Position = Vector3 }`. Presentation передаёт получателю
  ту же точную пару, проверенные overrides и тот же `None`/`Point` spatial
  результат; исходный `SoundRef`, `FolderPath` и другой authoring identifier в
  него не входят. Presentation также содержит только `Version = 1`. Оба payload
  отклоняют отсутствующий, нецелый, другой либо неподдерживаемый `Version`,
  unknown/missing/mixed поля и не могут
  содержать `Instance`, `PlayerId`, excluded recipient, `PlayerType`, bus,
  routing параметры или произвольные arrays/maps. Все строки, таблицы, числа и
  Vector3-компоненты валидируются по форме, размеру и конечности до fan-out.
  Client-hybrid attached discriminator и runtime-object reference отсутствуют.
- `PRD-REQ-034` Отдельный SFX request-ID/dedup cache для one-shot не требуется:
  transport epoch/sequence contract уже не исполняет повторно один принятый
  batch, а два отдельных принятых intent являются двумя осознанными событиями.
  One-shot остаётся fire-and-forget без acknowledgement и playback-ответа.
  Повтор transport batch не исполняет одно событие дважды, но новый API-вызов
  всегда считается новым one-shot. Ни клиент, ни сервер не сохраняют событие
  после постановки fan-out и не синтезируют его при resync или late readiness.
- `PRD-REQ-035` SFX runtime обязан получить один нормализованный строковый audio
  asset ID непосредственно из `AssetId` либо из `Sound.SoundId`, найденного по
  `AssetKey`/`ResourcePath`. Decimal и `rbxassetid://<digits>` нормализуются без
  преобразования через Luau number: prefix удаляется, `0`, whitespace и leading
  zeros отклоняются, а результатом остаётся одна положительная decimal string.
  Путь точного варианта обязан вести к
  `Sound`, а не к Folder; противоречащие друг другу asset IDs пропускают строку
  с warning. Folder-кандидаты дедуплицируются по логическому варианту до random.
- `PRD-REQ-036` Статический routing-конфиг является единственным источником
  player-type-to-fader и fader-to-parent связей. Он загружается как локальная
  Luau-таблица из DataModel; неизвестная связь или цикл
  отключает весь audio graph и публикует no-op
  runtime без частично слышимой маршрутизации.
- `PRD-REQ-037` `SpatialProfile` должен разрешаться через валидированный
  статический registry профилей. `DistanceCurve` и опциональный `AngleCurve`
  представлены упорядоченными immutable arrays точек, которые runtime
  преобразует в dictionaries для `AudioEmitter:SetDistanceAttenuation()` и
  `SetAngleAttenuation()`. Distance curve содержит `1..400` точек с уникальными
  строго возрастающими конечными `Distance >= 0` и `Gain01` в `0..1`; пустое
  либо отсутствующее значение явно выбирает Roblox default inverse-square
  curve. Angle curve содержит `1..400` точек с уникальными строго возрастающими
  конечными `Angle` в `0..180` и `Gain01` в `0..1`; отсутствие выбирает
  constant gain `1`. Между точками Roblox использует линейную интерполяцию, а
  за крайними точками — gain ближайшей крайней точки.
  Point-вызов всегда ненаправленный: он принимает только профиль без
  `AngleCurve`; directional profile отклоняет конкретный point-вызов до pool
  acquire. `AngleCurve` применяется только к attached source, ориентация которого
  получается из его валидированного `PositionInstance`.
  Канонический `place.rbxl` шаблона поставляется с
  `SoundService.AcousticSimulationEnabled = true`. Audio runtime не устанавливает,
  не переключает и не восстанавливает это глобальное свойство при успешной или
  неуспешной инициализации. Client-owned `AudioListener` получает
  `AcousticSimulationEnabled = true` один раз как часть валидного graph и не
  переключается отдельными воспроизведениями. `AcousticSimulationEnabled`
  конкретного профиля управляет только feature-owned `AudioEmitter` этой lease;
  поэтому одновременные профили с разными значениями не спорят за один общий
  listener. Эффективная симуляция дополнительно зависит от неизменяемого модулем
  глобального свойства. Возможность считается beta capability: система не
  обещает точность или наличие occlusion, diffraction и reverb на конкретном
  устройстве и не делает их release gate. Невалидный профиль исключает только
  затронутый вариант с предупреждением через общий `Logger`.
- `PRD-REQ-038` First-wins политика конфликтов применяется к generated
  SFX-индексам и к строковому атрибуту `AssetKey` физических `Sound`,
  наблюдаемому при startup scan.
  Generated rows используют исходный CSV order; физические Sounds используют
  канонический path-sorted order. Первая валидная привязка сохраняется,
  последующие конфликтующие привязки дают предупреждение через общий `Logger` и
  не ломают Assets,
  audio или gameplay bootstrap. Это намеренно изменяет текущую глобальную
  fail-closed политику duplicate `AssetKey` у `AssetRegistry`; реализация обязана
  согласованно обновить AssetRegistry contract, ADR/rules/docs и enforcement
  tests, а не обходить его внутри SFX после уже упавшего `Assets` command.
- `PRD-REQ-039` Manifest-owned AudioGraph subsystem владеет persistent graph,
  его generation publication и client binding. Серверная сторона владеет
  replicated fader graph, server-all
  random state и отдельными server pools только для server-all ordinary sounds.
  Клиенты владеют ordinary local/hybrid pools, отдельным Music pool и LIFO stack,
  listener/output edge и персональными fader levels. Один server-all ordinary playback представлен
  одним server-owned `AudioPlayer` и его штатными client replicas; клиент не
  создаёт зеркальную lease по application command. Hybrid handler никогда не
  создаёт server `AudioPlayer`, чтобы инициатор не получил нативный дубль, а
  Music никогда не создаёт server audio instance.
- `PRD-REQ-040` Канонический CSV source должен находиться по repository path
  `configs/audio/Sounds.csv` и генерировать array-mode модуль
  `src/ReplicatedStorage/Shared/Configs/Audio/SoundCatalog.luau`. Статический
  `AudioRuntimeConfig.luau`, `RoutingConfig.luau` и `SpatialProfiles.luau`
  принадлежат той же runtime-папке Configs;
  generated mutable table не выдаётся потребителям и замораживается SFX runtime
  после validation/indexing.
- `PRD-REQ-041` Server-all loop существует ровно пока активна server pool lease;
  server handle, потеря authoritative attached-source или server FIFO вызывают
  `AudioPlayer:Stop()` и release, распространяемые штатной репликацией.
  Для него нет application state registry, snapshot или `PlaybackId`.
  Client-local loop существует пока активен его local handle, пока не потерян
  attached-source, пока не применён local FIFO либо пока не остановлен client
  runtime. Client-hybrid API всегда отклоняет `Looping = true`; поэтому ordinary
  sound subsystem не владеет distributed loop registry, loop DTO, snapshot
  projection, resync reconciliation или recipient stop protocol.
- `PRD-REQ-042` Новый Music request сначала создаёт pending Music entry в конце
  стека, разрешает и валидирует её вариант, получает client lease и ожидает
  `IsReady`, не изменяя текущую playing entry. Если несколько верхних entries
  ожидают загрузки, текущая готовая запись продолжает играть; готовность нижней
  pending entry не позволяет ей обойти более новую верхнюю entry. Timeout, load
  failure, отмена или невалидный вариант удаляет и освобождает только свою
  entry, после чего стек повторно выбирает верхнюю готовую запись. Переход
  начинается лишь после readiness и финальной проверки region/`TimeLength`;
  entry, которая никогда не играла, начинает с начала effective playback region.
  Natural `Ended` любой audible incumbent удаляет именно её, даже если она стала
  non-top под pending entry. Если ended entry была structural top, стек
  возобновляет следующую допустимую запись; если над ней остаётся pending top,
  слышна тишина до её готовности. Неслышимая stopped entry не получает
  meaningful `Ended`. Любой callback действует только при совпадении entry,
  stack и pool-lease generations.
- `PRD-REQ-043` World listener использует позицию локального персонажа и
  ориентацию активной камеры. Изменение third-person camera distance само по
  себе не изменяет distance attenuation, а поворот камеры изменяет направленное
  восприятие. При временном отсутствии персонажа World-ветка остаётся беззвучной
  до безопасного rebind; непространственные UI/SFX/Music ветки продолжают работу.
  Server point lease использует собственный реплицируемый anchor.
- `PRD-REQ-044` Client-hybrid attached start, `SpatialSourceRef`, runtime-object
  resolver map и trusted owner metadata не входят в первую версию. Любой
  client-hybrid payload с attached discriminator либо object reference
  отклоняется до local acquire и network send. Client-local attached использует
  локальный `Instance`; server-all attached использует server-authoritative
  `Instance` напрямую, а его уничтожение останавливает и освобождает server lease
  через штатную Roblox replication без application stop event.
- `PRD-REQ-045` `PlayMusic` должен принимать опциональный discriminated
  `MusicTransition` со стратегиями `Instant`, `SequentialFade` и `Crossfade`;
  отсутствие опций означает `Instant`. Fade-стратегии могут задавать
  `FadeOutSeconds` и `FadeInSeconds`; отсутствующее значение равно `0.5`, а
  каждое заданное значение должно быть конечным числом от `0` до `10`. Ноль
  выполняет соответствующую фазу мгновенно. Невалидные transition-параметры
  отклоняют только новый request и не изменяют текущую top entry. Fade изменяет
  отдельный transition multiplier `0..1`, умножаемый на base source volume, и
  не изменяет каталог, Music fader или пользовательский уровень громкости.
  `PlayMusic` задаёт enter transition, а `MusicHandle:Stop()` может передать
  отдельный exit transition; при отсутствии exit options используется
  `Instant`.
- `PRD-REQ-046` При push готовой верхней entry стратегия `Instant` останавливает
  прежнюю верхнюю entry с сохранением `TimePosition` и запускает новую с
  multiplier `1`. `SequentialFade` уменьшает прежний multiplier до `0`,
  останавливает её без release, затем запускает новую с `0` и увеличивает до
  `1`. `Crossfade` запускает новую с `0`, одновременно уменьшает прежнюю до `0`
  и увеличивает новую до `1`, затем останавливает прежнюю без release. При pop
  верхней entry те же стратегии применяются в обратном направлении к следующей
  нижней entry, которая продолжает playback со своего сохранённого
  `TimePosition`; удаляемая entry освобождается после своей exit-фазы. При
  отсутствии нижней entry выполняется только fade-out удаляемой записи.
- `PRD-REQ-047` Каждая Music entry получает собственную generation, а каждое
  изменение стека — stack generation. Readiness, fade, timeout, `Ended` и
  delayed callbacks обязаны проверить entry, stack и pool-lease generations.
  Перед **любой** новой stack mutation (`PlayMusic`, handle `Stop`, `Ended`,
  timeout/failure removal или потеря `IsReady`) во время активного transition
  runtime синхронно отменяет его tweens/callbacks и канонизирует pre-mutation
  state. При обычной mutation прежняя structural top ready entry становится
  единственной playing entry с multiplier `1`; при потере `IsReady` затронутая
  entry сначала помечается неготовой, останавливается и исключается из выбора,
  после чего единственной playing entry становится самая верхняя оставшаяся
  готовая запись. Все прочие transition participants останавливаются с
  сохранённой позицией и multiplier `0`, а уже удаляемые entries освобождаются.
  Только после этой atomic interruption/rebase runtime увеличивает generation,
  применяет mutation и запускает максимум один новый переход. `StopAllMusic`
  является исключением без rebase: он сразу отменяет transition и освобождает
  все participants. Ни в один момент interruption не создаёт третью playing
  lease и не оставляет промежуточный multiplier после завершения mutation.
  Новый push не уничтожает предыдущие entries и не использует latest-wins.
  `MusicHandle:Stop()` удаляет только собственную entry: неслышимая non-top
  entry не меняет playback, audible non-top incumbent останавливается, а top
  entry запускает обычный pop transition. Более новая pending entry сама по
  себе не удаляется. `StopAllMusic` инвалидирует stack generation,
  освобождает все playing, stopped и pending entries и idempotent. В pool никогда
  не существует больше active Music leases, чем `MusicStackMaxDepth`.
- `PRD-REQ-048` Ordinary sound subsystem и Music subsystem должны иметь
  отдельные public API, runtime state, concrete pools и пути очистки своих
  воспроизведений. Внутри каждой подсистемы одна конкретная lease должна иметь
  ровно одного владельца идемпотентного завершения, через которого проходят все
  обычные, ошибочные и запоздалые пути очистки. Они
  могут совместно использовать только immutable audio catalog/config models и
  явно injected graph/fader dependencies; Music subsystem не владеет hybrid
  networking или ordinary FIFO, а ordinary sound subsystem
  не владеет Music stack или transitions.
- `PRD-REQ-049` Server/client manifests должны явно скомпоновать ordinary sound
  subsystem и отдельный AudioGraph owner после `Assets`, `Pooling`, `Players` и
  `Communication`; client дополнительно получает существующий
  `ContentPreloader`. Client AudioGraph, Ordinary и Music создаются до применения
  `GlobalSave` snapshot; AudioGraph передаёт им проверенную generation, но весь
  graph ещё не подключён к output.
  `AudioSettings` регистрируется как обычный provider перед `Version`, а его
  client `Run` синхронно применяет effective fader levels и только затем создаёт
  либо восстанавливает `Master -> AudioDeviceOutput` wire. Он не откладывает
  применение через асинхронный Signal. Communication handlers Ordinary/Music
  регистрируются до `ClientReady`, но
  `GlobalSave` отправляет `ClientReady` только после успешного возврата всех
  provider `Run`, включая AudioSettings. Initial snapshot, replacement snapshot
  и rollback используют ту же границу: при ошибке output остаётся отключённым
  либо возвращается к предыдущим настройкам, а readiness не публикуется.
  Disabled/no-op audio graph принимает provider lifecycle через безопасную
  no-op boundary и также не подключает output. AudioSettings участвует в обычном
  `GlobalSave` provider snapshot и rollback как пользовательские настройки;
  ordinary playback, Music stack и другое runtime playback state в snapshot не
  входят. Audio runtime не меняет общий snapshot prepare/apply/rollback contract
  и получает настройки через явно composed domain boundary.
- `PRD-REQ-050` До первой source-code правки реализации должны быть приняты не
  менее трёх отдельных template ADR и синхронный rules/docs/tests cascade.
  Config-решение ограничивает исключение
  из ADR-0017 только путями `ReplicatedStorage.Shared.Configs.Audio`, назначает
  owning validator и сохраняет абсолютные ceilings в code-owned
  `AudioSafetyLimits`. Asset-решение ограничивает first-wins только каталогом
  физических `Sound` под `ReplicatedStorage.Assets.Shared.Sounds`, сохраняет
  fail-closed duplicate policy для всех non-audio assets и задаёт механизм, при
  котором общий `AssetRegistry` не падает до запуска audio subsystem.
  AudioGraph-решение закрепляет единственного manifest-owned владельца graph,
  одноразовую bootstrap-инициализацию без production `Stop -> Initialize`,
  полную очистку каждого воспроизведения и поставляемое значение
  `SoundService.AcousticSimulationEnabled = true`, которое audio runtime не
  изменяет. До выполнения gate implementation status остаётся blocked, но продуктовые
  решения PRD считаются закрытыми. Feature также обязана добавить отдельное
  audio rule и route в rules index, current `docs/AudioSystem.md`, обновить все
  затронутые initialization/save/communication/assets/preloading/pooling docs и
  `docs/TestCoverage.md`, включить focused deterministic runners в
  `AllTestsRunner` и подготовить traceability matrix для всех 79 acceptance
  criteria с конкретным static, deterministic либо multi-client Studio
  evidence identity, fixture, observable result, cleanup и expected diagnostics.

## Quality Requirements

- `PRD-NFR-001` Локально-серверный режим должен начинать локальный звук до
  получения ответа сервера; сетевой round trip не должен находиться на
  критическом пути локального feedback.
- `PRD-NFR-002` Число активных и удерживаемых объектов каждой категории должно
  никогда не превышать соответствующие валидированные server/client active и
  retained limits из локального `AudioRuntimeConfig`. При заполненном ordinary
  active-бюджете FIFO-вытеснение должно завершиться до выдачи новой аренды;
  Music push при заполненном stack budget отклоняется без вытеснения существующей
  записи.
- `PRD-NFR-003` После завершения всех конечных звуков число активных аренд,
  временных emitters, wires и подключений должно возвращаться к исходному
  уровню.
- `PRD-NFR-004` Невалидный общий запрос не должен позволять клиенту заставить
  других игроков загрузить или воспроизвести произвольный аудио asset.
- `PRD-NFR-005` Ошибка SFX-каталога, загрузки аудио или построения audio graph
  не должна прерывать gameplay bootstrap или выбрасываться в вызывающий
  доменный код. Инициализация должна опубликовать корректно связанный graph
  целиком либо безопасный no-op SFX runtime без частичной маршрутизации;
  допустимая fail-soft фильтрация записей и конфликтов выполняется по правилу
  каталога выше и остаётся видимой в Log.
- `PRD-NFR-006` Повторный вызов инициализации в том же bootstrap должен вернуть
  уже опубликованную generation и не дублировать постоянные audio-объекты,
  wires, обработчики или пулы. Ошибка до публикации обязана очистить все
  частично созданные ресурсы. Production-контракт полной остановки и повторной
  инициализации не требуется.
- `PRD-NFR-007` Все диагностические записи SFX должны проходить через общий
  `Logger` со стабильными scope, reason code и безопасными полями. SFX не должен
  владеть отдельным хранилищем, ограничителем частоты, кэшем повторов или
  политикой подавления сообщений.
- `PRD-NFR-008` Диагностика client-originated ошибок должна полагаться на
  существующие экранирование и byte-ограничения полей/строки общего `Logger`, не
  записывать полный недоверенный payload, секреты или save-данные; обычный
  fail-soft путь не выводит stack trace.
- `PRD-NFR-009` Late `IsReady`, natural-end и другие callbacks старой generation
  не должны запускать, останавливать или освобождать более новую аренду того же
  pooled wrapper.

## Acceptance Criteria

- `PRD-AC-001` Сборка с валидным каталогом запускает точный вариант через raw
  asset ID, `AssetKey` и канонический ресурсный путь, а запрос по общему
  `CueId` выбирает один из связанных вариантов. Каждый запрос назначает
  ожидаемый asset ID и получает плеер из указанного строкой типа. Неизвестный идентификатор ничего не воспроизводит, не меняет
  pool-счётчики и создаёт warning.
- `PRD-AC-002` Непространственный тестовый звук сохраняет одинаковую
  слышимость при изменении позиции и направления камеры; его API не требует и
  не принимает пространственный аргумент.
- `PRD-AC-003` Звук, запущенный в мировой точке, слышен с пространственным
  ненаправленным затуханием из этой точки; directional profile отклоняется до
  acquire. Звук, прикреплённый к движущемуся объекту, следует за ним и использует
  его ориентацию для `AngleCurve` до завершения.
- `PRD-AC-004` Пока соответствующий server/client active-лимит типа не
  исчерпан, одновременные независимые запросы owning runtime получают разные
  активные аренды и не обрывают друг друга. После их завершения объекты
  возвращаются в правильные server/client пулы, а устаревший callback или handle
  не может освободить более новую аренду.
- `PRD-AC-005` Изменение уровня `UI` влияет только на UI-звуки, изменение
  `SFX` — только на непространственные игровые звуки, `World` — только на
  пространственные звуки, изменение `Music` — только на музыку, а установка
  `Master` в ноль заглушает все четыре категории.
- `PRD-AC-006` Push готовой Music entry с `Instant` останавливает предыдущую
  верхнюю entry без release и запускает новую без overlap. `SequentialFade`
  полностью глушит и останавливает предыдущую до старта новой; `Crossfade`
  временно использует ровно две соседние playing entries. После перехода играет
  только top entry, а предыдущая сохраняет lease и `TimePosition` ниже в стеке.
- `PRD-AC-007` Локальный запрос слышит только инициировавший клиент.
- `PRD-AC-008` Server-all one-shot создаёт ровно одну server pool lease и ни
  одного SFX communication message. Её server-owned `AudioPlayer` и graph
  распространяются Roblox replication; клиенты не вызывают SFX playback handler
  и не создают зеркальные client leases. SFX не синтезирует replay для позднего
  клиента и не обещает phase/start-position compensation.
- `PRD-AC-009` В локально-серверном сценарии инициатор начинает слышать звук
  до серверного подтверждения и не слышит дубль после доставки. Сервер ставит
  каждому другому ready-клиенту best-effort Presentation event; backpressure
  может отбросить его без retry или replay, а успешно доставленное событие
  воспроизводится не более одного раза. Сервер
  исключает игрока, связанного с входящим communication-context, даже если
  клиент пытается передать другой excluded-player identifier.
- `PRD-AC-010` Попытка клиента передать неизвестный asset ID, неизвестный
  ресурсный ключ, невалидную позицию или чрезмерную частоту запросов не
  запускает звук ни у одного другого клиента и оставляет пулы в валидном
  состоянии.
- `PRD-AC-011` Невалидная ссылка в отдельной записи каталога пропускается с
  конкретной диагностикой. Циклическая или несуществующая связь маршрутизации
  не публикует частично связанный graph и переводит SFX runtime в безопасный
  no-op режим; gameplay bootstrap и вызовы потребителей продолжаются без
  исключения. Клиент не связывает source/output с неполной либо mismatched
  AudioGraph generation и при timeout также публикует no-op runtime.
- `PRD-AC-012` Для ordinary type при `ServerMaxActive = N` server pool оставляет активными первые
  `N` server-all запросов типа, а запрос `N + 1` останавливает самый старый звук
  для всех через native replicated stop/release. Аналогичный
  `ClientMaxActive = N` применяет FIFO только внутри одного client runtime и не
  влияет на server pool или других клиентов.
- `PRD-AC-013` Отсутствующий встроенный тип, наличие server budget для `Music`,
  `Music.ClientMaxActive`, отличный от `MusicStackMaxDepth`,
  `Music.ClientMaxRetained` больше Music active budget, отрицательный/нецелый
  server/client лимит, неизвестный bus или превышение разрешённых hard caps,
  side-wide суммы active/retained/worst-case graph-object cost, границ source
  volume, playback speed либо fader dB публикует локальную frozen
  disabled audio model и no-op runtime с предупреждением через общий `Logger`,
  не прерывая gameplay
  bootstrap.
- `PRD-AC-014` Вызов только с ID использует все значения каталога. Допустимые
  `VolumeMultiplier` в `0..2`, `PlaybackSpeedMultiplier` в `0.5..2` и начальный
  `TimePosition` изменяют только конкретное воспроизведение. Множитель, который
  выводит итог за startup-диапазон PlayerType, даёт no-op и warning; попытка
  переопределить источник, тип плеера, bus, pool-лимит или preload-политику
  отклоняется.
- `PRD-AC-015` Изменение локального Luau-конфига требует новой сборки и не
  изменяет уже запущенные server/client runtime. Новая таблица применяется
  только после следующей полной инициализации соответствующего runtime.
- `PRD-AC-016` Удаление объекта, за которым следует пространственный звук,
  останавливает воспроизведение и возвращает active-счётчик соответствующего
  пула к корректному значению; устаревшее событие завершения не влияет на
  последующее использование плеера.
- `PRD-AC-017` Для записи или ресурсной папки с несколькими кандидатами серия
  воспроизведений учитывает допустимые источники из вложенных папок и не
  повторяет один и тот же вариант два раза подряд, пока доступно более одного
  кандидата. Две разные логические записи не разделяют состояние предыдущего
  выбора.
- `PRD-AC-018` Server-all запрос с коллекцией вариантов выбирает вариант на
  сервере и назначает его одной server-owned аренде без recipient DTO. Hybrid-
  инициатор выбирает точный вариант, играет его локально и отправляет серверу;
  каждый другой получатель воспроизводит тот же вариант, а инициатор не получает
  дубль.
- `PRD-AC-019` Запись без опциональных полей воспроизводится с `Volume01 = 1`
  и `PlaybackSpeed = 1`, без loop, без preload и с полным playback region; `World`
  использует встроенный default spatial profile.
- `PRD-AC-020` Все записи с `Preload = true` входят в завершающийся до SFX-ready
  preload-запрос `AudioCatalog.Preload.v1` с `FailurePolicy = "Warn"` и
  отсортированными уникальными normalized asset IDs. Повторное обращение к
  этому `RequestId` с тем же списком переиспользует sticky result. Ошибка загрузки одного asset
  появляется в результате и warning-диагностике, но не препятствует завершению
  client bootstrap.
- `PRD-AC-021` Два последовательных воспроизведения разных asset через один
  тип плеера могут переиспользовать один runtime `AudioPlayer`; во второй
  аренде отсутствуют asset ID, параметры, wires, callbacks и spatial-контекст
  первой аренды.
- `PRD-AC-022` Относительный путь `Steps`, канонический путь
  `Shared/Sounds/Steps` и полный путь
  `ReplicatedStorage/Assets/Shared/Sounds/Steps` разрешают одну физическую
  папку и один набор кандидатов. Путь с повторённым
  `Assets/Shared/Sounds/Assets/Shared/Sounds` отклоняется и не создаёт
  воспроизведение.
- `PRD-AC-023` Рекурсивный обход физической папки выбирает только потомков,
  являющихся `Sound` и сопоставленных с валидными SFX-записями. Его `SoundId`,
  канонический `ResourcePath` и опциональный `AssetKey` разрешаются в одну
  логическую запись; каждый выбранный потомок приводит к asset ID и
  `PlayerType` из конфига, а не к постоянному runtime-плееру.
- `PRD-AC-024` Если две разные записи объявляют один `AssetKey`, первый валидный
  вариант в порядке исходных строк разрешается через этот ключ, конфликтующая
  последующая привязка игнорируется с warning, а вторая запись остаётся
  доступной через свои другие уникальные идентификаторы. SFX и gameplay
  bootstrap завершаются без исключения.
- `PRD-AC-025` Представительный CSV с двумя строками `Footstep.Grass`, разными
  `VariantId`, строковыми identifier-полями и числовыми `Volume01` и
  `PlaybackSpeed` генерируется в Luau как две упорядоченные row table. Обе строки
  входят в один cue-index, а каждый индивидуальный идентификатор разрешает
  только свою строку.
- `PRD-AC-026` При `Volume01 = 0`, `0.5` и `1` фактическая громкость источника
  равна соответственно минимуму, середине и максимуму startup-диапазона его
  `PlayerType`; фактическая скорость остаётся указанным множителем.
- `PRD-AC-027` Установка клиентом уровня `Music` обновляет только его валидные
  client-authority `AudioSettings` через штатный dirty-provider patch, проходит
  повторную exact validation на сервере, сохраняется и восстанавливается после
  повторного входа. Она не изменяет уровни других клиентов или server runtime
  values; нулевой `Master` заглушает все
  локальные категории и нативно реплицированные server-all ordinary sounds, а
  восстановление предыдущего уровня возвращает их слышимость без изменения
  source-параметров. Music level влияет только на client-local Music этого
  клиента. `Enabled.Music = false` заглушает Music без изменения сохранённого
  `Levels.Music`; изменение уровня в выключенном состоянии и последующее
  включение применяют новое сохранённое значение. Клиентский patch с лишним
  полем, wrong version/type, NaN, infinity или уровнем вне `0..1` целиком
  отклоняется сервером и не изменяет сохранённый memento.
- `PRD-AC-028` Если вторая валидная строка одного `CueId` объявляет другой
  `PlayerType`, запрос по этому `CueId` никогда не выбирает её и создаёт warning,
  но запрос по её уникальному `AssetId`, `AssetKey` или `ResourcePath`
  воспроизводит точный вариант через указанный его строкой тип плеера.
- `PRD-AC-029` Строка без четырёх region-полей проигрывает весь трек. Заполненная
  только наполовину пара пропускает строку с warning, не прерывая gameplay.
- `PRD-AC-030` Заданный playback end больше фактического `TimeLength`
  ограничивается концом трека; start за концом трека даёт no-op, warning и
  освобождение аренды.
- `PRD-AC-031` Невалидный loop region при `Looping = true` воспроизводит звук с
  loop по эффективному playback region; тот же region при `Looping = false` не
  изменяет обычное однократное воспроизведение.
- `PRD-AC-032` Запрос непрогруженного ассета возвращает handle без ожидания.
  Готовность до timeout запускает звук, `Stop` или timeout до готовности не
  запускает его впоследствии и возвращает все ресурсы в исходное состояние.
  Для Music timeout новой entry не останавливает уже готовую предыдущую top
  entry. Переход `IsReady` active ordinary playback из true в false закрывает
  его lease и делает handle неактивным без ожидания `Ended`.
- `PRD-AC-033` Встроенные типы используют load timeout `2`, `3`, `3` и `15`
  секунд для `UI`, `SFX`, `World` и `Music` соответственно; значение вне
  `0.5..30` переводит audio feature этой стороны в frozen no-op runtime, не
  прерывая общий gameplay bootstrap.
- `PRD-AC-034` Pending ordinary запрос занимает active slot. При заполненном
  ordinary pool новый запрос может FIFO-вытеснить самый старый pending-запрос,
  после чего поздняя готовность вытесненного ассета ничего не запускает и не
  меняет новую аренду. Pending Music entry занимает свой stack slot и следует
  LIFO-порядку Music stack; ordinary FIFO к ней не применяется.
- `PRD-AC-035` Физический `Sound`, чей `SoundId` разрешает один вариант, а
  `ResourcePath` — другой, не участвует в Folder-выборе и создаёт warning;
  остальные валидные потомки папки продолжают воспроизводиться.
- `PRD-AC-036` При одинаковом injected random sample вариант с большим
  положительным `Weight` получает пропорционально больший интервал выбора;
  отсутствующий или невалидный вес ведёт себя как `1` и создаёт не более одного
  startup warning для записи.
- `PRD-AC-037` Два разных `CueId` и два разных канонических Folder-пути имеют
  независимый предыдущий выбор. Точный вызов варианта между двумя случайными
  вызовами не изменяет их anti-repeat результат.
- `PRD-AC-038` `SoundRef` с ровно одним поддерживаемым полем разрешается через
  соответствующий индекс. Пустой ref либо ref с несколькими полями возвращает
  неактивный handle на клиенте либо negative `DispatchResult` на сервере,
  создаёт warning и не меняет пул. `ResourcePath` на Folder не
  считается точным ref, а тот же путь через `FolderPath` выполняет рекурсивный
  random и дедуплицирует варианты.
- `PRD-AC-039` Любая client-side ошибка разрешения, валидации или загрузки
  возвращает handle, для которого `IsActive()` равно false после завершения
  fail-soft обработки, а повторный `Stop()` безопасен. Server-side отказ
  возвращает negative `DispatchResult`, а не фиктивный playback handle.
- `PRD-AC-040` Client-local вызов не создаёт network message; client-hybrid
  one-shot создаёт одно намерение после немедленного локального запуска и не
  создаёт server `AudioPlayer`; client-hybrid loop отклоняется до acquire/send.
  Server-all ordinary доступен только серверному коду,
  создаёт server lease и не создаёт SFX network message. Music создаёт только
  client lease. Local/server point и attached вызовы требуют соответствующий
  пространственный аргумент; hybrid предоставляет point, но не attached API.
- `PRD-AC-041` Первая версия не содержит публичной операции остановки всех
  обычных звуков по cue, type, bus или folder; остановка одного handle не
  затрагивает соседние аренды.
- `PRD-AC-042` Generic client/server play с Music-вариантом, Music play с
  non-Music вариантом и любой client-hybrid Music request дают no-op и warning
  до acquire/fan-out. Только client `PlayMusic` добавляет Music entry,
  `MusicHandle:Stop()` удаляет именно свою entry, а `StopAllMusic` освобождает
  весь Music stack и безопасен при его отсутствии.
- `PRD-AC-043` `AllowClientHybrid = false` отклоняется клиентом до predicted
  acquire и network send. При true любой локальный `SoundRef` сначала разрешается
  в канонические `CueId + VariantId`; сервер получает только эту пару и выполняет
  дальнейшую каталоговую, point и rate validation. Общий communication budget,
  per-type token bucket и code-owned aggregate/server ceilings применяются
  независимо. Отказ локальной Communication queue после prediction оставляет
  локальный one-shot активным, не повторяет send и создаёт диагностическую
  запись через общий `Logger`.
- `PRD-AC-044` Hybrid one-shot intent не содержит отдельного SFX request ID и не
  получает acknowledgement. Повтор transport batch не исполняется второй раз,
  а два разных принятых intent создают два события. После fan-out ни одна
  сторона не сохраняет application event state и не переиздаёт one-shot после
  resync.
- `PRD-AC-045` Hybrid one-shot ставится только другим клиентам, готовым в момент
  fan-out; поздняя readiness не воспроизводит старое hybrid-событие. Server-all
  one-shot не зависит от `ClientReady`, не создаёт application replay, а его
  наблюдаемое late-join/streaming поведение полностью принадлежит Roblox
  replication.
- `PRD-AC-046` Два одновременных World-источника сохраняют разные позиции при
  изменении World/Master gain; private interaction group предотвращает второй
  вывод через default listener и не захватывает unrelated audio.
- `PRD-AC-047` Строка только с `ResourcePath` получает нормализованный ID из
  `Sound.SoundId`; противоречие с прямым `AssetId` пропускает строку. Один
  вариант, найденный несколькими идентификаторами в Folder, участвует в weighted
  random ровно один раз.
- `PRD-AC-048` Дубликат точного `AssetId`, `AssetKey` или `ResourcePath` внутри
  generated CSV использует first-wins warning policy; повторный `CueId` с новым
  уникальным `VariantId` образует коллекцию и конфликтом не считается.
  Дубликат строкового атрибута `AssetKey` физического `Sound`
  также сохраняет первую
  валидную привязку в каноническом path-sorted порядке и создаёт warning без
  падения `Assets`, audio или gameplay bootstrap; интеграционные тесты
  подтверждают согласованное изменение контракта `AssetRegistry`.
- `PRD-AC-049` `Stop()` one-shot hybrid handle после отправки intent
  останавливает только локальный predicted playback инициатора, не создаёт
  cancellation message и не влияет на уже поставленные события остальных;
  distributed `PlaybackId` и looped hybrid handle отсутствуют.
- `PRD-AC-050` Один server-all dispatch создаёт ровно одну слышимую
  server-owned generation lease и один `AudioPlayer`; клиенты слышат штатные
  replicas и не приобретают mirror leases по SFX-команде. Server stop, FIFO и
  release изменяют playback без application stop message.
- `PRD-AC-051` Server attached start принимает валидный реплицируемый
  server-visible `Instance`, следует за ним и полностью освобождает server lease
  при его уничтожении. Client-local attached использует только локальный
  `Instance`. Client-hybrid API, intent и Presentation не содержат attached
  discriminator, `SpatialSourceRef`, `OwnerUserId` или resolver contract.
- `PRD-AC-052` Server-all loop создаёт одну server lease без event registry;
  server handle останавливает её через native replicated stop/release.
  Client-local loop существует только в local pool и останавливается своим
  handle. Тот же вариант с `Looping = true` через любой client-hybrid метод
  возвращает неактивный handle, warning, ноль local/network playback и не
  создаёт distributed state. В `GlobalSnapshot` допускаются только
  пользовательские AudioSettings provider data; playback state отсутствует.
- `PRD-AC-053` Два клиента независимо вызывают `PlayMusic` и создают только
  собственные client `AudioPlayer` leases. Сервер не создаёт Music player,
  command, snapshot или current-track state, а выбор и lifecycle одного клиента
  не изменяет музыку другого.
- `PRD-AC-054` Hybrid cue с несколькими вариантами выбирается один раз на
  инициаторе; сервер валидирует exact `CueId + VariantId`, не рандомизирует
  повторно и ставит эту пару только остальным ready-клиентам. Исходный
  `FolderPath` либо другой `SoundRef` через сеть не передаётся.
- `PRD-AC-055` При неподвижном персонаже изменение third-person zoom не меняет
  attenuation тестового World-звука, а поворот камеры изменяет направленную
  ориентацию listener без перемещения его distance origin.
- `PRD-AC-056` Два клиента устанавливают разные `Music` и `Master` levels на
  своих локальных репликах persistent faders. `Music` изменяет только их
  собственные client-local tracks, а `Master` также изменяет слышимость
  нативно реплицированных server-all ordinary sounds; уровни сервера и второго
  клиента не изменяются.
- `PRD-AC-057` Клиент применяет восстановленные либо default fader levels до
  создания `Master -> AudioDeviceOutput` wire, поэтому startup не выдаёт
  слышимый frame с неверной громкостью. Initial values приходят из обычного
  `AudioSettings` user-data provider; новый/отсутствующий provider и missing
  known fields используют полные defaults, включая built-in `1/true` при
  disabled audio config. Невалидный initial snapshot не подключает output и не
  публикует `ClientReady`; невалидный replacement snapshot откатывает прежние
  levels, enabled flags и output binding. Успешный resync применяет все поля
  атомарно до возобновления readiness. Respawn/rebind listener сохраняет уровни.
- `PRD-AC-058` Два server-all `World` sources используют разные server-owned
  emitters и сохраняют отдельные позиции. Изменение локального `World` fader
  после listener меняет общий gain, не превращая источники в один emitter.
  Server-all, client-local и client-hybrid `World` wrappers не имеют прямого
  wire к `World`/`Master`: каждый идёт только в свой emitter, затем через
  client-owned listener и общий `World` fader.
- `PRD-AC-059` Возврат server wrapper в пул очищает replicated asset, playing
  state, regions, volume, speed, looping, emitter, wires, callbacks, anchor и
  attached source до выдачи следующей generation. Idle wrapper находится под
  server-only pool parent; перед `Play()` полностью настроенный graph последним
  шагом parent-ится под явного реплицируемого предка, а release возвращает его
  под idle parent только после `Stop`, disconnect и полного reset.
- `PRD-AC-060` Server `Ended` освобождает только актуальную non-looping lease;
  explicit stop, FIFO, timeout и потеря источника не ждут `Ended`, а stale callback не
  освобождает более новую generation.
- `PRD-AC-061` Hybrid-инициатор создаёт один local player, сервер не создаёт
  audio instance, а communication start отправляется только остальным. Поэтому
  нативная server replication не возвращает инициатору второй playback.
- `PRD-AC-062` Пока новая верхняя Music entry ожидает `IsReady`, предыдущая
  audible incumbent продолжает звучать как non-top без изменения gain. Готовность
  нижней pending entry не позволяет ей обойти более новую entry; timeout/load
  failure удаляет только повреждённую entry и повторно вычисляет верх стека.
- `PRD-AC-063` После завершения любого перехода звучит ровно верхняя готовая
  Music entry. `SequentialFade` никогда не имеет двух слышимых Music tracks;
  `Crossfade` временно имеет ровно две playing leases, после чего прежняя
  останавливается с сохранённым `TimePosition`, но остаётся в стеке.
- `PRD-AC-064` Последовательность `PlayMusic(A)`, `PlayMusic(B)`,
  `PlayMusic(C)` создаёт стек `A, B, C`, не отменяет более ранние entries и
  никогда не превышает configured `MusicStackMaxDepth`. Push при полном стеке
  возвращает неактивный handle с warning и не вытесняет ни одну entry.
- `PRD-AC-065` Stale readiness, fade, timeout или `Ended` callback старой entry,
  stack либо pool-lease generation не меняет текущий top track, его transition
  gain или pool state.
- `PRD-AC-066` `MusicHandle:Stop()` для non-top entry освобождает только её и не
  меняет playback, если она неслышима. Stop audible non-top incumbent под
  pending top останавливает и удаляет её, оставляя тишину до готовности top.
  Stop playing top применяет её exit transition, освобождает её и возобновляет
  следующую готовую entry с сохранённого `TimePosition`.
  `StopAllMusic` отменяет все pending/fade callbacks, освобождает весь стек и
  idempotent.
- `PRD-AC-067` Если `IsReady` остановленной Music entry перед resume снова
  равен false, entry не вызывает `Play()` до повторной readiness. После reload
  она восстанавливает сохранённый в entry state `TimePosition` и продолжает
  трек; timeout удаляет только её и безопасно выбирает следующую запись без
  stale callback. Если `IsReady` становится false у audible entry, она проходит
  тот же bounded reload с сохранённой позицией, а следующая готовая нижняя entry
  может звучать как incumbent до её возвращения.
- `PRD-AC-068` Сценарий background/window подтверждает LIFO: после запуска
  фонового `A` окно добавляет `B`, `A` останавливается с сохранённой позицией;
  закрытие окна вызывает `BHandle:Stop()`, после чего `A` возобновляется с той
  же позиции. Обе системы используют только собственные handle и не знают друг
  о друге.
- `PRD-AC-069` Канонический `place.rbxl` до bootstrap имеет
  `SoundService.AcousticSimulationEnabled = true`. Успешная инициализация,
  отключённый профиль, частичная ошибка и fail-soft no-op не меняют это
  свойство. Валидный client graph один раз включает capability на своём listener
  и не переключает её отдельными playback. Включённый/выключенный профиль
  настраивает только feature-owned emitter своей lease, поэтому два
  одновременных разных профиля не меняют состояние общего listener. Отсутствие аппаратного эффекта
  occlusion/diffraction/reverb не считается ошибкой. Curve с граничными
  значениями `Distance = 0`, `Angle = 0/180`, `Gain01 = 0/1` и `400` точками
  принимается, а выход за любой предел отклоняет только вариант. Point-вызов
  принимает только профиль без `AngleCurve`; directional profile доступен
  attached-вызову.
- `PRD-AC-070` Повторный вызов `Initialize` в одном bootstrap возвращает ту же
  опубликованную generation и не меняет число persistent graph objects, wires,
  signal connections или pool resources. Принудительная ошибка на каждом этапе
  до публикации оставляет ноль частично созданных ресурсов и отменяет связанные
  callbacks; следующий независимый тест создаёт новую изолированную runtime
  fixture, а не выполняет production `Stop -> Initialize`.
- `PRD-AC-071` Manifest tests подтверждают обязательные зависимости audio
  subsystems и регистрацию client-hybrid one-shot handlers до публикации
  `ClientReady`. AudioGraph готов в detached-состоянии и передан уже созданным
  Ordinary/Music до `GlobalSave`,
  `AudioSettings` зарегистрирован перед `Version` с `Authority = "Client"`, а
  его `Run` синхронно применяет валидную initial generation и связывает local
  output до возврата. Только затем отправляется `ClientReady`. Disabled graph
  выполняет тот же provider lifecycle без output
  wire. `GlobalSnapshot` содержит только AudioSettings provider data и не
  содержит playback handles, Music stack, hybrid state, owner receipt или
  другой audio runtime projection.
- `PRD-AC-072` После `preview -> apply` CSV-конвертации повторный `preview` с
  теми же array-mode/type-override аргументами возвращает `status = "ok"`,
  нулевой diff и совпадающие target/output hashes; `apply` использует все три
  expected SHA-256 из предыдущего preview. Длинный decimal `AssetId` остаётся
  строкой и не теряет точность.
- `PRD-AC-073` Startup boundary tests подтверждают shipped pool budgets, hard
  caps, hybrid one-shot rate/burst, атомарный fan-out budget и
  identifier/payload limits из startup safety contract: значение на границе
  принимается, выше границы
  либо конфиг с валидными отдельными типами, но превышенной side-wide суммой,
  переводит затронутый config/runtime в указанное fail-soft состояние до
  создания pool/graph objects и без превышения фактических ресурсов. При
  недостатке fan-out tokens событие не ставится ни одному получателю.
  Диагностика проходит через общий `Logger`, а audio-specific warning cache и
  настройки подавления отсутствуют.
- `PRD-AC-074` До source implementation присутствуют не менее трёх Accepted
  template ADRs и
  обновлённые architecture/configuration/assets rules, docs и enforcement tests,
  которые закрывают config, asset и AudioGraph/lifecycle решения; duplicate
  non-audio `AssetKey`
  остаётся fail-closed, а повышение authoring config не может изменить
  `AudioSafetyLimits`. Канонический `place.rbxl` поставляет включённую Acoustic
  Simulation, а audio runtime не изменяет глобальное свойство. Присутствуют
  `audio` rule/index route,
  `docs/AudioSystem.md`, обновлённый `docs/TestCoverage.md`, focused runners в
  `AllTestsRunner` и полная evidence matrix всех 79 acceptance criteria с обязательными
  multi-client Studio сценариями для real graph и replication boundaries.
- `PRD-AC-075` Для каждой фазы `SequentialFade` и `Crossfade` новый push,
  `MusicHandle:Stop()`, natural `Ended`, потеря `IsReady` входящим или исходящим
  participant и `StopAllMusic` сначала синхронно
  отменяют старый scheduler и rebase/release его participants. После mutation
  звучит не более одной entry либо не более двух participants одного нового
  crossfade; третьей playing lease, stale tween и multiplier между `0` и `1`
  после завершения нет. При потере `IsReady` затронутая entry становится
  pending reload и не участвует в rebase; самая верхняя оставшаяся ready entry
  становится единственной audible с multiplier `1`, либо наступает тишина.
  Поздний tween callback отменённого перехода ничего не меняет.
- `PRD-AC-076` Последовательность `A playing -> B pending -> A Ended` удаляет
  audible non-top `A` и оставляет тишину до готовности `B`. Та же схема с
  `AHandle:Stop()` даёт тот же результат; Stop неслышимой более старой entry не
  меняет incumbent.
- `PRD-AC-077` Catalog variant с `Looping = true` успешно работает через
  client-local и server-all loop API, но непространственный и point
  client-hybrid вызов отклоняет его до predicted playback и network send.
  Client-hybrid attached API отсутствует. Ни `State` message, ни desired-state
  table, ни receipt не создаются.
- `PRD-AC-078` Public API, client intent, server Presentation, manifests и
  runtime не содержат client-hybrid attached method, `SpatialSourceRef`,
  `OwnerCharacter`, project resolver map или trusted object-owner metadata.
  Попытка передать attached discriminator или Roblox `Instance` отклоняется до
  local acquire и network send.
- `PRD-AC-079` Malformed, oversized, looped либо неавторизованный hybrid
  one-shot intent отклоняется до fan-out без изменения пулов. Валидное событие
  использует exact `Version = 1`, `CueId + VariantId` и `None`/`Point` spatial union
  и остаётся единственным bounded Presentation DTO в штатной Communication
  Presentation queue; missing, non-integer, unsupported или extra `Version`
  отклоняется. В Communication registry и
  `GlobalSnapshot` отсутствуют SFX `State`, `HybridOwnerState`,
  `HybridOwnerReceipt`, `HybridLoops` и отдельный audio resync endpoint.

## Assumptions

- Каталог звуков и routing-конфиг являются несекретными статическими данными,
  версионируемыми вместе со сборкой. Их runtime-путь —
  `ReplicatedStorage.Shared.Configs.Audio`; исходный CSV остаётся вне
  DataModel, а в Rojo попадает только сгенерированный Luau ModuleScript.
- Физическая иерархия группировки звуков принадлежит shared asset root
  `ReplicatedStorage.Assets.Shared.Sounds`; её публичные пути начинаются с
  namespace-relative `Shared/Sounds`, как требует существующий
  `AssetRegistry`. Экземпляры `Sound` в этой иерархии являются статическими
  дескрипторами аудиоассетов; их playback-свойства не заменяют параметры
  SFX-конфига и сами экземпляры не арендуются для runtime-воспроизведения.
- `AssetId`, `AssetKey` и `ResourcePath` являются альтернативными индексами
  SFX-каталога, а не идентификаторами runtime-плееров. Интеграция с существующим
  каталогом ресурсов допускается как внутренняя реализация разрешения, но не
  меняет владение аудиоассетом и плеером.
- Точный Roblox audio graph для 2D и 3D может различаться, если наблюдаемая
  иерархия `UI`/`SFX`/`World`/`Music`/`Master` и требования пространственной
  локализации выполняются полностью.
- Все audio startup-конфиги являются локальными версионируемыми Luau-таблицами
  в `ReplicatedStorage.Shared.Configs.Audio`, всегда присутствующими в DataModel
  конкретной сборки. Они не используют Roblox Experience Config или сетевую
  projection; server и client require-ят и независимо валидируют те же таблицы
  только во время своего bootstrap. Статический routing-конфиг задаёт
  допустимую топологию и валидируется совместно с runtime budgets, fader и
  spatial profiles.
- Пользовательские AudioSettings являются обычными user data и используют
  существующий provider/save/snapshot lifecycle. Они не меняют статический
  startup-конфиг и не сохраняют активное воспроизведение или Music stack.
- Канонический `place.rbxl` шаблона сохраняет
  `SoundService.AcousticSimulationEnabled = true` как общую authoring-настройку
  Experience. Audio runtime считает это внешним неизменяемым условием и владеет
  только настройкой своих emitter/listener объектов.
- Любая Music lease принадлежит клиенту. Внешняя клиентская игровая система
  может принимать решения из server-replicated или local gameplay state, но
  происхождение этого решения не входит в Music API.
- Сохранённый `TimePosition` остановленной Music entry остаётся доступен для
  последующего `AudioPlayer:Play()`; если Roblox изменит это engine-поведение,
  реализация должна сохранять и восстанавливать позицию явно без изменения
  публичной LIFO-семантики.

## Open Questions

- Нет.

## Risks

- Простая общая цепочка `World` через один фейдер может разрушить
  пространственное разделение источников. Техническая спецификация должна
  доказать, что выбранная топология `AudioEmitter`/`AudioListener`/`Wire`
  сохраняет позицию каждого активного звука и при этом реализует категорийный
  и master-контроль.
- Каноническая `CueId + VariantId` пара в клиентском сетевом запросе остаётся
  недоверенной: сервер обязан заново сопоставить её с разрешённым каталогом и
  `AllowClientHybrid` до рассылки; raw asset ID и FolderPath по сети не идут.
- Локальная предикция может дать звук, который сервер затем отклонит; система
  должна считать этот эффект presentation-feedback, а не доказательством
  успешного серверного действия.
- Слишком маленькие пулы будут обрезать важные звуки, а слишком большие —
  удерживать лишние audio-объекты и wires; бюджеты требуют измерения на
  целевых устройствах.
- FIFO-вытеснение может оборвать длинный важный эффект раньше короткого менее
  важного эффекта; это является осознанной политикой первой версии.
- Статический Luau-конфиг удобен для Git-review и CSV pipeline, но не даёт
  обновлять громкости и маршрутизацию без новой сборки.
- Решение хранить настраиваемые audio budgets и профили в локальных Luau-
  таблицах намеренно отличается от принятого общего правила ADR-0017 о tunable
  values в Experience Config. До первой source-code правки реализации требуется
  Accepted template ADR, который явно ограничивает/supersedes ADR-0017 только
  для путей `ReplicatedStorage.Shared.Configs.Audio` и перечисляет owning
  validator, code-owned ceilings, rules/docs/tests cascade и merge policy;
  скрытое двойное владение конфигурацией запрещено.
- First-wins для физического `AssetKey` намеренно меняет fail-closed invariant
  текущего `AssetRegistry` из ADR-0013. До source-code реализации требуется
  Accepted template ADR, который сохраняет fail-closed поведение для всех
  non-audio assets, задаёт точную audio-only границу
  `ReplicatedStorage.Assets.Shared.Sounds`, детерминированный path order и способ
  исключить падение общего Assets bootstrap. Без такого ограниченного решения
  и enforcement tests audio feature нельзя считать реализационно завершённой.
- Фактическая доставка, момент старта и late-join поведение server-all playback
  зависят от штатной Roblox replication и streaming. SFX намеренно не добавляет
  поверх них acknowledgement, replay или фазовую синхронизацию.
- Music stack удерживает stopped leases ради независимого LIFO-resume и поэтому
  расходует больше объектов, чем latest-wins модель. Ограничение глубины,
  отдельные entry/stack/lease generations и отказ нового push при полном стеке
  должны предотвращать утечки и изменение более нового top track.
- Acoustic Simulation является beta-возможностью Roblox: включённое в
  каноническом `place.rbxl` глобальное свойство влияет и на Advanced Audio вне
  этой feature, а качество устройства может ослабить или полностью отключить
  эффект. Это осознанная общая настройка шаблона, которую audio runtime не
  меняет; точный акустический эффект не является release gate.
