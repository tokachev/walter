# Design: Миграция с memory tool на native Claude Code memory

## Problem
Два параллельных хранилища знаний (ChromaDB memory tool + native Claude Code memory/rules) создают дублирование и инфра-оверхед. Memory tool сейчас сломан (readonly DB). Cross-project поиск не используется — главное преимущество memory tool не окупается.

## Approach
Полный переход на native Claude Code memory. Ценные записи из 963 в ChromaDB мигрируются в native memory + rules. Memory tool удаляется.

## Design

### Таксономия

| Тип знания | Куда | Пример |
|---|---|---|
| Глобальные правила, coding conventions, gotchas инструментов | `~/.claude/rules/*.md` | BQ партиционирование, SQL conventions |
| Project-specific решения, контекст, feedback | `~/.claude/projects/<project>/memory/*.md` | "Walter: выбрали iptables а не nftables" |
| Команда-facing инструкции | `CLAUDE.md` в корне репо | Как билдить, архитектура |

Правило отсечки: если знание выводимо из кода/git — не сохранять. Если актуально <1 месяца — не сохранять.

### Масштабирование

- MEMORY.md = индекс, <200 строк, 1 строка = 1 ссылка на topic file
- Topic files читаются on-demand через Read tool
- Целевой объём: 50-100 topic files на проект, 5-10 rules-файлов глобально
- Auto-Dream (когда выйдет) будет автоматически консолидировать

### Миграция (3 шага)

**Шаг 1**: Экспорт active записей из ChromaDB в `sandbox/memory-export/` как markdown (один файл на проект).

**Шаг 2**: Claude-агент фильтрует экспорт:
- DROP: stale решения, выполненные TODO, знания выводимые из кода
- MERGE: несколько записей на одну тему → один topic file
- KEEP: решения с неочевидным "почему", gotchas невидные из кода, validated feedback

**Шаг 3**: Раскладка отфильтрованного:
- Глобальное → `~/.claude/rules/` (обновить существующие или создать новые)
- Project-specific → `~/.claude/projects/<project>/memory/` + обновить MEMORY.md
- Обновить CLAUDE.md: убрать ссылки на memory tool

### Маппинг проектов

| memory tool project | native Claude Code project dir |
|---|---|
| reddit | `~/.claude/projects/<reddit-repo-path>/memory/` |
| mmdsmart | `~/.claude/projects/<mmdsmart-repo-path>/memory/` |
| flutter | `~/.claude/projects/<flutter-repo-path>/memory/` |
| zensai | `~/.claude/projects/<zensai-repo-path>/memory/` |
| personal | `~/.claude/projects/<personal-repo-path>/memory/` |

Конкретные пути определяются в Шаге 2 — агент резолвит по существующим `~/.claude/projects/*/` директориям. Если для проекта нет native директории — создаётся при первой сессии в этом репо.

### Walter ↔ Host memory sharing

Walter монтирует `~/.claude/rules/`, `agents/`, `skills/` read-only — глобальные знания доступны из контейнера. Project memory имеет расхождение путей: хост пишет в `-Users-...-<project>/memory/`, Walter — в `-workspace-<project>/memory/`. Решение: симлинк `memory/` в workspace-dir → хостовый dir. Walter автоматически создаёт симлинк при старте сессии если хостовый dir существует.

### Очистка

- Удалить `~/.claude/rules/memory-tool.md`
- Удалить MCP сервер memory tool из конфига Claude Code
- Удалить auto-save инструкции из всех CLAUDE.md
- **Agents/Skills**: grep `~/.claude/agents/*.md`, `~/.claude/skills/*/SKILL.md`, и `sdd/agents/*.md` на `memory_tool`/`memory.py` — удалить или заменить на native memory (Read/Write в `memory/`)
- Удалить вызовы `memory_auto_reflect` из всех агентов и скиллов
- `~/memory_tool/chromadb_data/` → оставить 30 дней как бэкап, потом удалить

## Decisions
- Полный native вместо гибрида: cross-project не нужен, 963 записей → реально ценных ~50-100
- Фильтрация через агента, а не ручная: слишком много записей для ручного ревью
- Rules для глобального, memory для project-specific: rules загружаются автоматически, memory — on-demand
- Симлинк для Walter↔Host memory: workspace-dir/memory → host-dir/memory. Проще чем менять маппинг в walter

## Out of Scope
- Миграция knowledge graph (не окупается без семантического поиска)
- Написание замены memory_auto_reflect (Auto-Dream покроет)
- Изменение auto memory инструкций в system prompt (они уже встроены)

## Next Steps
- Написать скрипт экспорта из ChromaDB
- Запустить фильтрацию агентом по каждому проекту
- Разложить результаты, обновить конфиги
