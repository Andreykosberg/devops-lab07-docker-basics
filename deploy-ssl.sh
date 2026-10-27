#!/bin/bash -x
# Доп. задание. Деплой nginx в контейнере с HTTPS.
# Сертификат пробрасывается в контейнер через volume mapping (-v), а не
# встраивается в образ.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME=nginx-lab7-ssl-cont
IMAGE_NAME=devops/nginx-lab7-ssl

# Если сертификата еще нет - генерируем
if [ ! -f "$SCRIPT_DIR/ssl/server.crt" ]; then
  "$SCRIPT_DIR/generate_cert.sh"
fi

# Удаляем старый контейнер, если есть
docker stop "$CONTAINER_NAME"
docker rm "$CONTAINER_NAME"

# Собираем образ (без сертификата внутри)
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR/nginx-ssl"

# Запускаем контейнер, пробрасываем порт 54443 -> 443,
# монтируем сертификат внутрь контейнера через volume (read-only)
docker run -d --name "$CONTAINER_NAME" -p 54443:443 \
  --restart unless-stopped \
  -v "$SCRIPT_DIR/ssl:/etc/nginx/ssl:ro" \
  "$IMAGE_NAME"

# Проверяем
docker ps -a
sleep 5
curl -k https://127.0.0.1:54443
docker logs -n 10 "$CONTAINER_NAME"
