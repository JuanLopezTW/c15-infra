# c15-infra

Infraestructura de EscapeRoom C15 (microservicios) en Azure, con Terraform.

| Qué | Dónde |
|---|---|
| Entorno de Container Apps en una red propia (`c15-entorno`, `c15-red`) | `main.tf` |
| Logs (Log Analytics, tope de 1 GB/día) | `main.tf` |
| Event Hubs Standard (Kafka) con los 4 topics `c15.*` | `eventos.tf` |
| Una base y un usuario por servicio en el Postgres existente | `bases.tf` |
| RabbitMQ (relay STOMP) y Redis (estado compartido), internos | `soporte.tf` |
| broker, salas, gameplay, social (internos) y gateway (público) | `servicios.tf` |

Todo va en **North Central US**, junto al Postgres `escaperoomserverbd`. Solo el gateway es público; los demás se ven entre ellos por nombre dentro del entorno.

## Lo que no hace Terraform

- **La versión que corre cada servicio:** la cambia el pipeline de su repo. Terraform crea la app con `:latest` la primera vez y después ignora la imagen.
- **Registrar proveedores** (`Microsoft.EventHub`, etc.): es de toda la suscripción y nuestro permiso es solo del grupo. Lo hace el dueño de la suscripción:
  ```
  az provider register --namespace Microsoft.EventHub
  ```

## Escalado manual

Las réplicas son fijas (mínimo = máximo). Para cambiarlas, editar `replicas` en `variables.tf` (o `-var`) y hacer `apply`. El ingress de Container Apps reparte entre las réplicas.

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
