# Usa a imagem base oficial do Python 3.12 em versão reduzida (slim) para diminuir o tamanho final do container
FROM python:3.12-slim

# Evita que o Python grave arquivos bytecode (.pyc) no disco
ENV PYTHONDONTWRITEBYTECODE=1

# Garanta que as saídas do Python (logs e prints) sejam exibidas imediatamente no terminal sem buffer
ENV PYTHONUNBUFFERED=1

# Instala bibliotecas de sistema essenciais para processamento de dados geoespaciais (GDAL, SpatiaLite) 
# e compiladores C/C++ necessários para compilar extensões Python.
# O 'rm -rf' ao final remove o cache do repositório para economizar espaço em disco.
RUN apt-get update && apt-get install -y \
    gdal-bin \
    libgdal-dev \
    libsqlite3-mod-spatialite \
    sqlite3 \
    gcc \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Define a pasta raiz de trabalho dentro do container onde os arquivos serão copiados
WORKDIR /app

# Instala os bindings Python do GDAL na versão exata da biblioteca C instalada no sistema operacional
RUN pip install --no-cache-dir GDAL==$(gdal-config --version)

# Copia primeiro apenas o arquivo de dependências (otimiza o reuso do cache das camadas do Docker)
COPY requirements.txt .

# Instala as dependências Python listadas no arquivo (como pygeoapi, gunicorn, etc.)
RUN pip install --no-cache-dir -r requirements.txt

# Copia os arquivos essenciais de configuração da API e o banco de dados geográfico
COPY pygeoapi-config.yml .
COPY pygeoapi-openapi.yml .
COPY bdgeo26.db .

# Copia o script shell responsável por inicializar o serviço
COPY start.sh .

# Concede permissão de execução ao script de inicialização
RUN chmod +x start.sh

# Define os caminhos dos arquivos de configuração como variáveis de ambiente padrão do pygeoapi
ENV PYGEOAPI_CONFIG=/app/pygeoapi-config.yml
ENV PYGEOAPI_OPENAPI=/app/pygeoapi-openapi.yml

# Documenta a porta interna padrão que o container disponibiliza
EXPOSE 5000

# Executa o script de entrada para rodar a aplicação quando o container for iniciado
CMD ["./start.sh"]