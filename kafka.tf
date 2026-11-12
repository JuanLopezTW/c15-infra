# Kafka en un contenedor interno (un nodo KRaft, igual que el compose local), mientras Event Hubs no este
# disponible (kafka_administrado = false). Sin disco: si se reinicia se pierden los eventos que iban en
# camino; lo guardado (salas, resultados, ranking) vive en Postgres.

module "kafka" {
  count      = var.kafka_administrado ? 0 : 1
  source     = "./modulos/servicio"
  nombre     = "c15-kafka"
  grupo      = data.azurerm_resource_group.c15.name
  entorno_id = azurerm_container_app_environment.c15.id
  imagen     = "apache/kafka:4.1.0"
  cpu        = 0.5
  memoria    = "1Gi"
  transporte = "tcp"
  puerto     = 9092
  jvm        = true
  tags       = local.tags
  entorno = {
    KAFKA_NODE_ID                                  = "1"
    KAFKA_PROCESS_ROLES                            = "broker,controller"
    KAFKA_LISTENERS                                = "PLAINTEXT://:9092,CONTROLLER://:9093"
    KAFKA_ADVERTISED_LISTENERS                     = "PLAINTEXT://c15-kafka:9092"
    KAFKA_CONTROLLER_LISTENER_NAMES                = "CONTROLLER"
    KAFKA_LISTENER_SECURITY_PROTOCOL_MAP           = "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
    KAFKA_CONTROLLER_QUORUM_VOTERS                 = "1@localhost:9093"
    KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR         = "1"
    KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR = "1"
    KAFKA_TRANSACTION_STATE_LOG_MIN_ISR            = "1"
    KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS         = "0"
    KAFKA_LOG_RETENTION_HOURS                      = "24"
    # Cabe en 1 GiB junto con lo que no es heap
    KAFKA_HEAP_OPTS = "-Xmx512m -Xms512m"
  }
}
