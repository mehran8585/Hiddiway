# =============================================================================
# Hiddify-Manager on Railway.com  —  Single-container blueprint
# =============================================================================
# برخلاف 3x-ui که یک باینری تک‌پارچه است، Hiddify یک استک کامل (۱۸+ سرویس)
# است که برای VPS با host networking و iptables طراحی شده. این Dockerfile
# تمام Hiddify + MariaDB + Redis + یک Nginx چندتکه‌کننده (multiplexer) را
# داخل یک ایمیج قرار می‌دهد تا روی Railway (که فقط یک پورت و بدون privileged
# می‌دهد) قابل اجرا باشد.
#
# نسخه‌ی Hiddify را با آرگومان build قابل کنترل است:
#   docker build --build-arg HIDDIFY_VERSION=dev .
#   docker build --build-arg HIDDIFY_VERSION=v13.0.0 .
#   docker build --build-arg HIDDIFY_VERSION=main .   (پیش‌فرض)
# =============================================================================

FROM ubuntu:24.04

# --- نسخه‌ی Hiddify (شاخه یا تگ گیت‌هاب) ---
ARG HIDDIFY_VERSION=main
ENV TERM=xterm
ENV TZ=Etc/UTC
ENV DEBIAN_FRONTEND=noninteractive
ENV HIDDIFY_DISABLE_UPDATE=true
ENV DOCKER_MODE=true

USER root
WORKDIR /opt/hiddify-manager/

# --- 1) نصب پیش‌نیازها (شامل git برای کلون Hiddify) --------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
        ca-certificates curl bash sudo gnupg lsb-release \
        nginx gettext tzdata socat \
        mariadb-server redis-server \
        git jq \
        iproute2 net-tools procps lsof && \
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*

# --- 2) کلون سورس Hiddify-Manager در زمان build -----------------------------
# (مزایا: ریپو گیت‌هاب شما سبک می‌ماند؛ آپدیت Hiddify فقط با rebuild انجام می‌شود)
# ⚠️ مهم: Hiddify از git submodules استفاده می‌کند (services/panel/src → Hiddify-Panel)
# بدون --recurse-submodules، پنل اصلی کلون نمی‌شود و docker-init.sh با خطای
# "Distribution not found at: .../hiddify-panel/src" کرش می‌کند.
RUN echo "[build] Cloning Hiddify-Manager (version/branch: ${HIDDIFY_VERSION})..." && \
    git clone --depth 1 --recurse-submodules --shallow-submodules \
        --branch "${HIDDIFY_VERSION}" \
        https://github.com/hiddify/Hiddify-Manager.git \
        /opt/hiddify-manager/ && \
    rm -rf /opt/hiddify-manager/.git /opt/hiddify-manager/services/panel/src/.git

# --- 3) نصب Hiddify در حالت داکر ---------------------------------------------
# fake systemctl خود هیدیفای را نصب می‌کند و سرویس‌ها را آماده می‌سازد.
RUN mkdir -p /etc/sudoers.d/ /opt/hiddify-manager/data && \
    bash ./scripts/common/hiddify_installer.sh docker --no-gui --no-log || true && \
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/* && \
    echo "Defaults:hiddify-panel !requiretty" >/etc/sudoers.d/hiddify && \
    echo "hiddify-panel ALL=(root) NOPASSWD: /opt/hiddify-manager/scripts/common/commander.py" >>/etc/sudoers.d/hiddify && \
    chmod 440 /etc/sudoers.d/hiddify

# --- 4) کپی فایل‌های اختصاصی Railway ما --------------------------------------
COPY nginx.conf.template  /etc/nginx/nginx.conf.template
COPY start.sh             /start.sh
COPY docker.env           /opt/hiddify-manager/docker.env

# ⚠️ مهم: اگر فایل‌ها در ویندوز ادیت شده باشند، خط‌شکن‌ها CRLF می‌شوند
# و داکر ارور "No such file or directory" می‌دهد. این خط آن‌ها را به LF تبدیل می‌کند.
RUN sed -i 's/\r$//' /start.sh /etc/nginx/nginx.conf.template && \
    chmod +x /start.sh

# پورت 3000 = تنها پورت عمومی Railway (هاست داخلی nginx)
EXPOSE 3000

# ⚠️ توجه: Railway دستور VOLUME در Dockerfile را پشتیبانی نمی‌کند.
# ⚠️ فقط یک Volume در پنل Railway بسازید و به این مسیر ماونت کنید:
#     /opt/hiddify-manager/data
#   این مسیر شامل داده‌های زیر است (همه داخل همان Volume):
#     - data/        : داده‌های پنل + SSL + بکاپ
#     - data/mysql/  : دیتابیس MariaDB
#     - data/redis/  : دیتای Redis
# اگر این Volume را نسازید، با هر redeploy همه‌چیز (کاربران + کانفیگ‌ها) پاک می‌شود!

ENTRYPOINT ["/start.sh"]
