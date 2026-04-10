# Webserver Egg (Pterodactyl)

Dit egg draait in een enkele container:
- NGINX (latest uit Debian repository)
- PHP-FPM (8.4 en 8.5, kiesbaar)

## Belangrijk gedrag

- Pterodactyl files blijven in `/home/container` (zelfde rol als `/app` in `docker/docker-compose.yml`).
- Standaard NGINX gebruikt `try_files` zoals `docker/nginx/api.conf` (`/index.php$is_args$args`).
- Met `NGINX_DOCUMENT_ROOT=auto` (default): als `public/index.php` bestaat, is de document root `/home/container/public` (zoals `root /app/public` lokaal).
- Symlink `/var/www/html` → `/home/container` wordt geprobeerd; lukt dat niet, dan wordt direct `/home/container` gebruikt.

## Pariteit met `docker/`

| Lokaal (Compose) | Pterodactyl egg |
|------------------|-----------------|
| Volume `/app` | `/home/container` |
| `root /app/public` | `/home/container/public` (auto of `NGINX_DOCUMENT_ROOT=public`) |
| `fastcgi_pass php:9000` | `unix:/home/container/.runtime/php-fpm.sock` |

Referentie-vhost om in **Startup → NGINX_CONFIG** te plakken: `docker/nginx/pterodactyl-webserver.conf`.

## Build container image

```bash
cd webserver
docker build -t ghcr.io/erosyn/pterodactyl-webserver:latest .
```

Push daarna naar je registry en vervang in `egg-webserver.json` de `docker_images` tag indien nodig.

## Auto build via GitHub Actions

In deze repository staat een workflow op `.github/workflows/build-webserver-image.yml` die de image automatisch naar GHCR pusht.

- Push naar `main`: publiceert `latest` en `sha-...` tags
- Tag push `v*` (bijv. `v1.0.0`): publiceert ook een versie-tag

## Egg importeren

1. Pterodactyl Panel -> Nests -> Import Egg.
2. Kies `webserver/egg-webserver.json`.
3. Maak server aan met image `ghcr.io/erosyn/pterodactyl-webserver:latest`.

## Instance settings / variables

- `CONSOLE_MODE`: `bash` (interactieve shell in console) of `services` (alleen service output)
- `PHP_VERSION`: `8.4` of `8.5`
- `APP_SCHEME`: `http` of `https`
- `NGINX_DOCUMENT_ROOT`: `auto`, `public`, of `root`
- `NGINX_CONFIG`: custom volledige nginx `server { ... }` (overschrijft default)
- `SSL_CERT` / `SSL_KEY`: optioneel PEM cert/key voor https default config

## Laravel deploy (aanrader)

Plaats je Laravel project in `/home/container` (via file manager, git clone, of upload).

Voer daarna in de console uit:

```bash
composer install --no-dev --optimize-autoloader
cp .env.example .env
php artisan key:generate
php artisan storage:link
php artisan config:cache
php artisan route:cache
php artisan view:cache
```

Zet in `.env` je externe database host/credentials (bijv. via Pterodactyl Database Hosts).

Gebruik voor `NGINX_CONFIG` de template uit `docker/nginx/pterodactyl-webserver.conf`, of zet alleen `NGINX_DOCUMENT_ROOT=public` / laat `auto` staan zonder custom config.

