#!/bin/bash

set -euo pipefail

# ============================================
# КОНФИГУРАЦИЯ
# ============================================

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-<YOUR_POSTGRES_PASSWORD>}"
POSTGRES_DATABASE="${POSTGRES_DATABASE:-postgres}"

MINIO_HOST="${MINIO_HOST:-http://localhost:9000}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-<YOUR_MINIO_ACCESS_KEY>}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-<YOUR_MINIO_SECRET_KEY>}"

CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
CLICKHOUSE_DATABASE="${CLICKHOUSE_DATABASE:-product_analytics}"

REDIS_CLI="${REDIS_CLI:-valkey-cli}"
REDIS_STREAM_CANVAS="canvas-images"
REDIS_STREAM_RAW="raw"

CONTAINER_POSTGRES="postgres"
CONTAINER_CLICKHOUSE="clickhouse"
CONTAINER_REDIS="redis"
CONTAINER_MINIO="minio"

MINIO_DATA_PATH="/bitnami/minio/data"

VOLUME_PATTERN_POSTGRES="${VOLUME_PATTERN_POSTGRES:-postgres}"
VOLUME_PATTERN_CLICKHOUSE="${VOLUME_PATTERN_CLICKHOUSE:-clickhouse}"
VOLUME_PATTERN_REDIS="${VOLUME_PATTERN_REDIS:-redis}"
VOLUME_PATTERN_MINIO="${VOLUME_PATTERN_MINIO:-minio}"

OUTPUT_DIR="/opt/docker/openreplay-crons"
FINAL_OUTPUT="${OUTPUT_DIR}/openreplay-storage-debug-$(date +%Y%m%d-%H%M%S).txt"

MINIO_TIMEOUT=30
DB_TIMEOUT=30

# ============================================
# ФУНКЦИИ
# ============================================

mkdir -p "$OUTPUT_DIR"

SHM_AVAILABLE=$(df /dev/shm 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
if [ "$SHM_AVAILABLE" -lt 10000 ]; then
    OUTPUT_FILE="$FINAL_OUTPUT"
    USE_TMPFS=false
else
    OUTPUT_FILE="/dev/shm/openreplay-debug-temp-$$.txt"
    USE_TMPFS=true
fi

exec 3>&1
exec 1>>"$OUTPUT_FILE" 2>&1

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >&3
}

separator() {
    log ""
    log "=========================================="
    log "$1"
    log "=========================================="
    log ""
}

# ============================================
# MAIN
# ============================================

log "OpenReplay Storage & Database Debug"
log "Создано: $(date)"
log ""
log "Конфигурация:"
if [ "$USE_TMPFS" = true ]; then
    log "  Режим: RAM буфер"
    log "  Временный файл: $OUTPUT_FILE (в /dev/shm)"
else
    log "  Режим: Прямая запись на диск"
fi
log "  Итоговый файл: $FINAL_OUTPUT"
log "  PostgreSQL: $CONTAINER_POSTGRES"
log "  ClickHouse: $CONTAINER_CLICKHOUSE"
log "  Redis: $CONTAINER_REDIS"
log "  MinIO: $CONTAINER_MINIO"
log ""

# ============================================
# 1. DOCKER VOLUMES
# ============================================
separator "1. DOCKER VOLUMES"

log "Docker volumes:"
docker volume ls | tee /dev/fd/3
log ""

log "Использование дисков по volume:"

VOLUME_SEARCH_PATTERN="${VOLUME_PATTERN_MINIO}|${VOLUME_PATTERN_POSTGRES}|${VOLUME_PATTERN_CLICKHOUSE}|${VOLUME_PATTERN_REDIS}"

for vol in $(docker volume ls -q | grep -E "$VOLUME_SEARCH_PATTERN" 2>/dev/null || echo ""); do
    if [ -n "$vol" ]; then
        vol_path=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}' 2>/dev/null || echo "")
        if [ -n "$vol_path" ] && [ -d "$vol_path" ]; then
            log "  Volume: $vol"
            
            df_output=$(df -h "$vol_path" 2>/dev/null | tail -1)
            filesystem=$(echo "$df_output" | awk '{print $1}')
            size_total=$(echo "$df_output" | awk '{print $2}')
            used=$(echo "$df_output" | awk '{print $3}')
            avail=$(echo "$df_output" | awk '{print $4}')
            usage_pct=$(echo "$df_output" | awk '{print $5}')
            
            echo "    Filesystem: $filesystem" | tee /dev/fd/3
            echo "    Всего: $size_total | Использовано: $used | Доступно: $avail | Процент: $usage_pct" | tee /dev/fd/3
            echo "    Путь: $vol_path" | tee /dev/fd/3
            echo "" | tee /dev/fd/3
        fi
    fi
done
log ""

# ============================================
# 2. CONTAINER SIZES
# ============================================
separator "2. РАЗМЕРЫ КОНТЕЙНЕРОВ"

log "Все OpenReplay контейнеры:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Size}}" | tee /dev/fd/3
log ""

# ============================================
# 3. MINIO STORAGE
# ============================================
separator "3. MINIO ХРАНИЛИЩЕ"

log "MinIO контейнер:"
docker ps --format "{{.Names}}\t{{.Size}}" | grep "$CONTAINER_MINIO" | tee /dev/fd/3 || echo "(контейнер не найден)" | tee /dev/fd/3
log ""

log "MinIO статистика (mc admin info):"
timeout $MINIO_TIMEOUT docker exec "$CONTAINER_MINIO" sh -c "mc alias set minio $MINIO_HOST $MINIO_ACCESS_KEY $MINIO_SECRET_KEY >/dev/null 2>&1 && mc admin info minio" 2>&1 | grep -E "Used|Objects|Buckets|Drives" | tee /dev/fd/3 || echo "(недоступно, timeout ${MINIO_TIMEOUT}s)" | tee /dev/fd/3
log ""

log "MinIO buckets (размеры):"
timeout $MINIO_TIMEOUT docker exec "$CONTAINER_MINIO" sh -c "mc alias set minio $MINIO_HOST $MINIO_ACCESS_KEY $MINIO_SECRET_KEY >/dev/null 2>&1 && mc du minio/" 2>&1 | tee /dev/fd/3 || echo "(недоступно, timeout ${MINIO_TIMEOUT}s)" | tee /dev/fd/3
log ""

# ============================================
# 4. POSTGRESQL
# ============================================
separator "4. POSTGRESQL"

log "PostgreSQL контейнер:"
docker ps --format "{{.Names}}\t{{.Size}}" | grep "$CONTAINER_POSTGRES" | tee /dev/fd/3 || echo "(контейнер не найден)" | tee /dev/fd/3
log ""

log "PostgreSQL размеры баз данных:"
timeout $DB_TIMEOUT docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER_POSTGRES" psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database ORDER BY pg_database_size(datname) DESC;" 2>&1 | tee /dev/fd/3 || echo "(недоступно, timeout ${DB_TIMEOUT}s)" | tee /dev/fd/3
log ""

log "PostgreSQL топ-10 таблиц:"
timeout $DB_TIMEOUT docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER_POSTGRES" psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -c "SELECT schemaname||'.'||tablename as table, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 10;" 2>&1 | tee /dev/fd/3 || echo "(недоступно, timeout ${DB_TIMEOUT}s)" | tee /dev/fd/3
log ""

# ============================================
# 5. CLICKHOUSE
# ============================================
separator "5. CLICKHOUSE"

log "ClickHouse контейнер:"
docker ps --format "{{.Names}}\t{{.Size}}" | grep "$CONTAINER_CLICKHOUSE" | tee /dev/fd/3 || echo "(контейнер не найден)" | tee /dev/fd/3
log ""

log "ClickHouse размеры баз данных:"
if [ -z "$CLICKHOUSE_PASSWORD" ]; then
    timeout $DB_TIMEOUT docker exec "$CONTAINER_CLICKHOUSE" clickhouse-client --user "$CLICKHOUSE_USER" --query "SELECT database, formatReadableSize(sum(bytes)) as size, formatReadableQuantity(sum(rows)) as rows FROM system.parts WHERE active GROUP BY database ORDER BY sum(bytes) DESC;" 2>&1 | tee /dev/fd/3 || echo "(недоступно, timeout ${DB_TIMEOUT}s)" | tee /dev/fd/3
else
    timeout $DB_TIMEOUT docker exec "$CONTAINER_CLICKHOUSE" clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "SELECT database, formatReadableSize(sum(bytes)) as size, formatReadableQuantity(sum(rows)) as rows FROM system.parts WHERE active GROUP BY database ORDER BY sum(bytes) DESC;" 2>&1 | tee /dev/fd/3 || echo "(недоступно, timeout ${DB_TIMEOUT}s)" | tee /dev/fd/3
fi
log ""

log "ClickHouse топ-10 таблиц:"
if [ -z "$CLICKHOUSE_PASSWORD" ]; then
    timeout $DB_TIMEOUT docker exec "$CONTAINER_CLICKHOUSE" clickhouse-client --user "$CLICKHOUSE_USER" --query "SELECT table, formatReadableSize(sum(bytes)) as size, formatReadableQuantity(sum(rows)) as rows FROM system.parts WHERE active AND database = '$CLICKHOUSE_DATABASE' GROUP BY table ORDER BY sum(bytes) DESC LIMIT 10;" 2>&1 | tee /dev/fd/3 || echo "(недоступно, timeout ${DB_TIMEOUT}s)" | tee /dev/fd/3
else
    timeout $DB_TIMEOUT docker exec "$CONTAINER_CLICKHOUSE" clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "SELECT table, formatReadableSize(sum(bytes)) as size, formatReadableQuantity(sum(rows)) as rows FROM system.parts WHERE active AND database = '$CLICKHOUSE_DATABASE' GROUP BY table ORDER BY sum(bytes) DESC LIMIT 10;" 2>&1 | tee /dev/fd/3 || echo "(недоступно, timeout ${DB_TIMEOUT}s)" | tee /dev/fd/3
fi
log ""

log "ClickHouse доступные таблицы:"
if [ -z "$CLICKHOUSE_PASSWORD" ]; then
    timeout $DB_TIMEOUT docker exec "$CONTAINER_CLICKHOUSE" clickhouse-client --user "$CLICKHOUSE_USER" --query "SHOW TABLES FROM $CLICKHOUSE_DATABASE;" 2>&1 | tee /dev/fd/3 || echo "(недоступно, timeout ${DB_TIMEOUT}s)" | tee /dev/fd/3
else
    timeout $DB_TIMEOUT docker exec "$CONTAINER_CLICKHOUSE" clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "SHOW TABLES FROM $CLICKHOUSE_DATABASE;" 2>&1 | tee /dev/fd/3 || echo "(недоступно, timeout ${DB_TIMEOUT}s)" | tee /dev/fd/3
fi
log ""

# ============================================
# 6. REDIS
# ============================================
separator "6. REDIS"

log "Redis контейнер:"
docker ps --format "{{.Names}}\t{{.Size}}" | grep "$CONTAINER_REDIS" | tee /dev/fd/3 || echo "(контейнер не найден)" | tee /dev/fd/3
log ""

log "Redis использование памяти:"
docker exec "$CONTAINER_REDIS" "$REDIS_CLI" INFO memory | grep -E "used_memory_human|maxmemory|mem_fragmentation" 2>&1 | tee /dev/fd/3 || echo "(недоступно)" | tee /dev/fd/3
log ""

log "Redis стримы:"
canvas_len=$(docker exec "$CONTAINER_REDIS" "$REDIS_CLI" XLEN "$REDIS_STREAM_CANVAS" 2>/dev/null || echo "0")
raw_len=$(docker exec "$CONTAINER_REDIS" "$REDIS_CLI" XLEN "$REDIS_STREAM_RAW" 2>/dev/null || echo "0")
echo "  $REDIS_STREAM_CANVAS: $canvas_len записей" | tee /dev/fd/3
echo "  $REDIS_STREAM_RAW: $raw_len записей" | tee /dev/fd/3
log ""

# ============================================
# 7. SYSTEM DISK USAGE
# ============================================
separator "7. ИСПОЛЬЗОВАНИЕ ДИСКОВ СИСТЕМЫ"

log "Общее использование дисков:"
df -h | head -20 | tee /dev/fd/3
log ""

log "Docker образы (топ-10):"
docker images --format "  {{.Repository}}:{{.Tag}} - {{.Size}}" 2>&1 | head -10 | tee /dev/fd/3 || echo "  (недоступно)" | tee /dev/fd/3
img_count=$(docker images -q 2>/dev/null | wc -l || echo "0")
echo "  Всего образов: $img_count" | tee /dev/fd/3
log ""

log "Docker контейнеры (топ-10):"
docker ps -a --format "  {{.Names}} ({{.Status}}) - {{.Size}}" 2>&1 | head -10 | tee /dev/fd/3 || echo "  (недоступно)" | tee /dev/fd/3
container_count=$(docker ps -aq 2>/dev/null | wc -l || echo "0")
echo "  Всего контейнеров: $container_count" | tee /dev/fd/3
log ""

# ============================================
# 8. КРАТКАЯ СВОДКА
# ============================================
separator "8. КРАТКАЯ СВОДКА"

log "Ключевые метрики:"

redis_mem=$(docker exec "$CONTAINER_REDIS" "$REDIS_CLI" INFO memory 2>/dev/null | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r' || echo "unknown")
log "  Redis память: $redis_mem"

pg_size=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER_POSTGRES" psql -U "$POSTGRES_USER" -t -c "SELECT pg_size_pretty(pg_database_size('$POSTGRES_DATABASE'));" 2>/dev/null | tr -d ' ' || echo "unknown")
log "  PostgreSQL БД: $pg_size"

if [ -z "$CLICKHOUSE_PASSWORD" ]; then
    ch_size=$(docker exec "$CONTAINER_CLICKHOUSE" clickhouse-client --user "$CLICKHOUSE_USER" --query "SELECT formatReadableSize(sum(bytes)) FROM system.parts WHERE active AND database = '$CLICKHOUSE_DATABASE';" 2>/dev/null || echo "unknown")
else
    ch_size=$(docker exec "$CONTAINER_CLICKHOUSE" clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "SELECT formatReadableSize(sum(bytes)) FROM system.parts WHERE active AND database = '$CLICKHOUSE_DATABASE';" 2>/dev/null || echo "unknown")
fi
log "  ClickHouse данные: $ch_size"

log ""

# ============================================
# ФИНАЛ
# ============================================
separator "ДИАГНОСТИКА ЗАВЕРШЕНА"

if [ "$USE_TMPFS" = true ]; then
    log "Копирование результатов из RAM на диск..."
    log "Источник: $OUTPUT_FILE"
    log "Назначение: $FINAL_OUTPUT"
    
    exec 1>&3
    
    if cp "$OUTPUT_FILE" "$FINAL_OUTPUT" 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Успешно скопировано в $FINAL_OUTPUT"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Успешно скопировано в $FINAL_OUTPUT" >> "$FINAL_OUTPUT"
        rm -f "$OUTPUT_FILE"
    else
        echo "ОШИБКА: Не удалось скопировать в $FINAL_OUTPUT" >&2
        echo "Результаты остались в: $OUTPUT_FILE" >&2
        exit 1
    fi
    
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Полный отчёт сохранён: $FINAL_OUTPUT"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Производительность: ОПТИМИЗИРОВАНО (RAM буферизация)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - Вывод записывался в RAM (/dev/shm)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - Одно копирование на диск в конце"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - Таймауты на медленных командах (${MINIO_TIMEOUT}s)"
else
    exec 1>&3
    
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Полный отчёт сохранён: $FINAL_OUTPUT"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Производительность: ПРЯМАЯ ЗАПИСЬ (режим низкой RAM)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - Таймауты на медленных командах (${MINIO_TIMEOUT}s)"
fi

echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Следующие шаги:"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 1. Просмотрите сводку выше"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 2. Проверьте детали: cat $FINAL_OUTPUT"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 3. Определите что нужно очистить на основе размеров"
echo ""

echo ""
echo "=========================================="
echo "Диагностика завершена!"
echo "=========================================="
echo ""
echo "Файл сохранён: $FINAL_OUTPUT"
echo ""
echo "Быстрый просмотр сводки:"
echo "  cat $FINAL_OUTPUT | grep -A 20 'КРАТКАЯ СВОДКА'"
echo ""
echo "Полный отчёт:"
echo "  less $FINAL_OUTPUT"
echo ""
