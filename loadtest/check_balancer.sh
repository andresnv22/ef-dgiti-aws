#!/usr/bin/env bash
# Hace N solicitudes al ALB y cuenta que instancia/zona respondio cada una.
# Las respuestas fallidas se cuentan como ERROR en lugar de detener el script.
# Uso: ./loadtest/check_balancer.sh http://<alb_dns_name> [N]
set -uo pipefail

URL="${1:?Uso: $0 http://<alb_dns_name> [numero_de_solicitudes]}"
N="${2:-30}"

echo "Enviando $N solicitudes a ${URL%/}/api/info ..."
for _ in $(seq 1 "$N"); do
  curl -s --max-time 5 "${URL%/}/api/info" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["instance_id"], d["availability_zone"])
except Exception:
    print("ERROR sin-respuesta-valida")
'
done | sort | uniq -c | awk '{printf "  %3d solicitudes -> %s (%s)\n", $1, $2, $3}'
