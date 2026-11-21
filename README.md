# infraestructura-swarm

Infraestructura y despliegue del sistema de microservicios:

- **`docker-compose.yml`**: define los 6 servicios (MySQL, ms-auth, ms-productos, ms-inventario, ms-ventas, api-gateway). Sirve para levantar todo en local y para desplegarlo en **Docker Swarm**.
- **`cloudformation/cluster.yaml`**: infraestructura como código en AWS: 3 instancias EC2 (1 manager + 2 workers), grupo de seguridad con los puertos de Swarm, IP fija para el manager y **Amazon API Gateway (HTTP API)**.
- **`scripts/`**: inicialización del clúster, unión de nodos y despliegue del stack.
- **`.github/workflows/ci-cd.yml`**: pipeline que provisiona la infraestructura, configura el clúster, despliega el stack y verifica el sistema.

## Arquitectura

```
                  Internet
                     │
          Amazon API Gateway (HTTP API, límite 20 req/s)
                     │
        ┌────────────▼──────────── Clúster Docker Swarm (EC2) ───────────────────┐
        │  api-gateway :8080  (JWT + roles)   ← único puerto publicado           │
        │        │  red overlay "backend"                                        │
        │  ms-auth ×2   ms-productos ×2   ms-ventas ×2   ms-inventario ×2        │
        │        │                                            │                  │
        │  mysql ×1 (nodo manager, volumen mysql_data)        │                  │
        └─────────────────────────────────────────────────────┼──────────────────┘
                                                              ▼
                     Amazon SQS inventario-alertas ──▶ AWS Lambda fn-alertas-inventario ──▶ CloudWatch
```

Los repositorios de los microservicios y de la función serverless son:
`ms-auth`, `ms-productos`, `ms-ventas`, `ms-inventario`, `api-gateway`, `fn-alertas-inventario`.

## 1. Ejecución local con Docker

Requisitos: Docker Desktop. Clonar todos los repositorios **en la misma carpeta**:

```bash
mkdir sistema && cd sistema
for r in ms-auth ms-productos ms-ventas ms-inventario api-gateway infraestructura-swarm; do
  git clone https://github.com/maca2003/$r.git
done
cd infraestructura-swarm
```

### Opción A: docker compose

```bash
docker compose build                              # construye las 5 imágenes desde los Dockerfile
docker compose up -d --scale api-gateway=1        # en local solo puede haber 1 gateway en el puerto 8080
docker compose ps
```

### Opción B: Docker Swarm de un solo nodo

```bash
docker compose build
docker swarm init
docker stack deploy -c docker-compose.yml sistema
docker stack services sistema
```

Probar: `POST http://localhost:8080/api/auth/login` con `{"username":"admin","password":"admin123"}`.

Detener: `docker compose down` o `docker stack rm sistema`.

## 2. El archivo docker-compose.yml

| Elemento | Para qué sirve |
|---|---|
| `build` | Ruta del repositorio con el Dockerfile. Se usa con `docker compose build`; Swarm lo ignora |
| `image` | `${REGISTRY}/servicio:${TAG}`. En local es `local/...`; en AWS es el registro de Amazon ECR |
| `networks: backend` | Red interna. En Swarm es **overlay** (conecta contenedores en nodos distintos). Los servicios se encuentran por nombre (`http://ms-productos:8082`) |
| `ports: 8080` | Solo el `api-gateway` se publica. Los microservicios no son accesibles desde fuera |
| `deploy.replicas` | Cantidad de contenedores de cada servicio (2 por microservicio) |
| `deploy.update_config` | Actualización continua: 1 réplica a la vez, la nueva arranca antes de detener la anterior (`start-first`) y si falla se hace rollback |
| `deploy.restart_policy` | Swarm reinicia los contenedores que fallan |
| `deploy.resources` | Límite de 512 MB por contenedor para repartir bien la memoria entre nodos |
| `placement.constraints` | MySQL siempre en el manager, junto a su volumen `mysql_data` |
| `x-servicio`, `x-despliegue` | Bloques comunes reutilizados con anclas YAML (`<<: *despliegue`) |

## 3. Clúster Docker Swarm en AWS

### Nodos

| Nodo | Rol | Qué ejecuta |
|---|---|---|
| `swarm-manager` | manager (líder) | Administra el clúster, MySQL y réplicas de servicios |
| `swarm-worker-1` | worker | Réplicas de servicios |
| `swarm-worker-2` | worker | Réplicas de servicios |

Puertos abiertos entre nodos (grupo de seguridad): `2377/tcp` (gestión), `7946/tcp+udp` (comunicación entre nodos), `4789/udp` (red overlay). Desde internet: `22` (SSH) y `8080` (API).

### Inicializar el clúster (manual)

El pipeline lo hace automáticamente, pero los pasos manuales son:

```bash
# Conectarse al manager (labsuser.pem se descarga desde Learner Lab → AWS Details)
ssh -i labsuser.pem ec2-user@<IP_PUBLICA_MANAGER>
sudo bash init-swarm.sh             # docker swarm init + muestra los comandos de unión
```

### Añadir un nodo WORKER

```bash
# En el manager: obtener el token
sudo docker swarm join-token -q worker

# En el nodo nuevo (con Docker instalado y en el mismo grupo de seguridad)
sudo bash join-swarm.sh <TOKEN_WORKER> <IP_PRIVADA_MANAGER>
```

### Añadir un nodo MANAGER

```bash
# En el manager actual
sudo docker swarm join-token -q manager

# En el nodo nuevo
sudo bash join-swarm.sh <TOKEN_MANAGER> <IP_PRIVADA_MANAGER>
```

> Se recomienda un número **impar** de managers (1, 3 o 5): Swarm necesita mayoría (quórum Raft) para seguir funcionando. Con 3 managers, el clúster tolera la caída de 1.

Otras operaciones útiles en el manager:

```bash
sudo docker node ls                                  # nodos y su estado
sudo docker node promote <NODO>                      # convertir un worker en manager
sudo docker node update --availability drain <NODO>  # sacar un nodo para mantención (sus tareas se mueven)
sudo docker node update --availability active <NODO> # devolverlo al clúster
```

### Desplegar el stack

```bash
# En el manager, con docker-compose.yml y scripts/deploy-stack.sh copiados en ~/sistema
sudo REGISTRY=<ID_CUENTA>.dkr.ecr.us-east-1.amazonaws.com DB_PASSWORD=<CLAVE> \
     SQS_ALERTAS_URL=<URL_COLA> bash ~/sistema/scripts/deploy-stack.sh

sudo docker stack services sistema       # servicios y réplicas
sudo docker service ps sistema_ms-ventas # en qué nodo corre cada réplica
```

### Escalar servicios

```bash
sudo docker service scale sistema_ms-productos=4    # escalar hacia arriba
sudo docker service scale sistema_ms-productos=1    # escalar hacia abajo
sudo docker service ps sistema_ms-productos --filter desired-state=running
```

Swarm reparte las réplicas entre los nodos y el balanceador interno (routing mesh) distribuye las peticiones sin cortar el servicio.

## 4. Decisiones del clúster

| Decisión | Motivo |
|---|---|
| 1 manager + 2 workers | Mínimo para repartir réplicas en varios nodos. Se puede crecer a 3 managers para alta disponibilidad del plano de control |
| 2 réplicas por microservicio y gateway | Si un contenedor o un nodo cae, la otra réplica sigue atendiendo (disponibilidad) |
| Red overlay y un solo puerto publicado | Los microservicios solo se alcanzan a través del api-gateway, que valida JWT y roles |
| `update_config` con `start-first` y `rollback` | Despliegues sin cortes; si la nueva versión falla, vuelve a la anterior |
| `HEALTHCHECK` en las imágenes | Swarm reemplaza las réplicas que dejan de responder |
| Límites de memoria | Evita que un servicio consuma toda la memoria de un nodo |
| MySQL fijo en el manager | El volumen de datos es local al nodo; así no se pierden datos al reprogramar el contenedor |
| Imágenes en Amazon ECR con etiqueta por commit | Trazabilidad: cada versión desplegada corresponde a un commit; se puede volver a una anterior |
| Infraestructura en CloudFormation y scripts idempotentes | El clúster se puede recrear igual en cualquier momento (mantenibilidad) |

## 5. Amazon API Gateway

Creado en `cloudformation/cluster.yaml` (HTTP API `sistema-api`):

- Ruta `ANY /{proxy+}` → integración `HTTP_PROXY` hacia `http://<IP_MANAGER>:8080/{proxy}` (el api-gateway del clúster).
- Límite de peticiones: 20 por segundo con ráfagas de 50, para proteger el backend.
- La autenticación la hace el api-gateway del sistema: sin token responde 401 y sin permisos responde 403.

URL pública: salida `UrlApiGateway` del stack `cluster-swarm`, por ejemplo
`https://abc123.execute-api.us-east-1.amazonaws.com/api/auth/login`.

## 6. Pipeline CI/CD

`.github/workflows/ci-cd.yml`, en cada push:

| Etapa | Ramas | Qué hace |
|---|---|---|
| Validar plantillas | todas | `cfn-lint` sobre la plantilla de CloudFormation |
| Provisionar infraestructura cloud | `main` | `aws cloudformation deploy` del stack `cluster-swarm` (EC2, grupo de seguridad, IP fija, API Gateway) |
| Configurar clúster Docker Swarm | `main` | Por SSH: `init-swarm.sh` en el manager y `join-swarm.sh` en cada worker |
| Desplegar stack en Swarm | `main` | Copia `docker-compose.yml` y ejecuta `deploy-stack.sh` (login en ECR + `docker stack deploy`) |
| Verificar sistema en la nube | `main` | Hace login a través de Amazon API Gateway y espera respuesta 200 |

### Secrets del repositorio

| Secret | Valor |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Learner Lab → AWS Details → AWS CLI (cambian en cada sesión del laboratorio) |
| `EC2_SSH_KEY` | Contenido completo de `labsuser.pem` (Learner Lab → AWS Details → Download PEM) |
| `DB_PASSWORD` | Contraseña de MySQL para el clúster |

## 7. Orden de la primera puesta en marcha

1. Iniciar el laboratorio en AWS Academy y cargar los secrets en los 7 repositorios.
2. Ejecutar el pipeline de **ms-auth, ms-productos, ms-ventas, ms-inventario y api-gateway** (push a `main`): crea los repositorios ECR y sube las imágenes.
3. Ejecutar el pipeline de **fn-alertas-inventario**: crea la cola SQS, la DLQ y la función Lambda.
4. Ejecutar el pipeline de **infraestructura-swarm**: crea el clúster, despliega el stack y verifica.
5. Agregar el secret `EC2_HOST` (salida `IpPublicaManager`) a los 5 repositorios de microservicios. Desde ese momento, cada push a `main` de un microservicio actualiza su servicio en el clúster automáticamente.

## 8. Flujo completo de prueba

1. `POST {UrlApiGateway}/api/auth/login` → token.
2. Crear categoría, producto e inventario con `stockMinimo: 5` y un lote de 10 unidades.
3. `POST {UrlApiGateway}/api/ventas` con 5 unidades → stock 5 (llega al mínimo).
4. ms-inventario publica la alerta en SQS → la Lambda la procesa:
   ```bash
   aws logs tail /aws/lambda/fn-alertas-inventario --since 10m
   ```
5. Escalar durante la prueba (`docker service scale sistema_ms-ventas=4`) y repetir la venta para verificar que el sistema sigue respondiendo.
