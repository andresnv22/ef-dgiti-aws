#!/bin/bash
# Plantilla procesada por templatefile() en main.tf.
# Las expresiones con llaves (repo_url, db_host, ...) las reemplaza Terraform;
# las variables de bash se escriben sin llaves ($VAR) para que Terraform no las toque.
set -euo pipefail

APP_DIR=/opt/app
APP_USER=appuser

dnf install -y git python3 python3-pip

# Metadatos de la instancia con IMDSv2 (se muestran en /api/info para evidenciar el balanceo)
TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

id -u $APP_USER >/dev/null 2>&1 || useradd --system --home-dir $APP_DIR --shell /sbin/nologin $APP_USER
mkdir -p $APP_DIR
rm -rf $APP_DIR/src

# Descarga del codigo versionado en GitHub (con reintentos por si el NAT aun no esta listo)
for attempt in 1 2 3 4 5 6; do
  if git clone --depth 1 --branch "${repo_branch}" "${repo_url}" $APP_DIR/src; then
    break
  fi
  echo "git clone fallo (intento $attempt), reintentando..."
  sleep 15
done
test -f $APP_DIR/src/app/app.py
COMMIT=$(git -C $APP_DIR/src rev-parse --short HEAD)

python3 -m venv $APP_DIR/venv
$APP_DIR/venv/bin/pip install --upgrade pip
$APP_DIR/venv/bin/pip install -r $APP_DIR/src/app/requirements.txt

cat > /etc/dgiti-app.env <<EOF
INSTANCE_ID=$INSTANCE_ID
AVAILABILITY_ZONE=$AZ
APP_VERSION=${app_version}-$COMMIT
DB_HOST=${db_host}
DB_REPLICA_HOST=${db_replica_host}
DB_PORT=3306
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
EOF
chmod 600 /etc/dgiti-app.env
chown -R $APP_USER:$APP_USER $APP_DIR

cat > /etc/systemd/system/dgiti-app.service <<EOF
[Unit]
Description=Servicio web EF DGITI (Flask + Gunicorn)
After=network-online.target
Wants=network-online.target

[Service]
User=$APP_USER
EnvironmentFile=/etc/dgiti-app.env
WorkingDirectory=$APP_DIR/src/app
ExecStart=$APP_DIR/venv/bin/gunicorn --bind 0.0.0.0:${app_port} --workers 2 --threads 2 --timeout 30 --access-logfile - app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dgiti-app.service
