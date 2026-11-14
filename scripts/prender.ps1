# Prende las Container Apps en orden: primero RabbitMQ, Redis y Kafka (si esta en contenedor) (los demas los necesitan al arrancar),
# espera a que esten sanos, y despues los servicios, con el gateway al final. Tarda unos 2-3 minutos.
# Uso: powershell -File scripts\prender.ps1
$grupo = 'Escape_Room_RG'
# c15-kafka solo existe con kafka_administrado = false
$existentes = az containerapp list -g $grupo --query "[].name" -o tsv

function Prender($a) {
    $rev = az containerapp show -g $grupo -n $a --query properties.latestRevisionName -o tsv
    az containerapp revision activate -g $grupo -n $a --revision $rev -o none
    Write-Host "$a prendiendo ($rev)"
    return $rev
}

function EsperarSana($a, $rev) {
    for ($i = 0; $i -lt 40; $i++) {
        $estado = az containerapp revision show -g $grupo -n $a --revision $rev --query "join('/', [properties.runningState || 'Nada', properties.healthState || 'Nada'])" -o tsv
        if ($estado -like 'Running*/Healthy') { Write-Host "  $a lista"; return }
        Start-Sleep 5
    }
    Write-Host "  $a no quedo sana en 3 min: revisa sus logs en el portal"
}

foreach ($grupoDeApps in @(@('c15-rabbitmq', 'c15-redis', 'c15-kafka'), @('c15-broker', 'c15-salas', 'c15-gameplay', 'c15-social'), @('c15-gateway'))) {
    $revisiones = @{}
    $grupoDeApps = $grupoDeApps | Where-Object { $existentes -contains $_ }
    foreach ($a in $grupoDeApps) { $revisiones[$a] = Prender $a }
    foreach ($a in $grupoDeApps) { EsperarSana $a $revisiones[$a] }
}
Write-Host "Listo: el juego vuelve a estar arriba"
