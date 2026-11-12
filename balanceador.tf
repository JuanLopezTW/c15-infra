# Plan B del balanceador (balanceador_azure = true): Azure Front Door delante del gateway, como servicio de
# balanceo de Azure explicito. Apagado por defecto (cuesta ~1,2 USD/dia): se prende solo si se exige.
# Container Apps ya balancea entre replicas con su ingress; Front Door suma el punto de entrada global con
# HTTPS propio (*.azurefd.net) y comprobacion de salud del origen.
# Requiere el proveedor Microsoft.Cdn registrado en la suscripcion (lo hace el dueno, ver README).

resource "azurerm_cdn_frontdoor_profile" "c15" {
  count               = var.balanceador_azure ? 1 : 0
  name                = "c15-balanceador"
  resource_group_name = data.azurerm_resource_group.c15.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = local.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "c15" {
  count                    = var.balanceador_azure ? 1 : 0
  name                     = "c15-juego-${substr(md5(data.azurerm_resource_group.c15.id), 0, 6)}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.c15[0].id
  tags                     = local.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "c15" {
  count                    = var.balanceador_azure ? 1 : 0
  name                     = "gateway"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.c15[0].id

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }

  # Solo manda trafico a un origen que responde
  health_probe {
    path                = "/api/version"
    protocol            = "Https"
    request_type        = "GET"
    interval_in_seconds = 30
  }
}

resource "azurerm_cdn_frontdoor_origin" "gateway" {
  count                          = var.balanceador_azure ? 1 : 0
  name                           = "c15-gateway"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.c15[0].id
  enabled                        = true
  host_name                      = module.gateway.fqdn
  origin_host_header             = module.gateway.fqdn
  https_port                     = 443
  certificate_name_check_enabled = true
  priority                       = 1
  weight                         = 1000
}

# Todo pasa tal cual (sin cache: es una API y un WebSocket)
resource "azurerm_cdn_frontdoor_route" "c15" {
  count                         = var.balanceador_azure ? 1 : 0
  name                          = "todo"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.c15[0].id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.c15[0].id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.gateway[0].id]
  supported_protocols           = ["Http", "Https"]
  patterns_to_match             = ["/*"]
  forwarding_protocol           = "HttpsOnly"
  https_redirect_enabled        = true
  link_to_default_domain        = true
}
