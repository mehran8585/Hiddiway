#!/bin/bash
# =============================================================================
# start.sh — ارکستراسیون تک‌کانتینری Hiddify روی Railway
# =============================================================================
set -e

export NGINX_PORT="${PORT:-3000}"
echo "[start] Railway PORT=${NGINX_PORT}"

# ---------- مقادیر پیش‌فرض برای متغیرهای محیطی ----------
: "${MYSQL_DATABASE:=hiddifypanel}"
: "${MYSQL_USER:=hiddifypanel}"
: "${MYSQL_PASSWORD:=hiddifypanel-strong-default-password}"
: "${REDIS_PASSWORD:=redis-strong-default-password}"
echo "[start] MYSQL_DATABASE=${MYSQL_DATABASE}  MYSQL_USER=${MYSQL_USER}"
echo "[start] (اگر این مقادیر پیش‌فرض هستند، در پنل Railway → Variables مقادیر واقعی را ست کنید)"

# ---------- symlink برای تطابق مسیرهای هیدیفای ----------
if [ ! -e /opt/hiddify-manager/services/hiddify-panel ]; then
    echo "[start] Creating symlink: services/hiddify-panel → services/panel"
    ln -sf /opt/hiddify-manager/services/panel /opt/hiddify-manager/services/hiddify-panel
fi

# ---------- MariaDB ----------
echo "[start] Initializing MariaDB..."
MYSQL_DATA_DIR=/opt/hiddify-manager/data/mysql
mkdir -p /run/mysqld "$MYSQL_DATA_DIR"
chown -R mysql:mysql /run/mysqld "$MYSQL_DATA_DIR" 2>/dev/null || true
if [ ! -d "$MYSQL_DATA_DIR/mysql" ]; then
    echo "[start] First boot: running mariadb-install-db..."
    mariadb-install-db --user=mysql --datadir="$MYSQL_DATA_DIR" 2>&1 | tail -5
fi
mysqld_safe --skip-networking=false --bind-address=127.0.0.1 --skip-syslog \
    --datadir="$MYSQL_DATA_DIR" \
    --socket=/run/mysqld/mysqld.sock &
echo "[start] Waiting for MariaDB to accept connections..."
MYSQL_READY=false
for i in $(seq 1 60); do
    if mariadb-admin --protocol=socket ping 2>/dev/null; then
        MYSQL_READY=true
        echo "[start] MariaDB is ready (after ${i}s)."
        break
    fi
    sleep 1
done
if [ "$MYSQL_READY" != "true" ]; then
    echo "[start] ERROR: MariaDB did not become ready in 60s. Aborting."
    exit 1
fi

mariadb --protocol=socket <<SQL || true
CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\`;
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'127.0.0.1' IDENTIFIED BY '$MYSQL_PASSWORD';
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';
GRANT ALL PRIVILEGES ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

# ---------- Redis ----------
echo "[start] Starting Redis..."
REDIS_DATA_DIR=/opt/hiddify-manager/data/redis
mkdir -p "$REDIS_DATA_DIR" /var/log/redis
chown -R redis:redis "$REDIS_DATA_DIR" /var/log/redis 2>/dev/null || true
redis-server --bind 127.0.0.1 --port 6379 \
    --requirepass "$REDIS_PASSWORD" \
    --dir "$REDIS_DATA_DIR" \
    --daemonize yes

# ---------- متغیرهای محیطی Hiddify ----------
export SQLALCHEMY_DATABASE_URI="mysql+mysqldb://${MYSQL_USER}:${MYSQL_PASSWORD}@127.0.0.1:3306/${MYSQL_DATABASE}?charset=utf8mb4"
export REDIS_URI_MAIN="redis://:${REDIS_PASSWORD}@127.0.0.1:6379/1"
export HIDDIFY_PROXY_PORT="${NGINX_PORT}"

# ---------- غیرفعال‌کردن سرویس‌های ناسازگار ----------
echo "[start] Disabling incompatible services (firewall, rust-rpxy-l4, haproxy)..."
SERVICES_DIR=/opt/hiddify-manager/services
for svc in firewall rust-rpxy-l4 haproxy; do
    if [ -f "$SERVICES_DIR/$svc/disable.sh" ]; then
        bash "$SERVICES_DIR/$svc/disable.sh" || true
    fi
    mv "$SERVICES_DIR/$svc" "$SERVICES_DIR/$svc.disabled" 2>/dev/null || true
done

# ---------- استارت Hiddify ----------
echo "[start] Booting Hiddify-Manager (docker mode)..."
bash /opt/hiddify-manager/scripts/docker-init.sh --no-gui 2>&1 | tee /tmp/hiddify-init.log &
HIDDIFY_PID=$!

# ---------- صبر تا پنل بالا بیاید ----------
echo "[start] Waiting for Hiddify panel to be ready (up to 120s)..."
PANEL_UP=false
for i in $(seq 1 120); do
    if ss -tln 2>/dev/null | grep -q ":9000" || \
       netstat -tln 2>/dev/null | grep -q ":9000"; then
        PANEL_UP=true
        echo "[start] Hiddify panel is up (port 9000 listening, after ${i}s)."
        break
    fi
    if [ $((i % 15)) -eq 0 ]; then
        echo "[start] ...still waiting (${i}s). Checking listening ports:"
        ss -tlnp 2>/dev/null | grep -E ":(9000|9001|8080|80|443|8001|8002)" || \
        netstat -tlnp 2>/dev/null | grep -E ":(9000|9001|8080|80|443|8001|8002)" || \
        echo "[start] (no relevant ports listening yet)"
    fi
    sleep 1
done

if [ "$PANEL_UP" != "true" ]; then
    echo "[start] WARNING: Hiddify panel did not respond on expected ports after 120s."
    echo "[start] Last 30 lines of Hiddify init log:"
    tail -30 /tmp/hiddify-init.log 2>/dev/null || echo "(no log)"
    echo "[start] Continuing anyway — nginx will start but panel may not work."
else
    echo "[start] ✅ Hiddify panel is ready! Proceeding to nginx."
fi

# ---------- اضافه‌کردن دامنه Railway به پنل (مهم!) ----------
# هیدیفای پنل رو با IP داخلی کانفیگ کرده، ولی کاربر از دامنه Railway میاد.
# برای اینکه پنل دامنه رو بشناسه، باید اون رو به لیست دامنه‌ها اضافه کنیم.
if [ -n "$HIDDIFY_DOMAIN" ]; then
    echo "[start] Adding HIDDIFY_DOMAIN to panel: $HIDDIFY_DOMAIN"
    if command -v hiddify-panel-cli >/dev/null 2>&1; then
        IFS=',' read -ra DOMAINS <<< "$HIDDIFY_DOMAIN"
        for domain in "${DOMAINS[@]}"; do
            domain=$(echo "$domain" | xargs)
            echo "[start] Adding domain: $domain"
            hiddify-panel-cli add-domain -d "$domain" 2>&1 | tail -3 || true
        done
    fi
    if command -v hiddify >/dev/null 2>&1; then
        echo "[start] Restarting panel to apply domain changes..."
        hiddify restart 2>&1 | tail -5 || true
    fi
else
    echo "[start] ⚠️ HIDDIFY_DOMAIN not set!"
    echo "[start] Please set HIDDIFY_DOMAIN in Railway Variables to your Railway domain"
    echo "[start] Example: kirtokos-kirikoni-rai-pay-chay205562.up.railway.app"
    echo "[start] Without this, the panel will return 404 when accessed via Railway domain."
fi

# ---------- تولید nginx.conf ----------
echo "[start] Generating nginx.conf (port ${NGINX_PORT})..."
envsubst '${NGINX_PORT}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf
nginx -t

# ---------- استارت nginx ----------
echo "[start] Starting Nginx on port ${NGINX_PORT} (foreground)..."
trap "kill $HIDDIFY_PID 2>/dev/null; exit 0" SIGTERM SIGINT
exec nginx -g 'daemon off;'
