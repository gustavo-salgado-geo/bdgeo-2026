-- Schemas do pipeline: raw (staging bruta) e analytics (dados prontos para a API)
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS analytics;

-- Descreve o propósito de cada schema
COMMENT ON SCHEMA raw IS 'Dados brutos carregados via ogr2ogr, sem tratamento';
COMMENT ON SCHEMA staging IS 'Dados em transformação';
COMMENT ON SCHEMA analytics IS 'Dados corrigidos, prontos para servir via OGC API';

-- Criando a tabela que será usada pela API 
CREATE TABLE IF NOT EXISTS analytics.car_area_imovel (
    cod_imovel          varchar NOT NULL,
    id                  varchar,
    status_imovel       varchar,
    dat_criacao         timestamptz,
    area                double,
    condicao            varchar,
    uf                  varchar(2),
    municipio           varchar,
    cod_municipio_ibge  integer,
    m_fiscal            double,
    tipo_imovel         varchar,
    geom_corrigida      boolean NOT NULL DEFAULT false,
    geom                geometry(MultiPolygon, 4674),

    CONSTRAINT car_area_imovel_pkey
        PRIMARY KEY (cod_imovel)
    PARTITION BY LIST (uf)
);


-- Comentarios para colunas cod_imovel e id da tabela analytics.car_area_imovel
COMMENT ON COLUMN analytics.car_area_imovel.cod_imovel IS
'Identificador do imóvel no CAR fornecido pelo órgão ambiental';

COMMENT ON COLUMN analytics.car_area_imovel.id IS
'Identificador do registro de origem no SICAR/WFS, associado à versão do imóvel.';


-- Cria função para corrigir geometria inválida e publicar dados para esquema analytics
CREATE OR REPLACE PROCEDURE analytics.upsert_car_area_imovel(
    p_uf text
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tabela_raw text;
    v_processados bigint;
BEGIN

    v_tabela_raw := format(
        'car_area_imovel_%s',
        lower(p_uf)
    );

    EXECUTE format(
        'SELECT count(*)
         FROM raw.%I
         WHERE cod_imovel IS NOT NULL',
        v_tabela_raw
    )
    INTO v_processados;

    RAISE NOTICE 'Processando CAR: UF=%, registros=%',
        p_uf,
        v_processados;

    EXECUTE format($sql$

        INSERT INTO analytics.car_area_imovel (
            cod_imovel,
            id,
            status_imovel,
            dat_criacao,
            area,
            condicao,
            uf,
            municipio,
            cod_municipio_ibge,
            m_fiscal,
            tipo_imovel,
            geom_corrigida,
            geom
        )

        SELECT
            r.cod_imovel,
            r.id,
            r.status_imovel,
            r.dat_criacao,
            r.area,
            r.condicao,
            r.uf,
            r.municipio,
            r.cod_municipio_ibge,
            r.m_fiscal,
            r.tipo_imovel,
            NOT ST_IsValid(r.geom),
            CASE
                WHEN r.geom IS NULL THEN NULL
                ELSE ST_Multi(
                    ST_CollectionExtract(
                        ST_MakeValid(r.geom),
                        3
                    )
                )
            END

        FROM (
            SELECT DISTINCT ON (cod_imovel)
                cod_imovel,
                id,
                status_imovel,
                dat_criacao,
                area,
                condicao,
                uf,
                municipio,
                cod_municipio_ibge,
                m_fiscal,
                tipo_imovel,
                geom,
                ogc_fid
            FROM raw.%I
            WHERE cod_imovel IS NOT NULL
            ORDER BY
                cod_imovel,
                dat_criacao DESC NULLS LAST,
                ogc_fid DESC
        ) r

        ON CONFLICT (cod_imovel)

        DO UPDATE SET
            id                  = EXCLUDED.id,
            status_imovel       = EXCLUDED.status_imovel,
            dat_criacao         = EXCLUDED.dat_criacao,
            area                = EXCLUDED.area,
            condicao            = EXCLUDED.condicao,
            uf                  = EXCLUDED.uf,
            municipio           = EXCLUDED.municipio,
            cod_municipio_ibge  = EXCLUDED.cod_municipio_ibge,
            m_fiscal            = EXCLUDED.m_fiscal,
            tipo_imovel         = EXCLUDED.tipo_imovel,
            geom_corrigida      = EXCLUDED.geom_corrigida,
            geom                = EXCLUDED.geom;

    $sql$, v_tabela_raw);

    RAISE NOTICE 'Carga concluída: UF=%', p_uf;

END;
$$;

-- Cria índices espaciais e de atributos para melhorar a performance de consultas
CREATE INDEX IF NOT EXISTS car_area_imovel_geom_idx
    ON analytics.car_area_imovel
    USING GIST (geom);

CREATE INDEX IF NOT EXISTS car_area_imovel_uf_idx
    ON analytics.car_area_imovel (uf);