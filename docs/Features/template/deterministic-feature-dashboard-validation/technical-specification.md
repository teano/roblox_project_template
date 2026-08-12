---
document_type: technical-specification
feature_id: TF-0008
status: approved
revision: 2
language: Russian
product_authority:
  path: docs/Features/template/deterministic-feature-dashboard-validation/product-requirements.md
  status: approved
  revision: 2
  sha256: ec6edd8462d5fed2c4f97909eb3bdcd20ce2ef99fe382e5f12d5d48b12b3258a
---

# Deterministic Feature Dashboard Validation — Technical Specification

## 1. Цель и критерий реализации

TF-0008 устраняет платформенную недетерминированность генерации и проверки
feature dashboard без изменения feature schema, lifecycle state machine,
namespace ownership или смысла таблицы. Один и тот же набор валидных
`feature.json` обязан давать один канонический byte stream dashboard, а
read-only проверка обязана различать безвредное представление line separators
и реальный content drift.

Спецификация считается реализованной, когда:

1. owning sync детерминированно строит весь dashboard из манифестов своего
   namespace и пишет UTF-8 без BOM, LF, ровно один terminal LF;
2. Check сравнивает логическое содержимое после единственной разрешённой
   нормализации `CRLF | CR -> LF`, ничего не записывает и сохраняет ownership;
3. manifest и dashboard читаются явным strict UTF-8 decoder, а `updatedAt`
   сохраняется JSON loader как строка, строго валидируется как RFC 3339
   instant, переводится в UTC и форматируется invariant-способом как
   `yyyy-MM-dd`;
4. одна и та же contract suite проходит на обязательном Windows 11 host
   отдельно под Windows PowerShell 5.1 и PowerShell 7.x в `en-US` и `ru-RU`,
   включая LF/CRLF/CR и `core.autocrlf=false|true`, и подтверждает одинаковый
   SHA-256 результата; отсутствие отдельного Windows 10 runner не блокирует
   реализацию, проверку или релиз, а доступное Windows 10 evidence остаётся
   только необязательным best-effort дополнением;
5. все проверки `SPEC-TEST-001..018` дают evidence для соответствующих
   `PRD-AC-001..017`.

Трассировка: `PRD-REQ-001..017`, `PRD-NFR-001..008`,
`PRD-AC-001..017`.

## 2. Авторитет и границы

### 2.1. Продуктовый авторитет

Единственный продуктовый источник — approved revision `2` файла
`docs/Features/template/deterministic-feature-dashboard-validation/product-requirements.md`
с exact-byte SHA-256
`ec6edd8462d5fed2c4f97909eb3bdcd20ce2ef99fe382e5f12d5d48b12b3258a`.
Внешний subscriber patch не является источником требований или реализации.

### 2.2. Репозиторий и архитектурная база

Текущий репозиторий — reusable template: `origin` указывает на
`teano/roblox_project_template`, отдельного `upstream` template remote и
`docs/adr/project/` нет. Изменения принадлежат template namespace.

Действующие `.agents/rules/feature-workflow.md` и template/ADR-0037 сохраняют:

- manifest как каноническое feature state;
- раздельное владение `template` и `project` namespace;
- запрет derived-проекту менять inherited template dashboard;
- исключительное право пользователя на lifecycle transitions;
- schema version 2, canonical branches и feature-scoped writer leases.

TF-0008 не вводит новое durable cross-module решение и не supersede
template/ADR-0037. Новый ADR не требуется, если реализация не выйдет за
описанные границы.

### 2.3. В scope

- `scripts/FeatureWorkflow.psm1`: чтение manifest JSON, timestamp validation и
  formatting, полный deterministic render, line-ending normalization,
  ownership-aware Check/Sync и diagnostics;
- `scripts/tests/feature-workflow.tests.ps1`: изолированные regression fixtures
  и обязательные Windows 11/PowerShell/culture/line-ending/Git contracts,
  включая исходную Windows 10 / PowerShell 7 / `ru-RU` fixture как
  детерминированный input, исполняемый на Windows 11;
- `.gitattributes`: точечный LF checkout contract для двух generated dashboard;
- generated `docs/Features/template/README.md` как результат owning sync;
- существующие entrypoints `scripts/sync-feature-index.ps1`,
  `scripts/validate-feature-workflow.ps1` и их вызов из
  `scripts/validate-repository-layout.ps1` без изменения public parameters.

Трассировка: `PRD-REQ-001..017`, `PRD-NFR-001..008`.

### 2.4. Вне scope

- schema version, ID allocation, status/activity, branch reservation, lease,
  Start/Continue/Pause/Reopen/Finish и user authority;
- колонки, русские labels, emoji, counters, sorting semantics, Markdown links,
  escaping или namespace filtering;
- Roblox runtime, Rojo mapping, `place.rbxl`, Studio и игровые системы;
- сетевые операции, внешний test framework или новая dependency;
- автоматическое исправление foreign template dashboard из derived-проекта;
- перевод репозитория только на PowerShell 7 или расширение официальной
  non-Windows support matrix;
- создание, покупка, подключение или обязательная доступность отдельной
  Windows 10 машины, VM, CI runner, capability prerequisite либо release job.

Трассировка: `PRD-REQ-004`, `PRD-REQ-006`, `PRD-REQ-016`, `PRD-REQ-017`,
`PRD-NFR-008`, `PRD-AC-015`, `PRD-AC-017`.

## 3. Подтверждённое текущее состояние

### EVID-001 — platform line separator попадает в expected content

`Get-FeatureIndexBlock` в `scripts/FeatureWorkflow.psm1` соединяет строки через
`[Environment]::NewLine`; `Sync-FeatureIndex` тем же значением дополняет
scaffold. На Windows expected content содержит CRLF, даже если tracked
dashboard содержит LF.

### EVID-002 — Check использует exact in-memory string equality

`Sync-FeatureIndex -Check` сравнивает `$current -cne $desired`. Git может
нормализовать line endings для index/diff, но PowerShell сравнивает working-tree
строки, поэтому чистый Git status не доказывает dashboard equality.

### EVID-003 — JSON date coercion образует locale round trip

`Get-FeatureManifests` вызывает `ConvertFrom-Json` без управления date kind, а
dashboard затем делает `[string]$m.updatedAt -> DateTimeOffset.Parse`. В новых
PowerShell ISO timestamp может быть уже преобразован в `DateTime`; его
промежуточная строка зависит от culture и позволяет поменять местами месяц и
день.

### EVID-004 — ownership создаёт неустранимый false-positive в derived

Derived-проект обязан проверять template dashboard, но non-Check template sync
правильно запрещён. Текущая универсальная ошибка советует sync owning namespace
даже тогда, когда caller им не владеет.

### EVID-005 — существующая contract surface

Dashboard сейчас содержит фиксированный scaffold, ровно один generated block,
counters и девять колонок. Sorting — status rank `in_progress`, `planned`,
`ready`, затем фиксированный ASCII ID. Существующая suite уже проверяет lifecycle,
namespace isolation, foreign byte preservation и real counter drift; она
запускает дочерние команды через жёстко выбранный Windows PowerShell.

### EVID-006 — default text decoding не является dual-host contract

Canonical dashboard и manifests записываются как UTF-8 без BOM, но текущие
read paths используют `Get-Content -Raw` без explicit encoding. Windows
PowerShell 5.1 интерпретирует такой input через legacy default encoding,
тогда как PowerShell 7 использует UTF-8. Поэтому BOM только на module/test
source не гарантирует сохранность русского текста, emoji и escaped JSON во
всей обязательной Windows 11/PowerShell matrix.

Трассировка: `PRD-REQ-003`, `PRD-REQ-005..008`, `PRD-REQ-011..017`,
`PRD-NFR-001`, `PRD-NFR-004`, `PRD-NFR-006`.

## 4. Владение и компоненты

### 4.1. Manifest loader

`Get-FeatureManifests` остаётся единственной точкой repository-wide discovery
manifest. Внутренний JSON helper обязан сохранить ISO values строками:

- если текущий `ConvertFrom-Json` имеет параметр `DateKind`, helper вызывает
  его с `-DateKind String`;
- иначе, включая Windows PowerShell 5.1, helper вызывает обычный
  `ConvertFrom-Json`, где timestamps остаются строками;
- capability определяется по metadata команды, не по строковому сравнению
  версии и не через вызов отсутствующего параметра;
- JSON parse failure немедленно завершает validation; partial records не
  рендерятся.

Helper применяется к feature manifests. Он не меняет schema или JSON writer и
не требует внешней библиотеки.

Manifest bytes читаются отдельным internal helper через
`[IO.File]::ReadAllBytes` и strict UTF-8 decoder
`[Text.UTF8Encoding]::new($false, $true)`. Invalid UTF-8 отклоняется до JSON
parse; helper не использует default ANSI/OEM encoding и не выполняет
replacement fallback. Полученная строка передаётся JSON helper без
промежуточной localized conversion.

До `ConvertFrom-Json` тот же loader выполняет JSON-string-aware scan raw text
и валидирует UTF-16 escape pairs. Scanner различает состояние вне/внутри JSON
string и штатные escapes, поэтому `\\uD800` как escaped backslash плюс literal
text не считается Unicode escape. Для каждого фактического `\uXXXX`:

- high surrogate `D800..DBFF` принимается только вместе с непосредственно
  следующим `\uDC00..\uDFFF` в той же JSON string;
- isolated low surrogate `DC00..DFFF`, high surrogate без следующей low half и
  mismatched pair отклоняются с manifest path и stable cause
  `invalid-surrogate-escape`;
- valid pair, ordinary BMP escape и явно заданный scalar U+FFFD принимаются;
- оставшийся JSON syntax по-прежнему авторитетно проверяет `ConvertFrom-Json`.

Это не даёт supported hosts превратить invalid escaped surrogate в U+FFFD до
strict dashboard boundary. Raw non-escaped invalid scalar уже отклоняется
предшествующим strict UTF-8 decoder.

`SPEC-REQ-001` (traces: `PRD-REQ-001`, `PRD-REQ-011..013`,
`PRD-REQ-017`, `PRD-NFR-002..003`, `PRD-NFR-006`, `PRD-NFR-008`).

### 4.2. Timestamp validator/formatter

Один внутренний helper принимает property label и исходную строку. Контракт:

1. null/empty `updatedAt` отклоняется;
2. значение должно пройти lexical RFC 3339 gate: полная calendar date,
   `T`/`t`, часы:минуты:секунды, optional fractional seconds и обязательный
   `Z`/`z` либо numeric offset `±HH:MM`; date-only и culture dates запрещены;
3. после lexical gate значение разбирается `DateTimeOffset.TryParse` с
   `InvariantCulture` и `DateTimeStyles.None`; parser обязан подтвердить
   календарь, время и допустимый offset;
4. display date вычисляется только через `ToUniversalTime()` и форматируется
   `ToString("yyyy-MM-dd", InvariantCulture)`;
5. current culture, UI culture и local timezone не читаются;
6. validation использует тот же helper до любого dashboard write, а renderer
   не выполняет повторный localized parse.

Непустые `startedAt` и `completedAt` проходят тот же strict parser вместо
текущего culture-dependent `TryParse`. Это сохраняет существующее требование
валидности timestamp и исключает два разных определения допустимого времени.
Изменение их display не происходит: dashboard показывает только `updatedAt`.

`SPEC-REQ-002` (traces: `PRD-REQ-011..013`, `PRD-NFR-002`,
`PRD-NFR-006`, `PRD-AC-009..012`).

### 4.3. Dashboard renderer

Один internal renderer строит весь файл, а не заменяет блок внутри
произвольного existing content. Входы: `NamespaceRole` и валидные records
только этого namespace. Выход: canonical .NET string со следующими
инвариантами:

- фиксированный title `# Фичи шаблона` или `# Фичи проекта`;
- фиксированная explanatory prose с точным manifest glob своего namespace;
- ровно одна пара markers `<!-- feature-index:begin -->` и
  `<!-- feature-index:end -->`;
- существующая summary line и существующая таблица из девяти колонок;
- ровно одна row на manifest;
- counters вычисляются из того же filtered record array;
- status ordering остаётся `in_progress`, `planned`, `ready`; tie break —
  ordinal comparison фиксированного ASCII ID;
- current mappings status/activity, eight-character base commit, branch code,
  relative feature/worklog links, blocker join и `Escape-MarkdownCell`
  сохраняются;
- строки соединяются литералом LF (`"`n"`), затем renderer удаляет только
  terminal CR/LF и добавляет ровно один LF;
- renderer возвращает только canonical string; owning sync/check boundary
  кодирует его один раз по strict contract §4.6 без BOM и replacement fallback;
- renderer не читает существующий dashboard, environment newline, culture,
  timezone, Git config или wall clock.

Scaffold до generated rows фиксируется текущим contract, включая переносы
prose; placeholder заменяется rendered block своего namespace:

```text
# {Фичи шаблона | Фичи проекта}

Этот dashboard генерируется из
`docs/Features/{template | project}/*/feature.json`. Манифесты —
единственный источник состояния; generated-блок не редактируется вручную.

{generated block}
```

Full-file render делает title, prose, markers, counters, table и rows одной
generated проекцией manifest set. Поэтому drift вне markers не становится
скрытым input будущего expected content.

`SPEC-REQ-003` (traces: `PRD-REQ-001..003`, `PRD-REQ-009..012`,
`PRD-REQ-015..016`, `PRD-NFR-001`, `PRD-NFR-003`, `PRD-NFR-007`).

### 4.4. Logical text normalization

Один internal pure helper выполняет только:

```text
CRLF -> LF
CR   -> LF
```

Порядок обязателен, чтобы CRLF не стал двумя separators. Helper не вызывает
`Trim`, Unicode normalization, whitespace folding, case conversion или
Markdown parsing. Terminal newline count, spaces, tabs, characters, row order,
markers и counters остаются значимыми.

`SPEC-REQ-004` (traces: `PRD-REQ-007..008`, `PRD-NFR-007`,
`PRD-AC-002..003`, `PRD-AC-007`).

### 4.5. Check contract

`Sync-FeatureIndex -Check` сохраняет public signature и работает так:

1. resolve repository role и проверяет допустимость видимого namespace;
2. полностью валидирует manifest set;
3. строит canonical expected dashboard через §4.3;
4. если файл отсутствует, fail-closed без создания directory/file;
5. читает существующие bytes тем же strict UTF-8 decoder без replacement
   fallback и вычисляет diagnostic drift kind;
6. сравнивает `Normalize(current)` с `Normalize(expected)` через ordinal,
   case-sensitive equality;
7. при equality успешно возвращает path, даже если физические separators — LF,
   CRLF, CR или смесь этих трёх;
8. при inequality выдаёт namespace/тип drift/recovery и nonzero exit;
9. ни в одной ветке Check не вызывает writer, Git mutation или config command.

Byte hash каждого существующего dashboard до и после Check обязан совпасть и
на success, и на failure.

`SPEC-REQ-005` (traces: `PRD-REQ-005..008`, `PRD-REQ-014..015`,
`PRD-NFR-004`, `PRD-NFR-006..007`, `PRD-AC-002..003`,
`PRD-AC-005`, `PRD-AC-007..008`, `PRD-AC-014`).

### 4.6. Owning sync contract

Non-Check sync может выбрать только writable namespace текущей repository
role. После полной manifest/timestamp validation он строит canonical bytes и:

- создаёт missing owning dashboard;
- заменяет malformed/missing-marker или stale owning dashboard целиком;
- переписывает логически корректный CRLF/CR dashboard в canonical LF;
- вызывает strict UTF-8 encoder ровно один раз и получает готовый `byte[]`;
- сравнивает именно этот `byte[]` с existing raw bytes для idempotence fast
  path и передаёт тот же массив, без повторного encode, в internal atomic byte
  writer;
- всегда пишет UTF-8 без BOM и ровно один terminal LF;
- при уже канонических bytes допускается skip write по raw byte equality с
  готовым canonical output; existing dashboard не требуется декодировать,
  поэтому owning sync может восстановить invalid UTF-8;
- независимо от optimization второй sync обязан сохранить exact SHA-256.

Internal byte writer сохраняет существующую atomic-write схему:

1. принимает только уже готовый `byte[]`;
2. создаёт unique temporary file в destination directory;
3. записывает его через `[IO.File]::WriteAllBytes`;
4. заменяет destination через существующий `Move-Item -Force` boundary;
5. удаляет только свой temporary file в `finally`.

Non-exported pure `ConvertTo-FeatureDashboardBytes(canonicalText)` вызывает
`[Text.UTF8Encoding]::new($false, $true).GetBytes($canonicalText)`. Non-exported
`Write-FeatureDashboard(path, canonicalText)` сначала вызывает этот converter,
и только после успешного результата разрешает directory creation, raw-byte
comparison или atomic byte writer. Unpaired surrogate поэтому вызывает
`EncoderFallbackException` до directory/temp/destination mutation и не может
быть заменён на U+FFFD. Check использует тот же pure converter для canonical
expected output, но никогда не вызывает writer.

Оба helpers остаются вне `Export-ModuleMember`; contract tests обращаются к ним
только через bounded module-scope invocation. Public/shared
`Write-Utf8NoBom(Path, Content)` сохраняет сигнатуру и прежнее string-output
поведение для manifests, leases, handoffs и worklogs, но делегирует финальную
запись тому же atomic byte writer после собственного existing encode. TF-0008
не делает эти unrelated artifacts частью strict dashboard contract и не
меняет их byte compatibility.

Derived repository продолжает получать hard failure при попытке non-Check
`NamespaceRole=template`; template repository продолжает отклонять project
namespace. Project sync не читает template content как input и не записывает
его.

`SPEC-REQ-006` (traces: `PRD-REQ-004`, `PRD-REQ-006`, `PRD-REQ-009..010`,
`PRD-REQ-012..015`, `PRD-NFR-003..005`, `PRD-AC-004`,
`PRD-AC-006`, `PRD-AC-012..014`).

### 4.7. Encoding and Git checkout contract

`.gitattributes` получает только два exact path rule:

```gitattributes
docs/Features/template/README.md text eol=lf
docs/Features/project/README.md text eol=lf
```

Это предотвращает новую working-tree CRLF materialization для generated
dashboard, но не является correctness dependency: существующие checkouts и
foreign inherited files всё равно проверяются по §4.5.

`scripts/FeatureWorkflow.psm1` и contract test, содержащие Cyrillic/emoji
literals, должны иметь source encoding, однозначно распознаваемую обоими
PowerShell hosts. Выбранный contract — UTF-8 with BOM для этих PowerShell source
files. Это не меняет output contract: dashboard и JSON остаются UTF-8 without
BOM. Альтернатива допустима только если все non-ASCII literals конструируются
из ASCII-safe code points и та же host matrix доказывает отсутствие corruption.

`SPEC-REQ-007` (traces: `PRD-REQ-003`, `PRD-REQ-007`, `PRD-REQ-009`,
`PRD-REQ-017`, `PRD-NFR-001`, `PRD-NFR-003`, `PRD-AC-001`,
`PRD-AC-004`, `PRD-AC-016`).

### 4.8. PowerShell host contract

Public entrypoints и параметры остаются неизменными. Contract suite запускается
внешней matrix по одному разу через `powershell.exe` 5.1 и `pwsh` 7.x.
Внутри suite дочерние workflow commands запускаются executable текущего host,
полученным как full path из
`[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName`; harness
проверяет, что path существует. Нельзя строить путь как
`Join-Path $PSHOME "pwsh.exe"`, повторно разрешать generic command name или
молча заменять один host другим.

Culture matrix задаётся в isolated child invocation до import module и sync:
thread `CurrentCulture` и `CurrentUICulture` явно устанавливаются в `en-US`
или `ru-RU`; fixture timestamp и expected SHA не зависят от machine default.
Оба значения восстанавливаются в `finally`.

Обязательная host matrix исполняется на Windows 11. Windows 10 не является
capability prerequisite, обязательной test cell или release-job gate: отсутствие
отдельного Windows 10 runner не меняет pass/fail обязательной проверки. Если
Windows 10 среда позднее доступна, тот же deterministic fixture и expected SHA
могут дать дополнительное best-effort evidence без изменения обязательных
contracts.

`SPEC-REQ-008` (traces: `PRD-REQ-003`, `PRD-REQ-012`, `PRD-REQ-017`,
`PRD-NFR-001..003`, `PRD-NFR-005`, `PRD-AC-001`, `PRD-AC-009`,
`PRD-AC-015..017`).

### 4.9. Diagnostics

Check различает минимум следующие stable diagnostic categories:

| Category | Condition | Owning recovery | Foreign template recovery |
|---|---|---|---|
| `missing` | dashboard file отсутствует | запустить owning sync с exact `-Scope` | восстановить/получить dashboard через approved upstream content |
| `markers` | markers отсутствуют, дублированы, перепутаны или malformed | owning sync пересоздаёт dashboard | восстановить/получить корректный upstream content |
| `encoding` | bytes не являются valid UTF-8 | owning sync пересоздаёт dashboard | восстановить/получить корректный upstream content |
| `content` | normalized full content отличается | owning sync | восстановить/обновить template из upstream |
| `manifest` | manifest UTF-8, JSON surrogate escapes, syntax, schema или timestamp invalid | исправить named manifest; dashboard не писать | исправить owning upstream source, не foreign dashboard |

Каждое сообщение называет namespace, category и path. Foreign diagnostic явно
говорит, что derived repository не владеет template dashboard, и никогда не
советует `sync ... -Scope Template`. Line-ending-only equality не выдаёт
warning и не создаёт шум.

`SPEC-REQ-009` (traces: `PRD-REQ-008`, `PRD-REQ-013..015`,
`PRD-NFR-006`, `PRD-AC-007..008`, `PRD-AC-012..014`).

## 5. Инварианты данных и алгоритмы

### 5.1. Canonical dashboard function

```text
Render(namespace, manifests): canonicalText
  validate every visible manifest
  records := manifests where record.namespace == namespace
  sort records by fixed status rank, then ordinal fixed-width ID
  render fixed scaffold + counters + table + rows
  updated := UTC calendar date(strict RFC3339 record.updatedAt)
  text := join every line with LF
  text := remove terminal CR/LF only, then append one LF
  return text

EncodeDashboard(canonicalText): bytes
  return StrictUTF8WithoutBOM(canonicalText)
```

Для одинаковых input values функция не имеет environment inputs. Folder name
остаётся частью существующих relative links и уже валидируется вместе с slug
record discovery.

`SPEC-REQ-010` (traces: `PRD-REQ-001..003`, `PRD-REQ-009..012`,
`PRD-REQ-016`, `PRD-NFR-001..003`).

### 5.2. Marker invariant

Canonical file содержит markers ровно по одному и в правильном порядке.
Check не пытается «починить» или выбрать один из нескольких blocks. Любое
нарушение marker invariant — real drift; owning sync заменяет весь файл,
foreign Check только сообщает ошибку.

`SPEC-REQ-011` (traces: `PRD-REQ-008`, `PRD-REQ-015`, `PRD-NFR-007`,
`PRD-AC-007`, `PRD-AC-013..014`).

### 5.3. Failure-before-mutation invariant

Manifest UTF-8 decode, raw JSON surrogate-pair scan, JSON parse, schema
validation, timestamp validation, namespace gate, render и strict output
encode выполняются именно в этом порядке до открытия temporary output. Ошибка
на любой этой стадии сохраняет existing dashboard byte-identical. Check
дополнительно fail-closed декодирует dashboard и при encoding error сохраняет
его bytes. Owning sync, напротив, считает любые existing noncanonical/invalid
bytes replaceable generated output и после успешного render перезаписывает их.
Atomic temporary file создаётся только для успешного owning write и очищается
существующим `finally`.

`SPEC-REQ-012` (traces: `PRD-REQ-005`, `PRD-REQ-012..015`,
`PRD-NFR-004..006`, `PRD-AC-006`, `PRD-AC-008`, `PRD-AC-012..014`).

### 5.4. Namespace invariant

Template repository видит и пишет только template dashboard. Initialized
derived repository видит template и project, но writable namespace — только
project. `-Check -Scope All` проверяет оба без мутации. `-Scope Project`
non-Check не вызывает template write и сохраняет его exact bytes при любом
project result.

`SPEC-REQ-013` (traces: `PRD-REQ-001`, `PRD-REQ-004..006`,
`PRD-REQ-014..015`, `PRD-NFR-004`, `PRD-AC-005..006`,
`PRD-AC-008`, `PRD-AC-014`).

## 6. Совместимость, миграция и rollout

### 6.1. Совместимость

- Public command names, parameters, default scope resolution и exit-code
  convention не меняются.
- Manifest schema version 2 и все lifecycle artifacts остаются byte/schema
  compatible; JSON writer не мигрируется.
- Current dashboard labels, links, escaping, counter meanings и ordering
  сохраняются.
- LF/CRLF/CR existing dashboard проходит Check, если normalized full content
  совпадает.
- Обязательная compatibility/release matrix использует Windows 11 с Windows
  PowerShell 5.1 и PowerShell 7.x, `en-US`/`ru-RU` и Git/EOL cells; Windows 10
  остаётся best-effort target и не является prerequisite или release gate.
- Derived projects не требуют локальной divergence для проверки исправленного
  inherited template dashboard после штатного upstream update.

`SPEC-REQ-014` (traces: `PRD-REQ-002..008`, `PRD-REQ-016..017`,
`PRD-NFR-001`, `PRD-NFR-003..004`, `PRD-NFR-008`, `PRD-AC-001`,
`PRD-AC-015..017`).

### 6.2. Миграция checkout

После принятия upstream fix owning template sync один раз фиксирует canonical
LF dashboard. `.gitattributes` применяется к новым checkout; существующие
working trees не требуют `git add --renormalize`, смены `core.autocrlf` или
перезаписи foreign files. При следующем разрешённом owning sync CRLF/CR файл
канонизируется автоматически.

Для derived-проекта правильный rollout — обычный template update. Он принимает
исправленные module/tests/attributes и canonical template dashboard. Project
dashboard остаётся project-owned и канонизируется только project sync.

`SPEC-REQ-015` (traces: `PRD-REQ-004..007`, `PRD-REQ-009..010`,
`PRD-REQ-014..015`, `PRD-AC-003..006`, `PRD-AC-013..015`).

### 6.3. Rollback

TF-0008 не изменяет persistent schema. Code rollback возможен обычным Git
revert, но вернёт известный Windows false-positive и не рекомендуется после
публикации canonical dashboard. Dashboard rollback не должен выполняться
отдельно от generator: manifest остаётся source of truth, а owning sync
восстанавливает текущую проекцию.

## 7. Безопасность, ресурсы и наблюдаемость

### 7.1. Trust boundaries

Manifest, dashboard и внешний patch являются недоверенным file input до
validation. Реализация:

- не выполняет content как PowerShell, command или Markdown directive;
- не использует `Invoke-Expression`, network, remote или executable из input;
- передаёт strings только в fixed renderer и existing Markdown escaping;
- не меняет Git config/index/worktree metadata в Check;
- не расширяет writable namespace по подсказке из dashboard;
- не принимает patch как runtime dependency.

`SPEC-REQ-016` (traces: `PRD-REQ-004..006`, `PRD-REQ-008`,
`PRD-NFR-002`, `PRD-NFR-005`, `PRD-NFR-008`).

### 7.2. Resource bounds and concurrency

Алгоритм остаётся локальным `O(F log F + B)`, где `F` — число manifests
namespace, `B` — суммарное число прочитанных/сформированных bytes. Он не вводит
wait, retry, background process или shared persistent cache. Existing atomic
writer ограничивает partial writes; feature writer lease/lifecycle ownership
не меняются. Параллельные external writers по-прежнему не входят в dashboard
API contract.

### 7.3. Observability

Success entrypoint сохраняет текущие user-facing сообщения с path. Failure
добавляет structured-in-text namespace и drift category из §4.9. Tests
проверяют обязательные substrings и отсутствие запрещённой foreign repair
инструкции; полный localized error text не становится brittle snapshot.

`SPEC-REQ-017` (traces: `PRD-REQ-014..015`, `PRD-NFR-002`,
`PRD-NFR-006`, `PRD-AC-008`, `PRD-AC-012..014`).

## 8. Детерминированная стратегия проверки

### 8.1. Test harness contract

`scripts/tests/feature-workflow.tests.ps1` сохраняет существующую contract
suite и добавляет isolated dashboard fixtures под уникальным temp root.
Fixtures инициализируются локальным Git repository без remote/network, имеют
явные manifests и оба namespace там, где это требуется. Каждый scenario:

1. сохраняет pre-hash проверяемых files;
2. запускает sync/check через текущий host или импортированный module под явно
   заданной culture;
3. проверяет exit code, bytes, BOM, separators, terminal LF и diagnostics;
4. проверяет post-hash для read-only/foreign paths;
5. восстанавливает culture в `finally`;
6. удаляет только собственный resolved temp path в существующем guarded
   cleanup.

Ни один scenario не использует рабочий feature lease, сеть, Studio, Roblox,
random timing или wall clock expectation.

### 8.2. Verification cases

#### `SPEC-TEST-001` — host/culture/Git canonical bytes matrix

Одна template fixture синхронизируется в независимых local Git copies для
`core.autocrlf=false` и `core.autocrlf=true` под PowerShell 5.1/en-US,
5.1/ru-RU, 7.x/en-US и 7.x/ru-RU на обязательном Windows 11 host. Все восемь
output имеют одинаковый expected SHA-256, UTF-8 без BOM, только LF и один
terminal LF. Дополнительная Windows 10 invocation при её доступности может
сравнить SHA с тем же expected значением, но её отсутствие не блокирует test,
verification или release; test не зависит от remote или network.

Traces: `PRD-AC-001`, `PRD-AC-015`, `PRD-AC-017`, `PRD-NFR-001`,
`PRD-NFR-003`.

#### `SPEC-TEST-002` — LF Check immutability

Canonical LF dashboard проходит Check; pre/post SHA-256 совпадает.

Traces: `PRD-AC-002`, `PRD-REQ-005`, `PRD-NFR-004`.

#### `SPEC-TEST-003` — CRLF/CR/mixed logical equality

Три copies с CRLF, CR и mixed line separators проходят Check без изменения
bytes; остальные symbols идентичны canonical content.

Traces: `PRD-AC-003`, `PRD-REQ-007`, `PRD-NFR-004`, `PRD-NFR-007`.

#### `SPEC-TEST-004` — owning canonicalization and idempotence

Owning sync преобразует CRLF dashboard в canonical LF/UTF-8-no-BOM/one-terminal-LF;
повторный sync сохраняет exact SHA-256.

Traces: `PRD-AC-004`, `PRD-REQ-009..010`.

#### `SPEC-TEST-005` — derived inherited CRLF all Check

Initialized derived fixture с logically current CRLF template dashboard и
current project dashboard проходит `-Check -Scope All`; inherited pre/post
hash совпадает.

Traces: `PRD-AC-005`, `PRD-REQ-005..007`, `PRD-NFR-004`.

#### `SPEC-TEST-006` — project-only preservation

Project sync исправляет stale project dashboard и сохраняет exact template
pre/post hash.

Traces: `PRD-AC-006`, `PRD-REQ-004`, `PRD-REQ-006`, `PRD-NFR-004`.

#### `SPEC-TEST-007` — full-file normalized drift and owning repair matrix

Отдельные owning fixtures меняют counter, feature row symbol/title, UTC date,
marker, table character, row order, top-level title, explanatory prose и
namespace manifest path. В трёх outer-scaffold cases весь generated marker
block намеренно остаётся byte-identical canonical block: текущая
marker-replacement реализация приняла бы такой file, а full-file renderer
обязан обнаружить drift.

Для каждого case Check возвращает nonzero с `content` либо `markers`, сохраняет
exact pre/post SHA-256 и не скрывает drift line-ending normalization. Затем
owning sync восстанавливает exact canonical full-file bytes — title, prose,
path, одну marker pair, counters/table/rows — и повторный Check проходит.

Traces: `PRD-AC-007`, `PRD-AC-013`, `PRD-REQ-001`, `PRD-REQ-008`,
`PRD-REQ-015`, `PRD-NFR-004`, `PRD-NFR-007`.

#### `SPEC-TEST-008` — foreign full-file drift diagnostic

Derived fixtures по отдельности меняют inherited template title, explanatory
prose и namespace manifest path вне markers, сохраняя canonical generated
block. Каждый `-Check -Scope All` получает nonzero, exact pre/post template
hash и foreign `content` diagnostic; output не содержит предложения template
sync. Ни Check, ни последующий project-only sync не восстанавливает foreign
scaffold.

Traces: `PRD-AC-008`, `PRD-REQ-001`, `PRD-REQ-006`, `PRD-REQ-008`,
`PRD-REQ-014..015`, `PRD-NFR-004`, `PRD-NFR-006..007`.

#### `SPEC-TEST-009` — Z instant under both cultures/hosts

`2026-08-05T13:28:08Z` даёт `2026-08-05` во всех четырёх host/culture cells.

Traces: `PRD-AC-009`, `PRD-REQ-011..012`.

#### `SPEC-TEST-010` — positive offset UTC boundary

`2026-08-05T00:30:00+14:00` даёт `2026-08-04`.

Traces: `PRD-AC-010`, `PRD-REQ-011`.

#### `SPEC-TEST-011` — negative offset UTC boundary

`2026-08-05T23:30:00-12:00` даёт `2026-08-06`.

Traces: `PRD-AC-011`, `PRD-REQ-011`.

#### `SPEC-TEST-012` — invalid/ambiguous timestamp fail-before-write

Matrix минимум из date-only, culture date `08/05/2026`, impossible calendar
date, missing zone и malformed offset отклоняется. Existing owning dashboard
сохраняет pre/post hash.

Traces: `PRD-AC-012`, `PRD-REQ-013`, `PRD-NFR-004`, `PRD-NFR-006`.

#### `SPEC-TEST-013` — missing owning dashboard recovery

Owning sync из отсутствующего file создаёт точный scaffold, одну marker pair,
table, UTF-8 без BOM, LF и один terminal LF; повторный sync idempotent.

Traces: `PRD-AC-013`, `PRD-REQ-009..010`, `PRD-REQ-015`.

#### `SPEC-TEST-014` — missing foreign dashboard fail-closed

Derived all Check при отсутствующем template README возвращает nonzero,
`missing`/foreign diagnostic и не создаёт file/directory.

Traces: `PRD-AC-014`, `PRD-REQ-006`, `PRD-REQ-014..015`,
`PRD-NFR-004`.

#### `SPEC-TEST-015` — original Windows 10/PowerShell 7/ru-RU fixture on Windows 11

Исходная Windows 10 / PowerShell 7 / `ru-RU` fixture из отчёта воспроизводится
как детерминированный regression input на обязательном Windows 11 host. Полный
release-candidate worktree с LF tracked dashboard и manifest timestamp
`2026-08-05T13:28:08.08195+03:00` запускает в isolated PowerShell 7 child с
`ru-RU` feature workflow validation и repository-layout validation без false
drift и без write. Displayed UTC date остаётся `2026-08-05`, а не `2026-05-08`;
dashboard pre/post SHA совпадает. Отдельное исполнение этой fixture на Windows
10 является необязательным best-effort evidence и не влияет на pass/fail.

Traces: `PRD-AC-015`, `PRD-AC-017`, `PRD-REQ-003`, `PRD-REQ-007`,
`PRD-REQ-011..012`.

#### `SPEC-TEST-016` — unchanged full workflow contract on both hosts

Полная существующая `feature-workflow.tests.ps1` вместе с новыми regressions
проходит отдельными top-level invocations под PowerShell 5.1 и PowerShell 7.x.
Каждая invocation использует свой current host для child commands.

Traces: `PRD-AC-016`, `PRD-REQ-016..017`, `PRD-NFR-003`,
`PRD-NFR-005`.

#### `SPEC-TEST-017` — repository release gates

После реализации успешно выполняются:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-feature-workflow.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync-feature-index.ps1 -Check -Scope All
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/tests/feature-workflow.tests.ps1
git diff --check
rojo build default.project.json --output <unique-temp-path>.rbxlx
```

Те же PowerShell repository gates и suite повторяются через `pwsh` 7.x.
Обе invocation выполняются на обязательном Windows 11 host и фиксируют host
version, culture, `core.autocrlf`, output SHA и exit codes. Отдельный Windows
10 runner или release job не является prerequisite: его отсутствие не
блокирует ни один gate и не меняет итоговый pass. Доступное позднее Windows 10
evidence может быть опубликовано дополнительно. Studio Play не запускается:
Roblox source/DataModel не меняются.

Traces: `PRD-AC-017`, `PRD-NFR-001..002`, `PRD-NFR-008`.

#### `SPEC-TEST-018` — strict UTF-8 input and recovery

Manifest fixture с кириллицей, emoji и escaped Markdown cell даёт одинаковый
dashboard под обоими hosts. Invalid UTF-8 byte sequence в manifest отклоняется
до write с `manifest`/encoding diagnostic и сохраняет owning dashboard hash.
Invalid UTF-8 dashboard в Check отклоняется как `encoding`, остаётся
byte-identical, а следующий разрешённый owning sync восстанавливает canonical
UTF-8/LF output. Foreign invalid UTF-8 dashboard никогда не переписывается.

Unicode-scalar boundary проверяется двумя независимыми subcases:

1. Raw-manifest loader получает по отдельности escaped isolated high surrogate
   `\uD800`, isolated low surrogate `\uDC00` и mismatched pair
   `\uD800\u0041`. Каждый input отклоняется JSON-aware scanner до
   `ConvertFrom-Json` с `manifest`/`invalid-surrogate-escape`; существующий
   dashboard hash не меняется и temporary output отсутствует. Control inputs
   `\uD83D\uDE00` и `\\uD800` принимаются, что доказывает pair/escape awareness,
   а не broad regex rejection. Invalid surrogate не материализуется как
   U+FFFD.
2. Test вызывает non-exported `Write-FeatureDashboard` через module scope с
   synthetic canonical string `([string][char]0xD800)` и destination под
   отсутствующим parent. Ожидается `EncoderFallbackException`; parent
   directory, destination и temporary file не появляются. Таким образом
   strict byte boundary проверяется напрямую и не зависит от поведения
   `ConvertFrom-Json` на конкретном host.

После замены invalid manifest escape на valid pair owning sync записывает
заранее вычисленные canonical bytes; Check проходит, а второй sync сохраняет
их exact SHA-256. Все loader и direct-encoder subcases выполняются под
PowerShell 5.1 и PowerShell 7.x.

Traces: `PRD-REQ-005..010`, `PRD-REQ-012..015`, `PRD-NFR-001`,
`PRD-NFR-003..006`, `PRD-AC-001`, `PRD-AC-004`, `PRD-AC-008`,
`PRD-AC-012`.

## 9. Acceptance trace matrix

| Product acceptance | Technical evidence | Основные contracts |
|---|---|---|
| `PRD-AC-001` | `SPEC-TEST-001`, `018` | `SPEC-REQ-001`, `003`, `007`, `008`, `010` |
| `PRD-AC-002` | `SPEC-TEST-002` | `SPEC-REQ-004`, `005` |
| `PRD-AC-003` | `SPEC-TEST-003` | `SPEC-REQ-004`, `005` |
| `PRD-AC-004` | `SPEC-TEST-004` | `SPEC-REQ-006`, `007`, `015` |
| `PRD-AC-005` | `SPEC-TEST-005` | `SPEC-REQ-005`, `013`, `015` |
| `PRD-AC-006` | `SPEC-TEST-006` | `SPEC-REQ-006`, `012`, `013` |
| `PRD-AC-007` | `SPEC-TEST-007` | `SPEC-REQ-004`, `005`, `009`, `011` |
| `PRD-AC-008` | `SPEC-TEST-008`, `018` | `SPEC-REQ-005`, `009`, `012`, `013`, `017` |
| `PRD-AC-009` | `SPEC-TEST-009` | `SPEC-REQ-001`, `002`, `008`, `010` |
| `PRD-AC-010` | `SPEC-TEST-010` | `SPEC-REQ-002`, `010` |
| `PRD-AC-011` | `SPEC-TEST-011` | `SPEC-REQ-002`, `010` |
| `PRD-AC-012` | `SPEC-TEST-012`, `018` | `SPEC-REQ-002`, `006`, `009`, `012`, `017` |
| `PRD-AC-013` | `SPEC-TEST-007`, `013` | `SPEC-REQ-003`, `006`, `011` |
| `PRD-AC-014` | `SPEC-TEST-014` | `SPEC-REQ-005`, `006`, `009`, `011..013`, `017` |
| `PRD-AC-015` | `SPEC-TEST-015` | `SPEC-REQ-001..005`, `007..010`, `014..015` |
| `PRD-AC-016` | `SPEC-TEST-016` | `SPEC-REQ-007..008`, `014` |
| `PRD-AC-017` | `SPEC-TEST-017` | `SPEC-REQ-001..017` |

## 10. Requirement coverage matrix

### 10.1. Functional requirements

| PRD requirement | Specification owners |
|---|---|
| `PRD-REQ-001` | `SPEC-REQ-003`, `010`, `013` |
| `PRD-REQ-002` | `SPEC-REQ-003`, `010`, `014` |
| `PRD-REQ-003` | `SPEC-REQ-003`, `007`, `008`, `010`, `014` |
| `PRD-REQ-004` | `SPEC-REQ-006`, `013..016` |
| `PRD-REQ-005` | `SPEC-REQ-005`, `012..014` |
| `PRD-REQ-006` | `SPEC-REQ-005..006`, `013..016` |
| `PRD-REQ-007` | `SPEC-REQ-004..005`, `007`, `014..015` |
| `PRD-REQ-008` | `SPEC-REQ-004..005`, `009`, `011`, `016` |
| `PRD-REQ-009` | `SPEC-REQ-003`, `006..007`, `010`, `015` |
| `PRD-REQ-010` | `SPEC-REQ-006`, `015` |
| `PRD-REQ-011` | `SPEC-REQ-001..003`, `010` |
| `PRD-REQ-012` | `SPEC-REQ-001..003`, `006`, `008`, `010`, `012` |
| `PRD-REQ-013` | `SPEC-REQ-001..002`, `006`, `009`, `012` |
| `PRD-REQ-014` | `SPEC-REQ-005..006`, `009`, `013`, `015`, `017` |
| `PRD-REQ-015` | `SPEC-REQ-003`, `005..006`, `009`, `011..013`, `015`, `017` |
| `PRD-REQ-016` | `SPEC-REQ-003`, `014` |
| `PRD-REQ-017` | `SPEC-REQ-001`, `007..008`, `014` |

### 10.2. Quality requirements

| PRD requirement | Specification owners |
|---|---|
| `PRD-NFR-001` | `SPEC-REQ-003`, `006..008`, `010`; `SPEC-TEST-001`, `017..018` |
| `PRD-NFR-002` | `SPEC-REQ-001..002`, `008`, `016..017`; §8.1 |
| `PRD-NFR-003` | `SPEC-REQ-001`, `003`, `006..008`, `010`, `014`; `SPEC-TEST-001`, `016`, `018` |
| `PRD-NFR-004` | `SPEC-REQ-005..006`, `012..015`; `SPEC-TEST-002..003`, `005..006`, `008`, `012`, `014`, `018` |
| `PRD-NFR-005` | `SPEC-REQ-006`, `008`, `012`, `016`; §8.1, `SPEC-TEST-016`, `018` |
| `PRD-NFR-006` | `SPEC-REQ-001..002`, `005`, `009`, `012`, `017`; `SPEC-TEST-008`, `012..014`, `018` |
| `PRD-NFR-007` | `SPEC-REQ-003..005`, `009`, `011`; `SPEC-TEST-003`, `007` |
| `PRD-NFR-008` | `SPEC-REQ-001`, `007`, `014`, `016`; `SPEC-TEST-017` |

## 11. Implementation sequence and gates

1. Добавить strict UTF-8 input helper, зафиксировать manifest JSON
   string-preservation и strict timestamp helper; добавить focused
   encoding/date/culture tests.
2. Выделить full-file canonical renderer, logical newline normalizer, one-shot
   strict dashboard encoder и shared atomic byte writer; добавить
   byte/marker/outer-scaffold/content tests.
3. Перестроить Check/Sync вокруг ownership и failure-before-mutation contracts;
   добавить derived foreign fixtures и diagnostics.
4. Добавить exact `.gitattributes` rules и source encoding compatibility для
   non-ASCII PowerShell files.
5. На обязательном Windows 11 host прогнать full dual-PowerShell contract suite,
   locale/Git/EOL matrix, repository gates и temporary Rojo build по
   `SPEC-TEST-017`; затем синхронизировать canonical template dashboard. Эта
   последовательность не ожидает Windows 10 capability или release job.

До первой source-code правки действует обязательный
`scripts/ensure-rojo-server.ps1` preflight из repository rules. Новый ADR gate
не требуется при сохранении §2.4; любое расширение ownership, schema, lifecycle
или public commands требует остановки и отдельного architecture review.

## 12. Assumptions and open questions

### 12.1. Assumptions

- Windows PowerShell 5.1 и PowerShell 7.x остаются равноправными supported
  repository hosts для этой feature.
- `updatedAt` — instant; UTC calendar date является утверждённым product
  representation, включая переход даты на offsets.
- Line separator не является логическим содержимым, но terminal newline count
  и все остальные characters являются.
- Dashboard целиком generated и не содержит поддерживаемых вручную секций;
  top-level `docs/Features/README.md` остаётся отдельным manual router.
- Обязательная release-среда предоставляет Windows 11, Windows PowerShell 5.1,
  PowerShell 7.x, `en-US`/`ru-RU` и требуемые Git/EOL fixtures.
- Отдельный Windows 10 runner недоступен и не требуется для реализации,
  verification или release; Windows 10 compatibility evidence остаётся
  необязательным best-effort дополнением с принятым остаточным риском.

### 12.2. Open questions

Открытых продуктовых, scope, ownership или public-contract вопросов нет.
Выбор capability-based JSON loading, invariant UTC parse, full-file renderer,
LF attributes, same-host child invocation и обязательной Windows 11 matrix без
Windows 10 gate является инженерной конкретизацией утверждённого PRD revision
2.
