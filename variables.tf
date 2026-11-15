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

variable "modo_produccion" {
  description = "true: minimo 2 replicas por servicio (escenarios D1, D2 y R1, y la presentacion). false: minimo 1, para no gastar credito en reposo"
  type        = bool
  default     = false
}

variable "caida_simulada" {
  description = "true: broker y gameplay exponen POST /dev/caida/<servicio> (solo admin) para la prueba de caida D1. Prenderlo solo durante la prueba"
  type        = bool
  default     = false
}

variable "max_replicas" {
  description = "Tope del autoescalado por servicio (D2)"
  type        = number
  default     = 5
}

variable "cpu_objetivo" {
  # 40 % y no 70 %: una replica nueva tarda ~2 min en estar lista (arranque de Java + readiness), asi que se pide
  # antes de que la carga se note. Con 128 jugadores en rampa la CPU se quedo en ~52 % y al 70 % nunca escalaba.
  description = "Uso de CPU (%) que dispara una replica mas (D2)"
  type        = number
  default     = 40
}

variable "replicas_fijas" {
  description = "Escalado manual: servicio -> replicas fijas (sin autoescalado), p. ej. { gameplay = 3 }"
  type        = map(number)
  default     = {}
}

variable "kafka_administrado" {
  description = "true: Event Hubs (requiere Microsoft.EventHub registrado en la suscripcion). false: Kafka en un contenedor interno"
  type        = bool
  default     = true
}

variable "balanceador_azure" {
  description = "Plan B: Azure Front Door delante del gateway (~1,2 USD/dia). Requiere Microsoft.Cdn registrado"
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
