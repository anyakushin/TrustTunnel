#!/usr/bin/env bash

set -e -x

NGINX_CONF_FILENAME="$1"

nginx -g 'daemon off;' -c "$NGINX_CONF_FILENAME" -p "$(pwd)" &
wait
