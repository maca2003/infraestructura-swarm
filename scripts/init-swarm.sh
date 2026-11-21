#!/bin/bash
# Inicializa el clúster Docker Swarm en el nodo MANAGER.
# Uso (en el manager):  ./init-swarm.sh
# Es idempotente: si el nodo ya pertenece a un clúster, no hace nada.
set -euo pipefail

# Espera a que Docker esté instalado y corriendo (lo instala el UserData de la instancia)
until docker info >/dev/null 2>&1; do
  echo "Esperando a Docker..."
  sleep 5
done

ESTADO=$(docker info --format '{{.Swarm.LocalNodeState}}')
if [ "$ESTADO" = "active" ]; then
  echo "El nodo ya pertenece a un clúster Swarm."
else
  # IP privada de la instancia (la usan los workers para unirse)
  TOKEN_IMDS=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  IP_PRIVADA=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN_IMDS" http://169.254.169.254/latest/meta-data/local-ipv4)
  docker swarm init --advertise-addr "$IP_PRIVADA"
fi

echo
echo "Comando para unir un WORKER:"
docker swarm join-token worker | grep "docker swarm join"
echo
echo "Comando para unir un MANAGER adicional:"
docker swarm join-token manager | grep "docker swarm join"
