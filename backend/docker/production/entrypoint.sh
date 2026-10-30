#!/bin/sh
set -e
php artisan config:cache
php artisan route:cache
php artisan view:cache
php-fpm -D
exec nginx -g 'daemon off;'
