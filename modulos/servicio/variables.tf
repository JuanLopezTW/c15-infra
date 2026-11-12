variable "nombre" {
  description = "Nombre de la Container App (los demas la encuentran por este nombre dentro del entorno)"
  type        = string
}

variable "grupo" {
  type = string
}

variable "entorno_id" {
  type = string
}

variable "imagen" {
  description = "Imagen inicial (despues la cambia el pipeline del repo)"
  type        = string
}

variable "min_replicas" {
  type    = number
  default = 1
}

variable "max_replicas" {
  type    = number
  default = 1
}

variable "cpu_objetivo" {
  description = "Uso de CPU (%) que dispara una replica mas. null: sin autoescalado"
  type        = number
  default     = null
}

variable "cpu" {
  type    = number
  default = 0.5
}

variable "memoria" {
  type    = string
  default = "1Gi"
}

variable "publico" {
  description = "true: accesible desde internet (solo el gateway). false: solo dentro del entorno"
  type        = bool
  default     = false
}

variable "transporte" {
  description = "http (servicios) o tcp (RabbitMQ, Redis)"
  type        = string
  default     = "http"
}

variable "puerto" {
  type    = number
  default = 8080
}

variable "jvm" {
  description = "Servicio Spring: le da tiempo de arrancar antes de darlo por caido"
  type        = bool
  default     = false
}

variable "comando" {
  type    = list(string)
  default = null
}

variable "entorno" {
  description = "Variables de entorno que no son secretas"
  type        = map(string)
  default     = {}
}

variable "secretos" {
  description = "Variables de entorno secretas: se guardan como secretos de la app, no en texto plano"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "identidad_id" {
  description = "Id de una identidad administrada (para llamar servicios de Azure sin claves guardadas). null: sin identidad"
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
