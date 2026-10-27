#!/bin/bash
# Доп. задание. Генерация самоподписанного SSL-сертификата для nginx в Docker.
set -e

DAYS="${1:-365}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSL_DIR="$SCRIPT_DIR/ssl"
mkdir -p "$SSL_DIR"

openssl req -x509 -nodes -days "$DAYS" \
  -newkey rsa:2048 \
  -keyout "$SSL_DIR/server.key" \
  -out "$SSL_DIR/server.crt" \
  -subj "/C=RU/ST=Moscow/L=Moscow/O=DevOpsLab/OU=Lab07/CN=nginx-lab7.local"

chmod 644 "$SSL_DIR/server.crt"
chmod 600 "$SSL_DIR/server.key"

echo "Сертификат сгенерирован:"
echo "  $SSL_DIR/server.crt"
echo "  $SSL_DIR/server.key"
openssl x509 -in "$SSL_DIR/server.crt" -noout -subject -dates
