# Eventos entre servicios: Event Hubs con la API de Kafka (los servicios no cambian, solo la conexion).
# Solo existe con kafka_administrado = true: requiere que el dueno de la suscripcion haya registrado
# Microsoft.EventHub (ver README). Mientras tanto se usa el Kafka en contenedor (kafka.tf).

locals {
  # Los mismos topics que crea el compose local (TopicosEventos de cada servicio), con el prefijo c15.
  topicos = ["partida-iniciada", "partida-terminada", "sala-cerrada", "sesion"]
}

resource "azurerm_eventhub_namespace" "c15" {
  count = var.kafka_administrado ? 1 : 0
  # El nombre es global en Azure: se le agrega un sufijo fijo del grupo
  name                = "c15-eventos-${substr(md5(data.azurerm_resource_group.c15.id), 0, 6)}"
  location            = var.region
  resource_group_name = data.azurerm_resource_group.c15.name
  sku                 = "Standard" # Basic no tiene Kafka
  capacity            = 1
  minimum_tls_version = "1.2"
  tags                = local.tags
}

resource "azurerm_eventhub" "topicos" {
  for_each          = var.kafka_administrado ? toset(local.topicos) : toset([])
  name              = "c15.${each.key}"
  namespace_id      = azurerm_eventhub_namespace.c15[0].id
  partition_count   = 3 # igual que en local: las replicas de un servicio se reparten las particiones
  message_retention = 1 # dias
}

# Credencial de los servicios: solo enviar y escuchar (no pueden crear ni borrar topics)
resource "azurerm_eventhub_namespace_authorization_rule" "servicios" {
  count               = var.kafka_administrado ? 1 : 0
  name                = "servicios"
  namespace_name      = azurerm_eventhub_namespace.c15[0].name
  resource_group_name = data.azurerm_resource_group.c15.name
  listen              = true
  send                = true
  manage              = false
}
