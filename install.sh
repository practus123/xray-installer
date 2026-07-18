#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    Установка Xray-core с настройками    ${NC}"
echo -e "${GREEN}========================================${NC}"

# 1. Запрос параметров у пользователя
read -p "Введите порт (по умолчанию 443): " PORT
PORT=${PORT:-443}

echo -e "${YELLOW}Выберите протокол:${NC}"
echo "1) VLESS"
echo "2) VMess"
read -p "Введите номер (1 или 2, по умолчанию 1): " PROTOCOL_CHOICE
PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-1}
if [ "$PROTOCOL_CHOICE" -eq 2 ]; then
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

# 2. Обновление системы и установка зависимостей
echo -e "${GREEN}[1/6] Обновление системы и установка зависимостей...${NC}"
apt update -y
apt install -y curl wget qrencode jq openssl

# 3. Включение BBR
echo -e "${GREEN}[2/6] Настройка BBR...${NC}"
if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo -e "${GREEN}BBR уже включен.${NC}"
else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo -e "${GREEN}BBR включен.${NC}"
fi

# 4. Установка Xray-core
echo -e "${GREEN}[3/6] Установка Xray-core...${NC}"
bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 5. Генерация ключей (только для REALITY)
echo -e "${GREEN}[4/6] Генерация ключей...${NC}"
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

# 6. Создание конфигурации
echo -e "${GREEN}[5/6] Создание конфигурации Xray...${NC}"
CONFIG_FILE="/usr/local/etc/xray/config.json"

# Формируем блок безопасности
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

# Формируем блок транспорта
TRANSPORT_BLOCK=""
if [ "$TRANSPORT" = "ws" ] || [ "$TRANSPORT" = "xhttp" ]; then
    TRANSPORT_BLOCK=",\"wsSettings\":{\"path\":\"$PATH_STR\"}"
elif [ "$TRANSPORT" = "grpc" ]; then
    TRANSPORT_BLOCK=",\"grpcSettings\":{\"serviceName\":\"\"}"
fi

# Формируем блок клиента (flow только если security не none и протокол vless)
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
        ]$([ "$PROTOCOL" = "vmess" ] && echo ',"decryption":"none"')
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

# 7. Создание вспомогательных скриптов
echo -e "${GREEN}[6/6] Создание скриптов управления...${NC}"

# mainuser
cat > /usr/local/bin/mainuser << 'EOF'
#!/bin/bash
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(grep 'uuid' /usr/local/etc/xray/.keys | awk '{print $2}')
security=$(jq -r '.inbounds[0].streamSettings.security' /usr/local/etc/xray/config.json)
if [ "$security" = "reality" ]; then
    pbk=$(grep 'PublicKey' /usr/local/etc/xray/.keys | awk '{print $2}')
    sid=$(grep 'shortsid' /usr/local/etc/xray/.keys | awk '{print $2}')
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pbk}&sid=${sid}&type=tcp&flow=xtls-rprx-vision&encryption=none#main"
elif [ "$security" = "tls" ]; then
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?security=tls&sni=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' /usr/local/etc/xray/config.json)&fp=firefox&type=tcp&encryption=none#main"
else
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?encryption=none#main"
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

# rmuser (без изменений)
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

# sharelink (с поддержкой none)
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
if [ "$security" = "reality" ]; then
    pbk=$(grep 'PublicKey' /usr/local/etc/xray/.keys | awk '{print $2}')
    sid=$(grep 'shortsid' /usr/local/etc/xray/.keys | awk '{print $2}')
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?security=reality&sni=${sni}&fp=firefox&pbk=${pbk}&sid=${sid}&type=tcp&flow=xtls-rprx-vision&encryption=none#${selected_email}"
elif [ "$security" = "tls" ]; then
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?security=tls&sni=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' /usr/local/etc/xray/config.json)&fp=firefox&type=tcp&encryption=none#${selected_email}"
else
    link="${protocol}://${uuid}@$(curl -4 -s icanhazip.com):${port}?encryption=none#${selected_email}"
fi
echo "Ссылка для $selected_email:"
echo "$link"
echo
echo "QR-код:"
echo "$link" | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/sharelink

# userlist (без изменений)
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

# 8. Завершение
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Установка завершена!${NC}"
echo -e "${GREEN}========================================${NC}"

systemctl restart xray

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