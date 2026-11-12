locals {
  # Los nombres de los secretos son publicos (solo el valor es secreto): se pueden usar en for_each
  secretos = nonsensitive(toset(keys(var.secretos)))
  # Nombre del secreto en Azure: minusculas y guiones (DB_PASSWORD -> db-password)
  nombre_secreto = { for k in local.secretos : k => lower(replace(k, "_", "-")) }
}

resource "azurerm_container_app" "app" {
  name                         = var.nombre
  container_app_environment_id = var.entorno_id
  resource_group_name          = var.grupo
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  dynamic "identity" {
    for_each = var.identidad_id == null ? [] : [1]
    content {
      type         = "UserAssigned"
      identity_ids = [var.identidad_id]
    }
  }

  dynamic "secret" {
    for_each = local.secretos
    content {
      name  = local.nombre_secreto[secret.value]
      value = var.secretos[secret.value]
    }
  }

  ingress {
    external_enabled = var.publico
    target_port      = var.puerto
    exposed_port     = var.transporte == "tcp" ? var.puerto : null
    transport        = var.transporte

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    # Autoescalado (D2): agrega replicas cuando el uso de CPU pasa el objetivo y las quita cuando baja
    dynamic "custom_scale_rule" {
      for_each = var.cpu_objetivo == null ? [] : [1]
      content {
        name             = "cpu"
        custom_rule_type = "cpu"
        metadata = {
          type  = "Utilization"
          value = tostring(var.cpu_objetivo)
        }
      }
    }

    container {
      name    = var.nombre
      image   = var.imagen
      cpu     = var.cpu
      memory  = var.memoria
      command = var.comando

      dynamic "env" {
        for_each = var.entorno
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secretos
        content {
          name        = env.value
          secret_name = local.nombre_secreto[env.value]
        }
      }

      # Una replica recibe trafico solo cuando Spring ya responde (/api/version es publica y no toca nada)
      dynamic "readiness_probe" {
        for_each = var.jvm && var.transporte == "http" ? [1] : []
        content {
          transport               = "HTTP"
          path                    = "/api/version"
          port                    = var.puerto
          interval_seconds        = 5
          failure_count_threshold = 3
        }
      }

      # Spring tarda en abrir el puerto: hasta ~2 min antes de darlo por fallido
      dynamic "startup_probe" {
        for_each = var.jvm ? [1] : []
        content {
          transport               = "TCP"
          port                    = var.puerto
          initial_delay           = 10
          interval_seconds        = 10
          failure_count_threshold = 10
        }
      }
    }
  }

  lifecycle {
    # La version que corre la decide el pipeline de cada repo, no Terraform
    ignore_changes = [template[0].container[0].image]
  }
}
