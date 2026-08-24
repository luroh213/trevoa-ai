# Backup diario do Fiado - Supabase -> JSON local + e-mail (opcional)
# Roda via Agendador de Tarefas do Windows. Config em backup-config.json (fora do git).
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = Get-Content "$dir\backup-config.json" -Raw -Encoding UTF8 | ConvertFrom-Json

function Invoke-FiadoRpc($nome, $corpo) {
  $json = $corpo | ConvertTo-Json -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  Invoke-RestMethod -Uri "$($cfg.supabaseUrl)/rest/v1/rpc/$nome" -Method Post `
    -Headers @{ apikey = $cfg.anonKey; Authorization = "Bearer $($cfg.anonKey)"; "Content-Type" = "application/json" } `
    -Body $bytes
}

$login = Invoke-FiadoRpc "fiado_login" @{ p_usuario = $cfg.adminUsuario; p_senha = $cfg.adminSenha }
if (-not $login.ok) { throw "Login admin falhou: $($login.erro)" }

$bk = Invoke-FiadoRpc "fiado_admin_backup" @{ p_token = $login.token }
if (-not $bk.ok) { throw "Backup falhou" }

$stamp = Get-Date -Format "yyyyMMdd-HHmm"
$outDir = Join-Path $dir "dumps"
New-Item -ItemType Directory -Force $outDir | Out-Null
$out = Join-Path $outDir "backup-fiado-$stamp.json"
$bk | ConvertTo-Json -Depth 30 | Set-Content -Path $out -Encoding UTF8

# Mantém só os últimos 30 dumps locais
Get-ChildItem (Join-Path $outDir "backup-fiado-*.json") |
  Sort-Object LastWriteTime -Descending |
  Select-Object -Skip 30 |
  Remove-Item -Force

$mercados = @($bk.mercados).Count
$clientes = @($bk.clientes).Count
$movs = @($bk.movimentos).Count

# E-mail opcional: precisa de "senha de app" do Gmail (myaccount.google.com/apppasswords)
if ($cfg.emailAppPassword) {
  $smtp = New-Object Net.Mail.SmtpClient("smtp.gmail.com", 587)
  $smtp.EnableSsl = $true
  $smtp.Credentials = New-Object Net.NetworkCredential($cfg.emailPara, $cfg.emailAppPassword)
  $msg = New-Object Net.Mail.MailMessage($cfg.emailPara, $cfg.emailPara)
  $msg.Subject = "Backup Fiado $stamp - $mercados mercados, $clientes clientes, $movs lancamentos"
  $msg.Body = "Backup diario em anexo.`nMercados: $mercados`nClientes: $clientes`nLancamentos: $movs`nGerado em: $($bk.geradoEm)"
  $att = New-Object Net.Mail.Attachment($out)
  $msg.Attachments.Add($att)
  $smtp.Send($msg)
  $att.Dispose(); $msg.Dispose(); $smtp.Dispose()
}

Write-Output "OK $out ($mercados mercados, $clientes clientes, $movs lancamentos)"
