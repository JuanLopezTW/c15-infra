# Apaga las 8 Container Apps: desactiva la revision activa de cada una. No corren ni cobran, y conservan toda
# su configuracion. Se prenden con prender.ps1. Requiere: az login en la suscripcion del grupo.
# Uso: powershell -File scripts\apagar.ps1
$grupo = 'Escape_Room_RG'
$apps = 'c15-gateway', 'c15-broker', 'c15-salas', 'c15-gameplay', 'c15-social', 'c15-kafka', 'c15-rabbitmq', 'c15-redis'
foreach ($a in $apps) {
    $rev = az containerapp revision list -g $grupo -n $a --query "[?properties.active].name | [0]" -o tsv
    if ($rev) {
        az containerapp revision deactivate -g $grupo -n $a --revision $rev -o none
        Write-Host "$a apagada ($rev)"
    } else {
        Write-Host "$a ya estaba apagada"
    }
}
Write-Host "Listo: el juego queda sin back hasta correr prender.ps1"
