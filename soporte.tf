# RabbitMQ (relay STOMP) y Redis (estado compartido entre replicas) como contenedores internos.
# Redis no guarda nada en disco a proposito: todo lo que tiene caduca en 1 h o menos (regla del profe).

resource "random_password" "rabbit" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

module "rabbitmq" {
  source     = "./modulos/servicio"
  nombre     = "c15-rabbitmq"
  grupo      = data.azurerm_resource_group.c15.name
  entorno_id = azurerm_container_app_environment.c15.id
  imagen     = "rabbitmq:4.3.6-management-alpine"
  cpu        = 0.5
  memoria    = "1Gi"
  transporte = "tcp"
  puerto     = 61613
  tags       = local.tags
  # Habilita el plugin STOMP (en local se monta el archivo enabled_plugins)
  comando = ["sh", "-c", "echo '[rabbitmq_management,rabbitmq_stomp].' > /etc/rabbitmq/enabled_plugins && exec docker-entrypoint.sh rabbitmq-server"]
  entorno = {
    RABBITMQ_DEFAULT_USER = "c15"
  }
  secretos = {
    RABBITMQ_DEFAULT_PASS = random_password.rabbit.result
  }
}

module "redis" {
  source     = "./modulos/servicio"
  nombre     = "c15-redis"
  grupo      = data.azurerm_resource_group.c15.name
  entorno_id = azurerm_container_app_environment.c15.id
  imagen     = "redis:8.8.2-alpine"
  cpu        = 0.25
  memoria    = "0.5Gi"
  transporte = "tcp"
  puerto     = 6379
  tags       = local.tags
  comando    = ["sh", "-c", "exec redis-server --requirepass \"$REDIS_CLAVE\" --save '' --appendonly no"]
  secretos = {
    REDIS_CLAVE = random_password.redis.result
  }
}
