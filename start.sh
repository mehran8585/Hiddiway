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

# ---------- مقادیر پیش‌فرض برای متغیرهای محیطی (اگر ست نشده باشند) ----------
# Railway ممکنه متغیرها رو از docker.env نخونه؛ اینجا مطمئن می‌شیم مقدار دارن.
: "${MYSQL_DATABASE:=hiddifypanel}"
: "${MYSQL_USER:=hiddifypanel}"
: "${MYSQL_PASSWORD:=hiddifypanel-strong-default-password}"
: "${REDIS_PASSWORD:=redis-strong-default-password}"
echo "[start] MYSQL_DATABASE=${MYSQL_DATABASE}  MYSQL_USER=${MYSQL_USER}"
echo "[start] (اگر این مقادیر پیش‌فرض هستند، در پنل Railway → Variables مقادیر واقعی را ست کنید)"

# ---------- سلفط مهم: symlink برای تطابق مسیرهای هیدیفای ----------
# docker-init.sh به services/hiddify-panel/src اشاره می‌کند، ولی submodule واقعاً
# در services/panel/src قرار دارد (طبق .gitmodules). این symlink آن را حل می‌کند.
if [ ! -e /opt/hiddify-manager/services/hiddify-panel ]; then
    echo "[start] Creating symlink: services/hiddify-panel → services/panel"
    ln -sf /opt/hiddify-manager/services/panel /opt/hiddify-manager/services/hiddify-panel
fi

# ---------- MariaDB (داخل کانتینر) ----------
echo "[start] Initializing MariaDB..."
# ... (بقیه فایل همون قبلی می‌مونه)
