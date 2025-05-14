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

install_packages() {
    echo -e "${COLOR_YELLOW}Установка необходимых пакетов...${COLOR_RESET}"
    apt-get update -y
    apt-get install -y ca-certificates curl jq ufw wget gnupg unzip nano dialog git unattended-upgrades locales dnsutils coreutils grep gawk

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

# Функция для проверки наличия remnanode
check_remnanode() {
    if ! sudo docker ps -q --filter "name=remnanode" | grep -q .; then
        echo -e "${COLOR_RED}Remnanode не установлен. Сначала установите Remnanode.${COLOR_RESET}"
        return 1
    fi
    return 0
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
    echo -e "4. Выйти без установки"

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
            echo -e "${COLOR_YELLOW}Выход без установки дополнительных компонентов${COLOR_RESET}"
            ;;
        *)
            echo -e "${COLOR_RED}Неверный выбор, выход${COLOR_RESET}"
            ;;
    esac
}

mkdir -p ${DIR_REMNAWAVE}
log_file="${DIR_REMNAWAVE}install_tblocker_warp.log"
exec > >(tee -a "$log_file") 2>&1

check_root
check_os

if [ ! -f ${DIR_REMNAWAVE}install_packages ]; then
    install_packages
fi

add_tblocker_warp_menu

exit 0
