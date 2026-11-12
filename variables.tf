variable "suscripcion" {
  description = "Suscripcion de Azure donde vive todo"
  type        = string
  default     = "f959f171-df81-4117-92b2-b95e9d672f6a"
}

variable "grupo" {
  description = "Grupo de recursos (ya existe; no lo crea Terraform)"
  type        = string
  default     = "Escape_Room_RG"
}

variable "region" {
  description = "Region de todo lo nuevo: la misma del Postgres, para que la latencia a la base sea minima"
  type        = string
  default     = "northcentralus"
}

variable "imagenes" {
  description = "Prefijo de las imagenes en GHCR (las publica el pipeline de cada repo)"
  type        = string
  default     = "ghcr.io/juanlopeztw"
}

variable "replicas" {
  description = "Replicas fijas por servicio (escalado manual: se cambia aqui y se hace apply)"
  type        = map(number)
  default = {
    gateway  = 1
    broker   = 1
    salas    = 1
    gameplay = 1
    social   = 1
  }
}

variable "kafka_administrado" {
  description = "true: Event Hubs (requiere Microsoft.EventHub registrado en la suscripcion). false: Kafka en un contenedor interno"
  type        = bool
  default     = false
}

variable "cors_origenes" {
  description = "Origenes que el gateway deja llamar a la API (el front en Azure Static Web Apps)"
  type        = string
  # localhost:5173 = npm run dev contra Azure, solo mientras se prueba (quitarlo despues de la presentacion)
  default = "https://mango-coast-0b946ea10.3.azurestaticapps.net,http://localhost:5173"
}

# ---------- Postgres que ya existe ----------

variable "postgres_servidor" {
  description = "Nombre del Postgres Flexible Server existente"
  type        = string
  default     = "escaperoomserverbd"
}

variable "postgres_admin" {
  description = "Usuario administrador del Postgres (solo lo usa Terraform para crear bases y usuarios)"
  type        = string
  default     = "AdminER"
}

variable "postgres_admin_clave" {
  description = "Clave del administrador. Nunca en un archivo: se pasa con la variable de entorno TF_VAR_postgres_admin_clave"
  type        = string
  sensitive   = true
}
