# El grupo ya existe (Owner del grupo, no de la suscripcion): Terraform solo lo lee
data "azurerm_resource_group" "c15" {
  name = var.grupo
}

locals {
  tags = { proyecto = "escaperoom-c15", gestionado = "terraform" }
}

# ---------- Logs ----------

resource "azurerm_log_analytics_workspace" "c15" {
  name                = "c15-logs"
  location            = var.region
  resource_group_name = data.azurerm_resource_group.c15.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  # Tope diario para que un error que llene los logs no se coma el credito
  daily_quota_gb = 1
  tags           = local.tags
}

# ---------- Red ----------
# RabbitMQ (STOMP) y Redis hablan TCP, no HTTP: en Container Apps eso exige que el entorno este en una red propia.

resource "azurerm_virtual_network" "c15" {
  name                = "c15-red"
  location            = var.region
  resource_group_name = data.azurerm_resource_group.c15.name
  address_space       = ["10.20.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "apps" {
  name                 = "c15-apps"
  resource_group_name  = data.azurerm_resource_group.c15.name
  virtual_network_name = azurerm_virtual_network.c15.name
  address_prefixes     = ["10.20.0.0/23"]

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ---------- Entorno de Container Apps ----------
# Todas las apps comparten este entorno: se ven entre ellas por nombre (http://c15-salas, c15-redis:6379...)
# y solo el gateway queda publico.

resource "azurerm_container_app_environment" "c15" {
  name                       = "c15-entorno"
  location                   = var.region
  resource_group_name        = data.azurerm_resource_group.c15.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.c15.id
  infrastructure_subnet_id   = azurerm_subnet.apps.id
  tags                       = local.tags

  # Plan de consumo: se paga por lo que usan las replicas
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  lifecycle {
    # Azure le pone nombre solo al grupo de infraestructura que administra
    ignore_changes = [infrastructure_resource_group_name]
  }
}
