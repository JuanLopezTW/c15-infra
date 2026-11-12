# Los 5 microservicios. La imagen la crea Terraform solo la primera vez: despues la cambia el pipeline
# de cada repo (por eso el modulo ignora los cambios de imagen).

locals {
  # Conexion a Kafka segun el interruptor kafka_administrado (variables.tf)
  kafka_event_hubs = tomap({
    KAFKA_SERVIDORES   = "${try(azurerm_eventhub_namespace.c15[0].name, "")}.servicebus.windows.net:9093"
    KAFKA_CREAR_TOPICS = "false" # los crea Terraform (eventos.tf)
    # Conexion a Event Hubs con la API de Kafka (Spring Boot las lee como spring.kafka.properties.*)
    SPRING_KAFKA_PROPERTIES_SECURITY_PROTOCOL = "SASL_SSL"
    SPRING_KAFKA_PROPERTIES_SASL_MECHANISM    = "PLAIN"
    # Event Hubs cierra las conexiones quietas a los 240 s: se renuevan antes
    SPRING_KAFKA_PROPERTIES_METADATA_MAX_AGE_MS         = "180000"
    SPRING_KAFKA_PROPERTIES_CONNECTIONS_MAX_IDLE_MS     = "180000"
    SPRING_KAFKA_PRODUCER_PROPERTIES_ENABLE_IDEMPOTENCE = "false"
  })
  kafka_contenedor = tomap({
    KAFKA_SERVIDORES   = "${try(module.kafka[0].nombre, "")}:9092"
    KAFKA_CREAR_TOPICS = "true" # igual que en local: los crea cada servicio al arrancar
  })

  # Lo que comparten broker, salas, gameplay y social (igual que el compose)
  entorno_comun = merge(
    var.kafka_administrado ? local.kafka_event_hubs : local.kafka_contenedor,
    {
      EVENTOS_KAFKA = "true"
      STOMP_RELAY   = "true"
      STOMP_HOST    = module.rabbitmq.nombre
      STOMP_PUERTO  = "61613"
      STOMP_USUARIO = "c15"
      ESTADO_REDIS  = "true"
      REDIS_HOST    = module.redis.nombre
      REDIS_PUERTO  = "6379"
    }
  )

  secretos_comunes = merge(
    var.kafka_administrado ? tomap({
      SPRING_KAFKA_PROPERTIES_SASL_JAAS_CONFIG = "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$ConnectionString\" password=\"${try(azurerm_eventhub_namespace_authorization_rule.servicios[0].primary_connection_string, "")}\";"
    }) : tomap({}),
    {
      STOMP_CLAVE = random_password.rabbit.result
      REDIS_CLAVE = random_password.redis.result
    }
  )

  postgres = "${var.postgres_servidor}.postgres.database.azure.com"

  base_de = {
    for s in local.con_base : s => {
      DB_HOST     = local.postgres
      DB_NAME     = postgresql_database.servicio[s].name
      DB_USERNAME = postgresql_role.servicio[s].name
      # El Postgres B1ms deja 35 conexiones para apps: 5 por replica (Spring trae 10) deja espacio para
      # escalar a mano y para Terraform
      SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE = "5"
    }
  }
}

module "broker" {
  source     = "./modulos/servicio"
  nombre     = "c15-broker"
  grupo      = data.azurerm_resource_group.c15.name
  entorno_id = azurerm_container_app_environment.c15.id
  imagen     = "${var.imagenes}/c15-broker:latest"
  replicas   = var.replicas.broker
  jvm        = true
  tags       = local.tags
  entorno    = local.entorno_comun
  secretos   = local.secretos_comunes
}

module "salas" {
  source     = "./modulos/servicio"
  nombre     = "c15-salas"
  grupo      = data.azurerm_resource_group.c15.name
  entorno_id = azurerm_container_app_environment.c15.id
  imagen     = "${var.imagenes}/c15-salas:latest"
  replicas   = var.replicas.salas
  jvm        = true
  tags       = local.tags
  entorno    = merge(local.entorno_comun, local.base_de.salas)
  secretos   = merge(local.secretos_comunes, { DB_PASSWORD = random_password.bd["salas"].result })
}

module "gameplay" {
  source     = "./modulos/servicio"
  nombre     = "c15-gameplay"
  grupo      = data.azurerm_resource_group.c15.name
  entorno_id = azurerm_container_app_environment.c15.id
  imagen     = "${var.imagenes}/c15-gameplay:latest"
  replicas   = var.replicas.gameplay
  jvm        = true
  tags       = local.tags
  entorno    = merge(local.entorno_comun, local.base_de.gameplay)
  secretos   = merge(local.secretos_comunes, { DB_PASSWORD = random_password.bd["gameplay"].result })
}

module "social" {
  source     = "./modulos/servicio"
  nombre     = "c15-social"
  grupo      = data.azurerm_resource_group.c15.name
  entorno_id = azurerm_container_app_environment.c15.id
  imagen     = "${var.imagenes}/c15-social:latest"
  replicas   = var.replicas.social
  jvm        = true
  tags       = local.tags
  entorno = merge(local.entorno_comun, local.base_de.social, {
    SALAS_URL = "http://${module.salas.nombre}" # el chat del lobby le pregunta a salas
  })
  secretos = merge(local.secretos_comunes, { DB_PASSWORD = random_password.bd["social"].result })
}

# La unica puerta publica: HTTPS lo pone Azure, y reparte entre las replicas de cada servicio
module "gateway" {
  source     = "./modulos/servicio"
  nombre     = "c15-gateway"
  grupo      = data.azurerm_resource_group.c15.name
  entorno_id = azurerm_container_app_environment.c15.id
  imagen     = "${var.imagenes}/c15-gateway:latest"
  replicas   = var.replicas.gateway
  jvm        = true
  publico    = true
  tags       = local.tags
  entorno = {
    BROKER_URL    = "http://${module.broker.nombre}"
    SALAS_URL     = "http://${module.salas.nombre}"
    GAMEPLAY_URL  = "http://${module.gameplay.nombre}"
    SOCIAL_URL    = "http://${module.social.nombre}"
    CORS_ORIGENES = var.cors_origenes
  }
}
