terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Crea las bases y los usuarios de cada servicio dentro del Postgres que ya existe
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.25"
    }
  }

  # El state vive en un Storage Account privado (nunca en git: guarda las claves generadas).
  # Se crea una sola vez con los comandos del README.
  backend "azurerm" {
    subscription_id      = "f959f171-df81-4117-92b2-b95e9d672f6a"
    resource_group_name  = "Escape_Room_RG"
    storage_account_name = "c15infratfstate"
    container_name       = "tfstate"
    key                  = "c15.tfstate"
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.suscripcion
  # Registrar proveedores es de toda la suscripcion y nuestro permiso es solo del grupo:
  # los registra el dueno de la suscripcion (ver README).
  resource_provider_registrations = "none"
}

provider "postgresql" {
  host            = "${var.postgres_servidor}.postgres.database.azure.com"
  port            = 5432
  database        = "postgres"
  username        = var.postgres_admin
  password        = var.postgres_admin_clave
  sslmode         = "require"
  superuser       = false # en Azure el admin no es superusuario
  connect_timeout = 15
}
