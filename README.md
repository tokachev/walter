# Walter

Docker-sandbox для запуска [Claude Code](https://docs.anthropic.com/en/docs/claude-code) с сетевой изоляцией, защитой от утечки секретов и встроенным агентом для расследования data-аномалий.

## Зачем

Claude Code получает полный доступ к файлам и терминалу. Walter оборачивает его в контейнер с тремя слоями защиты:

| Слой | Что делает | От чего защищает |
|------|-----------|-----------------|
| **Docker** | Изоляция файловой системы | Доступ к хостовым учётным данным (gcloud, aws, ssh) |
| **iptables** | Только api.anthropic.com разрешён | Исходящие запросы (boto3, gcloud SDK, curl, утечка данных) |
| **credential-guard** | Хуки PreToolUse сканируют 40+ паттернов секретов | Запись секретов в файлы проекта |

## Возможности

- **Интерактивный режим** — Claude Code внутри песочницы, всё как обычно
- **Режим промпта** — передать задачу одной командой
- **Исполнитель планов** — последовательное выполнение задач из markdown-плана
- **Детектив данных** — автономный агент для расследования аномалий в данных (BigQuery + Snowflake)
- **MCP-серверы** — только чтение для Snowflake, чтение/запись для BigQuery (с ограничением на один набор данных)
- **Планнотатор** — веб-интерфейс для ревью и утверждения планов

## Быстрый старт

```bash
# 1. Клонировать репозиторий
git clone <repo-url> walter && cd walter

# 2. Сделать скрипты исполняемыми
chmod +x walter network-lock.sh hooks/*.sh

# 3. Добавить токен авторизации
echo "CLAUDE_CODE_OAUTH_TOKEN=your-token" > .env

# 4. Собрать образ
docker build -t walter:latest .

# 5. Запустить
./walter -d ./my-project
```

## Использование

```bash
# Интерактивный режим
./walter -d ./my-project

# С промптом
./walter -d ./my-project "Добавить инкрементальную загрузку таблицы events"

# С инструментом памяти
./walter -m ~/memory_tool -d ./my-project

# Разрешить дополнительные домены (pip, npm и т.д.)
./walter -a "pypi.org,files.pythonhosted.org" -d ./my-project

# Выполнить план
./walter --plan docs/plans/my-plan.md -d ./my-project

# Пересобрать образ
./walter --build -d ./my-project
```

### Опции

| Флаг | Описание |
|------|----------|
| `-d, --dir <путь>` | Директория проекта (по умолчанию: текущая) |
| `-m, --memory <путь>` | Директория инструмента памяти для монтирования |
| `-a, --allow <домены>` | Дополнительные домены через запятую |
| `--snowflake-key <путь>` | PEM-файл приватного ключа Snowflake |
| `--bq-credentials <путь>` | JSON-файл сервисного аккаунта BigQuery |
| `--bq-mcp-config <путь>` | JSON-конфиг BigQuery MCP |
| `--plan <файл>` | Markdown-файл плана для выполнения |
| `--plan-max-iter <n>` | Макс. итераций при выполнении плана (по умолчанию: 50) |
| `--plan-retries <n>` | Количество повторов на задачу (по умолчанию: 2) |
| `--build` | Пересобрать Docker-образ перед запуском |

## Архитектура

```
┌─────────────────────────────────────────────────────┐
│  Docker-контейнер                                    │
│                                                      │
│  ┌─ network-lock.sh ─────────────────────────────┐  │
│  │ iptables: разрешён api.anthropic.com:443      │  │
│  │ ip6tables: заблокировано всё                   │  │
│  │ Фоновое обновление IP каждые 5 мин            │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
│  ┌─ Claude Code ─────────────────────────────────┐  │
│  │  Хуки (PreToolUse):                            │  │
│  │    credential-guard.sh → scan-credentials.sh   │  │
│  │    (Write, Edit, Bash)                         │  │
│  │                                                │  │
│  │  MCP-серверы:                                  │  │
│  │    snowflake-readonly (запрос, список, схема)  │  │
│  │    bigquery (чтение + запись в один набор)     │  │
│  │                                                │  │
│  │  Агенты:                                       │  │
│  │    Детектив данных (расследование аномалий)    │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
│  /workspace  ← директория проекта (чтение/запись)   │
│  НЕТ: gcloud, aws, ssh, файловая система хоста      │
└─────────────────────────────────────────────────────┘
```

## Структура проекта

```
walter/
├── walter                  # Главный лаунчер (оркестрация Docker)
├── network-lock.sh         # Сетевой файрвол (точка входа контейнера)
├── plan-executor.sh        # Исполнитель markdown-планов
├── Dockerfile
├── .env                    # Токен авторизации (не в git)
│
├── hooks/                  # Защита от утечки секретов (нативные хуки Claude Code)
│   ├── settings.json       # Конфигурация хуков
│   ├── credential-guard.sh # Обработчик PreToolUse
│   └── scan-credentials.sh # Сканер секретов (40+ regex-паттернов)
│
├── detective/              # Детектив данных — агент расследования аномалий
│   ├── detective_core.py   # Цикл расследования + SQL-исполнитель
│   ├── mcp_server.py       # MCP-сервер для Детектива данных
│   ├── connectors.py       # Коннекторы BigQuery и Snowflake
│   └── data-detective.md   # Определение агента для Claude Code
│
├── mcp/                    # MCP-серверы
│   ├── sql_utils.py        # Общие утилиты (markdown-таблицы, SQL-валидация)
│   ├── snowflake-readonly.py # Snowflake MCP (только чтение)
│   └── bigquery/
│       └── server.py       # BigQuery MCP (чтение + ограниченная запись)
│
├── plannotator/            # Веб-интерфейс для ревью планов
│   ├── server.js           # HTTP-сервер
│   ├── ui.html             # Интерфейс
│   └── hook.sh             # Хук для запроса разрешений
│
└── docs/plans/
    └── TEMPLATE.md         # Шаблон плана
```

## Настройка Детектива данных

Для работы Детектива данных добавьте переменные в `.env` вашего проекта:

```bash
# BigQuery
BQ_PROJECT=my-gcp-project
BQ_CREDENTIALS_PATH=/path/to/service-account.json

# Snowflake
SNOWFLAKE_ACCOUNT=myaccount.us-central1.gcp
SNOWFLAKE_USER=myuser
SNOWFLAKE_PRIVATE_KEY_PATH=/path/to/snowflake_key.pem
SNOWFLAKE_WAREHOUSE=COMPUTE_WH
SNOWFLAKE_DATABASE=MY_DB
SNOWFLAKE_ROLE=ANALYST

# Настройки агента (необязательно)
DETECTIVE_MODEL=claude-sonnet-4-20250514
DETECTIVE_MAX_ITER=15
```

## Требования

- Docker Desktop (macOS / Linux / Windows WSL)
- Токен Claude Code (OAuth или API-ключ)

## Решение проблем

| Проблема | Решение |
|----------|---------|
| `api.anthropic.com — FAILED` при старте | DNS не работает в контейнере: `docker run --rm alpine nslookup api.anthropic.com` |
| Claude Code не авторизован | Проверьте `CLAUDE_CODE_OAUTH_TOKEN` в `.env` или `ANTHROPIC_API_KEY` |
| Задача зависла | Ctrl+C останавливает контейнер; изменения сохраняются в директории проекта |
| Ложное срабатывание защиты секретов | Добавьте паттерн в `ALLOWLIST_PATTERNS` в `hooks/scan-credentials.sh` |

## Лицензия

MIT
