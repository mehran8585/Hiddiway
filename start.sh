#!/bin/bash
# =============================================================================
# start.sh — ارکستراسیون تک‌کانتینری Hiddify روی Railway
# =============================================================================
# ترتیب اجرا:
#   1) MariaDB + Redis (داخل همان کانتینر، روی 127.0.0.1)
#   2) ساختن nginx.conf از تمپلیت با پورت 3000
#   3) init دیتابیس Hiddify (اگر اولین بوت است)
#   4) اجرای fake systemctl → استارت سرویس‌های Hiddify (panel/core/xray/...)
#      (سرویس‌های firewall و rust-rpxy-l4 به‌خاطر نبود NET_ADMIN غیرفعال می‌شوند)
#   5) اجرای nginx ما روی پورت 3000 در foreground
# =============================================================================
set -e

export NGINX_PORT="${PORT:-3000}"
echo "[start] Railway PORT=${NGINX_PORT}"

# ---------- MariaDB (داخل کانتینر) ----------
echo "[start] Initializing MariaDB..."
# Railway Volume ممکنه owner/root رو روت نگه داره؛ با chown اصلاح می‌کنیم
mkdir -p /run/mysqld /var/lib/mysql
chown -R mysql:mysql /run/mysqld /var/lib/mysql 2>/dev/null || true
# اگر دیتابیس قبلاً init نشده (volume خالی)، آن را راه‌اندازی می‌کنیم
if [ ! -d /var/lib/mysql/mysql ]; then
    echo "[start] First boot: running mariadb-install-db..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql 2>&1 | tail -5
fi
# استارت MariaDB در background
# (هم TCP روی 127.0.0.1 و هم unix socket — برای دسترسی با root از socket استفاده می‌کنیم)
mysqld_safe --skip-networking=false --bind-address=127.0.0.1 --skip-syslog &
# صبر تا بالا بیاید (تا ۶۰ ثانیه)
echo "[start] Waiting for MariaDB to accept connections..."
MYSQL_READY=false
for i in $(seq 1 60); do
    # استفاده از unix socket (نه TCP) برای جلوگیری از خطای access denied
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

# ساخت کاربر/دیتابیس هیدیفای (با مقادیر docker.env)
# ⚠️ مهم: از socket استفاده می‌کنیم (نه TCP) چون MariaDB root فقط از طریق
# unix_socket auth کار می‌کنه و با -h 127.0.0.1 ارور "Access denied" میده.
mariadb --protocol=socket <<SQL || true
CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\`;
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'127.0.0.1' IDENTIFIED BY '$MYSQL_PASSWORD';
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD';
GRANT ALL PRIVILEGES ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

# ---------- Redis (داخل کانتینر) ----------
echo "[start] Starting Redis..."
install -d -o redis -g redis /var/lib/redis /var/log/redis
redis-server --bind 127.0.0.1 --port 6379 --requirepass "$REDIS_PASSWORD" --daemonize yes

# ---------- متغیرهای محیطی موردنیاز Hiddify ----------
# این URIها باید به 127.0.0.1 اشاره کنند چون همه‌چیز در یک کانتینر است
export SQLALCHEMY_DATABASE_URI="mysql+mysqldb://${MYSQL_USER}:${MYSQL_PASSWORD}@127.0.0.1:3306/${MYSQL_DATABASE}?charset=utf8mb4"
export REDIS_URI_MAIN="redis://:${REDIS_PASSWORD}@127.0.0.1:6379/1"
# پورت عمومی Railway (برای اینکه پنل لینک‌های درست بسازد)
export HIDDIFY_PROXY_PORT="${NGINX_PORT}"

# ---------- غیرفعال‌کردن سرویس‌هایی که روی Railway کار نمی‌کنند ----------
# این سرویس‌ها به NET_ADMIN / raw socket / host network نیاز دارند.
echo "[start] Disabling incompatible services (firewall, rust-rpxy-l4)..."
SERVICES_DIR=/opt/hiddify-manager/services
for svc in firewall rust-rpxy-l4; do
    if [ -f "$SERVICES_DIR/$svc/disable.sh" ]; then
        bash "$SERVICES_DIR/$svc/disable.sh" || true
    fi
    # جلوگیری از استارت توسط fake systemctl
    mv "$SERVICES_DIR/$svc" "$SERVICES_DIR/$svc.disabled" 2>/dev/null || true
done

# ---------- استارت Hiddify با fake systemctl خودش ----------
echo "[start] Booting Hiddify-Manager (docker mode)..."
# docker-init.sh خود هیدیفای fake systemctl را نصب می‌کند و سرویس‌ها را بالا می‌آورد.
# خروجی را لاگ می‌کنیم تا در صورت خطا، علت را ببینیم.
bash /opt/hiddify-manager/scripts/docker-init.sh --no-gui 2>&1 | tee /tmp/hiddify-init.log &
HIDDIFY_PID=$!

# صبر تا پنل بالا بیاید (Hiddify panel روی پورت 9000 در حالت داکر)
echo "[start] Waiting for Hiddify panel to be ready (up to 120s)..."
PANEL_UP=false
for i in $(seq 1 120); do
    # چک کردن چند پورت احتمالی پنل
    if curl -sf http://127.0.0.1:9000/ >/dev/null 2>&1 || \
       curl -sf http://127.0.0.1:9001/ >/dev/null 2>&1 || \
       curl -sf http://127.0.0.1:8080/ >/dev/null 2>&1; then
        PANEL_UP=true
        echo "[start] Hiddify panel is up (after ${i}s)."
        break
    fi
    # هر ۱۵ ثانیه یه لاگ وضعیت
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
fi

# ---------- تولید nginx.conf از تمپلیت ----------
echo "[start] Generating nginx.conf (port ${NGINX_PORT})..."
envsubst '${NGINX_PORT}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf
nginx -t

# ---------- foreground nginx (این پروسه اصلی کانتینر است) ----------
echo "[start] Starting Nginx on port ${NGINX_PORT} (foreground)..."
# اگر هیدیفای کرش کرد، nginx را هم ببند
trap "kill $HIDDIFY_PID 2>/dev/null; exit 0" SIGTERM SIGINT
exec nginx -g 'daemon off;'
