# Los 5 microservicios. La imagen la crea Terraform solo la primera vez: despues la cambia el pipeline
# de cada repo (por eso el modulo ignora los cambios de imagen).

locals {
  # Replicas de cada servicio: fijas si se pidio (escalado manual) o autoescalado por CPU (D2)
  escala = {
    for s in ["gateway", "broker", "salas", "gameplay", "social"] : s => (
      contains(keys(var.replicas_fijas), s)
      ? { min = var.replicas_fijas[s], max = var.replicas_fijas[s], cpu = null }
      : { min = var.modo_produccion ? 2 : 1, max = var.max_replicas, cpu = var.cpu_objetivo }
    )
  }

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

  # Prueba de caida D1 (CaidaSimuladaController): solo en broker y gameplay, y solo si se pide
  caida = var.caida_simulada ? { C15_CAIDA_SIMULADA_ACTIVA = "true" } : {}

  postgres = "${var.postgres_servidor}.postgres.database.azure.com"

  base_de = {
    for s in local.con_base : s => {
      DB_HOST     = local.postgres
      DB_NAME     = postgresql_database.servicio[s].name
      DB_USERNAME = postgresql_role.servicio[s].name
      # El Postgres B1ms deja 35 conexiones para apps: con hasta 5 replicas de cada uno de los 3 servicios
      # con base, 2 por replica (Spring trae 10) son 30. El estado vivo del juego esta en Redis, no aqui.
      SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE = "2"
    }
  }
}

module "broker" {
  source       = "./modulos/servicio"
  nombre       = "c15-broker"
  grupo        = data.azurerm_resource_group.c15.name
  entorno_id   = azurerm_container_app_environment.c15.id
  imagen       = "${var.imagenes}/c15-broker:latest"
  min_replicas = local.escala.broker.min
  max_replicas = local.escala.broker.max
  cpu_objetivo = local.escala.broker.cpu
  jvm          = true
  tags         = local.tags
  entorno      = merge(local.entorno_comun, local.caida)
  secretos     = local.secretos_comunes
}

module "salas" {
  source       = "./modulos/servicio"
  nombre       = "c15-salas"
  grupo        = data.azurerm_resource_group.c15.name
  entorno_id   = azurerm_container_app_environment.c15.id
  imagen       = "${var.imagenes}/c15-salas:latest"
  min_replicas = local.escala.salas.min
  max_replicas = local.escala.salas.max
  cpu_objetivo = local.escala.salas.cpu
  jvm          = true
  tags         = local.tags
  entorno      = merge(local.entorno_comun, local.base_de.salas)
  secretos     = merge(local.secretos_comunes, { DB_PASSWORD = random_password.bd["salas"].result })
}

module "gameplay" {
  source       = "./modulos/servicio"
  nombre       = "c15-gameplay"
  grupo        = data.azurerm_resource_group.c15.name
  entorno_id   = azurerm_container_app_environment.c15.id
  imagen       = "${var.imagenes}/c15-gameplay:latest"
  min_replicas = local.escala.gameplay.min
  max_replicas = local.escala.gameplay.max
  cpu_objetivo = local.escala.gameplay.cpu
  jvm          = true
  tags         = local.tags
  entorno      = merge(local.entorno_comun, local.base_de.gameplay, local.caida)
  secretos     = merge(local.secretos_comunes, { DB_PASSWORD = random_password.bd["gameplay"].result })
}

module "social" {
  source       = "./modulos/servicio"
  nombre       = "c15-social"
  grupo        = data.azurerm_resource_group.c15.name
  entorno_id   = azurerm_container_app_environment.c15.id
  imagen       = "${var.imagenes}/c15-social:latest"
  min_replicas = local.escala.social.min
  max_replicas = local.escala.social.max
  cpu_objetivo = local.escala.social.cpu
  jvm          = true
  tags         = local.tags
  identidad_id = azurerm_user_assigned_identity.social.id # lee los logs centralizados para el admin
  entorno = merge(local.entorno_comun, local.base_de.social, {
    SALAS_URL               = "http://${module.salas.nombre}" # el chat del lobby le pregunta a salas
    LOG_ANALYTICS_WORKSPACE = azurerm_log_analytics_workspace.c15.workspace_id
    AZURE_CLIENT_ID         = azurerm_user_assigned_identity.social.client_id # que identidad usar al pedir el token
  })
  secretos = merge(local.secretos_comunes, { DB_PASSWORD = random_password.bd["social"].result })
}

# La unica puerta publica: HTTPS lo pone Azure, y reparte entre las replicas de cada servicio
module "gateway" {
  source       = "./modulos/servicio"
  nombre       = "c15-gateway"
  grupo        = data.azurerm_resource_group.c15.name
  entorno_id   = azurerm_container_app_environment.c15.id
  imagen       = "${var.imagenes}/c15-gateway:latest"
  min_replicas = local.escala.gateway.min
  max_replicas = local.escala.gateway.max
  cpu_objetivo = local.escala.gateway.cpu
  jvm          = true
  publico      = true
  tags         = local.tags
  entorno = {
    BROKER_URL    = "http://${module.broker.nombre}"
    SALAS_URL     = "http://${module.salas.nombre}"
    GAMEPLAY_URL  = "http://${module.gameplay.nombre}"
    SOCIAL_URL    = "http://${module.social.nombre}"
    CORS_ORIGENES = var.cors_origenes
  }
}

# El admin (en social) consulta los logs de todos los servicios con esta identidad, sin claves guardadas:
# solo lectura y solo sobre ese workspace
resource "azurerm_user_assigned_identity" "social" {
  name                = "c15-social-identidad"
  location            = var.region
  resource_group_name = data.azurerm_resource_group.c15.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "social_lee_logs" {
  scope                = azurerm_log_analytics_workspace.c15.id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_user_assigned_identity.social.principal_id
}
