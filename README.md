# OpenReplay Storage Cleanup

Автоматизация очистки хранилища OpenReplay (Redis, Shared Volume, PostgreSQL, MinIO, ClickHouse).

---

## Структура файлов
```
/opt/docker/openreplay-crons/
├── openreplay-full-storage-debug-prod.sh      # Диагностика
├── openreplay-redis-cleanup-prod.sh           # Redis Streams
├── openreplay-shared-volume-cleanup-prod.sh   # Shared Volume
├── openreplay-postgres-cleanup-prod.sh        # PostgreSQL sessions
├── openreplay-minio-cleanup-prod.sh           # MinIO recordings
└── openreplay-clickhouse-cleanup-prod.sh      # ClickHouse system logs

/var/log/
├── redis-cleanup.log                          # Лог Redis cleanup
├── shared-volume-cleanup.log                  # Лог Shared Volume cleanup
├── postgres-cleanup.log                       # Лог PostgreSQL cleanup
├── minio-cleanup.log                          # Лог MinIO cleanup
└── clickhouse-cleanup.log                     # Лог ClickHouse cleanup

/etc/logrotate.d/
├── redis-cleanup                              # Ротация логов Redis
├── shared-volume-cleanup                      # Ротация логов Shared Volume
├── postgres-cleanup                           # Ротация логов PostgreSQL
├── minio-cleanup                              # Ротация логов MinIO
└── clickhouse-cleanup                         # Ротация логов ClickHouse
```

---

## Описание скриптов

### Storage Diagnostic (`openreplay-full-storage-debug-prod.sh`)

Комплексная диагностика всех компонентов OpenReplay.

**Что делает:**
1. Проверяет использование диска, RAM, swap и shm
2. Собирает статистику Redis (память, fragmentation, длину стримов canvas-images и raw)
3. Показывает размеры и статистику MinIO (mc admin info, du по бакетам)
4. Анализирует PostgreSQL (размер всей БД и топ-10 таблиц по размеру)
5. Проверяет ClickHouse (размер данных в product_analytics, список таблиц)
6. Выводит состояние и размеры всех Docker-контейнеров OpenReplay
7. Собирает общее использование дисков, Docker-образов и контейнеров
8. Сохраняет полный отчёт в `/opt/docker/openreplay-crons/openreplay-storage-debug-YYYYMMDD-HHMMSS.txt` (с буферизацией в RAM при наличии свободного /dev/shm)

### Redis Cleanup (`openreplay-redis-cleanup-prod.sh`)

MINID-based очистка Redis стримов с гарантированной защитой pending и lag записей.

**Параметры:**
```bash
SAFETY_BUFFER_MS=300000     # Буфер безопасности в мс (по умолчанию 5 минут)
STREAMS="canvas-images raw" # Стримы для очистки
REDIS_CONTAINER=redis       # Имя контейнера
REDIS_CLI=valkey-cli        # Команда CLI (valkey-cli/redis-cli)
DRY_RUN=false               # Тестовый режим (не удаляет)
VERBOSE=true                # Детальные логи
```

**Почему MINID, а не MAXLEN:**
- `MAXLEN ~ 300000` удаляет по количеству записей с конца стрима
- Проблема: если consumer отстал (большой lag), его pending/необработанные записи могут оказаться "старыми" по позиции и будут удалены → потеря данных
- `MINID` удаляет по ID (timestamp), гарантируя что записи новее `last-delivered-id` не будут затронуты

**Что делает:**
1. Проверяет доступность Redis (требуется Redis 6.2+ для MINID)
2. Для каждого стрима получает `last-delivered-id` всех consumer groups
3. Находит минимальный `last-delivered-id` (самый отстающий consumer)
4. Вычитает `SAFETY_BUFFER_MS` для дополнительной защиты
5. Выполняет `XTRIM stream MINID safe_id` — удаляет только записи старше безопасного ID
6. Показывает память Redis до и после, итоговые длины стримов
7. Логирует результат в `/var/log/redis-cleanup.log`

**Гарантии безопасности:**
- Pending записи не удаляются (они новее `last-delivered-id`)
- Lag записи не удаляются (они тоже новее)
- Удаляются только записи, обработанные всеми consumer-ами

### Shared Volume Cleanup (`openreplay-shared-volume-cleanup-prod.sh`)

Очистка промежуточных файлов сессий из shared volume.

**Параметры:**
```bash
RETENTION_DAYS=7               # Количество дней хранения для необработанных файлов (1 неделя)
SHARED_VOLUME_PATH=/srv/data/docker/volumes/docker-compose_shared-volume/_data
STORAGE_MOUNT_POINT=/srv/data  # Точка монтирования для df
STORAGE_DEVICE=md2             # Устройство для grep в выводе df
DRY_RUN=false                  # Тестовый режим (не удаляет)
VERBOSE=true                   # Детальные логи
RESTART_STORAGE=true           # Перезапуск контейнера storage после find
```

**Что делает:**
1. Проверяет доступность PostgreSQL
2. Получает список всех обработанных session_id из таблицы `sessions`
3. Синхронно удаляет файлы `<session_id>` и `<session_id>devtools` для всех обработанных сессий
4. Запускает в фоне `find ... -mtime +$RETENTION_DAYS -delete` для удаления старых необработанных файлов
5. Если RESTART_STORAGE=true — перезапускает контейнер storage после завершения find
6. Показывает df -h до и после запуска (значение «после» может обновиться позже)
7. Логирует результат в `/var/log/shared-volume-cleanup.log`

### PostgreSQL Cleanup (`openreplay-postgres-cleanup-prod.sh`)

Очистка старых сессий с сохранением избранных. Удаление выполняется батчами для снижения нагрузки на БД.

**Параметры:**
```bash
RETENTION_DAYS=365         # Количество дней хранения (1 год)
BATCH_SIZE=10000           # Размер батча для удаления (записей за раз)
POSTGRES_CONTAINER=postgres
POSTGRES_USER=postgres
POSTGRES_DB=postgres
DRY_RUN=false              # Тестовый режим (не удаляет)
VERBOSE=true               # Детальные логи
```

**Что делает:**
1. Подключается к PostgreSQL
2. Вычисляет timestamp старше RETENTION_DAYS дней (в миллисекундах)
3. Подсчитывает сессии старше указанной даты, не входящие в user_favorite_sessions
4. Удаляет старые сессии **батчами по BATCH_SIZE** (цикл DELETE ... LIMIT BATCH_SIZE)
5. Показывает размер таблицы sessions и всей БД до и после удаления
6. Выводит инструкции по ручному запуску VACUUM ANALYZE (autovacuum сработает сам позже)
7. Логирует результат в `/var/log/postgres-cleanup.log`

**Почему батчами:**
- Один DELETE на миллионы записей создаёт длительную блокировку
- Батчи снижают нагрузку на БД и позволяют другим запросам выполняться
- Можно прервать скрипт и продолжить позже без потери прогресса

### MinIO Cleanup (`openreplay-minio-cleanup-prod.sh`)

Очистка старых объектов через MinIO Batch Framework (expire).

**Параметры:**
```bash
RETENTION_DAYS=7           # Количество дней хранения (1 неделя)
MINIO_CONTAINER=minio
MINIO_BUCKETS="mobs sessions-assets"
DRY_RUN=false              # Тестовый режим (не запускает job)
VERBOSE=true               # Детальные логи
```

**Что делает:**
1. Проверяет доступность MinIO и поддержку Batch Framework
2. Для каждого бакета создаёт временный YAML-манифест с правилом expire olderThan ${RETENTION_DAYS}d
3. Копирует YAML в контейнер, запускает `mc batch start` (expire job)
4. Отслеживает прогресс job каждые 30 секунд (mc batch status/list)
5. Показывает df внутри MinIO до и после (но реальное удаление может быть позже)
6. Автоматически чистит временные YAML-файлы (через trap)
7. Логирует результат в `/var/log/minio-cleanup.log`

### ClickHouse Cleanup (`openreplay-clickhouse-cleanup-prod.sh`)

Очистка системных логов ClickHouse.

**Параметры:**
```bash
SYSTEM_RETENTION_DAYS=7    # Retention для system таблиц (логи CH)
DATA_RETENTION_DAYS=365    # Retention для пользовательских данных (1 год)
CLEANUP_METHOD=delete      # delete или truncate
CLICKHOUSE_CONTAINER=clickhouse
DRY_RUN=false              # Тестовый режим (не выполняет запросы)
VERBOSE=true               # Детальные логи
```

**Что делает:**
1. Проверяет доступность контейнера ClickHouse
2. Собирает размеры и количество строк во всех указанных system-таблицах до очистки
3. Для каждой system-таблицы выполняет:
   - TRUNCATE TABLE (если метод truncate)
   - ALTER TABLE ... DELETE WHERE event_date < today() - N (если метод delete)
4. Очищает пользовательские данные старше DATA_RETENTION_DAYS дней:
   - `product_analytics.events` (колонка: created_at) — клики, инпуты, просмотры страниц
   - `experimental.sessions` (колонка: datetime) — метаданные сессий
5. Показывает размеры таблиц после очистки (для delete — место освободится после мутаций и merges)
6. Выводит готовые команды для ручного запуска OPTIMIZE TABLE FINAL и проверки мутаций/merges
7. Логирует результат в `/var/log/clickhouse-cleanup.log`

## Примеры запуска
```bash
# Обычный запуск
./openreplay-redis-cleanup-prod.sh
./openreplay-postgres-cleanup-prod.sh
./openreplay-minio-cleanup-prod.sh

# С переопределением параметров
RETENTION_DAYS=30 ./openreplay-postgres-cleanup-prod.sh
BATCH_SIZE=50000 ./openreplay-postgres-cleanup-prod.sh
SAFETY_BUFFER_MS=600000 ./openreplay-redis-cleanup-prod.sh
DATA_RETENTION_DAYS=180 ./openreplay-clickhouse-cleanup-prod.sh

# Тестовый режим (показывает что будет удалено, но не удаляет)
DRY_RUN=true ./openreplay-shared-volume-cleanup-prod.sh
# Тестовый режим (создаёт YAML-манифест, но НЕ запускает batch job и не удаляет объекты)
DRY_RUN=true RETENTION_DAYS=7 ./openreplay-minio-cleanup-prod.sh

# Диагностика всей системы
./openreplay-full-storage-debug-prod.sh
# Результат сохраняется в: openreplay-storage-debug-YYYYMMDD-HHMMSS.txt
```

---

## Настройка Cron

```bash
cat > /etc/cron.d/openreplay-cleanup << 'EOF'
# OpenReplay Cleanup Jobs
# Timezone: CET (UTC+1)

# Redis Streams - каждые 2 часа
0 */2 * * * root /opt/docker/openreplay-crons/openreplay-redis-cleanup-prod.sh

# Shared Volume - каждую субботу в 01:00 CET
0 1 * * 6 root /opt/docker/openreplay-crons/openreplay-shared-volume-cleanup-prod.sh

# PostgreSQL - каждую субботу в 02:00 CET
0 2 * * 6 root /opt/docker/openreplay-crons/openreplay-postgres-cleanup-prod.sh

# MinIO - каждую субботу в 03:00 CET
0 3 * * 6 root /opt/docker/openreplay-crons/openreplay-minio-cleanup-prod.sh

# ClickHouse - каждую субботу в 04:00 CET
0 4 * * 6 root /opt/docker/openreplay-crons/openreplay-clickhouse-cleanup-prod.sh
EOF

chmod 0644 /etc/cron.d/openreplay-cleanup
chown root:root /etc/cron.d/openreplay-cleanup
ls -l /etc/cron.d/openreplay-cleanup

systemctl restart cron
journalctl -u cron -n 200 --no-pager | grep -i 'CMD.*openreplay'
```

---

## Настройка Logrotate

```bash
# Redis
cat > /etc/logrotate.d/redis-cleanup << 'EOF'
/var/log/redis-cleanup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# Shared Volume
cat > /etc/logrotate.d/shared-volume-cleanup << 'EOF'
/var/log/shared-volume-cleanup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# PostgreSQL
cat > /etc/logrotate.d/postgres-cleanup << 'EOF'
/var/log/postgres-cleanup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# MinIO
cat > /etc/logrotate.d/minio-cleanup << 'EOF'
/var/log/minio-cleanup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# ClickHouse
cat > /etc/logrotate.d/clickhouse-cleanup << 'EOF'
/var/log/clickhouse-cleanup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
```

**Проверка:**
```bash
logrotate -d /etc/logrotate.d/redis-cleanup
logrotate -d /etc/logrotate.d/shared-volume-cleanup
logrotate -d /etc/logrotate.d/postgres-cleanup
logrotate -d /etc/logrotate.d/minio-cleanup
logrotate -d /etc/logrotate.d/clickhouse-cleanup
```

---

## Быстрый фикс на новом стенде

### 1. Фикс nginx DNS кеширования (502 Bad Gateway)

Nginx резолвит hostname-ы upstream-ов один раз при старте и кеширует IP навсегда.
Если backend-контейнер перезапустился и получил новый IP в Docker-сети — nginx продолжает слать трафик на старый IP → **502 Bad Gateway**.

**Симптомы:**
- `502 Bad Gateway` на `https://openreplay.rioorg.com/ingest/v1/web/start`
- Данные в OpenReplay перестают поступать
- Проблема появляется после рестарта любого backend-контейнера (http, api, chalice и т.д.)

**Суть фикса:**
- Добавить `resolver 127.0.0.11 valid=10s ipv6=off;` — Docker embedded DNS с кешем 10 секунд
- Заменить все статические `proxy_pass http://host:port` на переменные (`set $upstream ...; proxy_pass $upstream;`)
- Это заставляет nginx переразрешать DNS на каждый запрос, а не только при старте

**Применение:**
```bash
cd /opt/docker/openreplay/scripts/docker-compose
cp nginx.conf nginx.conf.bak
cp nginx.conf.fixed nginx.conf
docker exec nginx nginx -t
docker exec nginx nginx -s reload

# Проверить ingest (с внешнего хоста, чтобы пройти полную цепочку: DNS → Caddy → nginx → backend)
curl -v -X OPTIONS https://openreplay.rioorg.com/ingest/v1/web/start
# Ожидаем: 200 (вместо 502)
```

> **Примечание:** если дальше выполняется шаг 2 (Redis) с `docker-compose restart`, nginx перезапустится и автоматически подхватит исправленный конфиг. В этом случае отдельный `nginx -s reload` не нужен.

> **Важно:** в коде сайта, на который установлен трекер OpenReplay, скрипт должен загружаться через Ваш домен OpenReplay, а не напрямую с `static.openreplay.com`:
> ```
> https://youropenreplaydomain.com/script/<version>/openreplay.js
> ```
> Это обходит блокировку адблокерами. Проксирование обеспечивает локация `/script/` в nginx.

### 2. Настройка Redis путём перехода на нестандартный image и valkey.conf
```bash
# Создаем кастомный Valkey образ с tini
cat > /opt/docker/openreplay/scripts/docker-compose/Dockerfile.valkey << 'EOF'
FROM valkey/valkey:8.0-alpine
RUN apk add --no-cache tini
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["valkey-server"]
EOF

# Собираем
docker build -t valkey-with-tini:8.0 -f /opt/docker/openreplay/scripts/docker-compose/Dockerfile.valkey /opt/docker/openreplay/scripts/docker-compose/

# Создаем оптимизированный конфиг
mkdir -p redis-config
cat > redis-config/valkey.conf << 'EOF'
# OpenReplay Redis/Valkey Optimized Configuration
# С jemalloc и active defragmentation

dir /data
port 6379
protected-mode no

# RAM - 35GB
maxmemory 35gb
maxmemory-policy allkeys-lru

# Persistence отключен (данные временные)
save ""
appendonly no

# Активная дефрагментация (работает только с jemalloc)
activedefrag yes
active-defrag-threshold-lower 5
active-defrag-threshold-upper 100
active-defrag-ignore-bytes 100mb
active-defrag-cycle-min 10
active-defrag-cycle-max 75
active-defrag-max-scan-fields 1000

# Lazyfree - асинхронное освобождение памяти
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
lazyfree-lazy-user-del yes

# Streams оптимизация
stream-node-max-bytes 4096
stream-node-max-entries 100

# Network
tcp-backlog 511
tcp-keepalive 300
timeout 0

# Slow log
slowlog-log-slower-than 10000
slowlog-max-len 128
EOF

# Обновляем docker-compose.yaml (секция redis)
# Заменить секцию redis на:
nano docker-compose.yaml
```

Заменить секцию `redis`:
```yaml
  redis:
    image: valkey-with-tini:8.0
    container_name: redis
    entrypoint: ["/sbin/tini", "--"]
    command: ["valkey-server", "/etc/valkey/valkey.conf"]
    volumes:
      - redisdata:/bitnami/redis/data
      - ./redis-config/valkey.conf:/etc/valkey/valkey.conf:ro
    networks:
      openreplay-net:
        aliases:
          - redis-master.db.svc.cluster.local
    environment:
      ALLOW_EMPTY_PASSWORD: "yes"
```

```bash
# Применяем изменения
docker stop redis && docker rm redis
docker-compose up -d redis

# Ждём завершения запуска примерно 10 секунд

# КРИТИЧЕСКИ ВАЖНО: обязательный рестарт всех сервисов
docker-compose restart
# Ждём завершения запуска примерно 15-20 секунд

# Проверка
docker exec redis valkey-cli INFO memory | grep allocator   # Должно быть: jemalloc-5.3.0
docker exec redis valkey-cli CONFIG GET activedefrag        # Должно быть: yes
docker exec redis valkey-cli XLEN canvas-images             # Должно быть больше 0
docker exec redis valkey-cli XLEN raw                       # Должно быть больше 0
docker logs --tail 20 http | grep -i error
```

### 3. Диагностика

```bash
# Скачать все 4 скрипта через scp/git/wget/curl
mkdir -p /opt/docker/openreplay-crons
cd /opt/docker/openreplay-crons
chmod +x openreplay-*.sh

# Запустить диагностику
chmod +x openreplay-storage-diagnostic.sh
./openreplay-storage-diagnostic.sh

# Просмотр результата
cat openreplay-storage-debug-*.txt | grep -A 20 "КРАТКАЯ СВОДКА"
```

---

### 4. Запуск очистки

```bash
# Эффективнее всего выполнить скрипты в такой последовательности
# Предварительно лучше выполнять запуск через

# MiniO, скрипт лучше закрыть когда циклом пойдут логи т.к. job-ы MiniO уже созданы
./openreplay-minio-cleanup-prod.sh

# Redis, ждать пока выполнится
./openreplay-redis-cleanup-prod.sh

# Shared Volumes, ждать пока выполнится видимая часть
./openreplay-shared-volume-cleanup-prod.sh

# ClickHouse, можно почистить но не обязательно
./openreplay-clickhouse-cleanup-prod.sh

# PostgreSQL, очистка освободит меньше всего места поэтому делается последней
./openreplay-postgres-cleanup-prod.sh
```

### 5. Настройка MiniO

```bash
# Добавляем alias для обеспечения доступа через локальный клиент, проверяем
docker exec minio mc alias set minio http://localhost:9000 <access_key> <secret_key>
docker exec minio mc alias list

# Добавляем новые policy, проверяем
docker exec minio mc ilm add minio/mobs --expiry-days 7
docker exec minio mc ilm add minio/sessions-assets --expiry-days 7
docker exec minio mc ilm ls minio/mobs
docker exec minio mc ilm ls minio/sessions-assets

# Если нужно отредактировать policy
docker exec minio mc ilm rule edit --id <ID_mobs> \
    --expire-days <новое количество дней> minio/mobs

docker exec minio mc ilm rule edit --id <ID_sessions-assets> \
    --expire-days <новое количество дней> minio/sessions-assets
```

### 6. Настройка Cron и logrotate
```bash
Актуальные настройки cron и logrotate представлены выше.
```

## Чеклист успешного восстановления

- [ ] Nginx resolver = 127.0.0.11 (DNS переразрешение)
- [ ] Диск < 80%
- [ ] RAM < 70%
- [ ] Redis streams заполняются (не 0)
- [ ] Redis allocator = jemalloc-5.3.0
- [ ] Redis activedefrag = yes
- [ ] HTTP логи без ошибок Redis
- [ ] Cron настроен
- [ ] MinIO ILM = 7 дней
- [ ] PostgreSQL retention = 365 дней
- [ ] ClickHouse data retention = 365 дней
- [ ] Shared Volume retention = 7 дней
- [ ] ClickHouse system retention = 7 дней
- [ ] Все cleanup скрипты executable

---

## Почему нужны и скрипт и maxmemory-policy (Redis)

### Проблема: Streams накапливаются быстрее чем обрабатываются

**Redis Streams** используется как очередь сообщений между компонентами:
- HTTP сервис записывает события браузера в stream `raw`
- HTTP сервис записывает canvas screenshots в stream `canvas-images`
- Worker'ы (sink, storage, db) читают и обрабатывают эти события

**Скорость накопления:**
- `canvas-images`: ~38,000 записей/день (~570 MB/день)
- `raw`: ~5,000 записей/день (~75 MB/день)
- **Итого**: ~43,000 записей/день (~645 MB/день)

**Проблема возникает когда:**
- Worker'ы не успевают обрабатывать (высокая нагрузка)
- Worker'ы падают/перезапускаются
- Очередь растет быстрее чем обрабатывается
- Redis памяти не хватает → OOM → система падает

**Без cleanup скрипта:**
```
День 1-10: 430k записей = 6.5 GB RAM (растет)
День 11-20: 860k записей = 13 GB RAM (продолжает расти)
День 21-30: 1.29M записей = 19.5 GB RAM (приближается к лимиту)
День 31+: Достигает maxmemory → Redis начинает удалять данные или крашится
```

**С скриптом:**
```
Каждые 2 часа: Удаляет записи старше last-delivered-id (с буфером 5 мин)
Память стабильна: ~8 GB (далеко от 35 GB лимита)
Pending и lag записи гарантированно сохранены
Worker'ы успевают обрабатывать очередь
```

### Сравнение подходов

| Параметр | Только скрипт | Только policy | Скрипт + Policy |
|----------|---------------|---------------|-----------------|
| **Сохранность pending** | [OK] Гарантирована | [ERROR] Может удалить | [OK] Гарантирована |
| **Защита от OOM** | [ERROR] Если упал | [OK] Всегда | [OK] Всегда |
| **Память** | ~8 GB | До 35 GB | ~8 GB |
| **Буфер безопасности** | 8 дней | 0 дней | 8 дней + 37 дней |
| **Нагрузка на RAID** | Минимальная | Средняя | Минимальная |

### Как работает вместе

**Нормальная работа (99.9% времени):**
```
Скрипт каждые 2 часа -> XTRIM MINID -> удаляет только обработанные записи
Память: ~8 GB (далеко от 35 GB)
maxmemory-policy: не срабатывает
```

**Если скрипт упал:**
```
День 1-30: Память растёт 8->12->20->30->34.5 GB
День 31: Достигает 35 GB -> maxmemory-policy срабатывает
         Redis автоматически удаляет -> [OK] OOM предотвращён
         Но: Может удалить pending (риск потери данных)
         
День 32: Замечаете проблему -> чините скрипт
         Скрипт подрезает -> память падает до ~8 GB
```

### Почему скрипт безопаснее policy

**Скрипт (MINID-based):**
```bash
# Находит самого отстающего consumer
min_delivered_id = get_min_delivered_id("canvas-images")  # 1737000000000-0
safe_id = min_delivered_id - SAFETY_BUFFER_MS             # 1736999700000-0 (минус 5 мин)

# XTRIM canvas-images MINID 1736999700000-0
# Удаляет только записи старше safe_id
# Pending и lag записи новее safe_id -> [OK] гарантированно сохранены
```

**Policy (allkeys-lru):**
```bash
# Удаляет по LRU без проверки pending
Память близка к 35 GB
-> Находит ключи с наименьшим LRU
-> Pending записи = давно не читались (ждут обработки)
[ERROR] Удаляет pending -> Потеря данных
```

### Реальный пример (до/после)

**До скрипта + policy:**
```
Период: 30+ дней без обслуживания
Redis память: 35 GB (достигнут maxmemory)
maxmemory-policy: Активно удаляет данные (включая pending)
Результат: Потеря необработанных событий
```

**После скрипта + policy:**
```
Redis память: ~8 GB
maxmemory-policy: Не срабатывает
Pending и lag записи: Гарантированно защищены
Worker'ы: Успевают обрабатывать очередь

Скрипт каждые 2 часа удаляет только обработанные записи (XTRIM MINID)
Даже если скрипт упадет на месяц - policy предотвратит OOM
```

---

## Почему нужен скрипт для Shared Volume

### Проблема: Storage сервис не успевает удалять данные

**Shared Volume (`/mnt/efs`)** используется как промежуточное файловое хранилище:
> `/mnt/efs` соответствует `/srv/data/docker/volumes/docker-compose_shared-volume/_data`
- HTTP записывает `.mob` файлы сессий (binary данные)
- Storage читает `.mob` файлы из Shared Volume
- Storage обрабатывает и конвертирует в формат MinIO
- Storage записывает результат в MinIO (S3-compatible storage)
- Storage должен удалить `.mob` файл из Shared Volume после успешной записи

**Скорость накопления (реальные данные):**
- ~126 GB/день файлов записывается
- Без очистки за 22 дня накопилось 2.78 TB

**Проблема возникает когда:**
- Storage падает во время обработки → файл остается "забытым"
- Запись в MinIO провалилась → Storage не удаляет локальный файл
- Docker-compose restart → Storage теряет контекст незавершенных файлов
- Высокая нагрузка → Storage не успевает чистить старые файлы
- Обновление версии → старые файлы остаются навсегда

**Критическая разница от MinIO:**
- MinIO хранит **итоговые** обработанные сессии (для клиентов)
- Shared Volume хранит **промежуточные** необработанные файлы
- Файл на Shared Volume должен жить **часы**, не дни

**Без скрипта:**
```
День 1-7: 882 GB (Storage упал несколько раз)
День 7-14: 1.76 TB (продолжают накапливаться)
День 14-22: 2.78 TB (диск заполнен на 97%)
Результат: Система не может записывать новые сессии
```

**Со скриптом:**
```
Каждую субботу: Удаляет файлы старше 7 дней
Максимум накопится: 882 GB (при полном отказе Storage)
Storage работает нормально: < 1 GB текущих файлов
```

### Сравнение подходов

| Параметр | Только Storage | Только скрипт | Storage + Скрипт |
|----------|----------------|---------------|------------------|
| **Очистка при нормальной работе** | [OK] Работает | [ERROR] Не работает | [OK] Работает |
| **Очистка если Storage упал** | [ERROR] Не работает | [OK] Работает | [OK] Работает |
| **Очистка "забытых" файлов** | [ERROR] Не чистит | [OK] Чистит | [OK] Чистит |
| **Защита от переполнения диска** | [ERROR] Нет защиты | [OK] Есть защита | [OK] Есть защита |
| **Буфер безопасности** | 0 дней | 15 дней | 15 дней |

### Как работает вместе

**Нормальная работа (99% времени):**
```
Storage сервис -> обрабатывает файлы -> записывает в MinIO -> удаляет локальные
Shared Volume: Чистый, только текущие файлы (< 1 GB)
Cleanup скрипт: Срабатывает еженедельно, находит 0-10 старых файлов
```

**Если Storage упал/зависает:**
```
День 1-7: Файлы накапливаются (~126 GB/день)
День 7: Cleanup скрипт срабатывает (суббота 01:00)
        -> Находит файлы старше 15 дней
        -> Удаляет их
        [OK] Shared Volume очищен

Без скрипта:
День 1-7: Файлы накапливаются (~882 GB)
День 7-14: Продолжают накапливаться (~1.76 TB)
День 15-22: Продолжают накапливаться (~2.78 TB)
[ERROR] Диск заполнен на 97% -> система падает
```

### Почему скрипт безопаснее полагаться только на Storage

**Storage сервис (работает только когда активен):**
```bash
# Удаляет только файлы которые успешно обработал
[OK] Обработал session_123.mob -> записал в MinIO -> удалил локальный файл

# Не удаляет "забытые" файлы:
- Если сам упал во время обработки
- Если запись в MinIO провалилась
- Если файл остался от старой версии
- Если произошел restart во время обработки
- Если сервис был остановлен (docker stop/restart)

[ERROR] "Забытые" файлы накапливаются бесконечно
```

**Скрипт:**
```bash
# Удаляет все файлы старше 15 дней
find /mnt/efs -type f -mtime +15 -delete
# Примечание: /mnt/efs -> /srv/data/docker/volumes/docker-compose_shared-volume/_data

# Независимо от:
- Работает ли Storage
- Был ли файл обработан
- Есть ли запись в MinIO
- Какая версия OpenReplay

[OK] Диск не переполнится
```

### Реальный пример (до/после)

**До скрипта:**
```
Период накопления: 22 дня (30.12.2025 - 21.01.2026)
Shared Volume: 2.78 TB мусора
Скорость накопления: 126 GB/день
Диск: 97% заполнен (3.5 TB из 3.6 TB)

Причина: Storage падал несколько раз за 3 недели
         Каждый раз оставлял "незавершенные" файлы
         За 22 дня накопилось 2.78 TB мусора
```

**После скрипта:**
```
Shared Volume: < 1 GB текущих файлов
Retention: 7 дней
Максимум накопится: 7 × 126 GB = 882 GB
Диск: 20-22% заполнен (~720 GB из 3.6 TB)

Скрипт еженедельно чистит старые файлы
Даже если Storage падает - диск не переполнится
```

---

## Итоговая конфигурация

### Redis
```bash
maxmemory: 35gb
maxmemory-policy: allkeys-lru
allocator: jemalloc-5.3.0
activedefrag: yes
```

### Скрипты
```bash
# Redis Cleanup
SAFETY_BUFFER_MS=300000
STREAMS="canvas-images raw"
REDIS_CONTAINER=redis
REDIS_CLI=valkey-cli

# Shared Volume Cleanup
RETENTION_DAYS=7
SHARED_VOLUME_PATH=/srv/data/docker/volumes/docker-compose_shared-volume/_data
STORAGE_MOUNT_POINT=/srv/data
STORAGE_DEVICE=md2

# PostgreSQL Cleanup
RETENTION_DAYS=365
BATCH_SIZE=10000
POSTGRES_CONTAINER=postgres
POSTGRES_USER=postgres
POSTGRES_DB=postgres

# MinIO Cleanup
RETENTION_DAYS=7
MINIO_CONTAINER=minio
MINIO_BUCKETS="mobs sessions-assets"

# MinIO ILM Policy
mobs: 7 дней
sessions-assets: 7 дней

# ClickHouse Cleanup
SYSTEM_RETENTION_DAYS=7
DATA_RETENTION_DAYS=365
CLEANUP_METHOD=delete
CLICKHOUSE_CONTAINER=clickhouse
```

### Использование диска (при правильной конфигурации)

```
Redis (буфер): ~8 GB
Shared Volume (7 дней): ~882 GB
PostgreSQL (365 дней): ~900 GB
MinIO (7 дней): ~105 GB
ClickHouse system (7 дней): ~6 GB
ClickHouse data (365 дней): ~200 GB (оценка)
Docker/system: ~50 GB

ИТОГО: ~2.15 TB из 3.6 TB (60% диска)
Свободно: 1.45 TB (запас 40%)
```

---

## Сохранность пользовательских данных

**Записи сессий (recordings): 7 дней**
**Метаданные и аналитика: 365 дней (1 год)**

Клиент может просматривать replay своих сессий в течение 7 дней с момента записи.
Метаданные сессий, аналитика (фаннелы, path analysis) и списки сессий доступны 1 год.
