# Una base y un usuario por servicio dentro del Postgres que ya existe.
# Cada usuario es dueno solo de su base: gameplay no puede entrar a la de salas.

locals {
  con_base = toset(["salas", "gameplay", "social"])
}

resource "random_password" "bd" {
  for_each = local.con_base
  length   = 32
  special  = false
}

resource "postgresql_role" "servicio" {
  for_each = local.con_base
  name     = "c15_${each.key}"
  login    = true
  password = random_password.bd[each.key].result
}

resource "postgresql_database" "servicio" {
  for_each = local.con_base
  name     = "c15_${each.key}"
  owner    = postgresql_role.servicio[each.key].name
}

# Por defecto cualquier usuario puede conectarse a cualquier base: se le quita a PUBLIC
resource "postgresql_grant" "sin_publico" {
  for_each    = local.con_base
  database    = postgresql_database.servicio[each.key].name
  role        = "public"
  object_type = "database"
  privileges  = []
}

# Desde Postgres 15 solo el dueno del esquema public crea tablas en el, y en Azure ese dueno es el grupo
# administrador, no el dueno de la base. Cada servicio recibe permiso de crear y usar public solo en SU base.
resource "postgresql_grant" "esquema" {
  for_each    = local.con_base
  database    = postgresql_database.servicio[each.key].name
  role        = postgresql_role.servicio[each.key].name
  schema      = "public"
  object_type = "schema"
  privileges  = ["CREATE", "USAGE"]
}
