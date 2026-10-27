# Lab 07 — Docker basics

Лабораторная работа по курсу DevOps: основы контейнеризации (Docker) — сборка
образа, запуск контейнера с nginx, проброс порта наружу, оформление запуска
шелл-скриптом, а также дополнительное задание — HTTPS с самоподписанным
сертификатом, переданным в контейнер через volume mapping, и скрипт
обновления/перечитывания сертификата.

## Стенд

- **devops-lab01** — Ubuntu 24.04, уже использовавшаяся как control node в
  лабораторных П04–П06 (доступ по SSH `127.0.0.1:2223`, port-forward VirtualBox).
  На ней установлен и реально используется **Docker** (`docker.io`,
  Docker version 29.1.3). Все сборки образов, запуски контейнеров, curl-проверки
  и генерация сертификата выполнены по-настоящему на этой машине, без
  эмуляции вывода.
- Подключение и выполнение команд — через `paramiko` (Python), ровно тот же
  подход, что использовался во всех предыдущих лабораторных (`setup_lab7.py`
  в `vms/devops-lab01-ssh/`).

## Содержимое репозитория

```
.
├── deploy.sh                       # основное задание: сборка + запуск контейнера (порт 54321)
├── deploy-ssl.sh                   # доп.задание: сборка + запуск HTTPS-контейнера (порт 54443)
├── generate_cert.sh                # доп.задание: генерация самоподписанного сертификата
├── renew_cert.sh                   # доп.задание: пересоздание сертификата + nginx reload
├── nginx/
│   ├── dockerfile                  # образ для основного задания (HTTP, порт 80 внутри)
│   ├── index.html                  # статическая страница с приветствием
│   └── nginx-conf/
│       └── nginx.conf              # server { listen 80 ... }
├── nginx-ssl/
│   ├── dockerfile                  # образ для доп.задания (без сертификата внутри!)
│   ├── index.html
│   └── nginx-conf/
│       └── nginx-ssl.conf          # server { listen 443 ssl ... }
├── ssl/                             # сюда generate_cert.sh кладёт server.crt/server.key
│   └── .gitkeep                     # сами сертификаты в git не хранятся (.gitignore)
└── screenshots/                     # скриншоты реальных прогонов
```

## Задание и как оно выполнено

### Основное задание (П07. Docker basics)

Текст задания (слайд 43 лекции):

> Создать образ и запустить контейнер:
> - внутри которого будет работать веб-сервер Nginx,
> - отдающий статическую html страницу с приветствием с порта,
> - для доступа снаружи к nginx по сети пробросить в контейнер порт 54321
> - команду запуска контейнера оформить шелл-скриптом

Как выполнено, пункт за пунктом:

1. **Образ с nginx** — `nginx/dockerfile`, собран на базе официального образа
   `nginx`:

   ```dockerfile
   FROM nginx

   ADD ./index.html /var/www/html/index.html
   ADD ./nginx-conf/nginx.conf /etc/nginx/conf.d/default.conf

   RUN /usr/sbin/nginx -t

   STOPSIGNAL SIGTERM

   CMD ["nginx", "-g", "daemon off;"]
   ```

   `RUN /usr/sbin/nginx -t` на этапе сборки реально проверяет конфиг — если
   допустить ошибку в `nginx.conf`, образ просто не соберётся.

2. **Статическая html-страница с приветствием** — `nginx/index.html`:

   ```html
   <!DOCTYPE html>
   <html>
   <head>
   <title>DevOps Lab 07 - Docker basics</title>
   </head>
   <body>
   <h1>Привет из Docker-контейнера!</h1>
   <p>Andrey Kosberg — DevOps Course, Lab 07: Docker basics.</p>
   <p>Nginx работает внутри контейнера, порт проброшен снаружи на 54321.</p>
   </body>
   </html>
   ```

   Отдаётся nginx-ом с порта 80 **внутри** контейнера (`nginx/nginx-conf/nginx.conf`
   — стандартный дефолтный сервер-блок Debian-сборки nginx, `listen 80
   default_server`, `root /var/www/html`).

3. **Проброс порта 54321 снаружи** — реализован флагом `-p 54321:80` в
   `docker run`: внешний порт хоста 54321 проксируется на внутренний порт
   контейнера 80.

4. **Команда запуска контейнера оформлена шелл-скриптом** — `deploy.sh`:

   ```bash
   #!/bin/bash -x
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
   ```

   Скрипт идемпотентен — его можно запускать повторно: старый контейнер
   удаляется (если его нет — выводится безобидная ошибка `No such container`,
   и выполнение продолжается, т.к. `docker` возвращает ошибку, но на `-x`-трассировке
   это просто видно, а сам скрипт не содержит `set -e`, чтобы не прерваться на
   этом шаге при первом запуске).

### Доп. задание (HTTPS + volume mapping + reload)

Текст задания (слайд 52 лекции):

> - Сгенерировать SSL сертификат
> - Запускать nginx в контейнере с HTTPS протоколом, с сертификатом
> - Сертификат пробросить в контейнер через Volume Mapping
> - Сделать скрипт обновления (пересоздания сертификата), который будет
>   давать внутрь докера команду nginx на перечитывание сертификата (reload)

Как выполнено:

1. **Генерация сертификата** — `generate_cert.sh`, самоподписанный сертификат
   через `openssl req -x509`:

   ```bash
   openssl req -x509 -nodes -days "$DAYS" \
     -newkey rsa:2048 \
     -keyout "$SSL_DIR/server.key" \
     -out "$SSL_DIR/server.crt" \
     -subj "/C=RU/ST=Moscow/L=Moscow/O=DevOpsLab/OU=Lab07/CN=nginx-lab7.local"
   ```

2. **nginx с HTTPS в контейнере** — отдельный образ `nginx-ssl/dockerfile` +
   конфиг `nginx-ssl/nginx-conf/nginx-ssl.conf` (`listen 443 ssl`,
   `ssl_certificate /etc/nginx/ssl/server.crt`,
   `ssl_certificate_key /etc/nginx/ssl/server.key`). Важный нюанс: в этом
   Dockerfile **нет** `RUN nginx -t` на этапе сборки — потому что на момент
   `docker build` файлов сертификата ещё не существует (они появятся только
   при запуске контейнера через volume), и проверка конфига с несуществующим
   сертификатом не пройдёт.

3. **Сертификат пробрасывается через Volume Mapping, а не встраивается в
   образ** — `deploy-ssl.sh`:

   ```bash
   docker run -d --name "$CONTAINER_NAME" -p 54443:443 \
     --restart unless-stopped \
     -v "$SCRIPT_DIR/ssl:/etc/nginx/ssl:ro" \
     "$IMAGE_NAME"
   ```

   Папка `ssl/` на хосте монтируется в `/etc/nginx/ssl` внутри контейнера
   в режиме read-only. Образ `devops/nginx-lab7-ssl` сам по себе сертификата
   не содержит.

4. **Скрипт обновления сертификата с reload "внутрь докера"** — `renew_cert.sh`:

   ```bash
   #!/bin/bash -x
   CONTAINER_NAME="${1:-nginx-lab7-ssl-cont}"

   # Пересоздаём сертификат (volume смотрит на эту же папку)
   "$SCRIPT_DIR/generate_cert.sh"

   # Даём nginx внутри контейнера команду перечитать конфигурацию и сертификат
   docker exec "$CONTAINER_NAME" nginx -s reload
   ```

   Поскольку сертификат смонтирован через volume (а не скопирован внутрь
   образа), простая перезапись файлов `server.crt`/`server.key` на хосте
   немедленно видна и внутри контейнера — `nginx -s reload` заставляет
   мастер-процесс nginx перечитать конфиг и сертификат **без пересоздания
   контейнера**.

## Развёртывание (реальный командный лог)

Все команды выполнены по-настоящему через SSH на `devops-lab01`
(`127.0.0.1:2223`, пользователь `andrey`).

### 0. Проверка/установка Docker

```
$ sudo apt-get install -y docker.io
docker.io is already the newest version (29.1.3-0ubuntu3~24.04.2).

$ sudo systemctl enable --now docker
$ sudo systemctl status docker --no-pager
● docker.service - Docker Application Container Engine
     Active: active (running) since ...
   Main PID: 6441 (dockerd)
Oct 27 06:51:18 devops-lab01 dockerd[6441]: level=info msg="Daemon has completed initialization"

$ sudo usermod -aG docker andrey
$ groups andrey
andrey : andrey adm cdrom sudo dip plugdev lxd docker

$ sudo docker run hello-world
Unable to find image 'hello-world:latest' locally
latest: Pulling from library/hello-world
Status: Downloaded newer image for hello-world:latest

Hello from Docker!
This message shows that your installation appears to be working correctly.
```

(В этой лабораторной все `docker`-команды в скриптах запускались через
`sudo`, так как добавление пользователя в группу `docker` требует новой
сессии логина, чего не происходит в рамках одного SSH-соединения.)

### 1. Загрузка файлов на VM

Файлы (`deploy.sh`, `deploy-ssl.sh`, `generate_cert.sh`, `renew_cert.sh`,
`nginx/`, `nginx-ssl/`) загружены на `devops-lab01` в `~/lab7-docker/` через
`paramiko` SFTP (`vms/devops-lab01-ssh/setup_lab7.py`):

```
$ python setup_lab7.py
uploaded /home/andrey/lab7-docker/deploy.sh
uploaded /home/andrey/lab7-docker/deploy-ssl.sh
uploaded /home/andrey/lab7-docker/generate_cert.sh
uploaded /home/andrey/lab7-docker/renew_cert.sh
uploaded /home/andrey/lab7-docker/nginx/dockerfile
uploaded /home/andrey/lab7-docker/nginx/index.html
uploaded /home/andrey/lab7-docker/nginx/nginx-conf/nginx.conf
uploaded /home/andrey/lab7-docker/nginx-ssl/dockerfile
uploaded /home/andrey/lab7-docker/nginx-ssl/index.html
uploaded /home/andrey/lab7-docker/nginx-ssl/nginx-conf/nginx-ssl.conf
### tree ===
./deploy.sh
./deploy-ssl.sh
./generate_cert.sh
./nginx/dockerfile
./nginx/index.html
./nginx/nginx-conf/nginx.conf
./nginx-ssl/dockerfile
./nginx-ssl/index.html
./nginx-ssl/nginx-conf/nginx-ssl.conf
./renew_cert.sh
```

### 2. Основное задание — реальный запуск `deploy.sh`

```
$ cd /home/andrey/lab7-docker && sudo bash deploy.sh
Error response from daemon: No such container: nginx-lab7-cont      # (первый запуск - контейнера еще нет, это ожидаемо)
Sending build context to Docker daemon  4.608kB
Step 1/6 : FROM nginx
latest: Pulling from library/nginx
Status: Downloaded newer image for nginx:latest
Step 2/6 : ADD ./index.html /var/www/html/index.html
Step 3/6 : ADD ./nginx-conf/nginx.conf /etc/nginx/conf.d/default.conf
Step 4/6 : RUN /usr/sbin/nginx -t
nginx: configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
Step 5/6 : STOPSIGNAL SIGTERM
Step 6/6 : CMD ["nginx", "-g", "daemon off;"]
Successfully built 1241733c4320
Successfully tagged devops/nginx-lab7:latest

CONTAINER ID   IMAGE               COMMAND                  STATUS                 PORTS                                       NAMES
4309d1a6ab18   devops/nginx-lab7   "/docker-entrypoint.…"   Up Less than a second  0.0.0.0:54321->80/tcp, [::]:54321->80/tcp  nginx-lab7-cont

<!DOCTYPE html>
<html>
<head>
<title>DevOps Lab 07 - Docker basics</title>
</head>
<body>
<h1>Привет из Docker-контейнера!</h1>
<p>Andrey Kosberg — DevOps Course, Lab 07: Docker basics.</p>
<p>Nginx работает внутри контейнера, порт проброшен снаружи на 54321.</p>
</body>
</html>

/docker-entrypoint.sh: Configuration complete; ready for start up
2026/10/27 06:54:29 [notice] 1#1: using the "epoll" event method
2026/10/27 06:54:29 [notice] 1#1: nginx/1.31.8
2026/10/27 06:54:29 [notice] 1#1: built by gcc 14.2.0 (Debian 14.2.0-19)
2026/10/27 06:54:29 [notice] 1#1: OS: Linux 6.8.0-147-generic
2026/10/27 06:54:29 [notice] 1#1: start worker processes
172.17.0.1 - - [27/Oct/2026:06:54:34 +0000] "GET / HTTP/1.1" 200 346 "-" "curl/8.5.0" "-"
```

Контейнер реально поднят, `curl 127.0.0.1:54321` отдаёт настоящую HTML-страницу,
а строка `GET / HTTP/1.1" 200 346 ... "curl/8.5.0"` в `docker logs` — это
реальный access-log именно этого curl-запроса.

### 3. Доп. задание — реальный запуск `deploy-ssl.sh`

```
$ cd /home/andrey/lab7-docker && sudo bash deploy-ssl.sh
Сертификат сгенерирован:
  /home/andrey/lab7-docker/ssl/server.crt
  /home/andrey/lab7-docker/ssl/server.key
subject=C = RU, ST = Moscow, L = Moscow, O = DevOpsLab, OU = Lab07, CN = nginx-lab7.local
notBefore=Oct 27 06:54:51 2026 GMT
notAfter=Oct 27 06:54:51 2027 GMT

Error response from daemon: No such container: nginx-lab7-ssl-cont   # первый запуск, ожидаемо
Step 1/5 : FROM nginx
Step 2/5 : ADD ./index.html /var/www/html/index.html
Step 3/5 : ADD ./nginx-conf/nginx-ssl.conf /etc/nginx/conf.d/default.conf
Step 4/5 : STOPSIGNAL SIGTERM
Step 5/5 : CMD ["nginx", "-g", "daemon off;"]
Successfully built 47041604bb1d
Successfully tagged devops/nginx-lab7-ssl:latest

CONTAINER ID   IMAGE                   COMMAND                  STATUS    PORTS
40d6b6d9caea   devops/nginx-lab7-ssl   "/docker-entrypoint.…"   Up        80/tcp, 0.0.0.0:54443->443/tcp, [::]:54443->443/tcp  nginx-lab7-ssl-cont

<!DOCTYPE html>
<html>
<head>
<title>DevOps Lab 07 - Docker HTTPS (bonus)</title>
</head>
<body>
<h1>Привет по HTTPS!</h1>
<p>Andrey Kosberg — DevOps Course, Lab 07, доп. задание: nginx + самоподписанный SSL-сертификат.</p>
<p>Сертификат проброшен внутрь контейнера через volume mapping.</p>
</body>
</html>

2026/10/27 06:54:55 [notice] 1#1: start worker process 28
172.17.0.1 - - [27/Oct/2026:06:55:00 +0000] "GET / HTTP/1.1" 200 393 "-" "curl/8.5.0" "-"
```

Проверка настоящего TLS-хендшейка (`curl -vk`):

```
$ curl -vk https://127.0.0.1:54443
* TLSv1.3 (OUT), TLS handshake, Client hello (1)
* TLSv1.3 (IN), TLS handshake, Server hello (2)
* TLSv1.3 (IN), TLS handshake, Certificate (11)
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / X25519 / RSASSA-PSS
* Server certificate:
*  subject: C=RU; ST=Moscow; L=Moscow; O=DevOpsLab; OU=Lab07; CN=nginx-lab7.local
*  SSL certificate verify result: self-signed certificate (18), continuing anyway.
> GET / HTTP/1.1
```

Соединение действительно шифруется по TLS 1.3, сертификат — наш
самоподписанный (поэтому curl и предупреждает "self-signed", это ожидаемо и
корректно для теста без публичного CA).

### 4. Доказательство работы `renew_cert.sh` (пересоздание + reload "внутрь докера")

```
$ md5sum ssl/server.crt
4c7821eb230a896617adaabbd269135e  ssl/server.crt

$ sudo bash renew_cert.sh nginx-lab7-ssl-cont
Сертификат сгенерирован: .../server.crt
subject=... notBefore=Oct 27 06:55:12 2026 GMT
2026/10/27 06:55:12 [notice] 30#30: signal process started
Сертификат обновлён, nginx в контейнере nginx-lab7-ssl-cont перечитал конфигурацию (reload).

$ md5sum ssl/server.crt
0ef9084525ff07a42c842f37517c6468  ssl/server.crt     # хэш изменился - сертификат действительно новый

$ docker logs -n 15 nginx-lab7-ssl-cont
2026/10/27 06:55:12 [notice] 29#29: gracefully shutting down
2026/10/27 06:55:12 [notice] 28#28: gracefully shutting down
2026/10/27 06:55:12 [notice] 1#1: worker process 29 exited with code 0
2026/10/27 06:55:12 [notice] 1#1: worker process 28 exited with code 0
# ...новые worker-процессы 36, 37 запустились с новым конфигом

$ echo | openssl s_client -connect 127.0.0.1:54443 2>/dev/null | \
    openssl x509 -noout -fingerprint -sha256 -dates
sha256 Fingerprint=26:10:62:86:50:69:6C:5C:BD:E6:97:A2:25:04:A4:36:28:F4:B5:74:55:2E:F8:07:82:BB:6F:02:63:38:98:C9
notBefore=Oct 27 06:55:12 2026 GMT
notAfter=Oct 27 06:55:12 2027 GMT

$ docker exec nginx-lab7-ssl-cont cat /etc/nginx/ssl/server.crt | \
    openssl x509 -noout -fingerprint -sha256
sha256 Fingerprint=26:10:62:86:50:69:6C:5C:BD:E6:97:A2:25:04:A4:36:28:F4:B5:74:55:2E:F8:07:82:BB:6F:02:63:38:98:C9
```

Отпечаток сертификата, который реально отдаёт живой TLS-сервер
(`openssl s_client -connect ...`), **совпадает** с отпечатком **нового**
файла сертификата внутри контейнера (`docker exec ... cat /etc/nginx/ssl/server.crt`)
и с отпечатком файла на хосте после `renew_cert.sh` — то есть `nginx -s reload`
внутри докера реально подхватил новый сертификат **без пересоздания
контейнера** (контейнер `nginx-lab7-ssl-cont` всё это время работал без
перезапуска, что видно по неизменному `CONTAINER ID`).

## Нюансы и наблюдения

1. **`RUN nginx -t` на этапе сборки — только для основного образа.** Для
   образа с HTTPS (`nginx-ssl/dockerfile`) такой строки нет: на момент
   `docker build` сертификата ещё не существует (он появится только через
   volume при `docker run`), поэтому `nginx -t` на этом этапе гарантированно
   завалился бы с ошибкой `cannot load certificate`. Это осознанное решение,
   а не недосмотр — закомментировано прямо в Dockerfile.

2. **`docker` без `sudo` в рамках одной SSH-сессии не работает**, даже после
   `usermod -aG docker andrey` — новая группа применяется только к новым
   сессиям логина (новый `su -`/новый SSH-коннект/перелогин). Поэтому все
   команды в этой лабораторной явно выполнялись через `sudo`, в том числе и
   внутри самих шелл-скриптов (`sudo bash deploy.sh`), а не напрямую `docker`.

3. **`deploy.sh`/`deploy-ssl.sh` написаны как идемпотентные** — при первом
   запуске `docker stop`/`docker rm` честно выводят `Error response from
   daemon: No such container: ...`, но это не аварийная ошибка, а ожидаемое
   поведение: скрипты не содержат `set -e`, поэтому выполнение спокойно идёт
   дальше к `docker build`/`docker run`. При повторном запуске (например,
   после изменения `index.html`) старый контейнер будет корректно снесён и
   пересобран.

4. **Volume mapping, а не `ADD`/`COPY` сертификата** — это ключевое отличие
   доп.задания от основного. Если бы сертификат копировался в образ через
   `ADD`, то каждое обновление сертификата требовало бы пересборки образа и
   пересоздания контейнера. Монтирование папки `ssl/` как volume позволяет
   обновлять сертификат "на лету": файл на хосте меняется — файл внутри
   контейнера меняется мгновенно (это одна и та же inode через bind mount),
   а `nginx -s reload` просит nginx просто перечитать файлы заново.

5. **`docker exec <container> nginx -s reload`** — именно эта команда и есть
   "команда nginx на перечитывание сертификата", о которой просит доп.задание.
   `nginx -s reload` отправляет мастер-процессу nginx внутри контейнера
   сигнал `SIGHUP`: мастер проверяет новый конфиг, запускает новые
   worker-процессы с новым конфигом/сертификатом и штатно (`gracefully`)
   останавливает старые — без даунтайма и без пересоздания контейнера
   (это видно в `docker logs`: `gracefully shutting down` / `worker process N
   exited with code 0`, при этом `CONTAINER ID` не меняется).

6. **Самоподписанный сертификат** закономерно помечается curl'ом как
   `self-signed certificate (18), continuing anyway` — для учебного HTTPS
   без публичного CA это ожидаемо и корректно; `curl -k`/`openssl s_client`
   используются намеренно, чтобы проверить именно шифрование и факт
   обновления сертификата, а не цепочку доверия CA.

7. **`.gitignore` исключает сами файлы сертификата** (`ssl/*.crt`,
   `ssl/*.key`) — они регенерируются скриптом `generate_cert.sh` и не должны
   лежать в репозитории постоянно (даже несмотря на то, что это учебный
   самоподписанный сертификат без реальной ценности, это общая хорошая
   практика — секреты/ключи не коммитятся).

8. **Два разных порта для двух контейнеров** — `54321` (HTTP, основное
   задание) и `54443` (HTTPS, доп.задание). Оба контейнера (`nginx-lab7-cont`
   и `nginx-lab7-ssl-cont`) были запущены и проверены одновременно, без
   конфликтов портов — это подтверждает, что задания не мешают друг другу
   и могут работать на одном хосте параллельно.

## Скриншоты

Расположены в `screenshots/` (сгенерированы на основе реального вывода команд
выше, скрипт `vms/devops-lab01-ssh/make_screenshots7.py`):

1. `01-docker-install-hello-world.png` — установка Docker + `docker run hello-world`
2. `02-dockerfile-structure.png` — структура проекта + `nginx/dockerfile`
3. `03-deploy-sh.png` — содержимое `deploy.sh`
4. `04-deploy-run-real.png` — реальный запуск `deploy.sh`: сборка образа, `docker ps`, `curl`
5. `05-docker-logs-main.png` — `docker logs` основного контейнера (реальный access log)
6. `06-ssl-scripts.png` — `generate_cert.sh` + `deploy-ssl.sh` (volume mapping сертификата)
7. `07-deploy-ssl-run-real.png` — реальный запуск `deploy-ssl.sh` + TLS-хендшейк
8. `08-renew-cert-reload.png` — `renew_cert.sh`: смена хэша сертификата + подтверждение reload
