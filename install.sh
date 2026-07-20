#!/bin/bash

# =============================================
#  Универсальный установщик VPN
#  Поддерживает: Xray (VLESS/VMess) и Hysteria2
# =============================================

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите с правами root (sudo).${NC}"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Универсальный установщик VPN       ${NC}"
echo -e "${GREEN}========================================${NC}"

# Обновление системы и установка базовых пакетов
echo -e "${GREEN}[0/5] Обновление системы и установка зависимостей...${NC}"
apt update -y
apt install -y curl wget qrencode jq openssl

# Выбор протокола
echo -e "${YELLOW}Выберите протокол для установки:${NC}"
echo "1) Xray (VLESS / VMess)"
echo "2) Hysteria2 (с Brutal)"
read -p "Введите номер (1 или 2, по умолчанию 1): " PROTOCOL_CHOICE
PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-1}

# =============================================
#  БЛОК УСТАНОВКИ HYSTERIA2
# =============================================
if [ "$PROTOCOL_CHOICE" -eq 2 ]; then
    echo -e "${GREEN}Начинаем установку Hysteria2...${NC}"

    # Запрос параметров
    read -p "Введите порт для Hysteria2 (по умолчанию 443): " HY_PORT
    HY_PORT=${HY_PORT:-443}
    read -p "Введите исходящую скорость в Мбит/с (up_mbps) для Brutal (0 = отключить): " UP_MBPS
    UP_MBPS=${UP_MBPS:-0}
    read -p "Введите входящую скорость в Мбит/с (down_mbps) для Brutal (0 = отключить): " DOWN_MBPS
    DOWN_MBPS=${DOWN_MBPS:-0}

    # Шаг 1: Установка Hysteria2 через официальный скрипт
    echo -e "${GREEN}[1/4] Установка Hysteria2...${NC}"
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/apernet/hysteria2-installer/main/install.sh)"

    # Шаг 2: Генерация самоподписанного сертификата
    echo -e "${GREEN}[2/4] Генерация самоподписанного сертификата...${NC}"
    mkdir -p /etc/hysteria/cert
    IP=$(curl -4 -s icanhazip.com)
    openssl req -x509 -newkey rsa:4096 -keyout /etc/hysteria/cert/private.key -out /etc/hysteria/cert/cert.crt -days 365 -nodes -subj "/CN=$IP" -addext "subjectAltName=IP:$IP"

    # Шаг 3: Создание конфигурации
    echo -e "${GREEN}[3/4] Создание конфигурации...${NC}"
    PASSWORD=$(openssl rand -hex 16)
    cat > /etc/hysteria/config.yaml << EOF
listen: :$HY_PORT
tls:
  cert: /etc/hysteria/cert/cert.crt
  key: /etc/hysteria/cert/private.key
auth:
  type: password
  password: $PASSWORD
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
ignoreClientBandwidth: false
udpIdleTimeout: 60s
masquerade:
  type: proxy
  proxy:
    url: https://www.google.com
    rewriteHost: true
EOF

    # Добавляем параметры Brutal, если они > 0
    if [ "$UP_MBPS" -gt 0 ] && [ "$DOWN_MBPS" -gt 0 ]; then
        cat >> /etc/hysteria/config.yaml << EOF
bandwidth:
  up: ${UP_MBPS} Mbps
  down: ${DOWN_MBPS} Mbps
EOF
    fi

    # Шаг 4: Запуск сервиса
    echo -e "${GREEN}[4/4] Запуск Hysteria2...${NC}"
    systemctl restart hysteria-server
    systemctl enable hysteria-server

    # Генерация ссылки и скрипта управления
    cat > /usr/local/bin/h2-show << 'EOF'
#!/bin/bash
IP=$(curl -4 -s icanhazip.com)
PASSWORD=$(grep 'password:' /etc/hysteria/config.yaml | awk '{print $2}')
PORT=$(grep 'listen:' /etc/hysteria/config.yaml | awk '{print $2}')
UP=$(grep -A1 'bandwidth:' /etc/hysteria/config.yaml | grep 'up:' | awk '{print $2}')
DOWN=$(grep -A1 'bandwidth:' /etc/hysteria/config.yaml | grep 'down:' | awk '{print $2}')
if [ -n "$UP" ] && [ -n "$DOWN" ]; then
    echo "hysteria2://$PASSWORD@$IP:$PORT?insecure=1&upmbps=$UP&downmbps=$DOWN&sni=www.google.com#Hysteria2-Brutal"
else
    echo "hysteria2://$PASSWORD@$IP:$PORT?insecure=1&sni=www.google.com#Hysteria2"
fi
EOF
    chmod +x /usr/local/bin/h2-show

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ Установка Hysteria2 завершена!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${YELLOW}Ваши параметры:${NC}"
    echo "Порт: $HY_PORT"
    echo "Brutal up: ${UP_MBPS} Мбит/с (0 = отключен)"
    echo "Brutal down: ${DOWN_MBPS} Мбит/с (0 = отключен)"
    echo -e "${YELLOW}Команды управления:${NC}"
    echo "  systemctl restart hysteria-server  - перезапустить"
    echo "  systemctl stop hysteria-server     - остановить"
    echo "  systemctl start hysteria-server    - запустить"
    echo "  h2-show                            - показать ссылку"
    echo -e "${YELLOW}Ссылка для подключения (сохраните её):${NC}"
    h2-show
    exit 0
fi

# =============================================
#  БЛОК УСТАНОВКИ XRAY (ОРИГИНАЛЬНАЯ ЛОГИКА)
# =============================================
echo -e "${GREEN}Начинаем установку Xray...${NC}"

# Запрос параметров для Xray
read -p "Введите порт (по умолчанию 443): " PORT
PORT=${PORT:-443}

echo -e "${YELLOW}Выберите протокол:${NC}"
echo "1) VLESS"
echo "2) VMess"
read -p "Введите номер (1 или 2, по умолчанию 1): " PROTOCOL_CHOICE_X
PROTOCOL_CHOICE_X=${PROTOCOL_CHOICE_X:-1}
if [ "$PROTOCOL_CHOICE_X" -eq 2 ]; then
    PROTOCOL="vmess"
else
    PROTOCOL="vless"
fi

echo -e "${YELLOW}Выберите транспорт:${NC}"
echo "1) TCP"
echo "2) WebSocket (ws)"
echo "3) gRPC"
echo "4) XHTTP"
read -p "Введите номер (по умолчанию 1): " TRANSPORT_CHOICE
TRANSPORT_CHOICE=${TRANSPORT_CHOICE:-1}
case $TRANSPORT_CHOICE in
    2) TRANSPORT="ws";;
    3) TRANSPORT="grpc";;
    4) TRANSPORT="xhttp";;
    *) TRANSPORT="tcp";;
esac

if [ "$TRANSPORT" = "ws" ] || [ "$TRANSPORT" = "xhttp" ]; then
    read -p "Введите путь (например /, по умолчанию /): " PATH_STR
    PATH_STR=${PATH_STR:-/}
fi

echo -e "${YELLOW}Выберите безопасность:${NC}"
echo "1) Reality (рекомендуется)"
echo "2) TLS (требуется сертификат)"
echo "3) None (без шифрования, не рекомендуется)"
read -p "Введите номер (по умолчанию 1): " SECURITY_CHOICE
SECURITY_CHOICE=${SECURITY_CHOICE:-1}

case $SECURITY_CHOICE in
  2)
    SECURITY="tls"
    read -p "Введите домен для сертификата (например, example.com): " DOMAIN
    ;;
  3)
    SECURITY="none"
    ;;
  *)
    SECURITY="reality"
    read -p "Введите домен для маскировки (по умолчанию github.com): " SNI_DOMAIN
    SNI_DOMAIN=${SNI_DOMAIN:-github.com}
    ;;
esac

# Шаг 1: Установка Xray-core
echo -e "${GREEN}[1/6] Установка Xray-core...${NC}"
bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Шаг 2: Включение BBR
echo -e "${GREEN}[2/6] Настройка BBR...${NC}"
if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo -e "${GREEN}BBR уже включен.${NC}"
else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo -e "${GREEN}BBR включен.${NC}"
fi

# Шаг 3: Генерация ключей
echo -e "${GREEN}[3/6] Генерация ключей...${NC}"
KEYS_FILE="/usr/local/etc/xray/.keys"
[ -f "$KEYS_FILE" ] && rm "$KEYS_FILE"
touch "$KEYS_FILE"

UUID=$(xray uuid)
echo "uuid: $UUID" >> "$KEYS_FILE"

if [ "$SECURITY" = "reality" ]; then
    echo "shortsid: $(openssl rand -hex 8)" >> "$KEYS_FILE"
    xray x25519 >> "$KEYS_FILE"
    PRIVATE_KEY=$(grep 'PrivateKey' "$KEYS_FILE" | awk '{print $2}')
    PUBLIC_KEY=$(grep 'PublicKey' "$KEYS_FILE" | awk '{print $2}')
fi

# Шаг 4: Создание конфига
echo -e "${GREEN}[4/6] Создание конфигурации Xray...${NC}"
CONFIG_FILE="/usr/local/etc/xray/config.json"

# Блок безопасности
SECURITY_BLOCK=""
if [ "$SECURITY" = "reality" ]; then
    SECURITY_BLOCK=$(cat <<EOF
,
        "realitySettings": {
          "show": false,
          "dest": "$SNI_DOMAIN:443",
          "xver": 0,
          "serverNames": [
            "$SNI_DOMAIN",
            "www.$SNI_DOMAIN"
          ],
          "privateKey": "$PRIVATE_KEY",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "$(grep 'shortsid' "$KEYS_FILE" | awk '{print $2}')"
          ]
        }
EOF
)
elif [ "$SECURITY" = "tls" ]; then
    SECURITY_BLOCK=$(cat <<EOF
,
        "tlsSettings": {
          "serverName": "$DOMAIN",
          "allowInsecure": false
        }
EOF
)
fi

# Блок транспорта
TRANSPORT_BLOCK=""
if [ "$TRANSPORT" = "ws" ] || [ "$TRANSPORT" = "xhttp" ]; then
    TRANSPORT_BLOCK=",\"wsSettings\":{\"path\":\"$PATH_STR\"}"
elif [ "$TRANSPORT" = "grpc" ]; then
    TRANSPORT_BLOCK=",\"grpcSettings\":{\"serviceName\":\"\"}"
fi

# Flow для VLESS (если безопасность не none)
CLIENT_FLOW=""
if [ "$PROTOCOL" = "vless" ] && [ "$SECURITY" != "none" ]; then
    CLIENT_FLOW=",\"flow\":\"xtls-rprx-vision\""
fi

cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "$PROTOCOL",
      "settings": {
        "clients": [
          {
            "email": "main",
            "id": "$UUID"$CLIENT_FLOW
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "$TRANSPORT"$TRANSPORT_BLOCK,
        "security": "$SECURITY"$SECURITY_BLOCK
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 3,
        "connIdle": 180
      }
    }
  }
}
EOF

# Шаг 5: Создание команд управления
echo -e "${GREEN}[5/6] Создание скриптов управления...${NC}"

# mainuser
cat > /usr/local/bin/mainuser << 'EOF'
#!/bin/bash
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(grep 'uuid' /usr/local/etc/xray/.keys | awk '{print $2}')
security=$(jq -r '.inbounds[0].streamSettings.security' /usr/local/etc/xray/config.json)
transport=$(jq -r '.inbounds[0].streamSettings.network' /usr/local/etc/xray/config.json)
[ -z "$transport" ] || [ "$transport" = "null" ] && transport="tcp"
if [ "$security" = "reality" ]; then
    pbk=$(grep 'PublicKey' /usr/local/etc/xray/.keys | awk '{print $2}')
    sid=$(grep 'shortsid' /usr/local/etc/xray/.keys | awk '{print $2}')
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pbk}&sid=${sid}&type=${transport}&flow=xtls-rprx-vision&encryption=none#main"
elif [ "$security" = "tls" ]; then
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?security=tls&sni=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' /usr/local/etc/xray/config.json)&fp=firefox&type=${transport}&encryption=none#main"
else
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?encryption=none&type=${transport}#main"
fi
echo "Ссылка для подключения:"
echo "$link"
echo
echo "QR-код:"
echo "$link" | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/mainuser

# newuser
cat > /usr/local/bin/newuser << 'EOF'
#!/bin/bash
read -p "Введите имя пользователя: " email
if [[ -z "$email" || "$email" == *" "* ]]; then
    echo "Имя не может быть пустым или содержать пробелы."
    exit 1
fi
if jq -e --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' /usr/local/etc/xray/config.json >/dev/null; then
    echo "Пользователь с таким именем уже существует."
    exit 1
fi
uuid=$(xray uuid)
security=$(jq -r '.inbounds[0].streamSettings.security' /usr/local/etc/xray/config.json)
if [ "$security" != "none" ]; then
    flow=",\"flow\":\"xtls-rprx-vision\""
else
    flow=""
fi
jq --arg email "$email" --arg uuid "$uuid" --arg flow "$flow" '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid} + ($flow | fromjson? // {})]' /usr/local/etc/xray/config.json > tmp.json && mv tmp.json /usr/local/etc/xray/config.json
systemctl restart xray
echo "Пользователь $email создан."
EOF
chmod +x /usr/local/bin/newuser

# rmuser
cat > /usr/local/bin/rmuser << 'EOF'
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json))
if [ ${#emails[@]} -eq 0 ]; then
    echo "Нет клиентов для удаления."
    exit 1
fi
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
read -p "Введите номер клиента для удаления: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#emails[@]} ]; then
    echo "Неверный номер."
    exit 1
fi
selected_email="${emails[$((choice-1))]}"
jq --arg email "$selected_email" 'del(.inbounds[0].settings.clients[] | select(.email == $email))' /usr/local/etc/xray/config.json > tmp.json && mv tmp.json /usr/local/etc/xray/config.json
systemctl restart xray
echo "Клиент $selected_email удалён."
EOF
chmod +x /usr/local/bin/rmuser

# sharelink
cat > /usr/local/bin/sharelink << 'EOF'
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json))
if [ ${#emails[@]} -eq 0 ]; then
    echo "Нет клиентов."
    exit 1
fi
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
read -p "Выберите клиента: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#emails[@]} ]; then
    echo "Неверный номер."
    exit 1
fi
selected_email="${emails[$((choice-1))]}"
uuid=$(jq -r --arg email "$selected_email" '.inbounds[0].settings.clients[] | select(.email == $email) | .id' /usr/local/etc/xray/config.json)
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
security=$(jq -r '.inbounds[0].streamSettings.security' /usr/local/etc/xray/config.json)
transport=$(jq -r '.inbounds[0].streamSettings.network' /usr/local/etc/xray/config.json)
[ -z "$transport" ] || [ "$transport" = "null" ] && transport="tcp"
if [ "$security" = "reality" ]; then
    pbk=$(grep 'PublicKey' /usr/local/etc/xray/.keys | awk '{print $2}')
    sid=$(grep 'shortsid' /usr/local/etc/xray/.keys | awk '{print $2}')
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pbk}&sid=${sid}&type=${transport}&flow=xtls-rprx-vision&encryption=none#${selected_email}"
elif [ "$security" = "tls" ]; then
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?security=tls&sni=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' /usr/local/etc/xray/config.json)&fp=firefox&type=${transport}&encryption=none#${selected_email}"
else
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?encryption=none&type=${transport}#${selected_email}"
fi
echo "Ссылка для $selected_email:"
echo "$link"
echo
echo "QR-код:"
echo "$link" | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/sharelink

# userlist
cat > /usr/local/bin/userlist << 'EOF'
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json))
if [ ${#emails[@]} -eq 0 ]; then
    echo "Список клиентов пуст."
    exit 1
fi
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
EOF
chmod +x /usr/local/bin/userlist

# Шаг 6: Завершение
echo -e "${GREEN}[6/6] Запуск Xray...${NC}"
systemctl restart xray

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Установка Xray завершена!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${YELLOW}Ваши параметры:${NC}"
echo "Протокол: $PROTOCOL"
echo "Транспорт: $TRANSPORT"
echo "Порт: $PORT"
echo "Безопасность: $SECURITY"
[ "$SECURITY" = "reality" ] && echo "SNI: $SNI_DOMAIN"
[ "$SECURITY" = "tls" ] && echo "Домен: $DOMAIN"
[ "$TRANSPORT" = "ws" ] || [ "$TRANSPORT" = "xhttp" ] && echo "Путь: $PATH_STR"

echo -e "${YELLOW}Команды управления:${NC}"
echo "  mainuser   - показать ссылку для основного пользователя"
echo "  newuser    - создать нового пользователя"
echo "  rmuser     - удалить пользователя"
echo "  sharelink  - показать ссылку для любого пользователя"
echo "  userlist   - показать список пользователей"

echo -e "${YELLOW}Ссылка для основного пользователя:${NC}"
mainuser

echo -e "${GREEN}Скрипт установки завершён.${NC}"