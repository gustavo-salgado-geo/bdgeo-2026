#!/bin/sh

set -e

echo "Iniciando pygeoapi..."
echo "PORT=${PORT}"

sed "s/port: 5000/port: ${PORT}/" \
    /app/pygeoapi-config.yml \
    > /tmp/pygeoapi-config.yml

export PYGEOAPI_CONFIG=/tmp/pygeoapi-config.yml
export PYGEOAPI_OPENAPI=/app/pygeoapi-openapi.yml

# Executa com Gunicorn otimizando o uso de memória
exec gunicorn --bind 0.0.0.0:${PORT} --workers 1 --threads 2 pygeoapi.flask_app:APP