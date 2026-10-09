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

    [string] $Iscc = "",

    # --- Assinatura digital (opcional) -------------------------------------
    #
    # Sem assinar, o Windows reclama do instalador: o SmartScreen mostra "editor
    # desconhecido", e o Smart App Control do Windows 11 simplesmente BLOQUEIA, sem
    # opcao de prosseguir. Como nem o php.exe nem o instalador sao assinados de fabrica,
    # em maquina com Smart App Control ligado nao ha como instalar sem certificado.
    #
    # Duas formas de informar o certificado:
    #   -CertificadoPfx "C:\cert.pfx" -SenhaCertificado "..."   (arquivo)
    #   -CertificadoThumbprint "A1B2..."                        (token USB / HSM / store)
    #
    # Sem nenhuma delas o build segue e so avisa - util para testar.
    [string] $CertificadoPfx = "",
    [string] $SenhaCertificado = "",
    [string] $CertificadoThumbprint = "",

    # O carimbo de tempo e o que mantem a assinatura valida depois que o certificado
    # vence. Sem ele, tudo o que foi assinado "expira" junto.
    [string] $CarimboUrl = "http://timestamp.sectigo.com"
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $raiz

function Passo($t) { Write-Host "`n>> $t" -ForegroundColor Cyan }
function Erro($t)  { Write-Host "   ERRO: $t" -ForegroundColor Red }
function Ok($t)    { Write-Host "   $t" -ForegroundColor Green }
function Aviso($t) { Write-Host "   $t" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Assinatura digital
# ---------------------------------------------------------------------------

function Get-SignTool {
    $cmd = Get-Command signtool.exe -EA SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Vem com o Windows SDK; a versao mais nova costuma ser a melhor.
    foreach ($base in @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")) {
        if (-not (Test-Path $base)) { continue }

        $achado = Get-ChildItem $base -Recurse -Filter 'signtool.exe' -EA SilentlyContinue |
                  Where-Object { $_.FullName -match '\\x64\\' } |
                  Sort-Object FullName -Descending | Select-Object -First 1

        if ($achado) { return $achado.FullName }
    }

    return $null
}

function Test-AssinaturaConfigurada {
    return ($CertificadoPfx -and (Test-Path $CertificadoPfx)) -or $CertificadoThumbprint
}

<#
    Assina os arquivos informados.

    Assina-se TUDO que é executável, não só o instalador: o php.exe e as DLLs que viajam
    dentro dele também não são assinados de fábrica, e o Smart App Control olha o que
    está sendo executado, não só o que foi baixado.
#>
function Invoke-Assinatura {
    param([string[]] $Arquivos, [string] $Descricao = 'Agente de Impresion NEOSYSTEM')

    if (-not (Test-AssinaturaConfigurada)) { return $true }

    $signtool = Get-SignTool
    if (-not $signtool) {
        Erro "Certificado informado, mas o signtool.exe nao foi encontrado."
        Write-Host "   Instale o Windows SDK (componente 'Signing Tools')." -ForegroundColor Yellow
        return $false
    }

    $existentes = $Arquivos | Where-Object { Test-Path $_ }
    if (-not $existentes) { return $true }

    $args = @('sign', '/fd', 'SHA256', '/td', 'SHA256', '/tr', $CarimboUrl, '/d', $Descricao)

    if ($CertificadoThumbprint) {
        # Token USB ou HSM: o certificado vive no store do Windows.
        $args += @('/sha1', $CertificadoThumbprint)
    } else {
        $args += @('/f', $CertificadoPfx)
        if ($SenhaCertificado) { $args += @('/p', $SenhaCertificado) }
    }

    $args += $existentes

    # A saida e silenciada porque a linha de comando carrega a senha do certificado.
    $saida = & $signtool @args 2>&1
    $codigo = $LASTEXITCODE

    if ($codigo -ne 0) {
        Erro "Falha ao assinar (signtool codigo $codigo)."
        # Mostra o erro sem ecoar a senha.
        $saida | Where-Object { $_ -notmatch [regex]::Escape($SenhaCertificado) -or -not $SenhaCertificado } |
            Select-Object -Last 5 | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
        return $false
    }

    Ok "assinados: $($existentes.Count) arquivo(s)"
    return $true
}

# ---------------------------------------------------------------------------
# Dependencias nativas
#
# "No se puede encontrar el modulo especificado" quase nunca quer dizer que a DLL
# pedida falta. Quer dizer que falta uma DEPENDENCIA dela. Foi o caso do php_curl.dll,
# que precisa de libssh2.dll e nghttp2.dll: as duas ficavam de fora do pacote e o
# curl nao carregava na maquina do cliente.
#
# E passava despercebido aqui porque a maquina de build tem o PHP de origem no PATH,
# e o Windows acha as dependencias por lá. O cliente nao tem esse PATH. Por isso:
#   1) as dependencias sao descobertas lendo a tabela de importacao do binario;
#   2) a verificacao final roda com o PATH limpo, que e o que reproduz o cliente.
#
# A leitura do PE orienta o que copiar; quem reprova o build e a verificacao
# funcional. Uma tabela de importacao nao conta tudo (ha carga tardia, ha API sets),
# entao ela avisa, nao condena.
# ---------------------------------------------------------------------------

function ConvertTo-OffsetArquivo {
    param($Rva, $Secoes)

    foreach ($s in $Secoes) {
        $tam = [Math]::Max($s.Tamanho, 1)
        if ($Rva -ge $s.Virtual -and $Rva -lt ($s.Virtual + $tam)) {
            return [int]($s.Bruto + ($Rva - $s.Virtual))
        }
    }
    return -1
}

<#
    Nomes das DLLs que um .exe/.dll importa, lidos do cabecalho PE.

    Procurar a string "xxx.dll" dentro do binario NAO serve: da falso positivo (o
    php7ts.dll "contem" libxml2.dll, que ele nao importa, porque libxml vem ligada
    estaticamente). A tabela de importacao e a fonte certa.
#>
function Get-ImportacoesDll {
    param([string] $Arquivo)

    try { $b = [System.IO.File]::ReadAllBytes($Arquivo) } catch { return @() }
    if ($b.Length -lt 0x40 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { return @() }   # MZ

    $pe = [System.BitConverter]::ToInt32($b, 0x3C)
    if ($pe -le 0 -or ($pe + 248) -ge $b.Length) { return @() }
    if ($b[$pe] -ne 0x50 -or $b[$pe + 1] -ne 0x45) { return @() }                  # PE

    $numSecoes   = [System.BitConverter]::ToUInt16($b, $pe + 6)
    $tamOpcional = [System.BitConverter]::ToUInt16($b, $pe + 20)
    $magia       = [System.BitConverter]::ToUInt16($b, $pe + 24)

    # DataDirectory[1] e o diretorio de importacao. 112 (PE32+) / 96 (PE32) e o
    # tamanho da parte fixa do cabecalho opcional; os +8 pulam o indice 0, que e a
    # exportacao - ler o indice 0 por engano devolve nomes de funcao, nao de DLL.
    $deslocDir = if ($magia -eq 0x20B) { 120 } else { 104 }
    $rvaImport = [System.BitConverter]::ToUInt32($b, $pe + 24 + $deslocDir)
    if ($rvaImport -eq 0) { return @() }

    # As secoes sao o que permite converter RVA em posicao dentro do arquivo.
    $secoes = @()
    for ($i = 0; $i -lt $numSecoes; $i++) {
        $s = $pe + 24 + $tamOpcional + ($i * 40)
        if (($s + 40) -gt $b.Length) { break }
        $secoes += [pscustomobject]@{
            Tamanho = [System.BitConverter]::ToUInt32($b, $s + 8)
            Virtual = [System.BitConverter]::ToUInt32($b, $s + 12)
            Bruto   = [System.BitConverter]::ToUInt32($b, $s + 20)
        }
    }

    $pos = ConvertTo-OffsetArquivo -Rva $rvaImport -Secoes $secoes
    if ($pos -lt 0) { return @() }

    $nomes = @()

    # Descritores de 20 bytes; o nome e um RVA no deslocamento 12. Termina num
    # descritor todo zerado.
    while (($pos + 20) -le $b.Length) {
        $rvaTabela = [System.BitConverter]::ToUInt32($b, $pos)
        $rvaNome   = [System.BitConverter]::ToUInt32($b, $pos + 12)
        if ($rvaTabela -eq 0 -and $rvaNome -eq 0) { break }

        $off = ConvertTo-OffsetArquivo -Rva $rvaNome -Secoes $secoes
        if ($off -ge 0) {
            $fim = $off
            while ($fim -lt $b.Length -and $b[$fim] -ne 0) { $fim++ }
            if ($fim -gt $off) {
                $nomes += [System.Text.Encoding]::ASCII.GetString($b, $off, $fim - $off)
            }
        }

        $pos += 20
    }

    return @($nomes | Sort-Object -Unique)
}

<#
    A dependencia e resolvida pelo proprio Windows?

    Os api-ms-win-* NAO existem como arquivo em System32 - sao API sets que o loader
    aponta para o ucrtbase.dll. Testar a existencia do arquivo os marcaria como
    faltantes. Fazem parte do Universal CRT, que vem no Windows 10 e no 11.
#>
function Test-DllDoSistema {
    param([string] $Nome)

    if ($Nome -like 'api-ms-win-*') { return $true }

    return Test-Path (Join-Path (Join-Path $env:SystemRoot 'System32') $Nome)
}

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
# vem no Windows 10/11 - esses nao precisam viajar.
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

# ---------------------------------------------------------------------------
Passo "Resolvendo as dependencias nativas"

# Nada aqui e listado a mao de proposito: o que o php_curl.dll precisa muda entre
# versoes do PHP, e manter uma lista fixa significa descobrir cada falta na maquina
# de um cliente. Le-se o que os binarios pedem e copia-se do PHP de origem.
$naoResolvidas = @()
$copiadas = 0

# Repete porque uma dependencia copiada traz as suas proprias. Converge em 2-3
# voltas; o limite so evita um laco infinito se algo estiver muito errado.
for ($volta = 1; $volta -le 8; $volta++) {
    $naoResolvidas = @()
    $novas = 0

    $noPacote = @(Get-ChildItem $destPhp -Recurse -File -EA SilentlyContinue |
                  Where-Object { $_.Extension -in '.dll', '.exe' })
    $nomes = @($noPacote | ForEach-Object { $_.Name.ToLower() })

    foreach ($arq in $noPacote) {
        foreach ($dep in (Get-ImportacoesDll $arq.FullName)) {
            if ($nomes -contains $dep.ToLower()) { continue }
            if (Test-DllDoSistema $dep) { continue }

            $naOrigem = Join-Path $PhpOrigem $dep
            if (Test-Path $naOrigem) {
                Copy-Item $naOrigem $destPhp -Force
                Write-Host "   + $dep  (pedida por $($arq.Name))" -ForegroundColor DarkGray
                $copiadas++
                $novas++
                continue
            }

            $pendente = "$dep (pedida por $($arq.Name))"
            if ($naoResolvidas -notcontains $pendente) { $naoResolvidas += $pendente }
        }
    }

    if ($novas -eq 0) { break }
}

if ($copiadas -gt 0) {
    Ok "$copiadas dependencia(s) acrescentada(s) ao pacote"
} else {
    Ok "nenhuma dependencia faltava"
}

if ($naoResolvidas.Count -gt 0) {
    # Aviso, nao erro: pode ser carga tardia ou um nome que o loader resolve de outra
    # forma. Quem decide e a verificacao funcional mais abaixo.
    Aviso "nao achei estas dependencias nem no sistema nem em ${PhpOrigem}:"
    $naoResolvidas | ForEach-Object { Write-Host "     - $_" -ForegroundColor Yellow }
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
$origemVbs    = Join-Path (Split-Path -Parent $raiz) 'iniciar-minimizado.vbs'

foreach ($f in @($origemAgente, $origemBat, $origemVbs)) {
    if (-not (Test-Path $f)) { Erro "Nao encontrado: $f"; exit 1 }
}

Copy-Item $origemAgente $payload
Copy-Item $origemBat    $payload
Copy-Item $origemVbs    $payload

# Dentro do instalador o PHP vai junto, entao o .bat aponta para ele.
$bat = Get-Content (Join-Path $payload 'iniciar.bat') -Raw
$bat = $bat -replace 'set "PHP_EXE=php"', 'set "PHP_EXE=%~dp0php\php.exe"'
Set-Content (Join-Path $payload 'iniciar.bat') $bat -Encoding ASCII

Ok "agente.php, iniciar.bat e iniciar-minimizado.vbs prontos"

# ---------------------------------------------------------------------------
Passo "Verificando o runtime montado"

$php = Join-Path $destPhp 'php.exe'

# O diagnostico vai num arquivo, e nao em -r, para a mensagem dizer QUAL item falta
# em vez de um "FALTA" generico. Fica fora do payload para nao ser empacotado.
$verificador = Join-Path $env:TEMP "neosystem-verificar-$PID.php"

@'
<?php
$itens = [
    'curl'     => 'extension_loaded',
    'openssl'  => 'extension_loaded',
    'mbstring' => 'extension_loaded',
];

$faltam = [];

foreach ($itens as $nome => $teste) {
    if (!$teste($nome)) {
        $faltam[] = $nome;
    }
}

// O agente converte acentos para a codepage da impressora e para a consola.
if (!function_exists('iconv')) {
    $faltam[] = 'iconv';
}

// Sem o wrapper https o agente nao fala com um ERP publicado em TLS.
if (!in_array('https', stream_get_wrappers(), true)) {
    $faltam[] = 'wrapper https';
}

echo $faltam ? 'FALTA: ' . implode(', ', $faltam) : 'OK';
'@ | Set-Content $verificador -Encoding ASCII

# PATH limpo: e isto que reproduz a maquina do cliente.
#
# Com o PATH desta maquina, o Windows acha em C:\Server\Php qualquer dependencia que
# tenha ficado fora do pacote, e o build aprova um instalador quebrado - foi
# exatamente o que aconteceu com o libssh2.dll/nghttp2.dll do curl. A pasta do
# proprio executavel continua sendo procurada primeiro, que e o que o pacote usa.
$pathOriginal = $env:PATH
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"

try {
    # display_errors=stderr porque o php.ini do pacote os silencia, e aqui queremos ver.
    $teste = & $php -d display_errors=stderr -d log_errors=0 $verificador 2>&1
} finally {
    $env:PATH = $pathOriginal
    Remove-Item $verificador -Force -EA SilentlyContinue
}

$linhas = @(($teste | Out-String) -split "`r?`n" | Where-Object { $_.Trim() })
$passou = @($linhas | Where-Object { $_.Trim() -eq 'OK' }).Count -gt 0

if (-not $passou) {
    Erro "O runtime montado nao serve (testado com o PATH limpo, como na maquina do cliente):"
    $linhas | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
    Write-Host "   Quase sempre e dependencia de DLL faltando - veja os avisos acima." -ForegroundColor Yellow
    exit 1
}

# Passou, mas o PHP reclamou de algo: nao reprova o build, e nao pode ficar escondido.
if ($linhas.Count -gt 1) {
    Aviso "o PHP funcionou, mas reclamou:"
    $linhas | Where-Object { $_.Trim() -ne 'OK' } | ForEach-Object { Write-Host "     $_" -ForegroundColor Yellow }
}

Ok "curl, openssl, mbstring, iconv e https presentes (com o PATH limpo)"

# php -l no agente, com o proprio runtime que vai ser distribuido.
$lint = & (Join-Path $destPhp 'php.exe') -l (Join-Path $payload 'agente.php') 2>&1
if ($lint -notmatch 'No syntax errors') {
    Erro "agente.php nao compila: $lint"
    exit 1
}
Ok "agente.php sem erros de sintaxe"

# ---------------------------------------------------------------------------
Passo "Assinatura digital do conteudo"

if (Test-AssinaturaConfigurada) {
    # Antes de empacotar: o que vai ser EXECUTADO na maquina do cliente.
    $paraAssinar = @(
        (Join-Path $destPhp 'php.exe'),
        (Join-Path $destPhp 'php7ts.dll')
    ) + (Get-ChildItem (Join-Path $destPhp 'ext') -Filter '*.dll' -EA SilentlyContinue | ForEach-Object { $_.FullName })

    if (-not (Invoke-Assinatura -Arquivos $paraAssinar)) { exit 1 }
} else {
    Aviso "sem certificado: o conteudo nao sera assinado"
    Write-Host "     O SmartScreen vai avisar, e o Smart App Control (Windows 11) BLOQUEIA." -ForegroundColor Yellow
    Write-Host "     Para assinar: -CertificadoPfx <arquivo> -SenhaCertificado <senha>" -ForegroundColor Yellow
    Write-Host "                   ou -CertificadoThumbprint <impressao digital>" -ForegroundColor Yellow
}

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

# O instalador em si tambem precisa de assinatura: e o primeiro arquivo que o Windows
# inspeciona, antes mesmo de qualquer coisa ser extraida.
if (Test-AssinaturaConfigurada) {
    Passo "Assinando o instalador"
    if (-not (Invoke-Assinatura -Arquivos @($exe.FullName))) { exit 1 }

    $sig = Get-AuthenticodeSignature $exe.FullName
    if ($sig.Status -ne 'Valid') {
        Erro "O instalador ficou com assinatura invalida: $($sig.Status)"
        exit 1
    }
    Ok "assinatura verificada: $(($sig.SignerCertificate.Subject -split ',')[0])"
}

Write-Host ""
Ok "Instalador pronto:"
Write-Host "     $($exe.FullName)" -ForegroundColor White
Write-Host "     $([math]::Round($exe.Length/1MB,1)) MB" -ForegroundColor White
Write-Host ""
Write-Host "  O cliente baixa esse arquivo, executa e digita o codigo de 6 caracteres." -ForegroundColor Gray
