#!/bin/bash

set -euo pipefail

# ============================================
# КОНФИГУРАЦИЯ
# ============================================

# Очистка system таблиц ClickHouse (логи, метрики)
# Записи старше SYSTEM_RETENTION_DAYS дней будут удалены
SYSTEM_RETENTION_DAYS="${SYSTEM_RETENTION_DAYS:-7}"

# Очистка пользовательских данных ClickHouse (events, sessions)
# Записи старше DATA_RETENTION_DAYS дней будут удалены
DATA_RETENTION_DAYS="${DATA_RETENTION_DAYS:-365}"

CLICKHOUSE_CONTAINER="clickhouse"
CLICKHOUSE_USER="default"
CLICKHOUSE_PASSWORD=""

# System таблицы для очистки
# query_log — логи всех SQL запросов
# metric_log — метрики производительности
# trace_log — трейсы для отладки
SYSTEM_TABLES=(
    "system.query_log"
    "system.asynchronous_metric_log"
    "system.metric_log"
    "system.trace_log"
    "system.part_log"
    "system.text_log"
    "system.processors_profile_log"
    "system.query_views_log"
)

# Пользовательские таблицы для очистки (retention = DATA_RETENTION_DAYS)
# product_analytics.events — клики, инпуты, просмотры страниц, кастомные события
# experimental.sessions — метаданные сессий в ClickHouse
# Формат: "database.table:date_column"
DATA_TABLES=(
    "product_analytics.events:created_at"
    "experimental.sessions:datetime"
)

# Методы очистки:
# truncate
# delete
CLEANUP_METHOD="${CLEANUP_METHOD:-delete}"

# Логирование
LOG_FILE="/var/log/clickhouse-cleanup.log"
VERBOSE="${VERBOSE:-true}"
DRY_RUN="${DRY_RUN:-false}"

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
# ch_exec
# --------------------------------------------
# Выполняет SQL запрос в ClickHouse контейнере.
# Поддерживает работу с паролем и без.
#
ch_exec() {
    if [ -z "$CLICKHOUSE_PASSWORD" ]; then
        docker exec "$CLICKHOUSE_CONTAINER" clickhouse-client \
            --user "$CLICKHOUSE_USER" \
            --query "$1"
    else
        docker exec "$CLICKHOUSE_CONTAINER" clickhouse-client \
            --user "$CLICKHOUSE_USER" \
            --password "$CLICKHOUSE_PASSWORD" \
            --query "$1"
    fi
}

# --------------------------------------------
# get_table_size
# --------------------------------------------
# Возвращает размер таблицы в человекочитаемом формате.
# Использует system.parts для подсчёта активных частей.
#
get_table_size() {
    local table=$1
    local size_query="SELECT formatReadableSize(sum(bytes)) FROM system.parts WHERE active AND table='${table##*.}' AND database='${table%%.*}';"
    ch_exec "$size_query" 2>/dev/null || echo "unknown"
}

# --------------------------------------------
# get_row_count
# --------------------------------------------
# Возвращает количество строк в таблице.
#
get_row_count() {
    local table=$1
    local count_query="SELECT formatReadableQuantity(sum(rows)) FROM system.parts WHERE active AND table='${table##*.}' AND database='${table%%.*}';"
    ch_exec "$count_query" 2>/dev/null || echo "unknown"
}

# ============================================
# MAIN
# ============================================

log "=========================================="
log "OpenReplay ClickHouse System Tables Cleanup"
log "=========================================="
log ""

# Проверка доступности ClickHouse
if ! docker ps --format '{{.Names}}' | grep -q "^${CLICKHOUSE_CONTAINER}$"; then
    log "ОШИБКА: Контейнер ClickHouse '$CLICKHOUSE_CONTAINER' не запущен!"
    exit 1
fi

log "ClickHouse контейнер доступен"
log ""

log "Конфигурация:"
log "  Метод: $CLEANUP_METHOD"
log "  System retention: $SYSTEM_RETENTION_DAYS дней"
log "  Data retention: $DATA_RETENTION_DAYS дней"
log "  System таблиц: ${#SYSTEM_TABLES[@]}"
log "  Data таблиц: ${#DATA_TABLES[@]}"
log "  Тестовый режим: $DRY_RUN"
log ""

# Вычисляем дату удаления
data_delete_before_days=$((DATA_RETENTION_DAYS))

if [ "$CLEANUP_METHOD" = "delete" ]; then
    delete_before_days=$((SYSTEM_RETENTION_DAYS))
    log "System данные: удалить старше $delete_before_days дней"
    log "User данные: удалить старше $data_delete_before_days дней"
    log ""
fi

# ============================================
# РАЗМЕРЫ ДО ОЧИСТКИ
# ============================================

log "=== Размеры system таблиц до очистки ==="
log ""

declare -A sizes_before
declare -A rows_before

for table in "${SYSTEM_TABLES[@]}"; do
    size=$(get_table_size "$table")
    rows=$(get_row_count "$table")
    
    sizes_before[$table]=$size
    rows_before[$table]=$rows
    
    log "  $table"
    log "    Размер: $size"
    log "    Строк: $rows"
    log ""
done

# ============================================
# ОЧИСТКА ТАБЛИЦ
# ============================================

log "=== Очистка таблиц ==="
log ""

for table in "${SYSTEM_TABLES[@]}"; do
    log "Обработка: $table"
    
    if [ "$DRY_RUN" = true ]; then
        log "  ТЕСТОВЫЙ РЕЖИМ: Таблица будет очищена"
        
        if [ "$CLEANUP_METHOD" = "truncate" ]; then
            log "  Запрос: TRUNCATE TABLE $table;"
        else
            log "  Запрос: ALTER TABLE $table DELETE WHERE event_date < today() - $delete_before_days;"
        fi
        
        log ""
        continue
    fi
    
    # Выполняем cleanup
    if [ "$CLEANUP_METHOD" = "truncate" ]; then
        cleanup_query="TRUNCATE TABLE $table;"
        log_verbose "  Выполнение: $cleanup_query"
        
        if ch_exec "$cleanup_query" >/dev/null 2>&1; then
            log "  [OK] Truncate выполнен успешно"
        else
            log "  [ERROR] Ошибка при truncate"
        fi
    else
        # DELETE старых записей
        cleanup_query="ALTER TABLE $table DELETE WHERE event_date < today() - $delete_before_days;"
        log_verbose "  Выполнение: $cleanup_query"
        
        if ch_exec "$cleanup_query" >/dev/null 2>&1; then
            log "  [OK] Mutation запланирован"
            log "  [INFO] Mutation будет применён асинхронно"
        else
            log "  [ERROR] Ошибка при планировании mutation"
        fi
    fi
    
    log ""
done

# ============================================
# ОПТИМИЗАЦИЯ ТАБЛИЦ (опционально)
# ============================================

if [ "$CLEANUP_METHOD" = "delete" ] && [ "$DRY_RUN" = false ]; then
    log "=== Оптимизация таблиц ==="
    log ""
    log "Этот шаг применяет DELETE mutations и может занять время..."
    log "Можно пропустить и позволить ClickHouse оптимизировать таблицы в фоне."
    log ""
    log "Пропускаем автоматическую оптимизацию."
    log "ClickHouse оптимизирует таблицы в фоне автоматически."
    log ""
fi

# ============================================
# РАЗМЕРЫ ПОСЛЕ ОЧИСТКИ (system)
# ============================================

if [ "$DRY_RUN" = false ]; then
    log "=== Размеры system таблиц после очистки ==="
    log ""
    
    for table in "${SYSTEM_TABLES[@]}"; do
        size_after=$(get_table_size "$table")
        rows_after=$(get_row_count "$table")
        
        size_before=${sizes_before[$table]}
        rows_before_val=${rows_before[$table]}
        
        log "  $table"
        log "    Размер: $size_after (было: $size_before)"
        log "    Строк: $rows_after (было: $rows_before_val)"
        log ""
    done
    
    if [ "$CLEANUP_METHOD" = "delete" ]; then
        log "Примечание: Место на диске освободится после применения mutations и слияния частей."
        log "Это происходит автоматически в фоне."
        log ""
    fi
fi

# ============================================
# ОЧИСТКА ПОЛЬЗОВАТЕЛЬСКИХ ДАННЫХ
# ============================================

log "=========================================="
log "Очистка пользовательских данных (retention: $DATA_RETENTION_DAYS дней)"
log "=========================================="
log ""

for entry in "${DATA_TABLES[@]}"; do
    # Парсим формат "database.table:date_column"
    table="${entry%%:*}"
    date_column="${entry##*:}"
    
    db_name="${table%%.*}"
    table_name="${table##*.}"
    
    log "=== Обработка: $table (колонка: $date_column) ==="
    
    # Проверяем существование таблицы
    table_exists=$(ch_exec "SELECT count() FROM system.tables WHERE database='$db_name' AND name='$table_name';" 2>/dev/null || echo "0")
    table_exists=$(echo "$table_exists" | tr -d '[:space:]')
    
    if [ "$table_exists" = "0" ]; then
        log "  [SKIP] Таблица $table не найдена, пропускаем"
        log ""
        continue
    fi
    
    # Размер до очистки
    data_size_before=$(get_table_size "$table")
    data_rows_before=$(get_row_count "$table")
    log "  Размер до: $data_size_before"
    log "  Строк до: $data_rows_before"
    
    # Подсчёт записей для удаления
    count_old=$(ch_exec "SELECT count() FROM $table WHERE $date_column < today() - $data_delete_before_days;" 2>/dev/null || echo "unknown")
    count_old=$(echo "$count_old" | tr -d '[:space:]')
    log "  Записей старше $DATA_RETENTION_DAYS дней: $count_old"
    
    if [ "$count_old" = "0" ] || [ "$count_old" = "unknown" ]; then
        if [ "$count_old" = "0" ]; then
            log "  [OK] Нет старых записей для удаления"
        else
            log "  [WARN] Не удалось подсчитать записи (таблица может иметь другую структуру)"
        fi
        log ""
        continue
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log "  ТЕСТОВЫЙ РЕЖИМ: Было бы удалено $count_old записей"
        log "  Запрос: ALTER TABLE $table DELETE WHERE $date_column < today() - $data_delete_before_days;"
        log ""
        continue
    fi
    
    # Выполняем удаление
    cleanup_query="ALTER TABLE $table DELETE WHERE $date_column < today() - $data_delete_before_days;"
    log_verbose "  Выполнение: $cleanup_query"
    
    if ch_exec "$cleanup_query" >/dev/null 2>&1; then
        log "  [OK] Mutation запланирован для $count_old записей"
        log "  [INFO] Mutation будет применён асинхронно"
    else
        log "  [ERROR] Ошибка при планировании mutation"
    fi
    
    # Размер после (будет обновлён после применения mutation)
    data_size_after=$(get_table_size "$table")
    data_rows_after=$(get_row_count "$table")
    log "  Размер после: $data_size_after (было: $data_size_before)"
    log "  Строк после: $data_rows_after (было: $data_rows_before)"
    log ""
done

# ============================================
# КОМАНДЫ ДЛЯ РУЧНОЙ ОПТИМИЗАЦИИ
# ============================================

log "=== Команды для ручной оптимизации ==="
log ""

log "Для ручной оптимизации всех таблиц (принудительное применение mutations):"
log ""
for table in "${SYSTEM_TABLES[@]}"; do
    if [ -z "$CLICKHOUSE_PASSWORD" ]; then
        echo "docker exec $CLICKHOUSE_CONTAINER clickhouse-client --user $CLICKHOUSE_USER --query \"OPTIMIZE TABLE $table FINAL;\""
    else
        echo "docker exec $CLICKHOUSE_CONTAINER clickhouse-client --user $CLICKHOUSE_USER --password <PASSWORD> --query \"OPTIMIZE TABLE $table FINAL;\""
    fi
done | tee -a "$LOG_FILE"
for entry in "${DATA_TABLES[@]}"; do
    table="${entry%%:*}"
    if [ -z "$CLICKHOUSE_PASSWORD" ]; then
        echo "docker exec $CLICKHOUSE_CONTAINER clickhouse-client --user $CLICKHOUSE_USER --query \"OPTIMIZE TABLE $table FINAL;\""
    else
        echo "docker exec $CLICKHOUSE_CONTAINER clickhouse-client --user $CLICKHOUSE_USER --password <PASSWORD> --query \"OPTIMIZE TABLE $table FINAL;\""
    fi
done | tee -a "$LOG_FILE"
log ""

log "Для проверки прогресса mutation:"
if [ -z "$CLICKHOUSE_PASSWORD" ]; then
    echo "docker exec $CLICKHOUSE_CONTAINER clickhouse-client --user $CLICKHOUSE_USER --query \"SELECT database, table, mutation_id, command, is_done, latest_fail_reason FROM system.mutations WHERE NOT is_done;\""
else
    echo "docker exec $CLICKHOUSE_CONTAINER clickhouse-client --user $CLICKHOUSE_USER --password <PASSWORD> --query \"SELECT database, table, mutation_id, command, is_done, latest_fail_reason FROM system.mutations WHERE NOT is_done;\""
fi | tee -a "$LOG_FILE"
log ""

log "Для проверки активных слияний (merges):"
if [ -z "$CLICKHOUSE_PASSWORD" ]; then
    echo "docker exec $CLICKHOUSE_CONTAINER clickhouse-client --user $CLICKHOUSE_USER --query \"SELECT * FROM system.merges;\""
else
    echo "docker exec $CLICKHOUSE_CONTAINER clickhouse-client --user $CLICKHOUSE_USER --password <PASSWORD> --query \"SELECT * FROM system.merges;\""
fi | tee -a "$LOG_FILE"
log ""

# ============================================
# ИТОГОВАЯ СТАТИСТИКА
# ============================================

log "=========================================="
log "Очистка завершена!"
log "=========================================="
log ""

if [ "$DRY_RUN" = true ]; then
    log "ТЕСТОВЫЙ РЕЖИМ: Данные не были удалены"
    log "Просмотрите лог и запустите без DRY_RUN=true для выполнения очистки"
else
    log "Очищено ${#SYSTEM_TABLES[@]} system таблиц (retention: $SYSTEM_RETENTION_DAYS дней)"
    log "Очищено ${#DATA_TABLES[@]} data таблиц (retention: $DATA_RETENTION_DAYS дней)"
    
    if [ "$CLEANUP_METHOD" = "truncate" ]; then
        log "Метод: TRUNCATE (все данные удалены немедленно)"
    else
        log "Метод: DELETE (удаление старых данных запланировано)"
        log "Место освободится после завершения фоновых слияний"
    fi
fi

log ""
log "Полный лог: $LOG_FILE"
log ""
