output "gateway_url" {
  description = "URL publica de la API (va en VITE_API_URL del front; el WebSocket es wss://<lo mismo>/ws)"
  value       = "https://${module.gateway.fqdn}"
}

output "eventhubs" {
  description = "Namespace de Event Hubs (Kafka)"
  value       = azurerm_eventhub_namespace.c15.name
}
