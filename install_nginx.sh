#!/bin/bash
# Подключение общих функций и цветов (если доступны)
if [ -f "/opt/remnasetup/scripts/common/colors.sh" ]; then
    source "/opt/remnasetup/scripts/common/colors.sh"
else
    # Определение базовых цветов, если файл недоступен
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    
    info() { echo -e "${BLUE}[INFO]${NC} $1"; }
    success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
    warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
    error() { echo -e "${RED}[ERROR]${NC} $1"; }
    question() { echo -en "${YELLOW}[?]${NC} $1 "; }
fi

if [ -f "/opt/remnasetup/scripts/common/functions.sh" ]; then
    source "/opt/remnasetup/scripts/common/functions.sh"
fi

# Проверка запуска от имени root
if [ "$EUID" -ne 0 ]; then
    error "Этот скрипт должен быть запущен от имени root"
    exit 1
fi

check_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        info "Nginx уже установлен"
        while true; do
            question "Хотите скорректировать конфигурацию Nginx? (y/n):"
            read -r UPDATE_CONFIG
            if [[ "$UPDATE_CONFIG" == "y" || "$UPDATE_CONFIG" == "Y" ]]; then
                return 0
            elif [[ "$UPDATE_CONFIG" == "n" || "$UPDATE_CONFIG" == "N" ]]; then
                info "Конфигурация Nginx останется без изменений"
                read -n 1 -s -r -p "Нажмите любую клавишу для возврата в меню..."
                exit 0
            else
                warn "Пожалуйста, введите только 'y' или 'n'"
            fi
        done
    fi
    return 0
}

install_nginx() {
    info "Установка Nginx..."
    apt update -y
    apt install -y nginx
    
    # Включение и запуск сервиса
    systemctl enable nginx
    systemctl start nginx
    
    success "Nginx успешно установлен!"
}

install_certbot() {
    info "Установка Certbot для получения SSL-сертификатов..."
    apt update -y
    apt install -y certbot python3-certbot-nginx
    success "Certbot успешно установлен!"
}

get_certificates() {
    info "Получение SSL-сертификатов для домена $DOMAIN..."
    
    # Проверка доступности домена
    if ! ping -c 1 $DOMAIN &> /dev/null; then
        warn "Домен $DOMAIN не разрешается. Убедитесь, что DNS настроен правильно."
        question "Продолжить получение сертификата? (y/n):"
        read -r CONTINUE_CERT
        if [[ "$CONTINUE_CERT" != "y" && "$CONTINUE_CERT" != "Y" ]]; then
            info "Получение сертификатов отменено"
            return 1
        fi
    fi
    
    # Получение сертификата с помощью Certbot
    if certbot --nginx -d $DOMAIN --email $EMAIL --agree-tos --non-interactive --redirect; then
        success "SSL-сертификаты для $DOMAIN успешно получены!"
        
        # Получение путей к сертификатам для дальнейшего использования
        SSL_CERT_PATH=$(find /etc/letsencrypt/live -name fullchain.pem | grep $DOMAIN)
        SSL_KEY_PATH=$(find /etc/letsencrypt/live -name privkey.pem | grep $DOMAIN)
        
        if [[ -n "$SSL_CERT_PATH" && -n "$SSL_KEY_PATH" ]]; then
            info "Сертификаты найдены в $SSL_CERT_PATH и $SSL_KEY_PATH"
        else
            warn "Не удалось автоматически определить пути к сертификатам"
            question "Введите путь к fullchain.pem:"
            read -r SSL_CERT_PATH
            
            question "Введите путь к privkey.pem:"
            read -r SSL_KEY_PATH
        fi
        
        return 0
    else
        error "Не удалось получить SSL-сертификаты. Проверьте ошибки и настройки домена."
        return 1
    fi
}

setup_renewal_cron() {
    info "Настройка автоматического обновления сертификатов..."
    
    # Проверка наличия записи в crontab
    if ! crontab -l | grep -q "certbot renew"; then
        # Создание задачи в cron для обновления сертификатов дважды в день (рекомендовано Let's Encrypt)
        (crontab -l 2>/dev/null; echo "0 0,12 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
        success "Задача автоматического обновления сертификатов добавлена в cron!"
    else
        info "Задача обновления сертификатов уже существует в cron"
    fi
}

configure_nginx() {
    info "Настройка конфигурации Nginx..."
    
    # Создание основного конфигурационного файла
    cat > /etc/nginx/nginx.conf <<EOL
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
    # multi_accept on;
}

# Настройка для WebSocket и XHTTP
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

# SSL общие настройки
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;

ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4;

http {
    # Базовые настройки
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # MIME типы
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Логи
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # Включение gzip
    gzip on;
    gzip_disable "msie6";
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    # Включение виртуальных хостов
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}

# Stream секция для Unix socket и прокси
stream {
    # Unix socket для REALITY
    server {
        listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
        ssl_certificate "$SSL_CERT_PATH";
        ssl_certificate_key "$SSL_KEY_PATH";
        ssl_trusted_certificate "$SSL_CERT_PATH";
        
        proxy_pass 127.0.0.1:$MONITOR_PORT;
    }
    
    # Отклонение неизвестных соединений
    server {
        listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
        server_name _;
        ssl_reject_handshake on;
        return 444;
    }
    
    include /etc/nginx/stream.d/*.conf;
}
EOL

    # Создание директории для stream конфигураций
    mkdir -p /etc/nginx/stream.d

    # Создание виртуального хоста
    cat > /etc/nginx/sites-available/$DOMAIN.conf <<EOL
# Переадресация HTTP на HTTPS (будет настроено автоматически certbot)
server {
    listen 80;
    server_name $DOMAIN;
    
    # Корневая директория сайта
    root /var/www/site;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}

# HTTPS конфигурация будет дополнена certbot
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    # SSL сертификаты будут настроены certbot
    
    # Корневая директория сайта
    root /var/www/site;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
EOL

    # Если пользователь выбрал настройку XHTTP
    if [[ "$SETUP_XHTTP" == "y" || "$SETUP_XHTTP" == "Y" ]]; then
        cat >> /etc/nginx/sites-available/$DOMAIN.conf <<EOL
    
    # XHTTP nginx reverse proxy
      location /xhttppath/ {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        client_body_timeout 5m;
        grpc_read_timeout 315;
        grpc_send_timeout 5m;
        grpc_pass unix:/dev/shm/xrxh.socket;
        }

EOL
    fi

    # Если пользователь выбрал настройку gRPC
    if [[ "$SETUP_GRPC" == "y" || "$SETUP_GRPC" == "Y" ]]; then
        cat >> /etc/nginx/sites-available/$DOMAIN.conf <<EOL
    
    # gRPC Proxy
    location /$GRPC_PATH {
        grpc_pass grpc://127.0.0.1:$GRPC_PORT;
        grpc_set_header Host \$host;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
EOL
    fi

    # Закрытие серверного блока
    cat >> /etc/nginx/sites-available/$DOMAIN.conf <<EOL
}

# Сервер для обработки fallback при ошибке подписи в REALITY
server {
    listen $MONITOR_PORT;
    server_name $DOMAIN;
    
    # Этот сервер будет использоваться XRAY для fallback при неуспешной авторизации
    root /var/www/site;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOL

    # Создание символической ссылки для активации конфигурации
    ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
    
    # Удаление дефолтной конфигурации
    rm -f /etc/nginx/sites-enabled/default
    
    # Создание каталога /dev/shm, если он не существует
    mkdir -p /dev/shm
    chmod 777 /dev/shm
    
    # Проверка конфигурации
    if nginx -t; then
        systemctl reload nginx
        success "Конфигурация Nginx успешно обновлена!"
    else
        error "Ошибка в конфигурации Nginx. Пожалуйста, проверьте настройки."
    fi
}


setup_site() {
    info "Настройка сайта..."
    
    # Создание директории для сайта
    mkdir -p /var/www/site
    
    # Если есть шаблон сайта в репозитории
    if [ -d "/opt/remnasetup/data/site" ]; then
        cp -r "/opt/remnasetup/data/site/"* /var/www/site/
    else
        # Создание простой страницы-заглушки
        cat > /var/www/site/index.html <<EOL
<!doctype html>
<html lang="ru">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Сервер $DOMAIN</title>
    <style>
      body {
        font-family: Arial, sans-serif;
        display: flex;
        justify-content: center;
        align-items: center;
        height: 100vh;
        margin: 0;
        background-color: #f5f5f5;
      }
      .container {
        text-align: center;
        padding: 2rem;
        border-radius: 8px;
        background-color: white;
        box-shadow: 0 4px 8px rgba(0, 0, 0, 0.1);
      }
      h1 {
        color: #333;
      }
    </style>
  </head>
  <body>
    <div class="container">
      <h1>$DOMAIN</h1>
      <p>Сервер успешно настроен и работает.</p>
    </div>
  </body>
</html>
EOL
    fi
    
    # Установка прав доступа
    chown -R www-data:www-data /var/www/site
    chmod -R 755 /var/www/site
    
    success "Сайт настроен успешно!"
}

main() {
    if check_nginx; then
        info "Начинаем настройку Nginx..."
        
        # Запрос доменного имени
        while true; do
            question "Введите доменное имя (например, example.com):"
            read -r DOMAIN
            if [[ -n "$DOMAIN" ]]; then
                break
            fi
            warn "Домен не может быть пустым. Пожалуйста, введите значение."
        done
        
        # Запрос email для сертификатов Let's Encrypt
        while true; do
            question "Введите email для регистрации SSL-сертификатов:"
            read -r EMAIL
            if [[ -n "$EMAIL" && "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                break
            fi
            warn "Введите корректный email-адрес."
        done
        
        # Запрос порта для fallback мониторинга (как в Caddy)
        while true; do
            question "Введите порт для fallback мониторинга (по умолчанию 8443):"
            read -r MONITOR_PORT
            MONITOR_PORT=${MONITOR_PORT:-8443}
            if [[ "$MONITOR_PORT" =~ ^[0-9]+$ ]]; then
                break
            fi
            warn "Порт должен быть числом."
        done
        
        # Запрос порта для REALITY
        while true; do
            question "Введите порт для REALITY (по умолчанию 443):"
            read -r REALITY_PORT
            REALITY_PORT=${REALITY_PORT:-443}
            if [[ "$REALITY_PORT" =~ ^[0-9]+$ ]]; then
                break
            fi
            warn "Порт должен быть числом."
        done
        
        # Запрос о настройке XHTTP
        question "Настроить XHTTP для прокси? (y/n):"
        read -r SETUP_XHTTP
        
        if [[ "$SETUP_XHTTP" == "y" || "$SETUP_XHTTP" == "Y" ]]; then
            # Запрос пути для XHTTP
            question "Введите путь для XHTTP (по умолчанию xhttppath):"
            read -r XHTTP_PATH
            XHTTP_PATH=${XHTTP_PATH:-xhttppath}
        fi
        
        # Запрос о настройке gRPC
        question "Настроить gRPC прокси? (y/n):"
        read -r SETUP_GRPC
        
        if [[ "$SETUP_GRPC" == "y" || "$SETUP_GRPC" == "Y" ]]; then
            # Запрос пути и порта для gRPC
            question "Введите путь для gRPC (по умолчанию VLSpdG9k):"
            read -r GRPC_PATH
            GRPC_PATH=${GRPC_PATH:-VLSpdG9k}
            
            question "Введите порт для gRPC (по умолчанию 2023):"
            read -r GRPC_PORT
            GRPC_PORT=${GRPC_PORT:-2023}
        fi
        
        # Установка необходимых компонентов
        if ! command -v nginx >/dev/null 2>&1; then
            install_nginx
        fi
        
        install_certbot
        setup_site
        
        if get_certificates; then
            setup_renewal_cron
            configure_nginx
        else
            warn "Продолжение настройки без SSL-сертификатов"
            configure_nginx
        fi
        
        success "Установка и настройка Nginx завершена успешно!"
        
        info "Важные настройки для XRAY:"
        echo "1. Для REALITY используйте dest: $MONITOR_PORT"
        echo "2. Для XHTTP с Nginx используйте unix-сокет: /dev/shm/xrxh.socket"
        echo "3. Для Fallback (для неподписанных запросов) настроен порт: $MONITOR_PORT"
    fi
    
    read -n 1 -s -r -p "Нажмите любую клавишу для выхода..."
    exit 0
}

main
