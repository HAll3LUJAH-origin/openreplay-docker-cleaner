#!/bin/bash

set -euo pipefail

# ============================================
# КОНФИГУРАЦИЯ
# ============================================

# Сессии старше RETENTION_DAYS дней будут удалены
# Избранные сессии (user_favorite_sessions) сохраняются
RETENTION_DAYS="${RETENTION_DAYS:-365}"

POSTGRES_CONTAINER="postgres"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="<YOUR_POSTGRES_PASSWORD>"
POSTGRES_DATABASE="postgres"

# Батчевое удаление — снижает нагрузку на БД
BATCH_SIZE="${BATCH_SIZE:-10000}"

# Логирование
LOG_FILE="/var/log/postgres-cleanup.log"
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
# pg_exec
# --------------------------------------------
# Выполняет SQL запрос в PostgreSQL контейнере.
# Возвращает только данные (-t), без заголовков.
#
pg_exec() {
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -t -c "$1"
}

# ============================================
# MAIN
# ============================================

log "=========================================="
log "OpenReplay PostgreSQL Cleanup"
log "=========================================="
log ""

# Проверка доступности PostgreSQL
if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    log "ОШИБКА: Контейнер PostgreSQL '$POSTGRES_CONTAINER' не запущен!"
    exit 1
fi

log "PostgreSQL контейнер доступен"
log ""

# Вычисляем дату удаления
delete_before_date=$(date -d "$RETENTION_DAYS days ago" '+%Y-%m-%d')
delete_before_ts=$(date -d "$delete_before_date" '+%s')
delete_before_ms=$((delete_before_ts * 1000))

log "Конфигурация:"
log "  Retention: $RETENTION_DAYS дней"
log "  Удалить сессии до: $delete_before_date"
log "  Timestamp (ms): $delete_before_ms"
log "  Размер батча: $BATCH_SIZE"
log "  Тестовый режим: $DRY_RUN"
log ""

# ============================================
# ПОДСЧЁТ СЕССИЙ ДЛЯ УДАЛЕНИЯ
# ============================================

log "=== Подсчёт сессий для удаления ==="
log ""

# Запрос с сохранением избранных сессий
# user_favorite_sessions — таблица с избранными сессиями
count_query="SELECT COUNT(*) FROM public.sessions
             WHERE start_ts < $delete_before_ms
             AND session_id NOT IN (SELECT session_id FROM user_favorite_sessions);"

sessions_to_delete=$(pg_exec "$count_query" | tr -d ' ')

log "Сессий для удаления: $sessions_to_delete"

if [ "$sessions_to_delete" -eq 0 ]; then
    log "Нет сессий для удаления. Завершение."
    exit 0
fi

# ============================================
# РАЗМЕР ДО ОЧИСТКИ
# ============================================

log ""
log "=== Размер БД до очистки ==="
log ""

sessions_size_query="SELECT pg_size_pretty(pg_total_relation_size('public.sessions'));"
sessions_size=$(pg_exec "$sessions_size_query" | tr -d ' ')
log "Таблица sessions: $sessions_size"

db_size_query="SELECT pg_size_pretty(pg_database_size('$POSTGRES_DATABASE'));"
db_size=$(pg_exec "$db_size_query" | tr -d ' ')
log "Общий размер БД: $db_size"

# ============================================
# УДАЛЕНИЕ СТАРЫХ СЕССИЙ
# ============================================

log ""
log "=== Удаление старых сессий ==="
log ""

if [ "$DRY_RUN" = true ]; then
    log "ТЕСТОВЫЙ РЕЖИМ: Было бы удалено $sessions_to_delete сессий (батчами по $BATCH_SIZE)"
    log "Запрос: DELETE FROM public.sessions WHERE session_id IN (SELECT session_id FROM public.sessions WHERE start_ts < $delete_before_ms AND session_id NOT IN (...) LIMIT $BATCH_SIZE);"
    log ""
    log "Тестовый режим завершён. Данные не удалены."
    exit 0
fi

# Батчевое удаление для снижения нагрузки на БД
log "Выполнение DELETE батчами по $BATCH_SIZE (с сохранением избранных сессий)..."

total_deleted=0
batch_num=0

while true; do
    batch_num=$((batch_num + 1))

    # DELETE частями: выбираем session_id для удаления и удаляем их
    batch_query="DELETE FROM public.sessions
                 WHERE session_id IN (
                     SELECT session_id FROM public.sessions
                     WHERE start_ts < $delete_before_ms
                     AND session_id NOT IN (SELECT session_id FROM user_favorite_sessions)
                     LIMIT $BATCH_SIZE
                 );"

    log_verbose "Батч $batch_num: выполняем DELETE..."

    batch_result=$(pg_exec "$batch_query" 2>&1)
    batch_deleted=$(echo "$batch_result" | grep "DELETE" | awk '{print $2}' || echo "0")

    if [ -z "$batch_deleted" ] || [ "$batch_deleted" -eq 0 ]; then
        log "[OK] Батч $batch_num: удалено 0 записей, завершаем"
        break
    fi

    total_deleted=$((total_deleted + batch_deleted))
    log "[OK] Батч $batch_num: удалено $batch_deleted, всего: $total_deleted"

    # Если удалили меньше чем BATCH_SIZE — это последний батч
    if [ "$batch_deleted" -lt "$BATCH_SIZE" ]; then
        log "[OK] Последний батч (удалено < $BATCH_SIZE)"
        break
    fi
done

deleted_count=$total_deleted

if [ "$deleted_count" -gt 0 ]; then
    log "[OK] Удалено сессий: $deleted_count"
else
    log "ВНИМАНИЕ: Удалено 0 сессий (возможно, они уже были удалены)"
fi

# ============================================
# РАЗМЕР ПОСЛЕ ОЧИСТКИ
# ============================================

log ""
log "=== Размер БД после очистки ==="
log ""

sessions_size_after=$(pg_exec "$sessions_size_query" | tr -d ' ')
db_size_after=$(pg_exec "$db_size_query" | tr -d ' ')

log "Таблица sessions: $sessions_size_after (было: $sessions_size)"
log "Общий размер БД: $db_size_after (было: $db_size)"

# ============================================
# ИНФОРМАЦИЯ О VACUUM
# ============================================

log ""
log "=== Информация о VACUUM ==="
log ""

log "PostgreSQL автоматически выполнит VACUUM когда БД будет простаивать."
log "Этот процесс может занять несколько часов или дней в зависимости от размера данных."
log ""
log "Для ручного запуска VACUUM (может быть медленным):"
log "  docker exec -e PGPASSWORD=\"$POSTGRES_PASSWORD\" $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DATABASE -c 'VACUUM VERBOSE ANALYZE public.sessions;'"
log ""
log "Проверить работу autovacuum:"
log "  docker exec -e PGPASSWORD=\"$POSTGRES_PASSWORD\" $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DATABASE -c 'SELECT * FROM pg_stat_progress_vacuum;'"
log ""

# ============================================
# ИТОГОВАЯ СТАТИСТИКА
# ============================================

log "=========================================="
log "Очистка завершена!"
log "=========================================="
log ""

remaining_sessions=$(pg_exec "SELECT COUNT(*) FROM public.sessions;" | tr -d ' ')

log "Итоговая статистика:"
log "  Удалено сессий: $deleted_count"
log "  Осталось сессий: $remaining_sessions"
log "  Размер БД: $db_size_after (было: $db_size)"
log "  Таблица sessions: $sessions_size_after (было: $sessions_size)"
log ""
log "Примечание: Место на диске освободится после завершения autovacuum"
log ""
log "Полный лог: $LOG_FILE"
log ""
