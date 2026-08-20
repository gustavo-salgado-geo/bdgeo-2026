#!/bin/bash

# Carga do Cadastro Ambiental Rural (CAR/SICAR) via WFS.
#
# Fluxo:
#   WFS -> download paginado em GeoJSON -> ogr2ogr -> raw.car_area_imovel_<UF>
#
# Uso:
#   ./etl_cadastro_ambiental_rural.sh <uf>
#
# Exemplo:
#   ./etl_cadastro_ambiental_rural.sh sp

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuração
# -----------------------------------------------------------------------------

BASE_URL="https://geoserver.car.gov.br/geoserver/sicar/wfs"
WORKSPACE="sicar"
SRS="EPSG:4674"

PAGE_SIZE=10000
MAX_RETRIES=5
RETRY_DELAY=5

ESTADOS_VALIDOS="ac ap am pa rr ro ma pi ce rn pb pe al se ba es rj sp mg pr sc rs ms mt go df to"

# -----------------------------------------------------------------------------
# Funções auxiliares
# -----------------------------------------------------------------------------

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

psql_exec() {
    local sql="$1"
    psql "$PG_CONNECTION" -v ON_ERROR_STOP=1 -qAtc "$sql"
}

get_total_records() {
    local url="${BASE_URL}?service=WFS&version=2.0.0&request=GetFeature&typeName=${WORKSPACE}:${LAYER}&resultType=hits"

    curl \
        -k \
        -sS \
        --fail \
        "$url" \
        | grep -oP 'numberMatched="\K[0-9]+'
}

download_page() {
    local start="$1"
    local end="$2"

    local out="${WORKDIR}/${LAYER}_${start}_${end}.geojson"

    if [[ -s "$out" ]] && [[ $(wc -c < "$out") -ge 200 ]]; then
        log "  Página já existe. Pulando download."
        return 0
    fi

    local url="${BASE_URL}?service=WFS&version=2.0.0&request=GetFeature&typeName=${WORKSPACE}:${LAYER}&srsName=${SRS}&outputFormat=application/json&startIndex=${start}&maxFeatures=${PAGE_SIZE}"

    curl \
        -k \
        -sS \
        --fail \
        --retry 0 \
        "$url" \
        -o "$out"

    [[ -s "$out" ]]
    [[ $(wc -c < "$out") -ge 200 ]]
}

load_raw() {
    local count=0

    for file in "$WORKDIR"/${LAYER}_*.geojson; do

        local flag="-append"

        if [[ "$count" -eq 0 ]]; then
            flag="-overwrite"
        fi

        log "Importando $(basename "$file") para raw.${TABELA}..."

        ogr2ogr \
            "$flag" \
            -f "PostgreSQL" \
            "$PG_CONNECTION" \
            "$file" \
            -nln "raw.$TABELA" \
            -lco GEOMETRY_NAME=geom \
            -nlt PROMOTE_TO_MULTI \
            -t_srs "$SRS" \
            --config OGR_GEOJSON_MAX_OBJ_SIZE 0

        count=$((count + 1))
    done
}

# -----------------------------------------------------------------------------
# Execução principal
# -----------------------------------------------------------------------------

main() {

    log "=============================================="
    log "Carga CAR/SICAR"
    log "UF: ${UF}"
    log "Camada WFS: ${WORKSPACE}:${LAYER}"
    log "Tabela destino: raw.${TABELA}"
    log "=============================================="

    # -------------------------------------------------------------------------
    # 1. Consultar quantidade total
    # -------------------------------------------------------------------------

    log "Consultando quantidade de registros no WFS..."

    local total

    total=$(get_total_records)

    if [[ -z "$total" || ! "$total" =~ ^[0-9]+$ || "$total" -eq 0 ]]; then
        log "ERRO: não foi possível obter o total de registros do WFS."
        exit 1
    fi

    local total_pages=$(( (total + PAGE_SIZE - 1) / PAGE_SIZE ))

    log "Total esperado: ${total}"
    log "Tamanho da página: ${PAGE_SIZE}"
    log "Total de páginas: ${total_pages}"

    # -------------------------------------------------------------------------
    # 2. Download paginado
    # -------------------------------------------------------------------------

    log "Iniciando download..."

    local page=0
    local start=0

    while [[ "$start" -lt "$total" ]]; do

        page=$((page + 1))

        local remaining=$((total - start))
        local expected=$PAGE_SIZE

        if [[ "$remaining" -lt "$PAGE_SIZE" ]]; then
            expected="$remaining"
        fi

        local end=$((start + expected - 1))

        log "Página ${page}/${total_pages} | registros ${start}-${end} | esperado: ${expected}"

        local start_time
        start_time=$(date +%s)

        local success=false

        for (( retry=1; retry<=MAX_RETRIES; retry++ )); do

        if download_page "$start" "$end"; then
                success=true
                break
            fi

            log "  Falha na página ${page}/${total_pages} (tentativa ${retry}/${MAX_RETRIES})"

            rm -f "${WORKDIR}/${LAYER}_${start}_${end}.geojson"

            if [[ "$retry" -lt "$MAX_RETRIES" ]]; then
                sleep "$RETRY_DELAY"
            fi
        done

        if [[ "$success" != true ]]; then
            log "ERRO: não foi possível baixar a página ${page} após ${MAX_RETRIES} tentativas."
            log "Carga interrompida."
            exit 1
        fi

        local file="${WORKDIR}/${LAYER}_${start}_${end}.geojson"
        local size
        size=$(du -h "$file" | cut -f1)

        local elapsed
        elapsed=$(( $(date +%s) - start_time ))

        log "  OK | arquivo: ${size} | tempo: ${elapsed}s"

        start=$((start + PAGE_SIZE))
    done

    # -------------------------------------------------------------------------
    # 3. Verificar quantidade de arquivos
    # -------------------------------------------------------------------------

    local downloaded_pages

    downloaded_pages=$(find "$WORKDIR" -maxdepth 1 -type f -name "${LAYER}_*.geojson" | wc -l)

    if [[ "$downloaded_pages" -ne "$total_pages" ]]; then
        log "ERRO: quantidade de páginas baixadas não corresponde ao esperado."
        log "Esperado: ${total_pages}"
        log "Baixado: ${downloaded_pages}"
        exit 1
    fi

    log "Download concluído: ${downloaded_pages}/${total_pages} páginas."

    # -------------------------------------------------------------------------
    # 4. Carga no PostGIS
    # -------------------------------------------------------------------------

    log "Iniciando carga no PostgreSQL..."

    load_raw

    log "Carga no PostgreSQL concluída."

    log "Iniciando preprocessamento e upsert na tabela analytics.car_area_imovel..."

    psql_exec "CALL analytics.upsert_car_area_imovel('${UF}');"

    # -------------------------------------------------------------------------
    # 5. Limpeza
    # -------------------------------------------------------------------------

    rm -rf "$WORKDIR"

    log "=============================================="
    log "Carga concluída para UF=${UF}"
    log "Tabela: raw.${TABELA}"
    log "=============================================="
}

# -----------------------------------------------------------------------------
# Argumentos
# -----------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
    log "Uso: $0 <uf>"
    exit 1
fi

UF=$(echo "$1" | tr '[:upper:]' '[:lower:]')

if [[ ! " $ESTADOS_VALIDOS " =~ " $UF " ]]; then
    log "ERRO: estado inválido: $UF"
    exit 1
fi

LAYER="sicar_imoveis_${UF}"
TABELA="car_area_imovel_${UF}"

WORKDIR="/tmp/car_${UF}"

# -----------------------------------------------------------------------------
# PostgreSQL
# -----------------------------------------------------------------------------

: "${PGHOST:?PGHOST não definida}"
: "${PGPORT:?PGPORT não definida}"
: "${PGDATABASE:?PGDATABASE não definida}"
: "${PGUSER:?PGUSER não definida}"
: "${PGPASSWORD:?PGPASSWORD não definida}"

PG_CONNECTION="PG:host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} password=${PGPASSWORD}"
# -----------------------------------------------------------------------------
# Preparação
# -----------------------------------------------------------------------------

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

main