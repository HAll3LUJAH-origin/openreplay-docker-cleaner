#!/bin/bash

set -euo pipefail

# ============================================
# КОНФИГУРАЦИЯ
# ============================================

RETENTION_DAYS="${RETENTION_DAYS:-7}"
MINIO_CONTAINER="minio"
MINIO_HOST="http://localhost:9000"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-<YOUR_MINIO_ACCESS_KEY>}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-<YOUR_MINIO_SECRET_KEY>}"
MINIO_BUCKETS="${MINIO_BUCKETS:-mobs sessions-assets}"

# Batch настройки
CHECK_INTERVAL=30           # Интервал проверки прогресса (секунды)

# Логирование
LOG_FILE="/var/log/minio-cleanup.log"
VERBOSE="${VERBOSE:-true}"
DRY_RUN="${DRY_RUN:-false}"

# ============================================
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ДЛЯ ОЧИСТКИ
# ============================================

CONTAINER_YAML_PATH=""  # Путь к YAML в контейнере (для trap)
LOCAL_YAML_PATH=""      # Путь к локальному YAML (для trap)

# ============================================
# ФУНКЦИИ
# ============================================

# --------------------------------------------
# cleanup_on_exit
# --------------------------------------------
# Удаляет временные YAML файлы при выходе (trap).
# Вызывается автоматически при EXIT, Ctrl+C, kill, ошибках.
#
cleanup_on_exit() {
    local exit_code=$?
    
    log_verbose "Выполняется финальная очистка (exit code: $exit_code)..."
    
    if [ -n "$LOCAL_YAML_PATH" ] && [ -f "$LOCAL_YAML_PATH" ]; then
        rm -f "$LOCAL_YAML_PATH" 2>/dev/null || true
        log_verbose "Удалён локальный YAML: $LOCAL_YAML_PATH"
    fi
    
    if [ -n "$CONTAINER_YAML_PATH" ]; then
        docker exec "$MINIO_CONTAINER" rm -f "$CONTAINER_YAML_PATH" 2>/dev/null || true
        log_verbose "Удалён YAML из контейнера: $CONTAINER_YAML_PATH"
    fi
    
    docker exec "$MINIO_CONTAINER" sh -c 'rm -f /tmp/openreplay-expiry-*.yaml /tmp/expiry.yaml' 2>/dev/null || true
    
    if [ $exit_code -ne 0 ]; then
        log "Скрипт завершён с ошибкой (код: $exit_code)"
    fi
}

# Устанавливаем trap на выход, Ctrl+C, kill и ошибки
trap cleanup_on_exit EXIT INT TERM ERR

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo "[DEBUG] $1" >&2
    fi
}

get_storage_size() {
    docker exec "$MINIO_CONTAINER" df -h /bitnami/minio/data 2>/dev/null | tail -1 || echo "unknown"
}

# --------------------------------------------
# check_minio_health
# --------------------------------------------
# Проверяет доступность MinIO и настраивает mc alias.
#
check_minio_health() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${MINIO_CONTAINER}$"; then
        log "ОШИБКА: Контейнер MinIO '$MINIO_CONTAINER' не запущен!"
        return 1
    fi
    
    # Настройка mc alias
    if ! docker exec "$MINIO_CONTAINER" mc alias set minio "$MINIO_HOST" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null 2>&1; then
        log "ОШИБКА: Не удалось настроить mc alias"
        return 1
    fi
    
    log "MinIO доступен"
    return 0
}

# --------------------------------------------
# check_batch_support
# --------------------------------------------
# Проверяет поддержку MinIO Batch Framework (требуется версия 2023 года или старше).
# Пробует mc batch generate, --help и проверяет версию.
#
check_batch_support() {
    log_verbose "Проверка поддержки MinIO Batch Framework..."
    
    # Попробовать mc batch generate
    local batch_output
    batch_output=$(docker exec "$MINIO_CONTAINER" sh -c 'mc batch generate 2>&1' || echo "")
    
    if echo "$batch_output" | grep -qi 'expire\|replicate\|keyrotate\|job types'; then
        log "[OK] MinIO Batch Framework поддерживается (версия: DEVELOPMENT.2025)"
        log_verbose "Вывод mc batch generate: $batch_output"
        return 0
    fi
    
    # Проверить через mc batch --help
    local batch_help
    batch_help=$(docker exec "$MINIO_CONTAINER" sh -c 'mc batch --help 2>&1' || echo "")
    
    if echo "$batch_help" | grep -qi 'start\|status\|list'; then
        log "[OK] MinIO Batch Framework поддерживается (обнаружено через --help)"
        log_verbose "Вывод mc batch --help: $batch_help"
        return 0
    fi
    
    # Проверить версию mc
    local mc_version
    mc_version=$(docker exec "$MINIO_CONTAINER" sh -c 'mc --version 2>&1' || echo "")
    
    if echo "$mc_version" | grep -q "DEVELOPMENT.2025\|RELEASE.202[3-9]"; then
        log "[OK] MinIO Batch Framework поддерживается (версия mc: $mc_version)"
        return 0
    fi
    
    # Если ничего не сработало - показываем debug информацию
    log "[ERROR] MinIO Batch Framework НЕ поддерживается"
    log_verbose "mc batch generate output: $batch_output"
    log_verbose "mc batch --help output: $batch_help"
    log_verbose "mc --version output: $mc_version"
    
    return 1
}

# --------------------------------------------
# cleanup_with_batch_framework
# --------------------------------------------
# Создаёт YAML-манифест expire и запускает mc batch start.
# Мониторит прогресс job до завершения.
# YAML файлы удаляются автоматически через trap.
#
cleanup_with_batch_framework() {
    local bucket="$1"
    
    log "=== Использование MinIO Batch Framework ==="
    log "Bucket: $bucket"
    log ""
    
    # Используем глобальные переменные для trap
    LOCAL_YAML_PATH="/tmp/minio-cleanup-batch-$(date +%s).yaml"
    CONTAINER_YAML_PATH="/tmp/openreplay-expiry-$(date +%s).yaml"
    
    # Очистка YAML файлов в контейнере перед началом
    docker exec "$MINIO_CONTAINER" sh -c 'rm -f /tmp/openreplay-expiry-*.yaml /tmp/expiry.yaml' 2>/dev/null || true
    
    # Создаём YAML конфиг для batch expiry
    cat > "$LOCAL_YAML_PATH" <<EOF
expire:
  apiVersion: v1
  bucket: ${bucket}
  prefix: ""
  
  rules:
    - type: object
      name: "*"
      olderThan: ${RETENTION_DAYS}d
      purge:
        deleteMarker: true
        deleteAllVersions: false
  
  notify:
    endpoint: ""
  
  retry:
    attempts: 10
    delay: 2s
EOF

    log "Batch конфигурация:"
    cat "$LOCAL_YAML_PATH" | tee -a "$LOG_FILE"
    log ""

    if [ "$DRY_RUN" = true ]; then
        log "ТЕСТОВЫЙ РЕЖИМ: Batch job не будет запущен"
        # Очистка произойдёт через trap
        return 0
    fi
    
    # Копируем YAML в контейнер с уникальным именем
    docker cp "$LOCAL_YAML_PATH" "${MINIO_CONTAINER}:${CONTAINER_YAML_PATH}" || {
        log "ОШИБКА: Не удалось скопировать YAML в контейнер"
        # Очистка произойдёт через trap
        return 1
    }
    
    # Удаляем локальный файл сразу после копирования
    rm -f "$LOCAL_YAML_PATH" 2>/dev/null || true
    LOCAL_YAML_PATH=""  # Уже удалён
    
    # Запускаем batch job
    log "Запуск batch expiry job..."
    local job_output
    job_output=$(docker exec "$MINIO_CONTAINER" mc batch start minio/ "${CONTAINER_YAML_PATH}" 2>&1 || echo "FAILED")
    
    # Удаляем YAML из контейнера сразу после запуска job (конфиг уже прочитан)
    docker exec "$MINIO_CONTAINER" rm -f "${CONTAINER_YAML_PATH}" 2>/dev/null || true
    CONTAINER_YAML_PATH=""  # Уже удалён
    
    log "$job_output"
    
    if echo "$job_output" | grep -q "FAILED\|ERROR\|error"; then
        log "ОШИБКА: Не удалось запустить batch job"
        log "Вывод: $job_output"
        return 1
    fi
    
    # Извлекаем JOB_ID из вывода
    # Формат: Successfully started 'expire' job `JOB_ID` on '2026-01-20...'
    local job_id
    job_id=$(echo "$job_output" | grep -oP 'job `\K[^`]+' | head -1)
    
    if [ -z "$job_id" ]; then
        # Альтернативный формат (без backticks)
        job_id=$(echo "$job_output" | grep -oP "job ['\"]?\K[^'\"[:space:]]+" | head -1)
    fi
    
    if [ -z "$job_id" ]; then
        log "ОШИБКА: Не удалось извлечь JOB_ID из вывода"
        log "Вывод был: $job_output"
        return 1
    fi
    
    log "[OK] Batch job успешно запущен"
    log "Job ID: $job_id"
    log ""
    log "Мониторинг прогресса (проверка каждые ${CHECK_INTERVAL}s)..."
    log "Для остановки нажмите Ctrl+C"
    log ""
    
    # Мониторим прогресс
    local prev_objects=0
    local no_change_count=0
    local iteration=0
    
    while true; do
        sleep "$CHECK_INTERVAL"
        iteration=$((iteration + 1))
        
        # Проверяем статус через mc batch list (без TTY)
        local list_output
        list_output=$(docker exec "$MINIO_CONTAINER" mc batch list minio/ 2>&1 || echo "ERROR")
        
        log_verbose "Итерация $iteration: получен список jobs"
        
        # Ищем наш job в списке
        local job_line
        job_line=$(echo "$list_output" | grep "$job_id" || echo "")
        
        if [ -z "$job_line" ]; then
            log ""
            log "[OK] Batch job завершён (не найден в списке активных jobs)"
            break
        fi
        
        # Проверяем статус из mc batch list
        local job_status
        job_status=$(echo "$job_line" | awk '{print $NF}')
        
        log_verbose "Job статус: $job_status"
        
        # Если статус не "in-progress" - job завершён
        if [ "$job_status" != "in-progress" ]; then
            log ""
            log "[OK] Batch job завершён (статус: $job_status)"
            break
        fi
        
        # Пытаемся получить детальный статус (игнорируем TTY ошибки)
        local status_output
        status_output=$(docker exec "$MINIO_CONTAINER" sh -c "mc batch status minio/ '$job_id' 2>&1" || echo "")
        
        # Показываем текущий прогресс если есть информация
        if echo "$status_output" | grep -q "Objects:"; then
            local objects=$(echo "$status_output" | grep -oP "Objects:\s+\K\d+" || echo "0")
            local failed=$(echo "$status_output" | grep -oP "FailedObjects:\s+\K\d+" || echo "0")
            
            log "[$(date '+%H:%M:%S')] Прогресс: $objects объектов обработано, ошибок: $failed"
            
            # Проверка на зависание (если прогресс не меняется)
            if [ "$objects" -eq "$prev_objects" ] && [ "$objects" -gt 0 ]; then
                no_change_count=$((no_change_count + 1))
                local minutes_stuck=$((no_change_count * CHECK_INTERVAL / 60))
                
                if [ "$no_change_count" -ge 10 ]; then
                    log "[WARNING] Прогресс не меняется уже ${minutes_stuck} минут"
                    log "   Это может быть нормально для очень больших bucket'ов"
                    log "   Или job может зависнуть (особенно на HDD RAID)"
                    log ""
                    log "   Для отмены: docker exec minio mc batch cancel minio/ $job_id"
                fi
            else
                no_change_count=0
            fi
            
            prev_objects=$objects
        else
            # Нет детальной информации - показываем только статус из списка
            log "[$(date '+%H:%M:%S')] Job работает (статус: $job_status)"
        fi
    done
    
    return 0
}



# ============================================
# MAIN
# ============================================

log "=========================================="
log "MinIO Немедленная Очистка"
log "=========================================="
log ""

# Проверки
check_minio_health || exit 1

log "Конфигурация:"
log "  Retention: $RETENTION_DAYS дней"
log "  Buckets: $MINIO_BUCKETS"
log "  Тестовый режим: $DRY_RUN"
log ""

# Проверка поддержки Batch Framework
if ! check_batch_support; then
    log "ОШИБКА: MinIO Batch Framework не поддерживается!"
    log "Требуется MinIO версии 2023+ с поддержкой Batch API"
    log "Текущая версия MinIO слишком старая."
    exit 1
fi

log "Используем MinIO Batch Framework"
log ""

# Размер до
storage_before=$(get_storage_size)
log "Хранилище до: $storage_before"
log ""

# Обрабатываем каждый bucket
for bucket in $MINIO_BUCKETS; do
    log "=========================================="
    log "Обработка bucket: $bucket"
    log "=========================================="
    log ""
    
    if ! cleanup_with_batch_framework "$bucket"; then
        log "ОШИБКА: Не удалось выполнить очистку bucket '$bucket'"
        log "Продолжаем со следующим bucket..."
        log ""
        continue
    fi
    
    log ""
    log "Bucket '$bucket' обработан"
    log ""
done

storage_after=$(get_storage_size)
log ""
log "=========================================="
log "Очистка завершена!"
log "=========================================="
log ""
log "Итог:"
log "  До: $storage_before"
log "  После: $storage_after"
log ""
log "ВАЖНО: ILM policy уже настроена, автоматическая очистка работает"
log "Этот скрипт нужен только для РАЗОВОЙ очистки старых данных"
log ""
log "Полный лог: $LOG_FILE"
log ""
