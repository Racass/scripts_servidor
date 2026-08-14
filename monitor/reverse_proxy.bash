#!/bin/bash

set -e

DOMAIN="monitor.corp"
UPSTREAM="127.0.0.1:3001"
CONFIG="/etc/nginx/sites-available/$DOMAIN"

echo "==> Instalando Nginx..."
apt update
apt install -y nginx

echo "==> Criando configuração do Nginx..."

cat > "$CONFIG" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN;

    location / {
        proxy_pass http://$UPSTREAM;

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket - necessário para o Uptime Kuma
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }
}
EOF

echo "==> Habilitando site..."
ln -sf "$CONFIG" "/etc/nginx/sites-enabled/$DOMAIN"

echo "==> Removendo configuração default..."
rm -f /etc/nginx/sites-enabled/default

echo "==> Testando configuração..."
nginx -t

echo "==> Habilitando e reiniciando Nginx..."
systemctl enable nginx
systemctl restart nginx

echo
echo "======================================"
echo " Nginx configurado com sucesso!"
echo "======================================"
echo
echo " $DOMAIN -> $UPSTREAM"
echo
systemctl --no-pager status nginx