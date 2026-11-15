# c15-infra

Infraestructura de EscapeRoom C15 (microservicios) en Azure, con Terraform.

| Qué | Dónde |
|---|---|
| Entorno de Container Apps en una red propia (`c15-entorno`, `c15-red`) | `main.tf` |
| Logs (Log Analytics, tope de 1 GB/día) | `main.tf` |
| Eventos entre servicios: Event Hubs Standard con los 4 topics `c15.*` (`kafka_administrado = true`, por defecto) o Kafka en contenedor (`false`) | `kafka.tf`, `eventos.tf` |
| Una base y un usuario por servicio en el Postgres existente | `bases.tf` |
| RabbitMQ (relay STOMP) y Redis (estado compartido), internos | `soporte.tf` |
| broker, salas, gameplay, social (internos) y gateway (público) | `servicios.tf` |

Todo va en **North Central US**, junto al Postgres `escaperoomserverbd`. Solo el gateway es público; los demás se ven entre ellos por nombre dentro del entorno.

## Tableros (O2)

Dos Azure Workbooks en el portal (`Escape_Room_RG` -> Workbooks, o Monitor -> Workbooks), con selector de periodo:
- **C15 - Tablero de negocio:** jugadores activos, sesiones, jugadores nuevos, salas, partidas jugadas, acertijos, retos, mensajes de chat, acciones en tiempo real, duracion promedio de una partida, funcionalidades mas usadas y actividad en el tiempo.
- **C15 - Tablero tecnico:** peticiones, tiempo de respuesta promedio y p95, % de errores, usuarios concurrentes, estado por replica (DEGRADADA: p95 > 300 ms o errores > 2 %; SIN SENAL: 2 min sin logs), p95 y errores por servicio en el tiempo, y CPU, memoria y replicas de cada servicio (metricas de Azure).

Lo de los logs esta consolidado entre replicas (una partida cuenta una vez). Las consultas son `tableros.tf`.

## Lo que no hace Terraform

- **La versión que corre cada servicio:** la cambia el pipeline de su repo. Terraform crea la app con `:latest` la primera vez y después ignora la imagen.
- **Registrar proveedores** (`Microsoft.EventHub`, etc.): es de toda la suscripción y nuestro permiso es solo del grupo. Lo hace el dueño de la suscripción:
  ```
  az provider register --namespace Microsoft.EventHub
  ```

## Kafka en contenedor o Event Hubs

`kafka_administrado` (en `variables.tf`) decide a dónde van los eventos entre servicios:
- `false`: un Kafka interno en un contenedor, igual que el compose local. Sin disco: si se reinicia se pierden los eventos que iban en camino.
- `true` (por defecto): Event Hubs Standard (requiere `Microsoft.EventHub` registrado en la suscripción). Cobra siempre (~0,75 USD/dia), tambien con las apps apagadas.

Cambiarlo es un `apply`: crea uno, apunta los servicios al nuevo y borra el otro. Hacerlo cuando nadie esté jugando (durante el cambio un evento puede perderse).

## Apagar y prender (para no gastar credito)

```
powershell -File scripts\apagar.ps1
powershell -File scripts\prender.ps1
```
`apagar` desactiva la revision activa de las apps (no corren ni cobran; conservan su configuracion). `prender` las reactiva en orden: RabbitMQ, Redis y Kafka, despues los servicios y al final el gateway (~3 min). Un push a un servicio o un `terraform apply` que lo cambie lo vuelve a prender solo.

## Autoescalado (D2) y modo produccion

Cada servicio escala por CPU (`cpu_objetivo`, 70 %) hasta `max_replicas` (5). El minimo depende de `modo_produccion`:
- `false` (por defecto): minimo 1, para no gastar credito en reposo.
- `true`: minimo 2, como dicen los escenarios D1, D2 y R1. Prenderlo para las pruebas y la presentacion:
  `terraform apply -var modo_produccion=true`.

Una replica nueva recibe trafico solo cuando responde `/api/version` (readiness). El pool de Postgres es de 2 conexiones por replica: 5 replicas x 3 servicios con base = 30 de las 35 que deja el B1ms.

## Prueba de caida (D1)

`caida_simulada = true` le da a broker y gameplay `POST /dev/caida/c15-broker` y `/dev/caida/c15-gameplay` (solo admin): la replica que atiende responde su nombre y se muere en seco, como un corte de luz; Azure la vuelve a levantar. Se prende junto con el minimo de 2 replicas y se apaga al terminar:
```
terraform apply -var modo_produccion=true -var caida_simulada=true
terraform apply -var modo_produccion=true
```

## Plan B del balanceador: Azure Front Door

`balanceador_azure = true` pone Azure Front Door delante del gateway (~1,2 USD/dia, requiere `Microsoft.Cdn` registrado). La URL sale en `balanceador_url`; el front se apunta ahi en vez de al gateway.

## Escalado manual

`replicas_fijas` deja un servicio con un numero fijo de replicas, sin autoescalado: `terraform apply -var 'replicas_fijas={gameplay=3}'`. El ingress de Container Apps reparte entre las replicas.

## Primera vez

1. Sesión en la suscripción (una vez por máquina):
   ```
   az login
   az account set --subscription f959f171-df81-4117-92b2-b95e9d672f6a
   ```
2. Storage Account del state (una sola vez en total):
   ```
   az storage account create -n c15infratfstate -g Escape_Room_RG -l northcentralus --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false
   az storage container create -n tfstate --account-name c15infratfstate --auth-mode key
   ```
3. Clave del admin de Postgres, solo en la terminal (nunca en un archivo):
   ```
   $env:TF_VAR_postgres_admin_clave = Read-Host -AsSecureString "Clave de AdminER" | ConvertFrom-SecureString -AsPlainText
   ```
   En Windows PowerShell 5.1 (sin `-AsPlainText`): `$env:TF_VAR_postgres_admin_clave = "<clave>"`, y cerrar la terminal al terminar.
4. ```
   terraform init
   terraform plan -out plan.tfplan
   terraform apply plan.tfplan
   ```
   Las imágenes `ghcr.io/juanlopeztw/c15-*:latest` deben existir antes del `apply` (las publica el pipeline de cada repo).

La URL pública sale al final (`gateway_url`).

## Al terminar el semestre

```
terraform destroy
```
Borra todo lo que creó (también las bases `c15_*` del Postgres, pero no el servidor). El Storage Account del state se borra a mano.
