#!/usr/bin/env bash
set -euo pipefail

PANEL_DIR="/home/container"
WEBROOT="/var/www/html"
MYSQL_DATA_DIR="${PANEL_DIR}/mysql"
PHP_VERSION="${PHP_VERSION:-8.4}"
APP_SCHEME="${APP_SCHEME:-http}"
NGINX_CONFIG_RAW="${NGINX_CONFIG:-}"
DB_NAME="${DB_NAME:-app}"
DB_USER="${DB_USER:-app}"
DB_PASSWORD="${DB_PASSWORD:-app_password}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-root_password}"
CONSOLE_MODE="${CONSOLE_MODE:-bash}"

if [[ "$PHP_VERSION" != "8.4" && "$PHP_VERSION" != "8.5" ]]; then
  echo "[entrypoint] Unsupported PHP version '$PHP_VERSION'. Use 8.4 or 8.5."
  exit 1
fi

if [[ "$CONSOLE_MODE" != "bash" && "$CONSOLE_MODE" != "services" ]]; then
  echo "[entrypoint] Unsupported CONSOLE_MODE '$CONSOLE_MODE'. Use bash or services."
  exit 1
fi

if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "[entrypoint] DB_NAME may only contain letters, numbers, and underscores."
  exit 1
fi

if [[ ! "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "[entrypoint] DB_USER may only contain letters, numbers, and underscores."
  exit 1
fi

mkdir -p "$PANEL_DIR" "$MYSQL_DATA_DIR" /var/www /run/php /run/mysqld /etc/nginx/conf.d /etc/mysql
# Some Pterodactyl environments mount runtime dirs as read-only for chown.
# Root ownership is already correct in that case, so we continue safely.
chown -R root:root /run/php /run/mysqld 2>/dev/null || true

EFFECTIVE_WEBROOT="$WEBROOT"
if rm -rf "$WEBROOT" 2>/dev/null && ln -sfn "$PANEL_DIR" "$WEBROOT" 2>/dev/null; then
  echo "[entrypoint] Linked ${WEBROOT} -> ${PANEL_DIR}"
else
  EFFECTIVE_WEBROOT="$PANEL_DIR"
  echo "[entrypoint] Could not link ${WEBROOT}; falling back to ${PANEL_DIR} as nginx root."
fi

cat > "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" <<PHPPOOL
[www]
user = root
group = root
listen = /run/php/php-fpm.sock
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

DEFAULT_HTTP_CONF='server {
    listen 80;
    listen [::]:80;
    server_name _;
    root __WEBROOT__;
    index index.php index.html index.htm;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \\.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }

    location ~ /\\.ht {
        deny all;
    }
}'

DEFAULT_HTTPS_CONF='server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;
    root __WEBROOT__;
    index index.php index.html index.htm;

    ssl_certificate /etc/nginx/ssl/selfsigned.crt;
    ssl_certificate_key /etc/nginx/ssl/selfsigned.key;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \\.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }

    location ~ /\\.ht {
        deny all;
    }
}'

if [[ -n "$NGINX_CONFIG_RAW" ]]; then
  printf "%s\n" "$NGINX_CONFIG_RAW" > /etc/nginx/conf.d/default.conf
else
  if [[ "$APP_SCHEME" == "https" ]]; then
    mkdir -p /etc/nginx/ssl

    if [[ -n "${SSL_CERT:-}" && -n "${SSL_KEY:-}" ]]; then
      printf "%s\n" "$SSL_CERT" > /etc/nginx/ssl/selfsigned.crt
      printf "%s\n" "$SSL_KEY" > /etc/nginx/ssl/selfsigned.key
    else
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/selfsigned.key \
        -out /etc/nginx/ssl/selfsigned.crt \
        -subj "/C=NL/ST=Noord-Holland/L=Amsterdam/O=Pterodactyl/CN=localhost"
    fi

    printf "%s\n" "${DEFAULT_HTTPS_CONF/__WEBROOT__/$EFFECTIVE_WEBROOT}" > /etc/nginx/conf.d/default.conf
  else
    printf "%s\n" "${DEFAULT_HTTP_CONF/__WEBROOT__/$EFFECTIVE_WEBROOT}" > /etc/nginx/conf.d/default.conf
  fi
fi

if [[ ! -d "${MYSQL_DATA_DIR}/mysql" ]]; then
  mariadb-install-db --user=root --datadir="${MYSQL_DATA_DIR}" >/dev/null 2>&1
fi

mysqld --user=root --datadir="${MYSQL_DATA_DIR}" --socket=/run/mysqld/mysqld.sock --bind-address=127.0.0.1 &
MYSQL_PID=$!

for _ in $(seq 1 30); do
  if mariadb-admin --socket=/run/mysqld/mysqld.sock ping >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

mariadb --socket=/run/mysqld/mysqld.sock <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

php-fpm${PHP_VERSION} -D
nginx -g "daemon off;" &
NGINX_PID=$!

if [[ "$CONSOLE_MODE" == "bash" ]]; then
  echo "[entrypoint] Console mode is bash. Services are running in background."
  exec /bin/bash -i
fi

wait -n "$MYSQL_PID" "$NGINX_PID"
