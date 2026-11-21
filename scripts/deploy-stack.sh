#!/bin/bash
# Despliega (o actualiza) el stack "sistema" en el clúster. Se ejecuta en el MANAGER.
# Variables requeridas:
#   REGISTRY         URL del registro ECR (ej: 123456789012.dkr.ecr.us-east-1.amazonaws.com)
#   DB_PASSWORD      contraseña de MySQL
# Variables opcionales:
#   SQS_ALERTAS_URL  URL de la cola de alertas (salida del stack fn-alertas-inventario)
#   TAG              etiqueta de las imágenes (por defecto: latest)
set -euo pipefail

: "${REGISTRY:?Falta la variable REGISTRY}"
: "${DB_PASSWORD:?Falta la variable DB_PASSWORD}"
export TAG="${TAG:-latest}"
export SQS_ALERTAS_URL="${SQS_ALERTAS_URL:-}"

cd "$(dirname "$0")/.."

# Inicia sesión en Amazon ECR (credenciales del rol LabInstanceProfile de la instancia)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REGISTRY"

# --with-registry-auth envía las credenciales de ECR a los workers para que puedan descargar las imágenes
docker stack deploy -c docker-compose.yml --with-registry-auth sistema

docker stack services sistema
