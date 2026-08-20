# Executar containers
docker compose up -d --build

# Executar as rotinas de processamento para a camada bronze
docker compose --profile tools run --rm etl bash ./scripts/etl_cadastro_ambiental_rural.sh

