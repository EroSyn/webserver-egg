# Webserver Egg (Pterodactyl)

Dit egg draait in een enkele container:
- NGINX (latest uit Debian repository)
- PHP-FPM (8.4 en 8.5, kiesbaar)

## Belangrijk gedrag

- Pterodactyl files blijven in `/home/container`.
- De webroot `/var/www/html` is een symlink naar `/home/container`.
- Je serveert dus altijd exact dezelfde map als in de Pterodactyl file manager.

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
- `NGINX_CONFIG`: custom volledige nginx vhost config (overschrijft default)
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

Gebruik voor `NGINX_CONFIG` deze Laravel-geschikte config:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name _;
    root /home/container/public;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass unix:/home/container/.runtime/php-fpm.sock;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
```

