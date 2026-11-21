#!/bin/bash
# Une este nodo a un clúster Docker Swarm existente.
# Uso (en el nodo nuevo):  ./join-swarm.sh <TOKEN> <IP_PRIVADA_MANAGER>
#   - Con el token de worker  -> se une como worker
#   - Con el token de manager -> se une como manager
# Los tokens se obtienen en el manager con:
#   docker swarm join-token -q worker
#   docker swarm join-token -q manager
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Uso: $0 <TOKEN> <IP_PRIVADA_MANAGER>"
  exit 1
fi
TOKEN=$1
IP_MANAGER=$2

until docker info >/dev/null 2>&1; do
  echo "Esperando a Docker..."
  sleep 5
done

ESTADO=$(docker info --format '{{.Swarm.LocalNodeState}}')
if [ "$ESTADO" = "active" ]; then
  echo "El nodo ya pertenece a un clúster Swarm."
  exit 0
fi

docker swarm join --token "$TOKEN" "$IP_MANAGER:2377"
