#!/usr/bin/env bash
set -euo pipefail

# Pterodactyl/Wings often runs the process as a UID without /etc/passwd → bash shows "I have no name!".
ensure_identity() {
  local uid gid name fix rc
  uid=$(id -u)
  gid=$(id -g)
  if command -v getent &>/dev/null && getent passwd "$uid" &>/dev/null; then
    return 0
  fi
  name="container"
  if [[ "$uid" -eq 0 ]]; then
    name="root"
  fi
  if [[ -w /etc/passwd ]]; then
    echo "${name}:x:${uid}:${gid}:${name}:/home/container:/bin/bash" >> /etc/passwd 2>/dev/null || true
  fi
  if command -v getent &>/dev/null && ! getent group "$gid" &>/dev/null && [[ -w /etc/group ]]; then
    echo "${name}:x:${gid}:" >> /etc/group 2>/dev/null || true
  fi
  if command -v getent &>/dev/null && getent passwd "$uid" &>/dev/null; then
    return 0
  fi
  fix="/home/container/.bash_erosyn_prompt"
  rc="/home/container/.bashrc"
  mkdir -p /home/container
  cat > "$fix" <<EOF
export USER=${name}
export LOGNAME=${name}
export HOME=/home/container
PS1='${name}@\h:\w\\\$ '
EOF
  if [[ -f "$rc" ]]; then
    grep -q bash_erosyn_prompt "$rc" 2>/dev/null || echo "[ -f ${fix} ] && . ${fix} # bash_erosyn_prompt" >> "$rc"
  else
    echo "[ -f ${fix} ] && . ${fix} # bash_erosyn_prompt" > "$rc"
  fi
}

ensure_identity

PANEL_DIR="/home/container"
WEBROOT="/var/www/html"
RUNTIME_DIR="${PANEL_DIR}/.runtime"
NGINX_RUNTIME_DIR="${RUNTIME_DIR}/nginx"
PHP_RUNTIME_DIR="${RUNTIME_DIR}/php"
SSL_RUNTIME_DIR="${RUNTIME_DIR}/ssl"
USER_SSL_DIR="${PANEL_DIR}/ssl"
PHP_SOCKET="${RUNTIME_DIR}/php-fpm.sock"

PHP_VERSION="${PHP_VERSION:-8.4}"
APP_SCHEME="${APP_SCHEME:-http}"
NGINX_CONFIG_RAW="${NGINX_CONFIG:-}"
NGINX_DOCUMENT_ROOT="${NGINX_DOCUMENT_ROOT:-auto}"
CONSOLE_MODE="${CONSOLE_MODE:-bash}"
LISTEN_PORT="${SERVER_PORT:-80}"

if [[ "$PHP_VERSION" != "8.4" && "$PHP_VERSION" != "8.5" ]]; then
  echo "[entrypoint] Unsupported PHP version '$PHP_VERSION'. Use 8.4 or 8.5."
  exit 1
fi

if [[ "$CONSOLE_MODE" != "bash" && "$CONSOLE_MODE" != "services" ]]; then
  echo "[entrypoint] Unsupported CONSOLE_MODE '$CONSOLE_MODE'. Use bash or services."
  exit 1
fi

if [[ "$NGINX_DOCUMENT_ROOT" != "auto" && "$NGINX_DOCUMENT_ROOT" != "public" && "$NGINX_DOCUMENT_ROOT" != "root" ]]; then
  echo "[entrypoint] Unsupported NGINX_DOCUMENT_ROOT '$NGINX_DOCUMENT_ROOT'. Use auto, public, or root."
  exit 1
fi

mkdir -p "$PANEL_DIR" "$RUNTIME_DIR" "$NGINX_RUNTIME_DIR" "$PHP_RUNTIME_DIR" "$SSL_RUNTIME_DIR"
mkdir -p "$USER_SSL_DIR"

EFFECTIVE_WEBROOT="$WEBROOT"
if rm -rf "$WEBROOT" 2>/dev/null && ln -sfn "$PANEL_DIR" "$WEBROOT" 2>/dev/null; then
  echo "[entrypoint] Linked ${WEBROOT} -> ${PANEL_DIR}"
else
  EFFECTIVE_WEBROOT="$PANEL_DIR"
  echo "[entrypoint] Could not link ${WEBROOT}; falling back to ${PANEL_DIR} as nginx root."
fi

case "$NGINX_DOCUMENT_ROOT" in
  public)
    NGINX_ROOT="${PANEL_DIR}/public"
    ;;
  root)
    NGINX_ROOT="${EFFECTIVE_WEBROOT}"
    ;;
  auto)
    if [[ -f "${PANEL_DIR}/public/index.php" ]]; then
      NGINX_ROOT="${PANEL_DIR}/public"
    else
      NGINX_ROOT="${EFFECTIVE_WEBROOT}"
    fi
    ;;
esac

echo "[entrypoint] NGINX document root: ${NGINX_ROOT} (NGINX_DOCUMENT_ROOT=${NGINX_DOCUMENT_ROOT})"

PHP_POOL_CONF="${PHP_RUNTIME_DIR}/www.conf"
PHP_MAIN_CONF="${PHP_RUNTIME_DIR}/php-fpm.conf"

cat > "$PHP_POOL_CONF" <<PHPPOOL
[www]
listen = ${PHP_SOCKET}
chdir = ${PANEL_DIR}
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
    listen ${LISTEN_PORT};
    listen [::]:${LISTEN_PORT};
    server_name _;
    server_tokens off;
    root ${NGINX_ROOT};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
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
    listen ${LISTEN_PORT} ssl;
    listen [::]:${LISTEN_PORT} ssl;
    server_name _;
    server_tokens off;
    root ${NGINX_ROOT};
    index index.php index.html index.htm;

    ssl_certificate ${SSL_RUNTIME_DIR}/selfsigned.crt;
    ssl_certificate_key ${SSL_RUNTIME_DIR}/selfsigned.key;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
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
    elif [[ -f "${USER_SSL_DIR}/fullchain.pem" && -f "${USER_SSL_DIR}/privkey.pem" ]]; then
      cp "${USER_SSL_DIR}/fullchain.pem" "${SSL_RUNTIME_DIR}/selfsigned.crt"
      cp "${USER_SSL_DIR}/privkey.pem" "${SSL_RUNTIME_DIR}/selfsigned.key"
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
    client_body_temp_path ${NGINX_RUNTIME_DIR}/client_temp;
    proxy_temp_path ${NGINX_RUNTIME_DIR}/proxy_temp;
    fastcgi_temp_path ${NGINX_RUNTIME_DIR}/fastcgi_temp;
    uwsgi_temp_path ${NGINX_RUNTIME_DIR}/uwsgi_temp;
    scgi_temp_path ${NGINX_RUNTIME_DIR}/scgi_temp;

    include ${NGINX_SERVER_CONF};
}
NGINXMAIN

php-fpm${PHP_VERSION} --fpm-config "$PHP_MAIN_CONF" &
PHP_PID=$!

nginx -c "${NGINX_RUNTIME_DIR}/nginx.conf" -g "daemon off;" &
NGINX_PID=$!

if [[ "$CONSOLE_MODE" == "bash" ]]; then
  echo "[entrypoint] Console mode is bash. Services are running in background."
  export HOME="${HOME:-/home/container}"
  cd "$HOME" 2>/dev/null || true
  exec /bin/bash -i
fi

wait -n "$PHP_PID" "$NGINX_PID"
