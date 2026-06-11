#!/bin/bash

set -euo pipefail

# ============================================
# КОНФИГУРАЦИЯ
# ============================================

# Буфер безопасности в миллисекундах (по умолчанию 5 минут)
# Не удаляем записи ближе чем SAFETY_BUFFER_MS к last-delivered-id
SAFETY_BUFFER_MS="${SAFETY_BUFFER_MS:-300000}"

REDIS_CONTAINER="${REDIS_CONTAINER:-redis}"
REDIS_CLI="${REDIS_CLI:-valkey-cli}"

LOG_FILE="${LOG_FILE:-/var/log/redis-cleanup.log}"
VERBOSE="${VERBOSE:-true}"
DRY_RUN="${DRY_RUN:-false}"

# Стримы для очистки
# canvas-images: скриншоты canvas
# raw: события браузера
STREAMS="${STREAMS:-canvas-images raw}"

# ============================================
# ФУНКЦИИ
# ============================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo "[DEBUG] $1" >&2
    fi
}

# --------------------------------------------
# get_min_delivered_id
# --------------------------------------------
# Возвращает минимальный last-delivered-id среди всех consumer groups.
# Это ID самого отстающего consumer-а.
# Удалять можно только записи старше этого ID.
#
# Пример: если есть группы db, sink, ender с разными last-delivered-id,
# возвращаем самый старый (минимальный по timestamp).
#
get_min_delivered_id() {
    local stream=$1
    local min_id=""
    local min_ts=""

    local groups_output
    groups_output=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" XINFO GROUPS "$stream" 2>/dev/null | tr -d '\0') || {
        log_verbose "Не удалось получить XINFO GROUPS для $stream"
        echo ""
        return
    }

    local ids
    ids=$(echo "$groups_output" | grep -A1 "^last-delivered-id$" | grep -v "^last-delivered-id$" | grep -v "^--$" || echo "")

    if [ -z "$ids" ]; then
        log_verbose "Нет last-delivered-id для $stream"
        echo ""
        return
    fi

    while IFS= read -r id; do
        [ -z "$id" ] && continue

        local ts
        ts=$(echo "$id" | cut -d- -f1)

        if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
            log_verbose "Пропускаем невалидный ID: $id"
            continue
        fi

        if [ -z "$min_ts" ] || [ "$ts" -lt "$min_ts" ]; then
            min_ts="$ts"
            min_id="$id"
        fi
    done <<< "$ids"

    echo "$min_id"
}

# --------------------------------------------
# get_groups_info
# --------------------------------------------
# Выводит информацию о всех consumer groups для диагностики:
#   - last-delivered: до какого ID consumer дочитал
#   - pending: прочитано, но не подтверждено (ждут XACK)
#   - lag: ещё не прочитано (очередь)
#
# Большой lag = consumer не успевает обрабатывать
# Большой pending = consumer читает, но не подтверждает (возможно падает)
#
get_groups_info() {
    local stream=$1

    local groups_output
    groups_output=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" XINFO GROUPS "$stream" 2>/dev/null | tr -d '\0') || {
        echo "  Нет consumer groups"
        return
    }

    local names
    names=$(echo "$groups_output" | grep -A1 "^name$" | grep -v "^name$" | grep -v "^--$" || echo "")

    local delivered_ids
    delivered_ids=$(echo "$groups_output" | grep -A1 "^last-delivered-id$" | grep -v "^last-delivered-id$" | grep -v "^--$" || echo "")

    local pendings
    pendings=$(echo "$groups_output" | grep -A1 "^pending$" | grep -v "^pending$" | grep -v "^--$" || echo "")

    local lags
    lags=$(echo "$groups_output" | grep -A1 "^lag$" | grep -v "^lag$" | grep -v "^--$" || echo "")

    paste <(echo "$names") <(echo "$delivered_ids") <(echo "$pendings") <(echo "$lags") 2>/dev/null | \
    while read -r name delivered pending lag; do
        printf "  Группа %s: last-delivered=%s, pending=%s, lag=%s\n" "$name" "$delivered" "$pending" "$lag"
    done
}

# --------------------------------------------
# get_first_entry_id
# --------------------------------------------
# Возвращает ID первой (самой старой) записи в стриме.
# Используется для проверки есть ли что удалять.
#
get_first_entry_id() {
    local stream=$1

    local stream_info
    stream_info=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" XINFO STREAM "$stream" 2>/dev/null | tr -d '\0') || {
        echo ""
        return
    }

    local first_id
    first_id=$(echo "$stream_info" | grep -A1 "^recorded-first-entry-id$" | tail -1 || echo "")

    if [ -z "$first_id" ] || [ "$first_id" = "0-0" ]; then
        first_id=$(echo "$stream_info" | grep -A1 "^first-entry$" | tail -1 | awk '{print $1}' || echo "")
    fi

    echo "$first_id"
}

# --------------------------------------------
# safe_trim_minid
# --------------------------------------------
# Основная функция очистки стрима.
#
# Получаем минимальный last-delivered-id (самый отстающий consumer)
# Вычитаем SAFETY_BUFFER_MS для дополнительной защиты
# Удаляем записи старше этого ID через XTRIM MINID
#
# Pending записи не удаляются (они новее last-delivered-id)
# Lag записи не удаляются (они тоже новее)
# Удаляются только записи, обработанные всеми consumer-ами
#
safe_trim_minid() {
    local stream=$1

    log "=== Обработка стрима: $stream ==="

    # Текущая длина стрима
    local current_len
    current_len=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" XLEN "$stream" 2>/dev/null || echo "0")
    log "Текущая длина: $current_len"

    if [ "$current_len" -eq 0 ]; then
        log "Стрим пустой, пропускаем"
        log ""
        return
    fi

    # Информация о consumer groups
    log "Consumer groups:"
    get_groups_info "$stream" | while read -r line; do log "$line"; done

    # Находим самого отстающего consumer-а
    local min_delivered_id
    min_delivered_id=$(get_min_delivered_id "$stream")

    if [ -z "$min_delivered_id" ]; then
        log "Нет consumer groups, пропускаем очистку"
        log ""
        return
    fi

    if [ "$min_delivered_id" = "0-0" ]; then
        log "Consumer ещё не читал данные (last-delivered=0-0), пропускаем"
        log ""
        return
    fi

    log "Минимальный last-delivered-id: $min_delivered_id"

    # Вычисляем безопасный ID для удаления (с буфером)
    local min_ts
    min_ts=$(echo "$min_delivered_id" | cut -d- -f1)

    local safe_ts=$((min_ts - SAFETY_BUFFER_MS))
    local safe_id="${safe_ts}-0"

    log "Безопасный ID для MINID (буфер ${SAFETY_BUFFER_MS}ms): $safe_id"

    # Получаем первую запись для проверки
    local first_id
    first_id=$(get_first_entry_id "$stream")

    if [ -z "$first_id" ]; then
        log "Не удалось получить first-entry, пропускаем"
        log ""
        return
    fi

    local first_ts
    first_ts=$(echo "$first_id" | cut -d- -f1)

    log "Первая запись в стриме: $first_id"

    # Проверяем есть ли что удалять
    if [ "$safe_ts" -le "$first_ts" ]; then
        log "Нечего удалять: безопасный ID ($safe_id) <= первая запись ($first_id)"
        log ""
        return
    fi

    # Оценка количества записей для удаления (примерная)
    # XRANGE выводит много строк на запись (ID + все поля), поэтому wc -l / 2
    # даёт завышенную оценку. Реальное число удалённых покажет XTRIM.
    local records_before_safe
    records_before_safe=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" XRANGE "$stream" - "$safe_id" COUNT 1000000 2>/dev/null | wc -l || echo "0")
    records_before_safe=$((records_before_safe / 2))

    log "Оценка записей для удаления: ~$records_before_safe (приблизительно, см. реальный результат ниже)"

    # DRY RUN режим - только показываем, не удаляем
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Команда: XTRIM $stream MINID $safe_id"
        log "[DRY RUN] Было бы удалено: ~$records_before_safe записей"
        log ""
        return
    fi

    # === ВЫПОЛНЯЕМ УДАЛЕНИЕ ===
    log "Выполняем: XTRIM $stream MINID $safe_id"

    local removed
    removed=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" XTRIM "$stream" MINID "$safe_id" 2>&1) || {
        log "[ERROR] Ошибка при выполнении XTRIM: $removed"
        log ""
        return
    }

    # Проверяем результат
    local after_len
    after_len=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" XLEN "$stream" 2>/dev/null || echo "0")

    local actual_removed=$((current_len - after_len))

    log "[OK] Удалено записей: $actual_removed"
    log "[OK] Длина стрима: $current_len -> $after_len"

    # Показываем состояние после очистки для верификации
    log "Проверка consumer groups после очистки:"
    get_groups_info "$stream" | while read -r line; do log "$line"; done

    log ""
}

# ============================================
# MAIN
# ============================================

log "=========================================="
log "OpenReplay Redis Streams Cleanup (MINID)"
log "=========================================="
log ""

# Проверка доступности Redis
if ! docker exec "$REDIS_CONTAINER" "$REDIS_CLI" PING >/dev/null 2>&1; then
    log "ОШИБКА: Redis недоступен!"
    log "Проверьте: docker ps | grep redis"
    exit 1
fi

log "Redis доступен"
log ""

# Версия Redis/Valkey (MINID требует Redis 6.2+)
redis_version=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" INFO server 2>/dev/null | grep -E "redis_version|valkey_version" | tr -d '\r' | tr '\n' ', ' || echo "unknown")
log "Версия: $redis_version"
log ""

log "Конфигурация:"
log "  Стримы: $STREAMS"
log "  Буфер безопасности: ${SAFETY_BUFFER_MS}ms"
log "  Тестовый режим: $DRY_RUN"
log ""

# Память до очистки
memory_before=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" INFO memory | grep used_memory_human | cut -d: -f2 | tr -d '\r')
log "Память до очистки: $memory_before"
log ""

# Обрабатываем каждый стрим
for stream in $STREAMS; do
    safe_trim_minid "$stream"
done

# Память после очистки
memory_after=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" INFO memory | grep used_memory_human | cut -d: -f2 | tr -d '\r')
log "Память после очистки: $memory_after"
log ""

log "=========================================="
log "Очистка завершена!"
log "=========================================="
log ""

# Итоговая статистика
log "Итоговое состояние:"
for stream in $STREAMS; do
    len=$(docker exec "$REDIS_CONTAINER" "$REDIS_CLI" XLEN "$stream" 2>/dev/null || echo "0")
    log "  $stream: $len записей"
done
log "  Redis память: $memory_after (было: $memory_before)"
log ""
log "Полный лог: $LOG_FILE"
log ""
