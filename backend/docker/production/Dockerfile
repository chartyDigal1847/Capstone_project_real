# Production image for the Firebase-backed target architecture.
# Includes PHP gRPC extension (required by google/cloud-firestore) and
# Redis extension (for production queue/cache). No MySQL runtime dependency —
# Firestore and Cloud Storage are managed Firebase services accessed via IAM.
FROM php:8.2-fpm-alpine AS vendor

RUN apk add --no-cache git unzip libzip-dev icu-dev oniguruma-dev \
    && docker-php-ext-install pdo_mysql bcmath intl zip opcache

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-interaction --prefer-dist --optimize-autoloader

FROM php:8.2-fpm-alpine

# Runtime libraries + gRPC C library (required by Firestore PHP client)
# Build the gRPC and Redis PHP extensions, then remove build deps.
RUN apk add --no-cache libzip icu-libs oniguruma nginx wget \
    && apk add --no-cache --virtual .build-deps \
        libzip-dev icu-dev oniguruma-dev \
        grpc-dev protobuf-dev \
        gcc g++ make linux-headers \
    && docker-php-ext-install pdo_mysql bcmath intl zip opcache \
    && pecl install grpc redis \
    && docker-php-ext-enable grpc redis \
    && apk del .build-deps \
    && apk add --no-cache grpc \
    && addgroup -g 10001 localspot \
    && adduser -D -G localspot -u 10001 localspot

WORKDIR /var/www/html
COPY --from=vendor /app/vendor ./vendor
COPY . .
COPY docker/production/nginx.conf /etc/nginx/http.d/default.conf
COPY docker/production/php.ini /usr/local/etc/php/conf.d/localspot.ini
COPY docker/production/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN mkdir -p storage/framework/{cache,sessions,views} storage/logs bootstrap/cache \
    && chown -R localspot:localspot /var/www/html \
    && chmod +x /usr/local/bin/entrypoint.sh \
    && rm -rf tests .git .env

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -qO- http://127.0.0.1:8080/up || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
