# Cadastra os segredos do PIX no Supabase.
# O token NAO e salvo em arquivo nem aparece na tela: vai direto para o cofre do Supabase.
# Como usar: abra o PowerShell na pasta fiado e rode:  .\definir-segredos-pix.ps1
# Pre-requisito: o Supabase CLI instalado (C:\supabase\supabase.exe) e o projeto ligado
# com "supabase link --project-ref SEU_REFERENCE_ID".

$ErrorActionPreference = 'Stop'

$cli = 'C:\supabase\supabase.exe'
if (-not (Test-Path $cli)) { $cli = 'supabase' }

Write-Host 'Cole o Access Token de PRODUCAO do Mercado Pago (nao aparece na tela):'
$seguro = Read-Host -AsSecureString 'Access Token'
$email = Read-Host 'E-mail para as cobrancas PIX'

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
try {
  $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($email)) {
  Write-Host 'Faltou o token ou o e-mail. Nada foi alterado.'
  exit 1
}

& $cli secrets set "MP_ACCESS_TOKEN=$token" "PIX_PAYER_EMAIL=$email"
$token = $null

if ($LASTEXITCODE -eq 0) {
  Write-Host 'Pronto: segredos cadastrados no Supabase.'
} else {
  Write-Host 'Falhou. Veja a mensagem de erro acima.'
  exit 1
}
