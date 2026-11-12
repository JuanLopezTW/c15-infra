output "gateway_url" {
  description = "URL publica de la API (va en VITE_API_URL del front; el WebSocket es wss://<lo mismo>/ws)"
  value       = "https://${module.gateway.fqdn}"
}

output "kafka" {
  description = "Donde van los eventos entre servicios"
  value       = var.kafka_administrado ? "Event Hubs: ${try(azurerm_eventhub_namespace.c15[0].name, "")}" : "Kafka en contenedor: c15-kafka:9092"
}

output "balanceador_url" {
  description = "Con balanceador_azure = true: URL de Front Door (va en VITE_API_URL; el WebSocket es wss://<lo mismo>/ws)"
  value       = var.balanceador_azure ? "https://${try(azurerm_cdn_frontdoor_endpoint.c15[0].host_name, "")}" : "(apagado)"
}
