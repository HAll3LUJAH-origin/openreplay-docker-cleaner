#!/bin/bash

set -euo pipefail

# ============================================
# КОНФИГУРАЦИЯ
# ============================================

# Retention для необработанных файлов
# Обработанные (есть в PostgreSQL) удаляются сразу
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# Путь к shared volume (где лежат .mob файлы сессий)
SHARED_VOLUME_PATH="${SHARED_VOLUME_PATH:-/srv/data/docker/volumes/docker-compose_shared-volume/_data}"

# Для df -h: точка монтирования и устройство (для grep в выводе)
STORAGE_MOUNT_POINT="${STORAGE_MOUNT_POINT:-/srv/data}"
STORAGE_DEVICE="${STORAGE_DEVICE:-md2}"

POSTGRES_CONTAINER="postgres"
POSTGRES_USER="postgres"
POSTGRES_DATABASE="postgres"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-<YOUR_POSTGRES_PASSWORD>}"

# Перезапуск Storage после очистки
# Storage кэширует список файлов, restart сбрасывает кэш
STORAGE_CONTAINER="storage"
RESTART_STORAGE="${RESTART_STORAGE:-true}"

# Логирование
LOG_FILE="/var/log/shared-volume-cleanup.log"
VERBOSE="${VERBOSE:-true}"
DRY_RUN="${DRY_RUN:-false}"

# Временный файл со списком session_id из PostgreSQL
TEMP_SESSION_LIST="/tmp/openreplay-processed-sessions-$(date +%s).txt"

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

cleanup_temp_files() {
    if [ -f "$TEMP_SESSION_LIST" ]; then
        rm -f "$TEMP_SESSION_LIST" 2>/dev/null || true
        log_verbose "Удалён временный файл: $TEMP_SESSION_LIST"
    fi
}

trap cleanup_temp_files EXIT INT TERM ERR

get_storage_size() {
    df -h "$STORAGE_MOUNT_POINT" 2>/dev/null | grep "$STORAGE_DEVICE" | awk '{print $3 " / " $2 " (" $5 ")"}' || echo "unknown"
}

check_postgres_health() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
        log "ОШИБКА: Контейнер PostgreSQL '$POSTGRES_CONTAINER' не запущен"
        return 1
    fi
    
    log "PostgreSQL доступен"
    return 0
}

# --------------------------------------------
# get_processed_sessions
# --------------------------------------------
# Экспортирует все session_id из PostgreSQL в временный файл.
# Если сессия есть в БД — значит Storage уже обработал её файл и отправил в MinIO.
# Локальный .mob файл можно удалить.
get_processed_sessions() {
    log "Получение списка обработанных сессий из PostgreSQL..."

    # Проверяем что PostgreSQL отвечает
    local session_count=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -t -A \
        -c "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")

    if [ "$session_count" -eq 0 ]; then
        log "ОШИБКА: Не удалось получить количество сессий из PostgreSQL"
        return 1
    fi

    log "Найдено $session_count обработанных сессий в PostgreSQL"

    # Экспортируем все session_id в временный файл
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -t -A \
        -c "SELECT session_id FROM sessions;" > "$TEMP_SESSION_LIST" 2>/dev/null

    if [ ! -s "$TEMP_SESSION_LIST" ]; then
        log "ОШИБКА: Не удалось экспортировать список сессий"
        return 1
    fi

    local exported_count=$(wc -l < "$TEMP_SESSION_LIST")
    log "Экспортировано $exported_count session_id в $TEMP_SESSION_LIST"

    return 0
}

# --------------------------------------------
# delete_processed_sessions
# --------------------------------------------
# Для каждого session_id из PostgreSQL удаляет файлы:
#   - <session_id>        (основной .mob файл)
#   - <session_id>devtools (devtools данные)
#
# Файлы удаляются синхронно с выводом прогресса каждые 5%.
#
delete_processed_sessions() {
    log "=== Удаление файлов обработанных сессий ==="
    log ""

    if [ ! -f "$TEMP_SESSION_LIST" ]; then
        log "ОШИБКА: Файл со списком сессий не найден"
        return 1
    fi

    local total_sessions=$(wc -l < "$TEMP_SESSION_LIST")
    local deleted_count=0
    local not_found_count=0

    # Прогресс каждые 5% (total/20)
    local progress_step=$((total_sessions / 20))
    [ "$progress_step" -lt 1 ] && progress_step=1

    log "Удаление файлов для $total_sessions сессий из $SHARED_VOLUME_PATH"
    log ""

    # DRY RUN — проверяем первые 100 сессий
    if [ "$DRY_RUN" = true ]; then
        log "ТЕСТОВЫЙ РЕЖИМ: Файлы не будут удалены"
        local sample=0
        while IFS= read -r session_id; do
            local main_file="${SHARED_VOLUME_PATH}/${session_id}"
            local devtools_file="${SHARED_VOLUME_PATH}/${session_id}devtools"

            if [ -f "$main_file" ]; then
                log_verbose "[DRY RUN] Будет удалён: $main_file"
                deleted_count=$((deleted_count + 1))
            fi

            if [ -f "$devtools_file" ]; then
                log_verbose "[DRY RUN] Будет удалён: $devtools_file"
                deleted_count=$((deleted_count + 1))
            fi

            sample=$((sample + 1))
            [ "$sample" -ge 100 ] && break
        done < "$TEMP_SESSION_LIST"

        log ""
        log "Примерно $deleted_count файлов будет удалено (проверено первые 100 сессий)"
        return 0
    fi

    # Основной цикл удаления
    local counter=0
    while IFS= read -r session_id; do
        counter=$((counter + 1))

        # Два файла на сессию: основной и devtools
        local main_file="${SHARED_VOLUME_PATH}/${session_id}"
        local devtools_file="${SHARED_VOLUME_PATH}/${session_id}devtools"

        local main_deleted=false
        local devtools_deleted=false

        if [ -f "$main_file" ]; then
            rm -f "$main_file" 2>/dev/null && main_deleted=true
            [ "$main_deleted" = true ] && deleted_count=$((deleted_count + 1))
        else
            not_found_count=$((not_found_count + 1))
        fi

        if [ -f "$devtools_file" ]; then
            rm -f "$devtools_file" 2>/dev/null && devtools_deleted=true
            [ "$devtools_deleted" = true ] && deleted_count=$((deleted_count + 1))
        fi

        # Вывод прогресса каждые 5%
        if [ $((counter % progress_step)) -eq 0 ]; then
            local percent=$((counter * 100 / total_sessions))
            log "[$(date '+%H:%M:%S')] Прогресс: $percent% ($counter/$total_sessions), удалено файлов: $deleted_count"
        fi

        log_verbose "Сессия $session_id: main=$main_deleted, devtools=$devtools_deleted"
    done < "$TEMP_SESSION_LIST"

    log ""
    log "Обработано сессий: $total_sessions"
    log "Удалено файлов: $deleted_count"
    log "Файлов не найдено: $not_found_count"
    log ""

    return 0
}

# --------------------------------------------
# delete_old_unprocessed
# --------------------------------------------
# Удаляет файлы старше RETENTION_DAYS дней (find -mtime).
# Запускается в фоне (find &) т.к. может работать долго на HDD RAID.
# После завершения перезапускает Storage контейнер (если RESTART_STORAGE=true).
#
delete_old_unprocessed() {
    log "=== Удаление старых необработанных файлов ==="
    log ""
    log "Удаление файлов старше $RETENTION_DAYS дней (битые/необработанные)"

    # DRY RUN — только подсчёт
    if [ "$DRY_RUN" = true ]; then
        log "ТЕСТОВЫЙ РЕЖИМ: Подсчёт файлов..."
        local old_count=$(find "$SHARED_VOLUME_PATH" -maxdepth 1 -type f -mtime +$RETENTION_DAYS 2>/dev/null | wc -l)
        log "Будет удалено примерно $old_count старых файлов"

        if [ "$RESTART_STORAGE" = true ]; then
            log "После завершения find контейнер Storage будет перезапущен"
        fi

        return 0
    fi

    # Запуск find в фоне
    log "Запуск find -delete в фоне..."

    if [ "$RESTART_STORAGE" = true ]; then
        # find + перезапуск Storage после завершения
        (find "$SHARED_VOLUME_PATH" -maxdepth 1 -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null && \
         docker restart "$STORAGE_CONTAINER" >/dev/null 2>&1 && \
         echo "[$(date '+%Y-%m-%d %H:%M:%S')] Storage контейнер перезапущен после очистки" >> "$LOG_FILE") &
        local find_pid=$!
        log "PID процесса find: $find_pid"
        log "Контейнер '$STORAGE_CONTAINER' будет автоматически перезапущен после завершения find"
    else
        # Только find без перезапуска
        find "$SHARED_VOLUME_PATH" -maxdepth 1 -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null &
        local find_pid=$!
        log "PID процесса find: $find_pid"
    fi

    log "Для мониторинга: watch -n 60 'df -h $STORAGE_MOUNT_POINT | grep $STORAGE_DEVICE'"
    log ""

    return 0
}

# ============================================
# MAIN
# ============================================

log "=========================================="
log "OpenReplay Shared Volume Cleanup"
log "=========================================="
log ""

check_postgres_health || exit 1

log "Конфигурация:"
log "  Retention: $RETENTION_DAYS дней"
log "  Shared volume: $SHARED_VOLUME_PATH"
log "  Restart Storage: $RESTART_STORAGE"
log "  Тестовый режим: $DRY_RUN"
log ""

storage_before=$(get_storage_size)
log "Хранилище до: $storage_before"
log ""

# Этап 1: Удалить файлы обработанных сессий
if ! get_processed_sessions; then
    log "ОШИБКА: Не удалось получить список сессий из PostgreSQL"
    exit 1
fi

if ! delete_processed_sessions; then
    log "ОШИБКА: Не удалось удалить файлы обработанных сессий"
    exit 1
fi

# Этап 2: Удалить старые необработанные файлы
if ! delete_old_unprocessed; then
    log "ОШИБКА: Не удалось запустить удаление старых файлов"
    exit 1
fi

storage_after=$(get_storage_size)
log ""
log "=========================================="
log "Очистка завершена"
log "=========================================="
log ""
log "Итог:"
log "  До: $storage_before"
log "  После: $storage_after"
log ""
log "ВАЖНО: find -delete работает в фоне"
log "Проверка прогресса: df -h $STORAGE_MOUNT_POINT | grep $STORAGE_DEVICE"
log ""
log "Полный лог: $LOG_FILE"
log ""
