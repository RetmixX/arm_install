#!/usr/bin/env bash
# =============================================================================
#  Установочный скрипт Arm Box: nginx + FastAPI (systemd) + frontend (nginx)
# =============================================================================
set -euo pipefail

BACKEND_REPO_URL="https://github.com/RetmixX/arm_box.git"      # <-- backend repo
FRONTEND_REPO_URL="https://github.com/RetmixX/arm_box_web.git" # <-- frontend repo

BACKEND_DIR="/root/arm_box"
FRONTEND_DIR="/var/www/arm_box_web"
SERVICE_NAME="arm_box"
NGINX_CONF="/etc/nginx/sites-available/arm_box"
NGINX_LINK="/etc/nginx/sites-enabled/arm_box"

LOG_FILE="/root/install.log"
# ---------------------------------------------------------------------------

# ------------------------- Логирование -------------------------------------
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO ] $*"; }
warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN ] $*"; }
err()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"; }

trap 'err "Скрипт прерван на строке $LINENO"; exit 1' ERR

log "=== Старт установки Arm Box ==="

# ------------------------- 1) Установка nginx ------------------------------
log "1) Установка nginx через apt"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx git python3 python3-venv python3-pip
log "nginx установлен"

# ------------------------- 2) Клонирование backend -------------------------
log "2) Клонирование backend из $BACKEND_REPO_URL в $BACKEND_DIR"
if [ -d "$BACKEND_DIR/.git" ]; then
    warn "Каталог $BACKEND_DIR уже существует — обновляю через git pull"
    git -C "$BACKEND_DIR" pull
else
    rm -rf "$BACKEND_DIR"
    git clone "$BACKEND_REPO_URL" "$BACKEND_DIR"
fi
log "Backend склонирован в $BACKEND_DIR"

# ------------------------- 3) venv + зависимости ---------------------------
log "3) Создание venv и установка зависимостей в $BACKEND_DIR"
cd "$BACKEND_DIR"
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate
log "Зависимости backend установлены"

# ------------------------- 4) .env -----------------------------------------
log "4) Создание файла .env"
cat > "$BACKEND_DIR/.env" <<'EOF'
DEVICE_PATH=/dev/ttyS1
EOF
log ".env создан: DEVICE_PATH=/dev/ttyS1"

# ------------------------- 5) systemd unit ---------------------------------
log "5) Создание systemd unit /etc/systemd/system/${SERVICE_NAME}.service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<'EOF'
[Unit]
Description=Arm Box FastAPI server
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/root/arm_box
ExecStart=/root/arm_box/.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
log "Unit-файл создан"

# ------------------------- 6) enable сервиса -------------------------------
log "6) Включение сервиса ${SERVICE_NAME}"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
log "Сервис включён в автозапуск"

# ------------------------- 7) Frontend -------------------------------------
log "7) Клонирование frontend из $FRONTEND_REPO_URL в $FRONTEND_DIR"
mkdir -p "$(dirname "$FRONTEND_DIR")"
if [ -d "$FRONTEND_DIR/.git" ]; then
    warn "Каталог $FRONTEND_DIR уже существует — обновляю через git pull"
    git -C "$FRONTEND_DIR" pull
else
    rm -rf "$FRONTEND_DIR"
    git clone "$FRONTEND_REPO_URL" "$FRONTEND_DIR"
fi
log "Frontend склонирован в $FRONTEND_DIR"

# ------------------------- 8) nginx конфиг ---------------------------------
log "8) Создание nginx-конфига $NGINX_CONF"
cat > "$NGINX_CONF" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/arm_box_web;
    index index.html;

    gzip on;
    gzip_min_length 1024;
    gzip_types text/css application/javascript text/javascript application/json image/svg+xml;

    location /assets/ {
        try_files $uri =404;
        add_header Cache-Control "no-cache";
    }

    location = /index.html {
        add_header Cache-Control "no-cache";
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Скрытые файлы не отдаём
    location ~ /\. {
        deny all;
    }
}
EOF
log "nginx-конфиг создан"

# ------------------------- 9) Подключение конфига nginx --------------------
log "9) Подключение конфига и проверка nginx"
# Отключаем дефолтный сайт, если он есть (иначе конфликт за default_server)
if [ -e /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
    log "Удалён симлинк дефолтного сайта"
fi
ln -sf "$NGINX_CONF" "$NGINX_LINK"
nginx -t
systemctl enable nginx
systemctl restart nginx
log "nginx перезапущен и подхватил конфиг"

log "=== Установка успешно завершена ==="
log "Логи установки сохранены в $LOG_FILE"

# ------------------------- 10) Reboot --------------------------------------
log "10) Перезагрузка системы"
sync
reboot