<#
    Compila o instalador do Agente de Impressao NEOSYSTEM.

    Monta um PHP minimo (so o que o agente usa), copia o agente e chama o Inno Setup.
    O resultado sai em .\dist\neosystem-agente-impresion-<versao>.exe

    Uso:
        .\build.ps1
        .\build.ps1 -PhpOrigem "C:\Server\Php" -Url "https://meuerp.com"

    Requisitos:
        - Inno Setup 6  (https://jrsoftware.org/isdl.php)
        - Uma instalacao de PHP 7.4+ x64 thread-safe para extrair o runtime
#>

param(
    # De onde sai o runtime embutido. Tem de ser x64 e da mesma familia do agente.
    [string] $PhpOrigem = "C:\Server\Php",

    # Pre-carrega a direcao na tela. Normalmente NAO se usa: o cliente digita a
    # dele na instalacao. Serve para gerar um instalador dedicado a um cliente.
    [string] $Url = "",

    [string] $Iscc = ""
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $raiz

function Passo($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Erro($t)  { Write-Host "   ERRO: $t" -ForegroundColor Red }
function Ok($t)    { Write-Host "   $t" -ForegroundColor Green }

# ---------------------------------------------------------------------------
Passo "Verificando o Inno Setup"

if (-not $Iscc) {
    $candidatos = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )
    $Iscc = $candidatos | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $Iscc -or -not (Test-Path $Iscc)) {
    Erro "Inno Setup 6 nao encontrado. Instale de https://jrsoftware.org/isdl.php"
    exit 1
}
Ok "ISCC: $Iscc"

# ---------------------------------------------------------------------------
Passo "Montando o runtime PHP minimo"

# So o necessario para o agente: HTTP (curl), TLS (openssl) e texto (mbstring).
# O resto do PHP (60+ MB de extensoes) nao entra.
$essenciais = @('php.exe', 'php7ts.dll', 'libssl-1_1-x64.dll', 'libcrypto-1_1-x64.dll')
$extensoes  = @('php_curl.dll', 'php_openssl.dll', 'php_mbstring.dll')

$payload = Join-Path $raiz 'payload'
$destPhp = Join-Path $payload 'php'

Remove-Item $payload -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $destPhp 'ext') -Force | Out-Null

$faltando = @()

foreach ($arquivo in $essenciais) {
    $origem = Join-Path $PhpOrigem $arquivo
    if (Test-Path $origem) { Copy-Item $origem $destPhp } else { $faltando += $arquivo }
}

foreach ($arquivo in $extensoes) {
    $origem = Join-Path $PhpOrigem "ext\$arquivo"
    if (Test-Path $origem) { Copy-Item $origem (Join-Path $destPhp 'ext') } else { $faltando += "ext\$arquivo" }
}

# Runtime do Visual C++ (VC15), do qual o PHP 7.4 x64 depende.
#
# Sem isto, numa maquina com o VC++ Redistributable antigo o php.exe nem arranca:
#   "'vcruntime140.dll' 14.0 is not compatible with this PHP build linked with 14.16"
#
# O Windows procura DLLs na pasta do executavel ANTES do System32, entao levar a copia
# correta junto resolve sem pedir ao cliente que instale nada. Sao redistribuiveis.
#
# Os api-ms-win-crt-*.dll que o PHP tambem referencia fazem parte do Universal CRT, que ja
# vem no Windows 10/11 — esses nao precisam viajar.
$versaoMinimaVc = [version]'14.16'
$runtimeVc = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
$vcCopiados = 0

foreach ($arquivo in $runtimeVc) {
    # Primeiro ao lado do proprio PHP (algumas distribuicoes ja o trazem), depois o sistema.
    $candidatos = @(
        (Join-Path $PhpOrigem $arquivo),
        (Join-Path $env:SystemRoot "System32\$arquivo")
    )

    $origem = $candidatos | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $origem) {
        # vcruntime140.dll e obrigatorio; os outros dois so entram se existirem.
        if ($arquivo -eq 'vcruntime140.dll') { $faltando += $arquivo }
        continue
    }

    $info = (Get-Item $origem).VersionInfo
    $versao = [version]"$($info.FileMajorPart).$($info.FileMinorPart)"

    if ($versao -lt $versaoMinimaVc) {
        Erro "$arquivo desta maquina e $versao, e o PHP exige $versaoMinimaVc ou maior."
        Write-Host "   Instale o Visual C++ Redistributable 2015-2022 (x64) e rode de novo." -ForegroundColor Yellow
        exit 1
    }

    Copy-Item $origem $destPhp
    $vcCopiados++
}

Ok "runtime do Visual C++ embutido ($vcCopiados arquivo(s))"

if ($faltando.Count -gt 0) {
    Erro "Nao achei em ${PhpOrigem}:"
    $faltando | ForEach-Object { Write-Host "     - $_" -ForegroundColor Red }
    Write-Host "   Aponte outra instalacao com -PhpOrigem" -ForegroundColor Yellow
    exit 1
}

# php.ini proprio: extension_dir relativo, para o PHP achar as DLLs onde quer que
# o cliente instale.
@"
; php.ini do Agente NEOSYSTEM - so o que o agente precisa.
extension_dir = "ext"
extension=curl
extension=openssl
extension=mbstring

; O agente roda em laco; nao ha requisicao HTTP com limite de tempo.
max_execution_time = 0
memory_limit = 128M

; A saida util vai para o agente.log.
display_errors = Off
log_errors = Off
"@ | Set-Content (Join-Path $destPhp 'php.ini') -Encoding ASCII

$mb = [math]::Round((Get-ChildItem $destPhp -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
Ok "PHP minimo: $mb MB"

# ---------------------------------------------------------------------------
Passo "Copiando o agente"

$origemAgente = Join-Path (Split-Path -Parent $raiz) 'agente.php'
$origemBat    = Join-Path (Split-Path -Parent $raiz) 'iniciar.bat'

foreach ($f in @($origemAgente, $origemBat)) {
    if (-not (Test-Path $f)) { Erro "Nao encontrado: $f"; exit 1 }
}

Copy-Item $origemAgente $payload
Copy-Item $origemBat    $payload

# Dentro do instalador o PHP vai junto, entao o .bat aponta para ele.
$bat = Get-Content (Join-Path $payload 'iniciar.bat') -Raw
$bat = $bat -replace 'set "PHP_EXE=php"', 'set "PHP_EXE=%~dp0php\php.exe"'
Set-Content (Join-Path $payload 'iniciar.bat') $bat -Encoding ASCII

Ok "agente.php e iniciar.bat prontos"

# ---------------------------------------------------------------------------
Passo "Verificando o runtime montado"

# Melhor descobrir aqui do que na maquina do cliente.
$teste = & (Join-Path $destPhp 'php.exe') -r "echo (function_exists('curl_init') && in_array('https', stream_get_wrappers()) && function_exists('mb_substr') && function_exists('iconv')) ? 'OK' : 'FALTA';" 2>&1

if ($teste -notmatch 'OK') {
    Erro "O PHP montado nao tem tudo o que o agente precisa: $teste"
    exit 1
}
Ok "curl, https, mbstring e iconv presentes"

# php -l no agente, com o proprio runtime que vai ser distribuido.
$lint = & (Join-Path $destPhp 'php.exe') -l (Join-Path $payload 'agente.php') 2>&1
if ($lint -notmatch 'No syntax errors') {
    Erro "agente.php nao compila: $lint"
    exit 1
}
Ok "agente.php sem erros de sintaxe"

# ---------------------------------------------------------------------------
Passo "Compilando o instalador"

$argumentos = @("/Q", "`"$(Join-Path $raiz 'neosystem-agente.iss')`"")

if ($Url) {
    $argumentos = @("/Q", "/DDefaultUrl=`"$Url`"", "`"$(Join-Path $raiz 'neosystem-agente.iss')`"")
    Ok "URL embutida: $Url"
}

$p = Start-Process -FilePath $Iscc -ArgumentList $argumentos -NoNewWindow -Wait -PassThru

if ($p.ExitCode -ne 0) {
    Erro "ISCC terminou com codigo $($p.ExitCode)"
    exit 1
}

$exe = Get-ChildItem (Join-Path $raiz 'dist') -Filter '*.exe' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $exe) { Erro "O .exe nao foi gerado"; exit 1 }

Write-Host ""
Ok "Instalador pronto:"
Write-Host "     $($exe.FullName)" -ForegroundColor White
Write-Host "     $([math]::Round($exe.Length/1MB,1)) MB" -ForegroundColor White
Write-Host ""
Write-Host "  O cliente baixa esse arquivo, executa e digita o codigo de 6 caracteres." -ForegroundColor Gray
