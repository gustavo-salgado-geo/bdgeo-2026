#!/bin/bash

# Carga do PRODES via WFS.
#
# Fluxo:
#   WFS -> download paginado em GeoJSON
#       -> ogr2ogr
#       -> raw.prodes_<bioma>
#
# Para cada bioma:
#   1. Remove a tabela raw existente
#   2. accumulated -> -overwrite
#   3. residual    -> -append
#   4. yearly      -> -append
#
# Exemplos de tabelas:
#   raw.prodes_amazon
#   raw.prodes_cerrado
#   raw.prodes_caatinga
#   raw.prodes_mata_atlantica
#   raw.prodes_pampa
#   raw.prodes_pantanal
#
# Uso:
#   ./etl_prodes_desmatamentos.sh

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuração
# -----------------------------------------------------------------------------

BASE_URL="https://terrabrasilis.dpi.inpe.br/geoserver"

MAX_RETRIES=5
RETRY_DELAY=5

WORKDIR="/tmp/prodes"

# -----------------------------------------------------------------------------
# Funções auxiliares
# -----------------------------------------------------------------------------

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

psql_exec() {
    local sql="$1"
    psql "$PSQL_CONNECTION" -v ON_ERROR_STOP=1 -qAtc "$sql"
}

# -----------------------------------------------------------------------------
# Consulta quantidade total de registros
# -----------------------------------------------------------------------------

get_total_records() {
    local url="$1"
    local type_name="$2"

    local hits_url="${url}?service=WFS&version=1.1.0&request=GetFeature&typeName=${type_name}&resultType=hits"

    curl \
        -k \
        -sS \
        --fail \
        "$hits_url" \
        | grep -oP 'numberOfFeatures="\K[0-9]+'
}

# -----------------------------------------------------------------------------
# Download de uma página
# -----------------------------------------------------------------------------

download_page() {
    local url="$1"
    local type_name="$2"
    local sort_by="$3"
    local start="$4"
    local page_size="$5"
    local output="$6"

    # Permite reaproveitar páginas já baixadas durante testes.
    if [[ -s "$output" ]] && [[ $(wc -c < "$output") -ge 200 ]]; then
        log "  Página já existe. Pulando download."
        return 0
    fi

    local fetch_url="${url}?service=WFS&version=1.1.0&request=GetFeature&typeName=${type_name}&outputFormat=application/json&maxFeatures=${page_size}&startIndex=${start}&sortBy=${sort_by}"

    curl \
        -k \
        -sS \
        --fail \
        --retry 0 \
        "$fetch_url" \
        -o "$output"

    [[ -s "$output" ]]
    [[ $(wc -c < "$output") -ge 200 ]]
}

# -----------------------------------------------------------------------------
# Download e carga de uma camada WFS
# -----------------------------------------------------------------------------

ingest_layer() {
    local url="$1"
    local type_name="$2"
    local sort_by="$3"
    local page_size="$4"
    local layer_name="$5"
    local tabela_raw="$6"
    local flag="$7"

    log "----------------------------------------------"
    log "Camada WFS: ${type_name}"
    log "Tabela destino: raw.${tabela_raw}"
    log "Modo: ${flag}"
    log "----------------------------------------------"

    # -------------------------------------------------------------------------
    # 1. Consultar total
    # -------------------------------------------------------------------------

    local total

    total=$(get_total_records "$url" "$type_name" || true)

    if [[ -z "$total" || ! "$total" =~ ^[0-9]+$ || "$total" -eq 0 ]]; then
        log "ERRO: não foi possível obter o total de registros de ${type_name}."
        exit 1
    fi

    local total_pages
    total_pages=$(( (total + page_size - 1) / page_size ))

    log "Total esperado: ${total}"
    log "Tamanho da página: ${page_size}"
    log "Total de páginas: ${total_pages}"

    # -------------------------------------------------------------------------
    # 2. Download paginado
    # -------------------------------------------------------------------------

    local page=0
    local start=0

    while [[ "$start" -lt "$total" ]]; do

        page=$((page + 1))

        local remaining=$((total - start))
        local expected="$page_size"

        if [[ "$remaining" -lt "$page_size" ]]; then
            expected="$remaining"
        fi

        local end=$((start + expected - 1))

        local filename="${layer_name}_${start}_${end}.geojson"
        local output="${WORKDIR}/${filename}"

        log "Página ${page}/${total_pages} | registros ${start}-${end} | esperado: ${expected}"

        local start_time
        start_time=$(date +%s)

        local success=false

        for ((retry=1; retry<=MAX_RETRIES; retry++)); do

            if download_page \
                "$url" \
                "$type_name" \
                "$sort_by" \
                "$start" \
                "$page_size" \
                "$output"; then

                success=true
                break
            fi

            log "  Falha na página ${page}/${total_pages} (tentativa ${retry}/${MAX_RETRIES})"

            rm -f "$output"

            if [[ "$retry" -lt "$MAX_RETRIES" ]]; then
                sleep "$RETRY_DELAY"
            fi
        done

        if [[ "$success" != true ]]; then
            log "ERRO: não foi possível baixar a página ${page} após ${MAX_RETRIES} tentativas."
            exit 1
        fi

        local size
        size=$(du -h "$output" | cut -f1)

        local elapsed
        elapsed=$(( $(date +%s) - start_time ))

        log "  OK | arquivo: ${size} | tempo: ${elapsed}s"

        start=$((start + page_size))
    done

    log "Download concluído: ${total_pages}/${total_pages} páginas."

    # -------------------------------------------------------------------------
    # 3. Verificar quantidade de arquivos
    # -------------------------------------------------------------------------

    local downloaded_pages

    downloaded_pages=$(
        find "$WORKDIR" \
            -maxdepth 1 \
            -type f \
            -name "${layer_name}_*.geojson" \
            | wc -l
    )

    if [[ "$downloaded_pages" -ne "$total_pages" ]]; then
        log "ERRO: quantidade de páginas baixadas não corresponde ao esperado."
        log "Esperado: ${total_pages}"
        log "Baixado: ${downloaded_pages}"
        exit 1
    fi

    # -------------------------------------------------------------------------
    # 4. Importar para PostGIS
    # -------------------------------------------------------------------------

    log "Importando ${layer_name} para raw.${tabela_raw}..."

    for file in "${WORKDIR}/${layer_name}_"*.geojson; do

        log "  Importando $(basename "$file")..."

        ogr2ogr \
            "$flag" \
            -f "PostgreSQL" \
            "$PG_CONNECTION" \
            "$file" \
            -nln "raw.${tabela_raw}" \
            -lco GEOMETRY_NAME=geom \
            -nlt PROMOTE_TO_MULTI \
            -t_srs "EPSG:4674" \
            --config OGR_GEOJSON_MAX_OBJ_SIZE 0

        # Depois do primeiro arquivo, todos os demais precisam ser append.
        flag="-append"
    done

    log "Carga concluída: raw.${tabela_raw}"

    # -------------------------------------------------------------------------
    # 5. Limpar arquivos da camada
    # -------------------------------------------------------------------------

    rm -f "${WORKDIR}/${layer_name}_"*.geojson
}

# -----------------------------------------------------------------------------
# Processamento de um bioma
# -----------------------------------------------------------------------------

process_biome() {
    local url_slug="$1"
    local table_suffix="$2"
    local accum_year="$3"
    local suffix="$4"
    local sort_by="$5"
    local page_size="$6"

    local base_url="${BASE_URL}/prodes-${url_slug}-nb/ows"
    local workspace="prodes-${url_slug}-nb"
    local tabela_raw="prodes_${table_suffix}"

    log "=============================================="
    log "Bioma WFS: ${url_slug}"
    log "Tabela: raw.${tabela_raw}"
    log "=============================================="

    log "Removendo tabela raw.${tabela_raw}, se existir..."

    psql_exec "
        DROP TABLE IF EXISTS raw.${tabela_raw};
    "

    ingest_layer \
        "$base_url" \
        "${workspace}:accumulated_deforestation_${accum_year}${suffix}" \
        "$sort_by" \
        "$page_size" \
        "${url_slug}_accumulated" \
        "$tabela_raw" \
        "-overwrite"

    ingest_layer \
        "$base_url" \
        "${workspace}:residual${suffix}" \
        "$sort_by" \
        "$page_size" \
        "${url_slug}_residual" \
        "$tabela_raw" \
        "-append"

    ingest_layer \
        "$base_url" \
        "${workspace}:yearly_deforestation${suffix}" \
        "$sort_by" \
        "$page_size" \
        "${url_slug}_yearly" \
        "$tabela_raw" \
        "-append"
}

# -----------------------------------------------------------------------------
# Execução principal
# -----------------------------------------------------------------------------

main() {

    log "=============================================="
    log "Carga PRODES"
    log "=============================================="

    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    # -------------------------------------------------------------------------
    # Biomas
    # -------------------------------------------------------------------------

    process_biome \
        "pantanal" \
        "pantanal" \
        "2000" \
        "" \
        "uuid" \
        "45000"

    process_biome \
        "pampa" \
        "pampa" \
        "2000" \
        "" \
        "uuid" \
        "45000"

    process_biome \
        "cerrado" \
        "cerrado" \
        "2000" \
        "" \
        "fid" \
        "20000"

    process_biome \
        "mata-atlantica" \
        "mata_atlantica" \
        "2000" \
        "" \
        "uuid" \
        "25000"

    process_biome \
        "caatinga" \
        "caatinga" \
        "2000" \
        "" \
        "uuid" \
        "20000"

    process_biome \
        "amazon" \
        "amazon" \
        "2007" \
        "_biome" \
        "uuid" \
        "30000"

    # -------------------------------------------------------------------------
    # Verificação
    # -------------------------------------------------------------------------

    log "=============================================="
    log "Tabelas PRODES carregadas:"
    log "=============================================="

    psql_exec "
        SELECT
            schemaname || '.' || tablename
        FROM pg_tables
        WHERE schemaname = 'raw'
          AND tablename LIKE 'prodes_%'
        ORDER BY tablename;
    "

    rm -rf "$WORKDIR"

    log "=============================================="
    log "Upsert e preprocessamento para esquema analytics:"
    log "=============================================="

    # psql_exec "CALL analytics.processa_prodes();"

    # psql_exec "VACUUM ANALYZE analytics.prodes_desmatamentos;"

    log "=============================================="
    log "Carga do PRODES concluída."
    log "=============================================="
}

# -----------------------------------------------------------------------------
# PostgreSQL
# -----------------------------------------------------------------------------

: "${PGHOST:?PGHOST não definida}"
: "${PGPORT:?PGPORT não definida}"
: "${PGDATABASE:?PGDATABASE não definida}"
: "${PGUSER:?PGUSER não definida}"
: "${PGPASSWORD:?PGPASSWORD não definida}"

# Conexão usada pelo GDAL/ogr2ogr
PG_CONNECTION="PG:host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} password=${PGPASSWORD}"

# Conexão usada pelo PostgreSQL/psql
PSQL_CONNECTION="host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} password=${PGPASSWORD}"
# -----------------------------------------------------------------------------
# Execução
# -----------------------------------------------------------------------------

main