FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y \
    gdal-bin \
    libgdal-dev \
    libsqlite3-mod-spatialite \
    sqlite3 \
    gcc \
    g++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN pip install --no-cache-dir GDAL==$(gdal-config --version)

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY pygeoapi-config.yml .
COPY pygeoapi-openapi.yml .
COPY bdgeo26.db .

COPY processes ./processes
COPY start.sh .

RUN chmod +x start.sh

ENV PYGEOAPI_CONFIG=/app/pygeoapi-config.yml
ENV PYGEOAPI_OPENAPI=/app/pygeoapi-openapi.yml

EXPOSE 5000

CMD ["./start.sh"]