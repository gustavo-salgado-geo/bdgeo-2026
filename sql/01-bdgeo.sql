CREATE TABLE IF NOT EXISTS analytics.prodes_desmatamentos (
    id              varchar NOT NULL,
    bioma           varchar NOT NULL,
    fid             integer,
    state           varchar,
    path_row        varchar,
    main_class      varchar,
    class_name      varchar,
    def_cloud       integer,
    julian_day      integer,
    image_date      date,
    year            integer,
    area_km         double precision,
    scene_id        integer,
    source          varchar,
    satellite       varchar,
    sensor          varchar,
    geom_corrigida  boolean DEFAULT false,
    geom            geometry(MultiPolygon, 4674),
    CONSTRAINT prodes_desmatamentos_pkey
        PRIMARY KEY (id)
);



CREATE OR REPLACE PROCEDURE analytics.processa_prodes()
LANGUAGE plpgsql
AS $$
DECLARE
    v_tabela_raw text;
    v_bioma text;
    v_processados bigint;

    v_tabelas text[] := ARRAY[
        'prodes_cerrado',
        'prodes_mata_atlantica',
    ];
-- Adicionar novos biomas conforme necessário (demora muito processar todos):
-- 'prodes_amazon',
-- 'prodes_caatinga',
-- 'prodes_cerrado',
-- 'prodes_mata_atlantica',
-- 'prodes_pampa',
-- 'prodes_pantanal'

BEGIN

    /*
     * O analytics representa um snapshot consolidado do PRODES.
     * Portanto, começamos uma nova carga.
     */
    TRUNCATE analytics.prodes_desmatamentos;

    FOREACH v_tabela_raw IN ARRAY v_tabelas
    LOOP

        v_bioma := replace(v_tabela_raw, 'prodes_', '');

        EXECUTE format(
            'SELECT count(*)
             FROM raw.%I
             WHERE id IS NOT NULL',
            v_tabela_raw
        )
        INTO v_processados;

        RAISE NOTICE
            'Processando PRODES: bioma=%, tabela=%, registros=%',
            v_bioma,
            v_tabela_raw,
            v_processados;

        /*
         * 1. Inserção direta.
         *
         * Não executamos ST_MakeValid aqui.
         * A geometria entra como está no raw.
         */
        EXECUTE format($sql$

            INSERT INTO analytics.prodes_desmatamentos (
                id,
                bioma,
                fid,
                state,
                path_row,
                main_class,
                class_name,
                def_cloud,
                julian_day,
                image_date,
                year,
                area_km,
                scene_id,
                source,
                satellite,
                sensor,
                geom_corrigida,
                geom
            )
            SELECT
                r.id,
                %L,
                r.fid,
                r.state,
                r.path_row,
                r.main_class,
                r.class_name,
                CASE
                    WHEN r.def_cloud::text ~ '^[0-9]+$'
                    THEN r.def_cloud::integer
                    ELSE NULL
                END,
                r.julian_day,
                r.image_date,
                r."year",
                r.area_km,
                r.scene_id,
                r."source",
                r.satellite,
                r.sensor,
                false,
                r.geom
            FROM raw.%I r
            WHERE r.id IS NOT NULL;

        $sql$, v_bioma, v_tabela_raw);

        RAISE NOTICE
            'Carga concluída: bioma=%',
            v_bioma;

    END LOOP;

    /*
     * 2. Identifica e corrige somente as geometrias inválidas.
     */
    RAISE NOTICE 'Verificando geometrias inválidas...';

    UPDATE analytics.prodes_desmatamentos
    SET
        geom = ST_Multi(
            ST_CollectionExtract(
                ST_MakeValid(geom),
                3
            )
        ),
        geom_corrigida = true
    WHERE geom IS NOT NULL
      AND NOT ST_IsValid(geom);

    RAISE NOTICE 'Preprocessamento geométrico concluído.';

END;
$$;


CREATE INDEX prodes_desmatamentos_geom_idx
    ON analytics.prodes_desmatamentos
    USING GIST (geom);

CREATE INDEX prodes_desmatamentos_bioma_idx
    ON analytics.prodes_desmatamentos (bioma);

CREATE INDEX prodes_desmatamentos_year_idx
    ON analytics.prodes_desmatamentos ("year");