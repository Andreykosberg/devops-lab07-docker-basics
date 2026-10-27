#!/bin/bash -x
# Лаб. П07. Docker basics - деплой nginx в контейнере.
# Собирает образ и (пере)запускает контейнер, пробрасывая порт 54321 -> 80.

CONTAINER_NAME=nginx-lab7-cont
IMAGE_NAME=devops/nginx-lab7

# Удаляем старый контейнер, если есть
docker stop "$CONTAINER_NAME"
docker rm "$CONTAINER_NAME"

# Собираем образ
docker build -t "$IMAGE_NAME" ./nginx

# Создаем и запускаем контейнер
docker run -d --name "$CONTAINER_NAME" -p 54321:80 \
  --restart unless-stopped \
  "$IMAGE_NAME"

# Проверяем
docker ps -a
sleep 5
curl 127.0.0.1:54321
docker logs -n 10 "$CONTAINER_NAME"
