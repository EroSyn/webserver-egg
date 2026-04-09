#!/usr/bin/env bash
set -euo pipefail

PANEL_DIR="/home/container"
WEBROOT="/var/www/html"
RUNTIME_DIR="${PANEL_DIR}/.runtime"
NGINX_RUNTIME_DIR="${RUNTIME_DIR}/nginx"
PHP_RUNTIME_DIR="${RUNTIME_DIR}/php"
SSL_RUNTIME_DIR="${RUNTIME_DIR}/ssl"
PHP_SOCKET="${RUNTIME_DIR}/php-fpm.sock"

PHP_VERSION="${PHP_VERSION:-8.4}"
APP_SCHEME="${APP_SCHEME:-http}"
NGINX_CONFIG_RAW="${NGINX_CONFIG:-}"
CONSOLE_MODE="${CONSOLE_MODE:-bash}"

if [[ "$PHP_VERSION" != "8.4" && "$PHP_VERSION" != "8.5" ]]; then
  echo "[entrypoint] Unsupported PHP version '$PHP_VERSION'. Use 8.4 or 8.5."
  exit 1
fi

if [[ "$CONSOLE_MODE" != "bash" && "$CONSOLE_MODE" != "services" ]]; then
  echo "[entrypoint] Unsupported CONSOLE_MODE '$CONSOLE_MODE'. Use bash or services."
  exit 1
fi

mkdir -p "$PANEL_DIR" "$RUNTIME_DIR" "$NGINX_RUNTIME_DIR" "$PHP_RUNTIME_DIR" "$SSL_RUNTIME_DIR"

EFFECTIVE_WEBROOT="$WEBROOT"
if rm -rf "$WEBROOT" 2>/dev/null && ln -sfn "$PANEL_DIR" "$WEBROOT" 2>/dev/null; then
  echo "[entrypoint] Linked ${WEBROOT} -> ${PANEL_DIR}"
else
  EFFECTIVE_WEBROOT="$PANEL_DIR"
  echo "[entrypoint] Could not link ${WEBROOT}; falling back to ${PANEL_DIR} as nginx root."
fi

PHP_POOL_CONF="${PHP_RUNTIME_DIR}/www.conf"
PHP_MAIN_CONF="${PHP_RUNTIME_DIR}/php-fpm.conf"

cat > "$PHP_POOL_CONF" <<PHPPOOL
[www]
user = root
group = root
listen = ${PHP_SOCKET}
listen.owner = root
listen.group = root
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
clear_env = no
chdir = /
PHPPOOL

cat > "$PHP_MAIN_CONF" <<PHPCONF
[global]
pid = ${PHP_RUNTIME_DIR}/php-fpm.pid
error_log = /proc/self/fd/2
daemonize = no

include=${PHP_POOL_CONF}
PHPCONF

DEFAULT_HTTP_SERVER="server {
    listen 80;
    listen [::]:80;
    server_name _;
    root ${EFFECTIVE_WEBROOT};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php$ {
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:${PHP_SOCKET};
    }

    location ~ /\\.ht {
        deny all;
    }
}"

DEFAULT_HTTPS_SERVER="server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;
    root ${EFFECTIVE_WEBROOT};
    index index.php index.html index.htm;

    ssl_certificate ${SSL_RUNTIME_DIR}/selfsigned.crt;
    ssl_certificate_key ${SSL_RUNTIME_DIR}/selfsigned.key;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php$ {
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:${PHP_SOCKET};
    }

    location ~ /\\.ht {
        deny all;
    }
}"

NGINX_SERVER_CONF="${NGINX_RUNTIME_DIR}/server.conf"
if [[ -n "$NGINX_CONFIG_RAW" ]]; then
  printf "%s\n" "$NGINX_CONFIG_RAW" > "$NGINX_SERVER_CONF"
else
  if [[ "$APP_SCHEME" == "https" ]]; then
    if [[ -n "${SSL_CERT:-}" && -n "${SSL_KEY:-}" ]]; then
      printf "%s\n" "$SSL_CERT" > "${SSL_RUNTIME_DIR}/selfsigned.crt"
      printf "%s\n" "$SSL_KEY" > "${SSL_RUNTIME_DIR}/selfsigned.key"
    else
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${SSL_RUNTIME_DIR}/selfsigned.key" \
        -out "${SSL_RUNTIME_DIR}/selfsigned.crt" \
        -subj "/C=NL/ST=Noord-Holland/L=Amsterdam/O=Pterodactyl/CN=localhost"
    fi

    printf "%s\n" "$DEFAULT_HTTPS_SERVER" > "$NGINX_SERVER_CONF"
  else
    printf "%s\n" "$DEFAULT_HTTP_SERVER" > "$NGINX_SERVER_CONF"
  fi
fi

cat > "${NGINX_RUNTIME_DIR}/nginx.conf" <<NGINXMAIN
worker_processes auto;
error_log /proc/self/fd/2 warn;
pid ${NGINX_RUNTIME_DIR}/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /proc/self/fd/1;
    sendfile on;
    keepalive_timeout 65;

    include ${NGINX_SERVER_CONF};
}
NGINXMAIN

php-fpm${PHP_VERSION} --fpm-config "$PHP_MAIN_CONF" &
PHP_PID=$!

nginx -c "${NGINX_RUNTIME_DIR}/nginx.conf" -g "daemon off;" &
NGINX_PID=$!

if [[ "$CONSOLE_MODE" == "bash" ]]; then
  echo "[entrypoint] Console mode is bash. Services are running in background."
  exec /bin/bash -i
fi

wait -n "$PHP_PID" "$NGINX_PID"
