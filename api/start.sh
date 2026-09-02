#!/bin/sh

# Interrompe a execução imediatamente se qualquer comando retornar erro
set -e

# Imprime mensagens informativas nos logs de deploy para monitoramento
echo "Iniciando pygeoapi..."
echo "PORT=${PORT}"

# Substitui a porta padrão (5000) pela porta dinâmica fornecida pelo Render ($PORT)
# O resultado é gravado em um novo arquivo de configuração no diretório temporário /tmp
sed "s/port: 5000/port: ${PORT}/" \
    /app/pygeoapi-config.yml \
    > /tmp/pygeoapi-config.yml

# Define a variável do config para o arquivo temporário
export PYGEOAPI_CONFIG=/tmp/pygeoapi-config.yml

# Define a variável do OpenAPI para um NOVO arquivo temporário
export PYGEOAPI_OPENAPI=/tmp/pygeoapi-openapi.yml

# GERANDO O OPENAPI ATUALIZADO (A Mágica acontece aqui!)
echo "Gerando novo arquivo OpenAPI com os metadados atualizados..."
# O 'if !' captura a falha do comando sem deixar o 'set -e' matar o script prematuramente.
# Se falhar, ele roda novamente sem o redirecionamento '>' para mostrar o Traceback exato na tela.
if ! pygeoapi openapi generate $PYGEOAPI_CONFIG > $PYGEOAPI_OPENAPI; then
    echo "❌ ERRO DE VALIDAÇÃO: O OpenAPI rejeitou o seu pygeoapi-config.yml!"
    echo "Detalhes do erro do schema:"
    pygeoapi openapi generate $PYGEOAPI_CONFIG
    exit 1
fi

# Substitui o processo do shell pelo servidor de produção Gunicorn:
# --bind: conecta a API a todas as interfaces de rede na porta atribuída ($PORT)
# --workers 1 --threads 2: limita a carga em 1 processo para conter o uso de RAM (evitando estouro de memória)
# pygeoapi.flask_app:APP: carrega o objeto Flask da aplicação (APP em maiúsculas)
exec gunicorn --bind 0.0.0.0:${PORT} --workers 1 --threads 2 pygeoapi.flask_app:APP