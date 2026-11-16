# Los 2 tableros obligatorios (O2) como Azure Workbooks, en el portal: Escape_Room_RG -> Workbooks.
# Las cifras de negocio y de peticiones salen de los logs centralizados (consolidados entre replicas: una partida
# cuenta una vez); CPU, memoria y replicas, de las metricas de cada Container App; mensajes, de Event Hubs.
# Se actualizan solos.

locals {
  workspace_id = lower(azurerm_log_analytics_workspace.c15.id)
  # Por nombre (no por el modulo) para que el tablero no dependa de cambios pendientes de las apps
  apps_ids = [for a in ["c15-gateway", "c15-broker", "c15-salas", "c15-gameplay", "c15-social"] :
  "${data.azurerm_resource_group.c15.id}/providers/Microsoft.App/containerApps/${a}"]

  # ---------- consultas (el periodo lo pone el selector del tablero) ----------
  kql_logs = <<-KQL
    ContainerAppConsoleLogs_CL
    | extend j = parse_json(Log_s)
    | extend evento = tostring(j.evento)
  KQL
  # Peticiones de jugadores en todos los puntos (gateway incluido). No cuentan /api/version (comprobacion de salud)
  # ni /api/admin (el panel del admin consulta Log Analytics y tarda segundos: marcaria degradado a quien lo atiende)
  kql_peticiones_todas = <<-KQL
    ${local.kql_logs}| where evento == 'http.peticion' and tostring(j.http.ruta) != '/api/version'
        and not(tostring(j.http.ruta) startswith '/api/admin')
  KQL
  # Solo en los servicios: cada peticion cuenta una vez (el gateway la registra tambien al pasarla)
  kql_peticiones = <<-KQL
    ${local.kql_peticiones_todas}| where ContainerAppName_s != 'c15-gateway'
  KQL

  kql_negocio_totales = <<-KQL
    ${local.kql_logs}| where ContainerAppName_s != 'c15-gateway'
    | summarize
        ['Jugadores activos'] = dcountif(tostring(j.userId), evento == 'http.peticion' and isnotempty(tostring(j.userId))),
        ['Sesiones iniciadas'] = countif(evento == 'stomp.conectado'),
        ['Jugadores nuevos'] = countif(evento == 'perfil.registrado'),
        ['Salas creadas'] = countif(evento == 'sala.creada'),
        ['Partidas jugadas'] = dcountif(tostring(j.matchId), evento == 'partida.terminada'),
        ['Acertijos resueltos'] = countif(evento == 'acertijo.resuelto'),
        ['Retos Heroe vs Verdugo'] = countif(evento == 'reto.terminado'),
        ['Mensajes de chat'] = countif(evento == 'chat.mensaje_enviado'),
        ['Acciones en tiempo real'] = countif(evento == 'http.peticion' and tostring(j.http.metodo) != 'GET')
    | evaluate narrow()
    | project Indicador = Column, Valor = toint(Value)
  KQL

  kql_negocio_duracion = <<-KQL
    ${local.kql_logs}| where evento in ('partida.iniciada', 'partida.terminada')
    | summarize inicio = minif(TimeGenerated, evento == 'partida.iniciada'), fin = maxif(TimeGenerated, evento == 'partida.terminada')
        by matchId = tostring(j.matchId)
    | where isnotempty(inicio) and isnotempty(fin)
    | summarize ['Duracion promedio de una partida (min)'] = round(avg(fin - inicio) / 1m, 1), ['Partidas medidas'] = count()
    | evaluate narrow()
    | project Indicador = Column, Valor = todouble(Value)
  KQL

  # Lo que hace el jugador (no las consultas GET ni las herramientas de admin /dev), con nombres para el gerente.
  # Una ruta que no este aqui aparece tal cual (METODO /ruta) en vez de perderse. Ojo: el Workbook toma cualquier
  # {texto} de la consulta como un parametro suyo, asi que la consulta compara con <matchId> (las llaves de la ruta
  # se cambian por < > con make_string, sin escribirlas).
  nombres_funciones = {
    "POST /api/partidas/{matchId}/jugadores/{userId}/movimiento"          = "Moverse en el mapa"
    "POST /api/partidas/{matchId}/objetos/{componenteMapaId}/recoleccion" = "Recoger un objeto"
    "POST /api/partidas/{matchId}/acertijos/{componenteMapaId}/bloqueo"   = "Abrir un acertijo"
    "DELETE /api/partidas/{matchId}/acertijos/{componenteMapaId}/bloqueo" = "Cerrar un acertijo"
    "POST /api/partidas/{matchId}/acertijos/{componenteMapaId}/solucion"  = "Responder un acertijo"
    "POST /api/partidas/{matchId}/acertijos/{componenteMapaId}/clicks"    = "Tocar un acertijo"
    "DELETE /api/partidas/{matchId}/acertijos/{componenteMapaId}/clicks"  = "Reiniciar un acertijo"
    "POST /api/partidas/{matchId}/reto/clicks"                            = "Clics en el reto Heroe vs Verdugo"
    "POST /api/chat/partidas/{matchId}"                                   = "Chat de la partida"
    "POST /api/chat/partidas/{matchId}/equipo"                            = "Chat del equipo"
    "POST /api/chat/salas/{salaId}"                                       = "Chat de la sala de espera"
    "POST /api/chat/global"                                               = "Chat del menu"
    "POST /api/salas"                                                     = "Crear una sala"
    "PATCH /api/salas/{salaId}/configuracion"                             = "Configurar la sala"
    "POST /api/salas/{salaId}/jugadores"                                  = "Entrar a una sala"
    "DELETE /api/salas/{salaId}/jugadores/{userId}"                       = "Salir de una sala"
    "POST /api/equipos/{equipoId}/miembros"                               = "Elegir equipo"
    "POST /api/salas/{salaId}/listo"                                      = "Marcarse listo"
    "DELETE /api/salas/{salaId}/listo"                                    = "Quitar el listo"
    "POST /api/perfil"                                                    = "Elegir nombre de jugador"
  }
  kql_negocio_mas_usadas = <<-KQL
    ${local.kql_peticiones}| extend metodo = tostring(j.http.metodo), ruta = tostring(j.http.ruta)
    | where metodo != 'GET' and not(ruta startswith '/dev/')
    | extend clave = replace_string(replace_string(strcat(metodo, ' ', ruta), make_string(123), '<'), make_string(125), '>')
    | summarize Usos = count() by clave
    | extend Funcion = case(${join(", ", [for k, v in local.nombres_funciones : "clave == '${replace(replace(k, "{", "<"), "}", ">")}', '${v}'"])}, clave)
    | summarize Usos = sum(Usos) by Funcion
    | top 10 by Usos
  KQL

  kql_negocio_jugadores_tiempo = <<-KQL
    ${local.kql_peticiones}| where isnotempty(tostring(j.userId))
    | summarize ['Jugadores activos'] = dcount(tostring(j.userId)) by bin(TimeGenerated, 5m)
  KQL

  kql_negocio_partidas_tiempo = <<-KQL
    ${local.kql_logs}| where evento in ('partida.iniciada', 'partida.terminada', 'acertijo.resuelto')
    | summarize Cantidad = count() by bin(TimeGenerated, 5m), Evento = evento
  KQL

  # Lo que siente el jugador: tiempos en la puerta de entrada (gateway); usuarios, de los servicios (tienen el userId)
  kql_tecnico_resumen = <<-KQL
    let entrada = ${replace(local.kql_peticiones_todas, "\n", " ")}
        | where ContainerAppName_s == 'c15-gateway'
        | extend ms = todouble(j.duracion.ms), estado = toint(j.http.estado)
        | summarize ['Peticiones'] = count(), ['Tiempo de respuesta promedio (ms)'] = round(avg(ms)),
            ['p95 en la entrada (ms)'] = round(percentile(ms, 95)), ['Errores 5xx'] = countif(estado >= 500)
        | extend ['% de errores'] = round(100.0 * ['Errores 5xx'] / max_of(['Peticiones'], 1), 2), k = 1;
    let usuarios = ${replace(local.kql_peticiones, "\n", " ")}
        | where TimeGenerated > ago(5m)
        | summarize ['Usuarios concurrentes (5 min)'] = dcount(tostring(j.userId))
        | extend k = 1;
    let conexiones = ${replace(local.kql_conexiones, "\n", " ")}
        | where TimeGenerated > ago(2m)
        | summarize arg_max(TimeGenerated, Conexiones) by Replica
        | summarize ['Conexiones de tiempo real (ahora)'] = sum(Conexiones)
        | extend k = 1;
    entrada
    | join kind=fullouter usuarios on k
    | join kind=fullouter conexiones on k
    | project-away k, k1, k2
    | evaluate narrow()
    | project Indicador = Column, Valor = todouble(Value)
  KQL

  # Solo las replicas de la version que corre cada servicio (las reemplazadas por un deploy no cuentan).
  # El estado mira los ULTIMOS 2 MIN (no todo el periodo elegido: si no, un minuto malo se diluye en una hora):
  # DEGRADADA: p95 > 300 ms o errores > 2 % en esos 2 min; SIN SENAL: 90 s sin ningun log (ni las comprobaciones de
  # salud, que llegan cada pocos segundos). Los logs tardan ~7 s en llegar: se detecta dentro de los 2 min (O2).
  kql_tecnico_replicas = <<-KQL
    let actuales = ContainerAppConsoleLogs_CL
        | summarize arg_max(TimeGenerated, RevisionName_s) by ContainerAppName_s
        | project Servicio = ContainerAppName_s, RevisionActual = RevisionName_s;
    let peticiones = ${replace(local.kql_peticiones_todas, "\n", " ")}
        | extend ms = todouble(j.duracion.ms), estado = toint(j.http.estado)
        | summarize Peticiones = count(), p50 = round(percentile(ms, 50)), p95 = round(percentile(ms, 95)),
            Errores5xx = countif(estado >= 500) by Servicio = ContainerAppName_s, Replica = ContainerGroupName_s;
    let recientes = ${replace(local.kql_peticiones_todas, "\n", " ")}
        | where TimeGenerated > ago(2m)
        | extend ms = todouble(j.duracion.ms), estado = toint(j.http.estado)
        | summarize p95Ahora = round(percentile(ms, 95)), PctErroresAhora = round(100.0 * countif(estado >= 500) / count(), 2)
            by Servicio = ContainerAppName_s, Replica = ContainerGroupName_s;
    ${replace(local.kql_logs, "\n", " ")}
    | where ContainerAppName_s !in ('c15-rabbitmq', 'c15-redis', 'c15-kafka')
    | summarize UltimaSenal = max(TimeGenerated), Excepciones = countif(tostring(j.log.level) == 'ERROR')
        by Servicio = ContainerAppName_s, Replica = ContainerGroupName_s, Revision = RevisionName_s
    | join kind=inner actuales on Servicio
    | where Revision == RevisionActual
    | join kind=leftouter peticiones on Servicio, Replica
    | join kind=leftouter recientes on Servicio, Replica
    | join kind=leftouter (${replace(local.kql_conexiones, "\n", " ")} | summarize arg_max(TimeGenerated, Conexiones) by Replica | project Replica, Conexiones) on Replica
    | extend PctErrores = round(100.0 * coalesce(Errores5xx, 0) / max_of(coalesce(Peticiones, 0), 1), 2)
    | extend Estado = case(UltimaSenal < ago(90s), 'SIN SENAL', p95Ahora > 300 or PctErroresAhora > 2, 'DEGRADADA', 'OK')
    | project Estado, Servicio, Replica, ['p95 ultimos 2 min'] = p95Ahora, ['% errores ultimos 2 min'] = PctErroresAhora,
        Peticiones = coalesce(Peticiones, 0), p50, p95, PctErrores, Excepciones, Conexiones, UltimaSenal
    | order by Estado asc, Servicio asc
  KQL

  kql_tecnico_p95_tiempo = <<-KQL
    ${local.kql_peticiones_todas}| summarize p95 = round(percentile(todouble(j.duracion.ms), 95)) by bin(TimeGenerated, 5m),
        Servicio = iff(ContainerAppName_s == 'c15-gateway', 'entrada (gateway)', ContainerAppName_s)
  KQL

  # Cada replica del broker reporta sus conexiones STOMP cada 30 s (ConexionesWebSocket)
  kql_conexiones = <<-KQL
    ${local.kql_logs}| where evento == 'ws.conexiones'
    | extend Replica = ContainerGroupName_s, Conexiones = toint(j.ws.conexiones)
  KQL

  kql_tecnico_conexiones_tiempo = <<-KQL
    ${local.kql_conexiones}| summarize Conexiones = max(Conexiones) by bin(TimeGenerated, 1m), Replica
  KQL

  # Seguridad (S1, S2, S3): lo rechazado en la API (contado en el gateway: cada intento una vez) y en el tiempo
  # real (el broker: CONNECT sin token valido, suscripciones o envios no permitidos)
  kql_seguridad = <<-KQL
    ${local.kql_logs}| extend estado = toint(j.http.estado)
    | where (evento == 'http.peticion' and ContainerAppName_s == 'c15-gateway' and estado in (401, 403, 429))
        or evento in ('stomp.rechazado', 'stomp.denegado')
    | extend Motivo = case(estado == 401, 'Sin token o token invalido (401)', estado == 403, 'Sin permiso (403)',
        estado == 429, 'Demasiados mensajes (429)', evento == 'stomp.rechazado', 'Tiempo real: conexion sin token valido',
        'Tiempo real: canal no permitido')
  KQL

  kql_seguridad_tiempo = <<-KQL
    ${local.kql_seguridad}| summarize Rechazos = count() by bin(TimeGenerated, 5m), Motivo
  KQL

  kql_seguridad_rutas = <<-KQL
    ${local.kql_seguridad}| summarize Rechazos = count(), Ultimo = max(TimeGenerated)
        by Motivo, Ruta = iff(evento == 'http.peticion', strcat(tostring(j.http.metodo), ' ', tostring(j.http.ruta)), strcat('STOMP ', tostring(j.comando)))
    | top 10 by Rechazos
  KQL

  kql_tecnico_errores_tiempo = <<-KQL
    ${local.kql_logs}| where tostring(j.log.level) == 'ERROR' or (evento == 'http.peticion' and toint(j.http.estado) >= 500)
    | summarize Errores = count() by bin(TimeGenerated, 5m), Servicio = ContainerAppName_s
  KQL

  # ---------- piezas del Workbook ----------
  selector_periodo = {
    type = 9
    name = "periodo"
    content = {
      version = "KqlParameterItem/1.0"
      style   = "pills"
      parameters = [{
        id         = "8d6c0f8c-2d4c-4d0b-9e1a-6f6b3f4c1a01"
        version    = "KqlParameterItem/1.0"
        name       = "Periodo"
        label      = "Periodo"
        type       = 4
        isRequired = true
        value      = { durationMs = 3600000 }
        typeSettings = {
          allowCustom = true
          selectableValues = [
            { durationMs = 900000 }, { durationMs = 3600000 }, { durationMs = 14400000 },
            { durationMs = 86400000 }, { durationMs = 604800000 }
          ]
        }
      }]
    }
  }

  # tamano: 0 mediano, 1 pequeno, 3 minimo (los cuadritos usan el minimo: no dejan espacio en blanco)
  # ancho: "100" (fila entera) o "50" (dos lado a lado)
  consulta = { for k, v in {
    negocio_totales          = { titulo = "Uso del juego", query = local.kql_negocio_totales, vista = "tiles", ancho = "100" }
    negocio_duracion         = { titulo = "Tiempo promedio de interaccion", query = local.kql_negocio_duracion, vista = "tiles", ancho = "100" }
    negocio_jugadores_tiempo = { titulo = "Jugadores activos en el tiempo", query = local.kql_negocio_jugadores_tiempo, vista = "timechart", ancho = "50" }
    negocio_partidas_tiempo  = { titulo = "Partidas y acertijos en el tiempo", query = local.kql_negocio_partidas_tiempo, vista = "timechart", ancho = "50" }
    negocio_mas_usadas       = { titulo = "Funcionalidades mas usadas (acciones de los jugadores)", query = local.kql_negocio_mas_usadas, vista = "barchart", ancho = "100" }
    tecnico_resumen          = { titulo = "Resumen del sistema (tiempos en la puerta de entrada)", query = local.kql_tecnico_resumen, vista = "tiles", ancho = "100" }
    tecnico_replicas         = { titulo = "Estado por replica, ultimos 2 min (DEGRADADA: p95 > 300 ms o errores > 2 %; SIN SENAL: 90 s sin logs)", query = local.kql_tecnico_replicas, vista = "table", ancho = "100" }
    tecnico_p95_tiempo       = { titulo = "Tiempo de respuesta p95 por servicio (ms, cada 5 min)", query = local.kql_tecnico_p95_tiempo, vista = "timechart", ancho = "50" }
    tecnico_errores_tiempo   = { titulo = "Errores y excepciones por servicio (cada 5 min)", query = local.kql_tecnico_errores_tiempo, vista = "timechart", ancho = "50" }
    tecnico_conexiones       = { titulo = "Conexiones de tiempo real por replica del broker", query = local.kql_tecnico_conexiones_tiempo, vista = "timechart", ancho = "100" }
    seguridad_tiempo         = { titulo = "Intentos rechazados (cada 5 min)", query = local.kql_seguridad_tiempo, vista = "timechart", ancho = "50" }
    seguridad_rutas          = { titulo = "Rutas con mas rechazos", query = local.kql_seguridad_rutas, vista = "table", ancho = "50" }
    } : k => {
    type        = 3
    name        = k
    customWidth = v.ancho
    content = merge({
      version                  = "KqlItem/1.0"
      title                    = v.titulo
      query                    = v.query
      size                     = v.vista == "tiles" ? 3 : 0
      queryType                = 0
      resourceType             = "microsoft.operationalinsights/workspaces"
      crossComponentResources  = [local.workspace_id]
      timeContextFromParameter = "Periodo"
      visualization            = v.vista
      }, v.vista == "tiles" ? {
      tileSettings = {
        titleContent = { columnMatch = "Indicador" }
        leftContent  = { columnMatch = "Valor", formatter = 12, formatOptions = { palette = "auto" } }
        showBorder   = true
      }
      } : {}, v.vista == "timechart" ? {
      # La leyenda sin el numero grande (sumaba los puntos: no significa nada para un p95)
      chartSettings = { showMetricInfo = false, showLegend = true }
    } : {})
  } }

  metrica = { for k, v in {
    cpu      = { titulo = "CPU por replica (%)", metrica = "CpuPercentage", agregado = 4, division = "podName", ancho = "50" }
    memoria  = { titulo = "Memoria por replica (%)", metrica = "MemoryPercentage", agregado = 4, division = "podName", ancho = "50" }
    replicas = { titulo = "Replicas por servicio (autoescalado)", metrica = "Replicas", agregado = 3, division = null, ancho = "100" }
    } : k => {
    type        = 10
    name        = "metrica_${k}"
    customWidth = v.ancho
    content = {
      chartId                  = "c15-${k}"
      version                  = "MetricsItem/2.0"
      title                    = v.titulo
      size                     = 0
      chartType                = 2
      resourceType             = "microsoft.app/containerapps"
      metricScope              = 0
      resourceIds              = local.apps_ids
      timeContextFromParameter = "Periodo"
      metrics = [merge(
        { namespace = "microsoft.app/containerapps", metric = "microsoft.app/containerapps--${v.metrica}", aggregation = v.agregado },
        v.division == null ? {} : { splitBy = v.division }
      )]
    }
  } }

  # Eventos entre servicios (Event Hubs): lo que entra, lo que sale y si Azure nos limita por capacidad
  metrica_eventos = var.kafka_administrado ? [{
    type        = 10
    name        = "metrica_eventos"
    customWidth = "100"
    content = {
      chartId                  = "c15-eventos"
      version                  = "MetricsItem/2.0"
      title                    = "Eventos entre servicios (Event Hubs): mensajes y limitaciones"
      size                     = 0
      chartType                = 2
      resourceType             = "microsoft.eventhub/namespaces"
      metricScope              = 0
      resourceIds              = [lower(azurerm_eventhub_namespace.c15[0].id)]
      timeContextFromParameter = "Periodo"
      metrics = [for m in ["IncomingMessages", "OutgoingMessages", "ThrottledRequests", "ServerErrors"] :
        { namespace = "microsoft.eventhub/namespaces", metric = "microsoft.eventhub/namespaces--${m}", aggregation = 1 }
      ]
    }
  }] : []
}

resource "azurerm_application_insights_workbook" "negocio" {
  name                = uuidv5("dns", "negocio.tableros.escaperoomc15")
  resource_group_name = data.azurerm_resource_group.c15.name
  location            = var.region
  display_name        = "C15 - Tablero de negocio"
  source_id           = local.workspace_id
  category            = "workbook"
  tags                = local.tags
  data_json = jsonencode({
    version             = "Notebook/1.0"
    fallbackResourceIds = [local.workspace_id]
    items = [
      { type = 1, name = "titulo", content = { json = "## Escape Room C15 - uso del juego\nConsolidado entre replicas (cada partida cuenta una vez)." } },
      local.selector_periodo,
      local.consulta.negocio_totales,
      local.consulta.negocio_duracion,
      local.consulta.negocio_jugadores_tiempo,
      local.consulta.negocio_partidas_tiempo,
      local.consulta.negocio_mas_usadas,
    ]
  })
}

resource "azurerm_application_insights_workbook" "tecnico" {
  name                = uuidv5("dns", "tecnico.tableros.escaperoomc15")
  resource_group_name = data.azurerm_resource_group.c15.name
  location            = var.region
  display_name        = "C15 - Tablero tecnico"
  source_id           = local.workspace_id
  category            = "workbook"
  tags                = local.tags
  data_json = jsonencode({
    version             = "Notebook/1.0"
    fallbackResourceIds = [local.workspace_id]
    items = concat([
      { type = 1, name = "titulo", content = { json = "## Escape Room C15 - estado del sistema\nPor servicio y replica. Tiempos de respuesta en la puerta de entrada (gateway), que es lo que siente el jugador." } },
      local.selector_periodo,
      local.consulta.tecnico_resumen,
      local.consulta.tecnico_replicas,
      local.consulta.tecnico_p95_tiempo,
      local.consulta.tecnico_errores_tiempo,
      local.consulta.tecnico_conexiones,
      local.metrica.cpu,
      local.metrica.memoria,
      local.metrica.replicas,
      { type = 1, name = "titulo_seguridad", content = { json = "### Seguridad\nIntentos rechazados en la puerta de entrada: sin token o con un token invalido (401), sin el rol necesario (403) o demasiados mensajes de chat (429)." } },
      local.consulta.seguridad_tiempo,
      local.consulta.seguridad_rutas,
      { type = 1, name = "titulo_eventos", content = { json = "### Eventos entre servicios" } },
    ], local.metrica_eventos)
  })
}
