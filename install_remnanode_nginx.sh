#!/bin/bash

SCRIPT_VERSION="1.0.0"
DIR_REMNAWAVE="/usr/local/remnawave_reverse/"

COLOR_RESET="\033[0m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_WHITE="\033[1;37m"
COLOR_RED="\033[1;31m"
COLOR_GRAY='\033[0;90m'

question() {
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}$*${COLOR_RESET}"
}

reading() {
    read -rp " $(question "$1")" "$2"
}

error() {
    echo -e "${COLOR_RED}$*${COLOR_RESET}"
    exit 1
}

check_os() {
    if ! grep -q "bullseye" /etc/os-release && ! grep -q "bookworm" /etc/os-release && ! grep -q "jammy" /etc/os-release && ! grep -q "noble" /etc/os-release; then
        error "Поддержка только Debian 11/12 и Ubuntu 22.04/24.04"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Скрипт нужно запускать с правами root"
    fi
}

spinner() {
  local pid=$1
  local text=$2

  export LC_ALL=en_US.UTF-8
  export LANG=en_US.UTF-8

  local spinstr='▉▊▋▌▍▎▏▎▍▌▋▊▉'
  local text_code="$COLOR_GREEN"
  local bg_code=""
  local effect_code="\033[1m"
  local delay=0.1
  local reset_code="$COLOR_RESET"

  printf "${effect_code}${text_code}${bg_code}%s${reset_code}" "$text" > /dev/tty

  while kill -0 "$pid" 2>/dev/null; do
    for (( i=0; i<${#spinstr}; i++ )); do
      printf "\r${effect_code}${text_code}${bg_code}[%s] %s${reset_code}" "$(echo -n "${spinstr:$i:1}")" "$text" > /dev/tty
      sleep $delay
    done
  done

  printf "\r\033[K" > /dev/tty
}

extract_domain() {
    local SUBDOMAIN=$1
    echo "$SUBDOMAIN" | awk -F'.' '{if (NF > 2) {print $(NF-1)"."$NF} else {print $0}}'
}

check_domain() {
    local domain="$1"
    local show_warning="${2:-true}"
    local allow_cf_proxy="${3:-true}"

    local domain_ip=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    local server_ip=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org || curl -s -4 ipinfo.io/ip)

    if [ -z "$domain_ip" ] || [ -z "$server_ip" ]; then
        if [ "$show_warning" = true ]; then
            echo -e "${COLOR_YELLOW}ВНИМАНИЕ:${COLOR_RESET}"
            echo -e "${COLOR_RED}Не удалось определить IP-адрес домена или сервера.${COLOR_RESET}"
            printf "${COLOR_YELLOW}Убедитесь, что домен %s правильно настроен и указывает на этот сервер (%s).${COLOR_RESET}\n" "$domain" "$server_ip"
            reading "Введите 'y' для продолжения или 'n' для выхода (y/n):" confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                return 2
            fi
        fi
        return 1
    fi

    local cf_ranges=$(curl -s https://www.cloudflare.com/ips-v4)
    local cf_array=()
    if [ -n "$cf_ranges" ]; then
        IFS=$'\n' read -r -d '' -a cf_array <<<"$cf_ranges"
    fi

    local ip_in_cloudflare=false
    local IFS='.'
    read -r a b c d <<<"$domain_ip"
    local domain_ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))

    if [ ${#cf_array[@]} -gt 0 ]; then
        for cidr in "${cf_array[@]}"; do
            if [[ -z "$cidr" ]]; then
                continue
            fi
            local network=$(echo "$cidr" | cut -d'/' -f1)
            local mask=$(echo "$cidr" | cut -d'/' -f2)
            read -r a b c d <<<"$network"
            local network_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
            local mask_bits=$(( 32 - mask ))
            local range_size=$(( 1 << mask_bits ))
            local min_ip_int=$network_int
            local max_ip_int=$(( network_int + range_size - 1 ))

            if [ "$domain_ip_int" -ge "$min_ip_int" ] && [ "$domain_ip_int" -le "$max_ip_int" ]; then
                ip_in_cloudflare=true
                break
            fi
        done
    fi

    if [ "$domain_ip" = "$server_ip" ]; then
        return 0
    elif [ "$ip_in_cloudflare" = true ]; then
        if [ "$allow_cf_proxy" = true ]; then
            return 0
        else
            if [ "$show_warning" = true ]; then
                echo -e "${COLOR_YELLOW}ВНИМАНИЕ:${COLOR_RESET}"
                printf "${COLOR_RED}Домен %s указывает на IP Cloudflare (%s).${COLOR_RESET}\n" "$domain" "$domain_ip"
                echo -e "${COLOR_YELLOW}Проксирование Cloudflare недопустимо для selfsteal домена. Отключите проксирование (переключите в режим 'DNS Only').${COLOR_RESET}"
                reading "Введите 'y' для продолжения или 'n' для выхода (y/n):" confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    return 1
                else
                    return 2
                fi
            fi
            return 1
        fi
    else
        if [ "$show_warning" = true ]; then
            echo -e "${COLOR_YELLOW}ВНИМАНИЕ:${COLOR_RESET}"
            printf "${COLOR_RED}Домен %s указывает на IP-адрес %s, который отличается от IP этого сервера (%s).${COLOR_RESET}\n" "$domain" "$domain_ip" "$server_ip"
            echo -e "${COLOR_YELLOW}Для корректной работы домен должен указывать на текущий сервер.${COLOR_RESET}"
            reading "Введите 'y' для продолжения или 'n' для выхода (y/n):" confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                return 1
            else
                return 2
            fi
        fi
        return 1
    fi

    return 0
}

check_certificates() {
    local DOMAIN=$1

    if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
            echo -e "${COLOR_GREEN}Сертификаты найдены в /etc/letsencrypt/live/${COLOR_RESET}$DOMAIN"
            return 0
        fi
    fi
    return 1
}

is_wildcard_cert() {
    local domain=$1
    local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"

    if [ ! -f "$cert_path" ]; then
        return 1
    fi

    if openssl x509 -noout -text -in "$cert_path" | grep -q "\*\.$domain"; then
        return 0
    else
        return 1
    fi
}

check_cert_expiry() {
    local domain=$1
    local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"

    if [ ! -f "$cert_path" ]; then
        echo -e "${COLOR_RED}Сертификат не найден${COLOR_RESET}"
        return 1
    fi

    local expiry_date=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2)
    local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null)
    local current_epoch=$(date +%s)

    if [ -z "$expiry_epoch" ]; then
        echo -e "${COLOR_RED}Ошибка разбора сертификата${COLOR_RESET}"
        return 1
    fi

    local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))

    echo "$days_left"
    return 0
}

get_certificates() {
    local DOMAIN=$1
    local CERT_METHOD=$2
    local LETSENCRYPT_EMAIL=$3
    local BASE_DOMAIN=$(extract_domain "$DOMAIN")
    local WILDCARD_DOMAIN="*.$BASE_DOMAIN"

    printf "${COLOR_YELLOW}Генерация сертификатов для %s...${COLOR_RESET}\n" "$DOMAIN"

    case $CERT_METHOD in
        1)
            reading "Введите Cloudflare API токен:" CLOUDFLARE_API_KEY
            reading "Введите Cloudflare email:" CLOUDFLARE_EMAIL

            check_api() {
                local attempts=3
                local attempt=1

                while [ $attempt -le $attempts ]; do
                    if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
                        api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones --header "Authorization: Bearer ${CLOUDFLARE_API_KEY}" --header "Content-Type: application/json")
                    else
                        api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones --header "X-Auth-Key: ${CLOUDFLARE_API_KEY}" --header "X-Auth-Email: ${CLOUDFLARE_EMAIL}" --header "Content-Type: application/json")
                    fi

                    if echo "$api_response" | grep -q '"success":true'; then
                        echo -e "${COLOR_GREEN}Cloudflare API токен валиден${COLOR_RESET}"
                        return 0
                    else
                        echo -e "${COLOR_RED}Попытка $attempt из $attempts: Cloudflare API токен невалиден${COLOR_RESET}"
                        if [ $attempt -lt $attempts ]; then
                            reading "Введите Cloudflare API токен:" CLOUDFLARE_API_KEY
                            reading "Введите Cloudflare email:" CLOUDFLARE_EMAIL
                        fi
                        attempt=$((attempt + 1))
                    fi
                done
                error "Cloudflare API токен невалиден после $attempts попыток"
            }

            check_api

            mkdir -p ~/.secrets/certbot
            if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_api_token = $CLOUDFLARE_API_KEY
EOL
            else
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOL
            fi
            chmod 600 ~/.secrets/certbot/cloudflare.ini

            certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$BASE_DOMAIN" \
                -d "$WILDCARD_DOMAIN" \
                --email "$CLOUDFLARE_EMAIL" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1
            ;;
        2)
            echo -e "${COLOR_YELLOW}Используется метод ACME HTTP-01 (без wildcard)${COLOR_RESET}"
            ufw allow 80/tcp comment 'HTTP for ACME challenge' > /dev/null 2>&1

            certbot certonly \
                --standalone \
                -d "$DOMAIN" \
                --email "$LETSENCRYPT_EMAIL" \
                --agree-tos \
                --non-interactive \
                --http-01-port 80 \
                --key-type ecdsa \
                --elliptic-curve secp384r1

            ufw delete allow 80/tcp > /dev/null 2>&1
            ufw reload > /dev/null 2>&1
            ;;
        *)
            echo -e "${COLOR_RED}Неверный метод генерации сертификата${COLOR_RESET}"
            exit 1
            ;;
    esac

    if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        echo "renew_hook = sh -c 'cd /opt/remnawave && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx'" >> /etc/letsencrypt/renewal/$DOMAIN.conf
        crontab -l 2>/dev/null | { cat; echo "0 5 1 */2 * /usr/bin/certbot renew --quiet"; } | crontab -
    else
        echo -e "${COLOR_RED}Ошибка генерации сертификата${COLOR_RESET}"
        exit 1
    fi
}

randomhtml() {
    cd /opt/ || { echo "Ошибка распаковки архива"; exit 1; }

    rm -f main.zip 2>/dev/null
    rm -rf simple-web-templates-main/ sni-templates-main/ 2>/dev/null

    echo -e "${COLOR_YELLOW}Установка случайного шаблона для маскировочного сайта${COLOR_RESET}"
    sleep 1
    spinner $$ "Пожалуйста, подождите..." &
    spinner_pid=$!

    template_urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
        "https://github.com/SmallPoppa/sni-templates/archive/refs/heads/main.zip"
    )
    
    selected_url=${template_urls[$RANDOM % ${#template_urls[@]}]}

    while ! wget -q --timeout=30 --tries=10 --retry-connrefused "$selected_url"; do
        echo "Ошибка загрузки, повторная попытка..."
        sleep 3
    done

    unzip -o main.zip &>/dev/null || { echo "Ошибка распаковки архива"; exit 0; }
    rm -f main.zip

    if [[ "$selected_url" == *"eGamesAPI"* ]]; then
        cd simple-web-templates-main/ || { echo "Ошибка распаковки архива"; exit 0; }
        rm -rf assets ".gitattributes" "README.md" "_config.yml" 2>/dev/null
    else
        cd sni-templates-main/ || { echo "Ошибка распаковки архива"; exit 0; }
        rm -rf assets "README.md" "index.html" 2>/dev/null
    fi

    mapfile -t templates < <(find . -maxdepth 1 -type d -not -path . | sed 's|./||')

    RandomHTML="${templates[$RANDOM % ${#templates[@]}]}"

    if [[ "$selected_url" == *"SmallPoppa"* && "$RandomHTML" == "503 error pages" ]]; then
        cd "$RandomHTML" || { echo "Ошибка распаковки архива"; exit 0; }
        versions=("v1" "v2")
        RandomVersion="${versions[$RANDOM % ${#versions[@]}]}"
        RandomHTML="$RandomHTML/$RandomVersion"
        cd ..
    fi

    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    printf "\r\033[K" > /dev/tty

    echo "Выбран шаблон: ${RandomHTML}"

    if [[ -d "${RandomHTML}" ]]; then
        if [[ ! -d "/var/www/html/" ]]; then
            mkdir -p "/var/www/html/" || { echo "Не удалось создать /var/www/html/"; exit 1; }
        fi
        rm -rf /var/www/html/*
        cp -a "${RandomHTML}"/. "/var/www/html/"
        echo "Шаблон скопирован в /var/www/html/"
    else
        echo "Ошибка распаковки архива" && exit 1
    fi

    cd /opt/
    rm -rf simple-web-templates-main/ sni-templates-main/
}

install_packages() {
    echo -e "${COLOR_YELLOW}Установка необходимых пакетов...${COLOR_RESET}"
    apt-get update -y
    apt-get install -y ca-certificates curl jq ufw wget gnupg unzip nano dialog git certbot python3-certbot-dns-cloudflare unattended-upgrades locales dnsutils coreutils grep gawk

    if ! dpkg -l | grep -q '^ii.*cron '; then
        apt-get install -y cron
    fi

    if ! systemctl is-active --quiet cron; then
        systemctl start cron
    fi

    if ! systemctl is-enabled --quiet cron; then
        systemctl enable cron
    fi

    if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
        if grep -q "^# en_US.UTF-8 UTF-8" /etc/locale.gen; then
            sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        else
            echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
        fi
    fi
    locale-gen
    update-locale LANG=en_US.UTF-8

    if grep -q "Ubuntu" /etc/os-release; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | tee /etc/apt/keyrings/docker.asc > /dev/null
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    elif grep -q "Debian" /etc/os-release; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | tee /etc/apt/keyrings/docker.asc > /dev/null
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # UFW
    ufw --force reset
    ufw allow 22/tcp comment 'SSH'
    ufw allow 443/tcp comment 'HTTPS'
    ufw --force enable

    # Unattended-upgrade
    echo 'Unattended-Upgrade::Mail "root";' >> /etc/apt/apt.conf.d/50unattended-upgrades
    echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades
    systemctl restart unattended-upgrades

    mkdir -p ${DIR_REMNAWAVE}
    touch ${DIR_REMNAWAVE}install_packages
}

install_remnawave_node() {
    mkdir -p /opt/remnawave && cd /opt/remnawave

    reading "Введите selfsteal домен для ноды, который указали при при создании инбаунда:" SELFSTEAL_DOMAIN

    check_domain "$SELFSTEAL_DOMAIN" true false
    local domain_check_result=$?
    if [ $domain_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}Установка прервана пользователем${COLOR_RESET}"
        exit 1
    fi

    while true; do
        reading "Введите IP адрес панели, чтобы разрешить соединение между панелью и ноды:" PANEL_IP
        if echo "$PANEL_IP" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null && \
           [[ $(echo "$PANEL_IP" | tr '.' '\n' | wc -l) -eq 4 ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -vE '^[0-9]{1,3}$') ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -E '^(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2})$') ]]; then
            break
        else
            echo -e "${COLOR_RED}Введите корректный IP-адрес в формате X.X.X.X (например, 142.211.22.44)${COLOR_RESET}"
        fi
    done

    echo -n "$(question "Введите сертификат, полученный от панели, сохраняя строку SSL_CERT= (вставьте содержимое и 2 раза нажмите Enter):")"
    CERTIFICATE=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if [ -n "$CERTIFICATE" ]; then
                break
            fi
        else
            CERTIFICATE="$CERTIFICATE$line\n"
        fi
    done

    echo -e "${COLOR_YELLOW}Вы уверены, что сертификат правильный? (y/n):${COLOR_RESET}"
    read confirm
    echo

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${COLOR_RED}Установка прервана пользователем${COLOR_RESET}"
        exit 1
    fi

    cat > .env-node <<EOL
### APP ###
APP_PORT=2222

### XRAY ###
$(echo -e "$CERTIFICATE" | sed 's/\\n$//')
EOL

    SELFSTEAL_BASE_DOMAIN=$(extract_domain "$SELFSTEAL_DOMAIN")

    declare -A unique_domains
    unique_domains["$SELFSTEAL_BASE_DOMAIN"]=1

    cat > docker-compose.yml <<EOL
services:
  remnawave-nginx:
    image: nginx:1.26
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOL
}

# Функция для установки и настройки Tblocker
install_tblocker() {
    echo -e "${COLOR_YELLOW}Установка Tblocker...${COLOR_RESET}"
    
    # Проверка наличия remnanode
    if ! check_remnanode; then
        return 1
    fi
    
    # Создаем необходимые директории
    sudo mkdir -p /opt/tblocker
    sudo chmod -R 777 /opt/tblocker
    sudo mkdir -p /var/lib/toblock
    sudo chmod -R 777 /var/lib/toblock
    
    # Запрашиваем данные для конфигурации
    while true; do
        reading "Введите токен бота для Tblocker (создайте бота в @BotFather для оповещений):" ADMIN_BOT_TOKEN
        if [[ -n "$ADMIN_BOT_TOKEN" ]]; then
            break
        fi
        echo -e "${COLOR_RED}Токен бота не может быть пустым. Пожалуйста, введите значение.${COLOR_RESET}"
    done
    echo "ADMIN_BOT_TOKEN=$ADMIN_BOT_TOKEN" > /tmp/install_vars
    
    while true; do
        reading "Введите Telegram ID админа для Tblocker:" ADMIN_CHAT_ID
        if [[ -n "$ADMIN_CHAT_ID" ]]; then
            break
        fi
        echo -e "${COLOR_RED}Telegram ID админа не может быть пустым. Пожалуйста, введите значение.${COLOR_RESET}"
    done
    echo "ADMIN_CHAT_ID=$ADMIN_CHAT_ID" >> /tmp/install_vars
    
    reading "Укажите время блокировки пользователя (указывается значение в минутах, по умолчанию 10):" BLOCK_DURATION
    BLOCK_DURATION=${BLOCK_DURATION:-10}
    echo "BLOCK_DURATION=$BLOCK_DURATION" >> /tmp/install_vars
    
    # Проверка необходимости настройки вебхуков
    WEBHOOK_NEEDED="n"
    while true; do
        reading "Требуется настройка отправки вебхуков? (y/n):" WEBHOOK_NEEDED
        if [[ "$WEBHOOK_NEEDED" == "y" || "$WEBHOOK_NEEDED" == "Y" || "$WEBHOOK_NEEDED" == "n" || "$WEBHOOK_NEEDED" == "N" ]]; then
            break
        fi
        echo -e "${COLOR_RED}Пожалуйста, введите только 'y' или 'n'${COLOR_RESET}"
    done
    
    if [[ "$WEBHOOK_NEEDED" == "y" || "$WEBHOOK_NEEDED" == "Y" ]]; then
        while true; do
            reading "Укажите адрес вебхука (пример portal.domain.com/tblocker/webhook):" WEBHOOK_URL
            if [[ -n "$WEBHOOK_URL" ]]; then
                break
            fi
            echo -e "${COLOR_RED}Адрес вебхука не может быть пустым. Пожалуйста, введите значение.${COLOR_RESET}"
        done
        echo "WEBHOOK_URL=$WEBHOOK_URL" >> /tmp/install_vars
    fi
    
    # Установка Tblocker
    sudo su - << 'ROOT_EOF'
source /tmp/install_vars

curl -fsSL git.new/install -o /tmp/tblocker-install.sh || {
    echo -e "\033[1;31mОшибка: Не удалось скачать скрипт Tblocker.\033[0m"
    exit 1
}

printf "\n\n\n" | bash /tmp/tblocker-install.sh || {
    echo -e "\033[1;31mОшибка: Не удалось выполнить скрипт Tblocker.\033[0m"
    exit 1
}

rm /tmp/tblocker-install.sh

if [[ -f /opt/tblocker/config.yaml ]]; then
    sed -i 's|^LogFile:.*$|LogFile: "/var/lib/toblock/access.log"|' /opt/tblocker/config.yaml
    sed -i 's|^UsernameRegex:.*$|UsernameRegex: "email: (\\\\S+)"|' /opt/tblocker/config.yaml
    sed -i "s|^AdminBotToken:.*$|AdminBotToken: \"$ADMIN_BOT_TOKEN\"|" /opt/tblocker/config.yaml
    sed -i "s|^AdminChatID:.*$|AdminChatID: \"$ADMIN_CHAT_ID\"|" /opt/tblocker/config.yaml
    sed -i "s|^BlockDuration:.*$|BlockDuration: $BLOCK_DURATION|" /opt/tblocker/config.yaml

    if [[ "$WEBHOOK_NEEDED" == "y" || "$WEBHOOK_NEEDED" == "Y" ]]; then
        sed -i 's|^SendWebhook:.*$|SendWebhook: true|' /opt/tblocker/config.yaml
        sed -i "s|^WebhookURL:.*$|WebhookURL: \"https://$WEBHOOK_URL\"|" /opt/tblocker/config.yaml
    else
        sed -i 's|^SendWebhook:.*$|SendWebhook: false|' /opt/tblocker/config.yaml
    fi
else
    echo -e "\033[1;31mОшибка: Файл /opt/tblocker/config.yaml не найден.\033[0m"
    exit 1
fi

exit
ROOT_EOF

    # Перезапуск службы Tblocker
    sudo systemctl restart tblocker.service
    
    # Настройка crontab для очистки логов
    echo -e "${COLOR_YELLOW}Настройка crontab...${COLOR_RESET}"
    crontab -l > /tmp/crontab_tmp 2>/dev/null || true
    echo "0 * * * * truncate -s 0 /var/lib/toblock/access.log" >> /tmp/crontab_tmp
    echo "0 * * * * truncate -s 0 /var/lib/toblock/error.log" >> /tmp/crontab_tmp
    
    crontab /tmp/crontab_tmp
    rm /tmp/crontab_tmp
    
    # Остановка remnawave для подключения Tblocker
    cd /opt/remnawave
    sudo docker compose down
    
    # Обновление docker-compose.yml для подключения Tblocker
    if grep -q "volumes:" /opt/remnawave/docker-compose.yml && ! grep -q "/var/lib/toblock" /opt/remnawave/docker-compose.yml; then
        sed -i '/volumes:/a\      - \/var\/lib\/toblock:\/var\/lib\/toblock' /opt/remnawave/docker-compose.yml
    elif ! grep -q "volumes:" /opt/remnawave/docker-compose.yml; then
        sed -i '/remnanode:/a\    volumes:\n      - \/var\/lib\/toblock:\/var\/lib\/toblock' /opt/remnawave/docker-compose.yml
    fi

    
    sudo docker compose up -d
    echo -e "${COLOR_GREEN}Tblocker успешно установлен!${COLOR_RESET}"
}

# Функция для проверки наличия remnanode
check_remnanode() {
    if ! sudo docker ps -q --filter "name=remnanode" | grep -q .; then
        echo -e "${COLOR_RED}Remnanode не установлен. Сначала установите Remnanode.${COLOR_RESET}"
        return 1
    fi
    return 0
}

# Функция для установки WARP
install_warp() {
    echo -e "${COLOR_YELLOW}Установка WARP (WireProxy)...${COLOR_RESET}"
    
    # Проверка установлен ли уже WARP
    if command -v wireproxy >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}WARP (WireProxy) уже установлен${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Переустановка невозможна.${COLOR_RESET}"
        return 1
    fi
    
    # Запрос порта для WARP
    while true; do
        reading "Введите порт для WARP (1000-65535, по умолчанию 40000):" WARP_PORT
        WARP_PORT=${WARP_PORT:-40000}
        
        if [[ "$WARP_PORT" =~ ^[0-9]+$ ]] && [ "$WARP_PORT" -ge 1000 ] && [ "$WARP_PORT" -le 65535 ]; then
            break
        fi
        echo -e "${COLOR_RED}Порт должен быть числом от 1000 до 65535.${COLOR_RESET}"
    done
    
    # Проверка наличия expect и установка при необходимости
    if ! command -v expect >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}Устанавливается пакет expect для автоматизации установки WARP...${COLOR_RESET}"
        sudo apt update -y
        sudo apt install -y expect
    fi
    
    # Загрузка и запуск скрипта установки WARP
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O menu.sh
    chmod +x menu.sh
    
    # Автоматизация установки через expect
    expect <<EOF
spawn bash menu.sh w
expect "Choose:" { send "1\r" }
expect "Choose:" { send "1\r" }
expect "Please customize the Client port" { send "$WARP_PORT\r" }
expect "Choose:" { send "1\r" }
expect eof
EOF
    
    # Очистка временных файлов
    rm -f menu.sh
    echo -e "${COLOR_GREEN}WARP успешно установлен!${COLOR_RESET}"
}

add_tblocker_warp_menu() {
    # Проверим, установлен ли Remnanode
    if ! check_remnanode; then
        echo -e "${COLOR_YELLOW}Сначала завершите установку Remnanode, затем можно будет установить Tblocker и WARP${COLOR_RESET}"
        return
    fi

    echo -e "${COLOR_YELLOW}Хотите установить дополнительные компоненты?${COLOR_RESET}"
    echo -e "1. Установить Tblocker"
    echo -e "2. Установить WARP"
    echo -e "3. Установить оба компонента"
    echo -e "4. Продолжить без установки дополнительных компонентов"
    
    reading "Выберите опцию (1-4):" ADDITIONAL_OPTION
    
    case "$ADDITIONAL_OPTION" in
        1)
            install_tblocker
            ;;
        2)
            install_warp
            ;;
        3)
            install_tblocker
            install_warp
            ;;
        4)
            echo -e "${COLOR_YELLOW}Пропускаем установку дополнительных компонентов${COLOR_RESET}"
            ;;
        *)
            echo -e "${COLOR_RED}Неверный выбор, пропускаем установку дополнительных компонентов${COLOR_RESET}"
            ;;
    esac
}

installation_node() {
    echo -e "${COLOR_YELLOW}Установка ноды${COLOR_RESET}"
    sleep 1

    mkdir -p ${DIR_REMNAWAVE}

    install_remnawave_node

    declare -A domains_to_check
    domains_to_check["$SELFSTEAL_DOMAIN"]=1

    echo -e "${COLOR_YELLOW}Проверка сертификатов...${COLOR_RESET}"
    sleep 1

    echo -e "${COLOR_YELLOW}Требуемые домены для сертификатов:${COLOR_RESET}"
    for domain in "${!domains_to_check[@]}"; do
        echo -e "${COLOR_WHITE}- $domain${COLOR_RESET}"
    done

    need_certificates=false
    min_days_left=9999

    for domain in "${!domains_to_check[@]}"; do
        if check_certificates "$domain"; then
            days_left=$(check_cert_expiry "$domain")
            if [ $? -eq 0 ] && [ "$days_left" -lt "$min_days_left" ]; then
                min_days_left=$days_left
            fi
        else
            base_domain=$(extract_domain "$domain")
            if check_certificates "$base_domain" && is_wildcard_cert "$base_domain"; then
                printf "${COLOR_WHITE}Найден wildcard сертификат %s для домена %s${COLOR_RESET}\n" "$base_domain" "$domain"
                days_left=$(check_cert_expiry "$base_domain")
                if [ $? -eq 0 ] && [ "$days_left" -lt "$min_days_left" ]; then
                    min_days_left=$days_left
                fi
            else
                need_certificates=true
                break
            fi
        fi
    done

    if [ "$need_certificates" = true ]; then
        echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}Выберите метод генерации сертификатов для всех доменов:${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}1. Cloudflare API (поддерживает wildcard)${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ACME HTTP-01 (один домен, без wildcard)${COLOR_RESET}"
        reading "Выберите опцию (1-2):" CERT_METHOD

        if [ "$CERT_METHOD" == "2" ]; then
            reading "Введите ваш email для регистрации в Let's Encrypt:" LETSENCRYPT_EMAIL
        fi
    else
        echo -e "${COLOR_GREEN}Все сертификаты уже существуют. Пропускаем генерацию.${COLOR_RESET}"
        CERT_METHOD="2"

        if ! crontab -u root -l 2>/dev/null | grep -q "/usr/bin/certbot renew --quiet"; then
            if [ "$min_days_left" -le 30 ]; then
                crontab -l 2>/dev/null | { cat; echo "0 5 * * * /usr/bin/certbot renew --quiet >> ${DIR_REMNAWAVE}cron_jobs.log 2>&1"; } | crontab -
            else
                crontab -l 2>/dev/null | { cat; echo "0 5 1 */2 * /usr/bin/certbot renew --quiet >> ${DIR_REMNAWAVE}cron_jobs.log 2>&1"; } | crontab -
            fi

            for domain in "${!domains_to_check[@]}"; do
                base_domain=$(extract_domain "$domain")
                cert_domain="$domain"
                if ! [ -d "/etc/letsencrypt/live/$domain" ] && [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
                    cert_domain="$base_domain"
                fi
                if [ -f "/etc/letsencrypt/renewal/$cert_domain.conf" ]; then
                    desired_hook="renew_hook = sh -c 'cd /opt/remnawave && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx'"
                    if ! grep -q "renew_hook" "/etc/letsencrypt/renewal/$cert_domain.conf"; then
                        echo "$desired_hook" >> "/etc/letsencrypt/renewal/$cert_domain.conf"
                    elif ! grep -Fx "$desired_hook" "/etc/letsencrypt/renewal/$cert_domain.conf" > /dev/null; then
                        sed -i "/renew_hook/c\\$desired_hook" "/etc/letsencrypt/renewal/$cert_domain.conf"
                    fi
                fi
            done
        fi
    fi

    declare -A unique_domains

    if [ "$need_certificates" = true ] && [ "$CERT_METHOD" == "1" ]; then
        for domain in "${!domains_to_check[@]}"; do
            local base_domain=$(extract_domain "$domain")
            unique_domains["$base_domain"]="1"
        done

        min_days_left=9999
        for domain in "${!unique_domains[@]}"; do
            printf "${COLOR_YELLOW}Проверка сертификатов для %s...${COLOR_RESET}\n" "$domain"
            if check_certificates "$domain"; then
                echo -e "${COLOR_YELLOW}Используем существующие сертификаты${COLOR_RESET}"
                days_left=$(check_cert_expiry "$domain")
                if [ $? -eq 0 ] && [ "$days_left" -lt "$min_days_left" ]; then
                    min_days_left=$days_left
                fi
            else
                echo -e "${COLOR_RED}Сертификаты не найдены. Получаем новые...${COLOR_RESET}"
                echo -e "${COLOR_YELLOW}Генерация wildcard сертификата *.$domain${COLOR_RESET}"
                get_certificates "$domain" "$CERT_METHOD" "" "*.${domain}"
                min_days_left=90
            fi
            for sub_domain in "${!domains_to_check[@]}"; do
                if [[ "$sub_domain" == *"$domain" ]]; then
                    echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$sub_domain/fullchain.pem:ro" >> /opt/remnawave/docker-compose.yml
                    echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$sub_domain/privkey.pem:ro" >> /opt/remnawave/docker-compose.yml
                fi
            done
        done

        if ! crontab -u root -l 2>/dev/null | grep -q "/usr/bin/certbot renew --quiet"; then
            if [ "$min_days_left" -le 30 ]; then
                crontab -l 2>/dev/null | { cat; echo "0 5 * * * /usr/bin/certbot renew --quiet >> ${DIR_REMNAWAVE}cron_jobs.log 2>&1"; } | crontab -
            else
                crontab -l 2>/dev/null | { cat; echo "0 5 1 */2 * /usr/bin/certbot renew --quiet >> ${DIR_REMNAWAVE}cron_jobs.log 2>&1"; } | crontab -
            fi
            for domain in "${!unique_domains[@]}"; do
                if [ -f "/etc/letsencrypt/renewal/$domain.conf" ]; then
                    desired_hook="renew_hook = sh -c 'cd /opt/remnawave && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx'"
                    if ! grep -q "renew_hook" "/etc/letsencrypt/renewal/$domain.conf"; then
                        echo "$desired_hook" >> "/etc/letsencrypt/renewal/$domain.conf"
                    elif ! grep -Fx "$desired_hook" "/etc/letsencrypt/renewal/$domain.conf" > /dev/null; then
                        sed -i "/renew_hook/c\\$desired_hook" "/etc/letsencrypt/renewal/$domain.conf"
                    fi
                fi
            done
        fi
    elif [ "$need_certificates" = true ] && [ "$CERT_METHOD" == "2" ]; then
        for domain in "${!domains_to_check[@]}"; do
            printf "${COLOR_YELLOW}Проверка сертификатов для %s...${COLOR_RESET}\n" "$domain"
            if check_certificates "$domain"; then
                echo -e "${COLOR_YELLOW}Используем существующие сертификаты${COLOR_RESET}"
            else
                echo -e "${COLOR_RED}Сертификаты не найдены. Получаем новые...${COLOR_RESET}"
                get_certificates "$domain" "$CERT_METHOD" "$LETSENCRYPT_EMAIL"
            fi
            echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> /opt/remnawave/docker-compose.yml
            echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> /opt/remnawave/docker-compose.yml
        done
    else
        for domain in "${!domains_to_check[@]}"; do
            base_domain=$(extract_domain "$domain")
            cert_domain="$domain"
            if ! [ -d "/etc/letsencrypt/live/$domain" ] && [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
                cert_domain="$base_domain"
            fi
            echo "      - /etc/letsencrypt/live/$cert_domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> /opt/remnawave/docker-compose.yml
            echo "      - /etc/letsencrypt/live/$cert_domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> /opt/remnawave/docker-compose.yml
        done
    fi

    NODE_CERT_DOMAIN="$SELFSTEAL_DOMAIN"

    cat >> /opt/remnawave/docker-compose.yml <<EOL
      - /dev/shm:/dev/shm
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && nginx -g "daemon off;"'
    network_mode: host
    depends_on:
      - remnanode
    logging:
      driver: json-file
      options:
        max-size: "30m"
        max-file: "5"

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    env_file:
      - path: /opt/remnawave/.env-node
        required: false
    volumes:
      - /dev/shm:/dev/shm
    logging:
      driver: json-file
      options:
        max-size: "30m"
        max-file: "5"
EOL

cat > /opt/remnawave/nginx.conf <<EOL
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;

ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 208.67.222.222 208.67.220.220;

server {
    server_name $SELFSTEAL_DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$NODE_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";

    root /var/www/html;
    index index.html;

    location /xhttppath/ {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_body_timeout 5m;
        grpc_read_timeout 315;
        grpc_send_timeout 5m;
        grpc_pass unix:/dev/shm/xrxh.socket;
    }
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
EOL

    ufw allow from $PANEL_IP to any port 2222
    ufw reload

    echo -e "${COLOR_YELLOW}Запуск ноды${COLOR_RESET}"
    sleep 3
    cd /opt/remnawave
    docker compose up -d > /dev/null 2>&1 &

    spinner $! "Пожалуйста, подождите..."

    randomhtml

    printf "${COLOR_YELLOW}Проверка подключения ноды для %s...${COLOR_RESET}\n" "$SELFSTEAL_DOMAIN"
    local max_attempts=3
    local attempt=1
    local delay=15

    while [ $attempt -le $max_attempts ]; do
        printf "${COLOR_YELLOW}Попытка %d из %d...${COLOR_RESET}\n" "$attempt" "$max_attempts"
        if curl -s --fail --max-time 10 "https://$SELFSTEAL_DOMAIN" | grep -q "html"; then
            echo -e "${COLOR_GREEN}Нода успешно подключена!${COLOR_RESET}"
            break
        else
            printf "${COLOR_RED}Нода недоступна на попытке %d.${COLOR_RESET}\n" "$attempt"
            if [ $attempt -eq $max_attempts ]; then
                printf "${COLOR_RED}Нода не подключена после %d попыток!${COLOR_RESET}\n" "$max_attempts"
                echo -e "${COLOR_YELLOW}Проверьте конфигурацию или перезапустите панель.${COLOR_RESET}"
                exit 1
            fi
            sleep $delay
        fi
        ((attempt++))
    done

    echo -e "${COLOR_GREEN}Нода успешно подключена${COLOR_RESET}"
}

mkdir -p ${DIR_REMNAWAVE}
log_file="${DIR_REMNAWAVE}install_node.log"
exec > >(tee -a "$log_file") 2>&1

check_root
check_os

if [ ! -f ${DIR_REMNAWAVE}install_packages ]; then
    install_packages
fi

installation_node

exit 0