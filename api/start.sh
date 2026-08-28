#!/bin/sh

set -e

echo "Iniciando pygeoapi..."
echo "PORT=${PORT}"

sed "s/port: 5000/port: ${PORT}/" \
    /app/pygeoapi-config.yml \
    > /tmp/pygeoapi-config.yml

export PYGEOAPI_CONFIG=/tmp/pygeoapi-config.yml
export PYGEOAPI_OPENAPI=/app/pygeoapi-openapi.yml

exec pygeoapi serve --flask