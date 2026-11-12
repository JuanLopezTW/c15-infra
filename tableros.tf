# Los 2 tableros obligatorios (O2) como Azure Workbooks, en el portal: Escape_Room_RG -> Workbooks.
# Las cifras de negocio y de peticiones salen de los logs centralizados (consolidados entre replicas: una partida
# cuenta una vez); CPU, memoria y replicas, de las metricas de cada Container App. Se actualizan solos.

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
  # Peticiones de jugadores: /api/version es la comprobacion de salud, no gente
  kql_peticiones = <<-KQL
    ${local.kql_logs}| where evento == 'http.peticion' and tostring(j.http.ruta) != '/api/version'
  KQL

  kql_negocio_totales = <<-KQL
    ${local.kql_logs}| summarize
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
  KQL

  kql_negocio_mas_usadas = <<-KQL
    ${local.kql_peticiones}| summarize Usos = count() by Funcion = strcat(tostring(j.http.metodo), ' ', tostring(j.http.ruta))
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

  kql_tecnico_resumen = <<-KQL
    ${local.kql_peticiones}| extend ms = todouble(j.duracion.ms), estado = toint(j.http.estado)
    | summarize ['Peticiones'] = count(), ['Tiempo de respuesta promedio (ms)'] = round(avg(ms)),
        ['p95 (ms)'] = round(percentile(ms, 95)), ['Errores 5xx'] = countif(estado >= 500),
        ['Usuarios concurrentes (5 min)'] = dcountif(tostring(j.userId), TimeGenerated > ago(5m))
    | extend ['% de errores'] = round(100.0 * ['Errores 5xx'] / ['Peticiones'], 2)
    | evaluate narrow()
    | project Indicador = Column, Valor = todouble(Value)
  KQL

  # Una replica degradada (p95 > 300 ms o errores > 2 %) o sin logs en 2 min, como dice el escenario O2
  kql_tecnico_replicas = <<-KQL
    let peticiones = ${replace(local.kql_peticiones, "\n", " ")}
        | extend ms = todouble(j.duracion.ms), estado = toint(j.http.estado)
        | summarize Peticiones = count(), p50 = round(percentile(ms, 50)), p95 = round(percentile(ms, 95)),
            Errores5xx = countif(estado >= 500) by Servicio = ContainerAppName_s, Replica = ContainerGroupName_s;
    ${replace(local.kql_logs, "\n", " ")}
    | summarize UltimaSenal = max(TimeGenerated), Excepciones = countif(tostring(j.log.level) == 'ERROR')
        by Servicio = ContainerAppName_s, Replica = ContainerGroupName_s
    | join kind=leftouter peticiones on Servicio, Replica
    | extend PctErrores = round(100.0 * coalesce(Errores5xx, 0) / max_of(coalesce(Peticiones, 0), 1), 2)
    | extend Estado = case(UltimaSenal < ago(2m), 'SIN SENAL', p95 > 300 or PctErrores > 2, 'DEGRADADA', 'OK')
    | project Estado, Servicio, Replica, Peticiones = coalesce(Peticiones, 0), p50, p95, PctErrores, Excepciones, UltimaSenal
    | order by Estado asc, Servicio asc
  KQL

  kql_tecnico_p95_tiempo = <<-KQL
    ${local.kql_peticiones}| summarize p95 = percentile(todouble(j.duracion.ms), 95) by bin(TimeGenerated, 1m), Servicio = ContainerAppName_s
  KQL

  kql_tecnico_errores_tiempo = <<-KQL
    ${local.kql_logs}| where tostring(j.log.level) == 'ERROR' or (evento == 'http.peticion' and toint(j.http.estado) >= 500)
    | summarize Errores = count() by bin(TimeGenerated, 1m), Servicio = ContainerAppName_s
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

  consulta = { for k, v in {
    negocio_totales          = { titulo = "Uso del juego", query = local.kql_negocio_totales, vista = "tiles" }
    negocio_duracion         = { titulo = "Tiempo promedio de interaccion", query = local.kql_negocio_duracion, vista = "table" }
    negocio_mas_usadas       = { titulo = "Funcionalidades mas usadas", query = local.kql_negocio_mas_usadas, vista = "barchart" }
    negocio_jugadores_tiempo = { titulo = "Jugadores activos en el tiempo", query = local.kql_negocio_jugadores_tiempo, vista = "timechart" }
    negocio_partidas_tiempo  = { titulo = "Partidas y acertijos en el tiempo", query = local.kql_negocio_partidas_tiempo, vista = "timechart" }
    tecnico_resumen          = { titulo = "Resumen del sistema", query = local.kql_tecnico_resumen, vista = "tiles" }
    tecnico_replicas         = { titulo = "Estado por replica (degradada: p95 > 300 ms o errores > 2 %; sin senal: 2 min sin logs)", query = local.kql_tecnico_replicas, vista = "table" }
    tecnico_p95_tiempo       = { titulo = "Tiempo de respuesta p95 por servicio (ms)", query = local.kql_tecnico_p95_tiempo, vista = "timechart" }
    tecnico_errores_tiempo   = { titulo = "Errores y excepciones por servicio", query = local.kql_tecnico_errores_tiempo, vista = "timechart" }
    } : k => {
    type = 3
    name = k
    content = merge({
      version                  = "KqlItem/1.0"
      title                    = v.titulo
      query                    = v.query
      size                     = 0
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
    } : {})
  } }

  metrica = { for k, v in {
    cpu      = { titulo = "CPU por replica (%)", metrica = "CpuPercentage", agregado = 4, division = "podName" }
    memoria  = { titulo = "Memoria por replica (%)", metrica = "MemoryPercentage", agregado = 4, division = "podName" }
    replicas = { titulo = "Replicas por servicio (autoescalado)", metrica = "Replicas", agregado = 3, division = null }
    } : k => {
    type = 10
    name = "metrica_${k}"
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
    items = [
      { type = 1, name = "titulo", content = { json = "## Escape Room C15 - estado del sistema\nPor servicio y replica. Degradada: p95 > 300 ms o errores > 2 %. Sin senal: 2 min sin logs." } },
      local.selector_periodo,
      local.consulta.tecnico_resumen,
      local.consulta.tecnico_replicas,
      local.consulta.tecnico_p95_tiempo,
      local.consulta.tecnico_errores_tiempo,
      local.metrica.cpu,
      local.metrica.memoria,
      local.metrica.replicas,
    ]
  })
}
