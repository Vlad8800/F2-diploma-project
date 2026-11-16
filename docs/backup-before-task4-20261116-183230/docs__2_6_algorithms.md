# 2.6. Моделювання логіки критичних вузлів системи

## 2.6.1. Вибір алгоритмів та позначення

| № | Критичний вузол | Роль в архітектурі UseTrace Studio |
| --- | --- | --- |
| А1 | Конкурентне редагування вимоги | Frontend SPA → Backend API → PostgreSQL: атомарна нова ревізія або відмова без часткового запису. |
| А2 | Додавання залежності з перевіркою DAG | Backend API → PostgreSQL: ребро зберігається лише за відсутності циклу. |
| А3 | Поширення впливу зміни | Backend API → PostgreSQL: досяжні вимоги отримують `needs_review := true`. |

`:=` — присвоювання; `=` та `!=` — порівняння. `AND`, `OR`, `NOT` — булеві оператори. `V[i]`, `E[j]`, `Q[i]`, `Adj[u][j]` — індексовані елементи колекцій. Активна вимога має `status IN {draft, approved}`; `archived` не входить до активного графа. Ребро `A → B` означає, що зміна A може вплинути на B. Транзакції запису містять також аудит та зміну ревізій проєкту. WebSocket-події публікуються після `COMMIT`.
`graph_changed` набуває значення 1 при зміні складу активного графа, інакше 0. `requirements.version` є редакційною версією `title`, `statement`, `type`, `status`; зміни системного `needs_review` відстежує `projects.project_revision` без редакційних ревізій залежних вимог. Одне агреговане `audit_events` описує вихідну бізнес-операцію. Ребро `source_id → target_id` задає напрям потенційного впливу.

## 2.6.2. А1 — конкурентне редагування вимоги

**Вхід:** `project_id`, `requirement_id`, `expected_version`, `payload`, JWT. **Вихід:** актуальна вимога або контрольована помилка. **Інваріант:** одна фактична редакційна зміна створює одну незмінну ревізію відповідної версії та одну подію аудиту; повторний `PUT` без зміни полів не створює нової ревізії.

1. Перевірити JWT, право запису, UUID, `expected_version >= 1` і поля `payload`. Порожнє тіло відхилити.
2. Почати транзакцію, заблокувати `projects[project_id]`, прочитати `requirements[requirement_id]`. Відхилити відсутню, чужу проєкту або архівовану вимогу. Перевірити дозволений перехід `current.status → payload.status`.
3. Порівняти `current.version = expected_version`. За конфлікту повернути `409` без змін. Якщо всі редакційні поля вже дорівнюють `payload`, завершити транзакцію без UPDATE, нової ревізії, аудиту та збільшення лічильників і повернути `200` з поточним станом.
4. До оновлення прочитати з PostgreSQL знімок активного графа `pre_graph` під тим самим блокуванням, звірити `graph_revision`; за помилки завантаження виконати ROLLBACK. Обчислити `next_version := current.version + 1`, виконати умовний `UPDATE ... WHERE version = expected_version`; вимагати `updated_rows = 1`. Записати `requirement_revisions[next_version]`, викликати А3 зі знімком `pre_graph`, отриманим до можливої зміни статусу; при зміні складу активного графа збільшити `graph_revision`. Після успішного А3 збільшити `project_revision` і записати одну подію `audit_events`, включивши `needs_review` до `changed_fields` лише за фактичного оновлення залежних вимог.
5. За помилки БД, А3 або дедлайну виконати `ROLLBACK`. Після `COMMIT` повернути `200` і надіслати повідомлення WebSocket.

```mermaid
graph TD
    A(["Початок А1"]) --> B[/"Ввід: JWT, project_id, requirement_id, expected_version, payload"/]
    B --> C{"auth_ok AND can_write AND valid_ids AND valid_payload AND expected_version >= 1?"}
    C -- Ні --> X[/"Вивід: response[error_code]"/]
    C -- Так --> D["BEGIN; lock := projects[project_id]; current := requirements[requirement_id]"]
    D --> E{"db_ok AND NOT timeout?"}
    E -- Ні --> R["ROLLBACK; result := 503"]
    E -- Так --> F{"current != null AND current.project_id = project_id?"}
    F -- Ні --> N["ROLLBACK; result := 404"]
    F -- Так --> G{"current.version = expected_version AND current.status != archived AND valid_transition?"}
    G -- Ні --> H["ROLLBACK; result := conflict_or_invalid_status"]
    G -- Так --> G2{"editorial_fields = payload?"}
    G2 -- Так --> G3["COMMIT; result := current"]
    G2 -- Ні --> I["pre_graph := active_graph(project_id); next_version := current.version + 1; updated_rows := conditional_update"]
    I --> J{"updated_rows = 1 AND NOT timeout?"}
    J -- Ні --> J2{"NOT timeout AND updated_rows != 1?"}
    J2 -- Так --> H
    J2 -- Ні --> R
    J -- Так --> K["revision[next_version] := snapshot; impact_result := A3(current.id, pre_graph); graph_revision := graph_revision + graph_changed"]
    K --> O{"db_ok AND impact_result != error AND NOT timeout?"}
    O -- Ні --> R
    O -- Так --> P["project_revision := project_revision + 1; audit := aggregate_event"]
    P --> P2{"db_ok AND NOT timeout?"}
    P2 -- Ні --> R
    P2 -- Так --> P3["COMMIT; result := updated_requirement"]
    P3 --> Q[/"Вивід: response[200], event[project_revision]"/]
    G3 --> Q2[/"Вивід: response[200], current"/]
    X --> Z(["Кінець А1"])
    R --> Z
    N --> Z
    H --> Z
    Q --> Z
    Q2 --> Z
```

**Edge cases:** повторний запит зі старою версією отримує `409`; ідентичний `PUT` з актуальною версією повертає `200` без нового запису; відсутня вимога — `404`; збій ревізії або аудиту скасовує зміну основного запису; порожній список залежностей дає порожній результат А3. Невдала доставка WebSocket після `COMMIT` не відкочує зафіксовану транзакцію: клієнт повторно читає стан за `project_revision`. Час без А3 — `O(1)` записів. Дозволено переходи `draft → draft/approved/archived` і `approved → draft/approved/archived`; `archived` є термінальним для PUT, порушення повертає `409 INVALID_STATUS_TRANSITION`. `needs_review` в залежних вимогах не збільшує їхньої редакційної версії.

## 2.6.3. А2 — додавання ребра з алгоритмом Кана

**Вхід:** `project_id`, `source_id`, `target_id`, JWT через `POST /api/v1/projects/{projectId}/requirement-dependencies`. **Вихід:** `201` з ребром або `400/401/403/404/409/429/503` за контрактом 2.5. **Інваріант:** активний граф проєкту залишається DAG.

1. Перевірити право запису, UUID та `source_id != target_id`. Заблокувати рядок проєкту в транзакції; прочитати активні вершини `V[i]` і ребра `E[j]`. Обидва кінці мають належати цьому проєкту й бути активними. Повторне ребро відхилити.
2. Додати кандидат лише до локального знімка: `E_prime := E ∪ {(source_id,target_id)}`. Обчислити `indegree[V[i]]`, сформувати `Q[i]` із вершин нульового степеня.
3. Поки `head < |Q|`, зняти `u := Q[head]`; для кожного `Adj[u][j]` зменшити `indegree[v]` і додати `v` до черги при нульовому степені. Контролювати дедлайн, `processed <= |V|` і `scanned_edges <= |E_prime|`.
4. Якщо `processed != |V|`, відхилити цикл. Інакше згенерувати `edge_id := uuid()`, вставити ребро з цим ID під унікальними обмеженнями, збільшити `graph_revision` та `project_revision`, записати один аудит із `entity_type = requirement_dependency`, `entity_id = edge_id`, `entity_version = NULL` і виконати `COMMIT`. Актуальний граф читається з PostgreSQL під блокуванням проєкту; кеш NetworkX дозволений лише після звірки `graph_revision` у цій транзакції.

```mermaid
graph TD
    A(["Початок А2"]) --> B[/"Ввід: JWT, project_id, source_id, target_id"/]
    B --> C{"auth_ok AND can_write AND valid_ids AND source_id != target_id?"}
    C -- Ні --> X[/"Вивід: response[error_code]"/]
    C -- Так --> D["BEGIN; lock := projects[project_id]; V[i], E[j] := active_graph(project_id)"]
    D --> E{"db_ok AND endpoints_active AND NOT duplicate_edge AND NOT timeout?"}
    E -- Ні --> R["ROLLBACK; result := rejected"]
    E -- Так --> F["E_prime := E + candidate; Adj := adjacency(E_prime[j]); indegree := count_targets(E_prime[j]); Q := zero_indegree(V[i])"]
    F --> G["head := 0; processed := 0; scanned_edges := 0"]
    G --> H{"head < |Q| AND processed < |V| AND NOT timeout?"}
    H -- Так --> I["u := Q[head]; head := head + 1; processed := processed + 1; j := 0"]
    I --> J{"j < |Adj[u]| AND scanned_edges < |E_prime| AND NOT timeout?"}
    J -- Так --> K["v := Adj[u][j]; indegree[v] := indegree[v] - 1; scanned_edges := scanned_edges + 1; j := j + 1"]
    K --> L{"indegree[v] = 0?"}
    L -- Так --> M["Q[|Q|] := v"]
    L -- Ні --> J
    M --> J
    J -- Ні --> T{"j = |Adj[u]| AND NOT timeout?"}
    T -- Так --> H
    T -- Ні --> R
    H -- Ні --> N{"NOT timeout AND processed = |V| AND scanned_edges <= |E_prime|?"}
    N -- Ні --> R
    N -- Так --> O["edge_id := uuid(); INSERT edge[edge_id]; graph_revision := graph_revision + 1; project_revision := project_revision + 1; audit.entity_id := edge_id"]
    O --> P{"db_ok AND NOT timeout?"}
    P -- Ні --> R
    P -- Так --> Q["COMMIT; result := edge"]
    Q --> S[/"Вивід: result"/]
    X --> Z(["Кінець А2"])
    R --> Z
    S --> Z
```

**Edge cases:** самозалежність і дубль відхиляються; порожній граф не містить допустимих кінців; ізольовані вершини входять до `|V|`. Замок проєкту серіалізує паралельні зміни графа. Час і пам'ять — `O(|V| + |E|)`.

## 2.6.4. А3 — поширення впливу по активному графу

**Вхід:** `project_id`, `changed_id`, активний `Adj[u][j]`, відкрита транзакція А1. **Вихід:** `affected` або помилка для А1. **Інваріант:** кожна досяжна вершина відвідується не більше разу; стартова вимога не позначається як власний наслідок. А3 не виконує `COMMIT`.

1. Перевірити стартову вимогу й завантаження графа. Для архівації зняти знімок графа до виключення вузла. Ініціалізувати `Q[0] := changed_id`, `visited := {changed_id}`, `head := 0`, `affected := ∅`.
2. Поки `head < |Q| AND NOT timeout`, взяти `u := Q[head]`; для кожного `Adj[u][j]` додати активне `v` того ж проєкту до `Q` і `affected` тільки при `v NOT IN visited`.
3. Для кожного `affected[i]` записати `needs_review := true` у транзакції А1 без збільшення `requirements.version` та без окремих `requirement_revisions`; зафіксувати агреговану зміну під одним `project_revision` і однією подією аудиту вихідної вимоги. На помилці БД, дедлайні чи перевищенні конфігурованих лімітів вершин/ребер повернути помилку; А1 виконає `ROLLBACK`.

```mermaid
graph TD
    A(["Початок А3"]) --> B[/"Ввід: project_id, changed_id, Adj[u][j], deadline"/]
    B --> C{"changed_exists AND graph_loaded AND NOT timeout?"}
    C -- Ні --> X["result := error"]
    C -- Так --> D["Q[0] := changed_id; visited := {changed_id}; affected := empty; head := 0; scanned_edges := 0"]
    D --> E{"head < |Q| AND |visited| <= max_vertices AND NOT timeout?"}
    E -- Так --> F["u := Q[head]; head := head + 1; j := 0"]
    F --> G{"j < |Adj[u]| AND scanned_edges < max_edges AND NOT timeout?"}
    G -- Так --> H["v := Adj[u][j]; j := j + 1; scanned_edges := scanned_edges + 1"]
    H --> I{"active(v) AND same_project(v) AND v NOT IN visited?"}
    I -- Так --> J["visited := visited + {v}; Q[|Q|] := v; affected := affected + {v}"]
    I -- Ні --> G
    J --> G
    G -- Ні --> T{"j = |Adj[u]| AND NOT timeout?"}
    T -- Так --> E
    T -- Ні --> X
    E -- Ні --> K{"head = |Q| AND NOT timeout AND |visited| <= max_vertices AND scanned_edges <= max_edges?"}
    K -- Ні --> X
    K -- Так --> L["i := 0"]
    L --> M{"i < |affected| AND NOT timeout?"}
    M -- Так --> N["requirements[affected[i]].needs_review := true; i := i + 1"]
    N --> M
    M -- Ні --> O{"db_ok AND NOT timeout?"}
    O -- Ні --> X
    O -- Так --> P["result := affected"]
    X --> Y[/"Вивід: result_error"/]
    P --> Q[/"Вивід: affected"/]
    Y --> Z(["Кінець А3"])
    Q --> Z
```

**Edge cases:** без вихідних ребер `affected := ∅`; повторні шляхи не дублюють запис; архівовані проміжні вершини не розгортаються; помилка скасовує всю транзакцію А1. Час `O(|V_reachable| + |E_reachable|)`, додаткова пам'ять `O(|V_reachable|)`. `max_vertices`, `max_edges` та `deadline` задаються конфігурацією; досягнення ліміту означає контрольовану відмову, а не частковий результат.

## 2.6.5. Межі специфікації

А1 і А2 використовують однакове блокування рядка проєкту. Результат А3 входить у транзакцію А1. HTTP-відповіді редагування і маршрут `POST /api/v1/projects/{projectId}/requirement-dependencies` визначено в підрозділі 2.5. Окремий `PUT .../review-acknowledgement` під блокуванням проєкту звіряє `expected_version` та `expected_project_revision`, скидає `needs_review`, збільшує тільки `project_revision` й пише одну подію аудиту; редакційна версія і ревізії вимоги не змінюються. Після втрати підтвердження COMMIT клієнт виконує GET та звіряє поточний стан до повтору PUT; при втраті WebSocket-події заголовки ревізій в REST показують розбіжність, а повний знімок проєкту є окремим контрактом наступного етапу. Код Mermaid зберігається як `graph TD`; відображення саме в цільовому PKM Workspace перевіряється після вставлення.

## 2.6.6. Контроль артефактів

У трьох схемах термінатори подано округленими блоками, операції — прямокутниками, перевірки — ромбами, ввід/вивід — паралелограмами. Присвоювання в процесах записані через `:=`; `=` і `!=` у ромбах позначають порівняння; складені умови використовують `AND`, `OR`, `NOT`. Статична перевірка вихідного Mermaid-коду виявила 3 схеми і не виявила стрілок до невизначених вузлів. Це не замінює перевірку рендерингу в цільовому PKM Workspace.
