output "nombre" {
  value = azurerm_container_app.app.name
}

output "fqdn" {
  value = azurerm_container_app.app.ingress[0].fqdn
}

output "id" {
  value = azurerm_container_app.app.id
}
