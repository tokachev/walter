# Walter vs Ralphex — Сравнение и рекомендации

## Общий обзор

| | **Walter** | **Ralphex** |
|---|---|---|
| **Язык** | Bash + Python + Node.js | Go (единый бинарник) |
| **Установка** | Клонирование репо + Docker build | `go install` / Homebrew / Docker wrapper |
| **Фокус** | Безопасный sandbox + MCP + данные | Автономное выполнение планов + review |
| **Docker** | Собственный Dockerfile, кастомный образ | Готовые образы на GHCR, обёртка-скрипт |
| **Stars** | — | 758 |

---

## Детальное сравнение по функциям

### 1. Безопасность и изоляция

| Функция | Walter | Ralphex |
|---------|--------|---------|
| Docker-изоляция | ✅ Полный кастомный Dockerfile | ✅ Готовые образы (base + Go) |
| Сетевой firewall (iptables) | ✅ Только api.anthropic.com | ❌ Нет |
| Credential Guard (40+ паттернов) | ✅ PreToolUse hooks | ❌ Нет |
| SQL Guard (защита от DROP/TRUNCATE) | ✅ | ❌ Нет |
| Аудит-лог (JSONL) | ✅ | ❌ Нет |
| Circuit breaker | ✅ | ❌ Нет |
| Cost tracking + бюджет | ✅ ($5 по умолчанию) | ❌ Нет |

**Вывод**: Walter значительно сильнее в безопасности. Ralphex полагается только на Docker-изоляцию.

---

### 2. Выполнение планов

| Функция | Walter | Ralphex |
|---------|--------|---------|
| Парсинг `### Task N:` | ✅ | ✅ |
| Чекбоксы `- [ ]` / `- [x]` | ❌ | ✅ |
| Validation commands (тесты после таска) | ❌ | ✅ |
| Автоматический коммит после таска | ❌ | ✅ |
| `[WAIT]` — ручное подтверждение | ✅ | ❌ |
| Retry per task | ✅ (2 попытки) | ✅ |
| Max iterations | ✅ (600) | ✅ (50) |
| Перемещение в completed/ | ❌ | ✅ |
| Worktree-изоляция (параллельные планы) | ❌ | ✅ |
| Интерактивное создание плана | ❌ | ✅ (`--plan`) |
| fzf выбор плана | ❌ | ✅ |
| Rate limit wait + retry | ❌ | ✅ (`--wait 1h`) |

**Вывод**: Ralphex значительно мощнее в оркестрации планов.

---

### 3. Code Review

| Функция | Walter | Ralphex |
|---------|--------|---------|
| Фаза 1: 5 параллельных агентов | ✅ | ✅ |
| Фаза 2: внешний review | ✅ (Codex peer-review) | ✅ (Codex / custom script) |
| Фаза 3: финальный review (2 агента) | ✅ | ✅ |
| Кастомные review-агенты (шаблоны) | ❌ | ✅ (`{{agent:name}}`) |
| Stalemate detection | ❌ | ✅ (`--review-patience=N`) |
| Review-only режим | ✅ (`--review-only`) | ✅ (`--review`) |
| External-only режим | ❌ | ✅ (`--external-only`) |
| Finalize step (rebase/squash) | ❌ | ✅ (`finalize_enabled`) |
| Настраиваемые промпты review | ✅ (md файлы) | ✅ (txt файлы) |

**Вывод**: Очень похожи, но Ralphex гибче в настройке review-цикла.

---

### 4. Мониторинг и уведомления

| Функция | Walter | Ralphex |
|---------|--------|---------|
| Web dashboard | ✅ Plannotator (approve/deny) | ✅ Streaming dashboard (`--serve`) |
| Telegram-уведомления | ❌ | ✅ |
| Slack-уведомления | ❌ | ✅ |
| Email-уведомления | ❌ | ✅ |
| Webhook-уведомления | ❌ | ✅ |
| Custom script нотификации | ❌ | ✅ |
| Progress logging | ❌ | ✅ (`.ralphex/progress/`) |
| Streaming output с timestamps | ❌ | ✅ |

**Вывод**: Ralphex гораздо лучше в наблюдаемости и нотификациях.

---

### 5. Уникальные фичи Walter (нет в Ralphex)

| Функция | Описание |
|---------|----------|
| **Data Detective** | Автономный агент для расследования аномалий в данных (BigQuery + Snowflake) |
| **MCP-серверы** | Read-only Snowflake, Read/Write BigQuery |
| **GSD Workflow** | Goal-Specification-Design — полный цикл планирования проекта |
| **Credential Guard** | 40+ паттернов секретов, интеграция с native hooks |
| **Network Lock** | iptables firewall с автообновлением IP |
| **Cost Tracking** | Отслеживание токенов и бюджета |
| **Circuit Breaker** | Автоостановка при высокой частоте ошибок |
| **SQL Guard** | Защита от деструктивных SQL-операций |

---

### 6. Уникальные фичи Ralphex (нет в Walter)

| Функция | Описание |
|---------|----------|
| **Единый бинарник Go** | Простая установка через `go install` / Homebrew |
| **Validation commands** | Автозапуск тестов/линтеров после каждого таска |
| **Auto-commit per task** | Автоматический коммит после каждого выполненного таска |
| **Чекбоксы в плане** | `- [ ]` → `- [x]` прогресс прямо в файле |
| **Worktree isolation** | Параллельное выполнение нескольких планов |
| **Notification system** | Telegram, Slack, Email, Webhook, custom script |
| **Web dashboard** | Real-time streaming прогресса в браузере |
| **Stalemate detection** | Автоостановка при зацикливании review |
| **Finalize step** | Автоматический rebase/squash после review |
| **Rate limit handling** | `--wait` с автоматическим retry |
| **Bedrock support** | Нативная поддержка AWS Bedrock |
| **Interactive plan creation** | Создание плана через диалог с AI |
| **fzf plan selector** | Быстрый выбор плана из списка |
| **Custom claude_command** | Замена Claude на Codex или другую модель |
| **Progress logging** | Подробные логи в `.ralphex/progress/` |

---

## Рекомендации: что добавить в Walter

### Приоритет 1 — Высокий (быстрая реализация, большой эффект)

#### 1. Validation Commands в plan-executor
Запуск тестов/линтеров после каждого таска. В Ralphex это секция `## Validation Commands` в плане.
```markdown
## Validation Commands
- `pytest tests/`
- `ruff check .`
```
**Почему**: Сейчас Walter не проверяет, что таск выполнен корректно. Ошибки накапливаются.

#### 2. Auto-commit после каждого таска
Автоматический `git add + git commit` после успешного выполнения таска.
**Почему**: Позволяет откатиться к любому таску; сейчас в Walter все изменения в одном коммите.

#### 3. Чекбоксы `- [ ]` / `- [x]` в плане
Отметка выполненных пунктов прямо в файле плана.
**Почему**: Визуальный прогресс и возможность продолжить с места остановки.

#### 4. Stalemate Detection в review
Автоостановка review-цикла если N раундов подряд без изменений.
**Почему**: Сейчас review может зацикливаться бесконечно.

---

### Приоритет 2 — Средний (умеренная сложность, хороший эффект)

#### 5. Notification System
Уведомления о завершении/ошибке через Telegram/Slack/Webhook.
**Почему**: Walter часто работает долго в фоне — нужно знать когда закончил.

#### 6. Rate Limit Handling (`--wait`)
Автоматическое ожидание и повтор при rate limit от API.
**Почему**: Длинные планы часто упираются в rate limits.

#### 7. Finalize Step
Опциональный шаг после review: rebase, squash коммитов, создание PR.
**Почему**: Автоматизация рутинных git-операций после завершения.

#### 8. Progress Logging
Запись прогресса в файл с timestamps для каждого таска.
**Почему**: Нужно для отладки и анализа производительности.

#### 9. Streaming Web Dashboard
Обновить Plannotator до real-time streaming дашборда с прогрессом выполнения.
**Почему**: Plannotator сейчас только для approve/deny, но не показывает live-прогресс.

---

### Приоритет 3 — Низкий (сложная реализация, нишевый эффект)

#### 10. Worktree Isolation
Параллельное выполнение нескольких планов в git worktrees.
**Почему**: Полезно при работе над несколькими фичами одновременно.

#### 11. Interactive Plan Creation (`--plan`)
Создание плана через диалог с AI с fzf-выбором.
**Почему**: Упрощает создание планов, но GSD workflow уже частично покрывает это.

#### 12. Bedrock Support
Поддержка AWS Bedrock как альтернативного провайдера.
**Почему**: Нишевая потребность, но расширяет аудиторию.

#### 13. Custom Claude Provider
Возможность заменить Claude на Codex или другую модель через wrapper-скрипт.
**Почему**: Гибкость, но сложная реализация.

---

## Что НЕ нужно копировать из Ralphex

Walter уже **превосходит** Ralphex в этих областях:

1. **Безопасность** — iptables + Credential Guard + SQL Guard уникальны для Walter
2. **Data/MCP** — Detective + BigQuery/Snowflake MCP не имеют аналогов в Ralphex
3. **GSD Workflow** — Полный цикл планирования проекта
4. **Cost Control** — Tracking токенов и бюджетов
5. **Audit** — JSONL аудит-логи для compliance

---

## Итог

Walter — это **безопасный enterprise-grade sandbox** с фокусом на data и compliance.
Ralphex — это **эффективный execution engine** с фокусом на автономность и наблюдаемость.

Лучшая стратегия: взять из Ralphex execution-фичи (validation, auto-commit, чекбоксы, stalemate detection, notifications) и добавить в Walter, сохранив уникальные преимущества Walter в безопасности и data-интеграции.
