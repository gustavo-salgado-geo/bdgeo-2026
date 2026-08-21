# BDGeo 2026

## Requisitos
- Docker
- Docker Compose

## 1) Subir o ambiente
```bash
docker compose up -d --build

## 2) Criar tabelas e funções do banco

docker compose --profile tools run --rm etl bash -lc 'psql -f ./sql/00-bdgeo.sql'
docker compose --profile tools run --rm etl bash -lc 'psql -f ./sql/01-bdgeo.sql'

## 3) Executar ETLs
docker compose --profile tools run --rm etl bash etl_cadastro_ambiental_rural.sh
docker compose --profile tools run --rm etl bash etl_prodes_desmatamentos.sh

# 4) Criar os buckets depois de subir o RustFS
docker compose --profile setup run --rm rustfs-setup


