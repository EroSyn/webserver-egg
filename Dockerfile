FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg2 \
        lsb-release \
        apt-transport-https \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://packages.sury.org/php/apt.gpg \
       | gpg --dearmor -o /etc/apt/keyrings/sury-php.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(. /etc/os-release && echo $VERSION_CODENAME) main" \
       > /etc/apt/sources.list.d/sury-php.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        nginx \
        redis-server \
        php8.4-fpm \
        php8.4-cli \
        php8.4-common \
        php8.4-curl \
        php8.4-gd \
        php8.4-mbstring \
        php8.4-mysql \
        php8.4-bcmath \
        php8.4-xml \
        php8.4-zip \
        php8.4-intl \
        php8.5-fpm \
        php8.5-cli \
        php8.5-common \
        php8.5-curl \
        php8.5-gd \
        php8.5-mbstring \
        php8.5-mysql \
        php8.5-bcmath \
        php8.5-xml \
        php8.5-zip \
        php8.5-intl \
        tar \
        unzip \
        git \
        composer \
        openssl \
        procps \
        tini \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /run/php /var/www \
    && chown -R root:root /run/php /var/www

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Image default user; Wings may still start the container with panel UID (see README).
USER root

EXPOSE 80 443

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
