<?php
/**
 * Agente de impresion NEOSYSTEM.
 *
 * Corre en la maquina del local, al lado de la impresora. Pregunta al ERP "hay algo para
 * imprimir?", imprime y confirma. Esa es toda la funcion: el ERP hospedado afuera no alcanza
 * una impresora detras del NAT, asi que quien esta adentro tiene que ir a buscar el trabajo.
 *
 * No depende de Laravel ni de composer: PHP con cURL alcanza. Se instala copiando esta
 * carpeta y editando agente.ini.
 *
 *   php agente.php                  corre en primer plano (para probar)
 *   php agente.php --once           un solo ciclo y sale (para el Programador de tareas)
 *   php agente.php --test           imprime un ticket de prueba y sale
 *   php agente.php --ping           solo verifica token y conexion
 *   php agente.php --pair=CODIGO --url=https://...   se registra y escribe el agente.ini
 *   php agente.php --config=otro.ini
 *
 * Ver docs/impresion-agente.md.
 */

/** Se manda al ERP en cada consulta; aparece en la pantalla de agentes. */
const VERSION_AGENTE = '1.0.0';

// -----------------------------------------------------------------------------
// Configuracion
// -----------------------------------------------------------------------------

const PADROES = [
    'url'          => 'http://localhost:8000',
    'token'        => '',
    'terminal'     => 'principal',
    'agente'       => '',   // vacio => nombre de la maquina
    'intervalo'    => 3,    // segundos entre consultas cuando no hay trabajo
    'lote'         => 5,    // trabajos por consulta
    'timeout'      => 20,   // segundos de espera por el ERP
    'log'          => 'agente.log',
    'log_nivel'    => 'info', // info | error
    'verificar_ssl'=> 1,
];

function cargarConfig($ruta)
{
    $config = PADROES;

    if (! is_file($ruta)) {
        salir("No se encontro el archivo de configuracion: $ruta\n"
            . "Copie agente.ini.example a agente.ini y complete la URL y el token.");
    }

    $ini = parse_ini_file($ruta, false, INI_SCANNER_TYPED);

    if ($ini === false) {
        salir("No se pudo leer $ruta. Revise la sintaxis (clave = valor).");
    }

    foreach ($ini as $clave => $valor) {
        if (array_key_exists($clave, $config)) {
            $config[$clave] = $valor;
        }
    }

    $config['url'] = rtrim(trim((string) $config['url']), '/');

    if ($config['url'] === '' || trim((string) $config['token']) === '') {
        salir("Faltan datos en $ruta: 'url' y 'token' son obligatorios.");
    }

    if (trim((string) $config['agente']) === '') {
        $config['agente'] = gethostname() ?: 'agente';
    }

    // Un intervalo muy chico castiga al servidor sin ganar nada perceptible.
    $config['intervalo'] = max(1, (int) $config['intervalo']);
    $config['lote']      = max(1, min(25, (int) $config['lote']));
    $config['timeout']   = max(5, (int) $config['timeout']);

    return $config;
}

// -----------------------------------------------------------------------------
// Log
// -----------------------------------------------------------------------------

$LOG_RUTA  = null;
$LOG_NIVEL = 'info';

function registrar($nivel, $mensaje)
{
    global $LOG_RUTA, $LOG_NIVEL;

    if ($LOG_NIVEL === 'error' && $nivel !== 'error') {
        return;
    }

    $linea = sprintf("[%s] %-5s %s\n", date('Y-m-d H:i:s'), strtoupper($nivel), $mensaje);

    echo $linea;

    if ($LOG_RUTA) {
        // El log no puede tumbar al agente: si el disco esta lleno, seguimos imprimiendo.
        @file_put_contents($LOG_RUTA, $linea, FILE_APPEND | LOCK_EX);

        // Rotacion simple, para que no crezca sin techo en una maquina que no se apaga.
        if (@filesize($LOG_RUTA) > 5 * 1024 * 1024) {
            @rename($LOG_RUTA, $LOG_RUTA . '.1');
        }
    }
}

function salir($mensaje)
{
    fwrite(STDERR, $mensaje . "\n");
    exit(1);
}

// -----------------------------------------------------------------------------
// Comunicacion con el ERP
// -----------------------------------------------------------------------------

/**
 * @return array{ok:bool, status:int, body:array|null, error:string|null}
 */
function llamar(array $config, $metodo, $ruta, array $datos = null)
{
    $ch = curl_init($config['url'] . $ruta);

    $opciones = [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => $config['timeout'],
        CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_HTTPHEADER     => [
            'token: ' . $config['token'],
            'Accept: application/json',
            'Content-Type: application/json',
        ],
    ];

    if (! $config['verificar_ssl']) {
        // Solo para redes internas con certificado propio.
        $opciones[CURLOPT_SSL_VERIFYPEER] = false;
        $opciones[CURLOPT_SSL_VERIFYHOST] = 0;
    }

    if ($metodo === 'POST') {
        $opciones[CURLOPT_POST]       = true;
        $opciones[CURLOPT_POSTFIELDS] = json_encode($datos ?: []);
    }

    curl_setopt_array($ch, $opciones);

    $respuesta = curl_exec($ch);
    $status    = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $errorCurl = curl_error($ch);

    curl_close($ch);

    if ($respuesta === false) {
        return ['ok' => false, 'status' => 0, 'body' => null, 'error' => $errorCurl ?: 'Sin respuesta'];
    }

    $body = json_decode($respuesta, true);

    if ($status < 200 || $status >= 300) {
        $detalle = is_array($body) && isset($body['error']) ? $body['error'] : substr((string) $respuesta, 0, 200);

        return ['ok' => false, 'status' => $status, 'body' => $body, 'error' => "HTTP $status: $detalle"];
    }

    return ['ok' => true, 'status' => $status, 'body' => $body, 'error' => null];
}

// -----------------------------------------------------------------------------
// Impresion
// -----------------------------------------------------------------------------

/**
 * Manda bytes crudos a la impresora.
 *
 * En Windows se escribe a un archivo temporal y se copia en binario al recurso compartido:
 * es lo mismo que hace WindowsPrintConnector de escpos-php, sin arrastrar la libreria.
 * Por eso la impresora tiene que estar COMPARTIDA (o ser un puerto local tipo LPT1) — el
 * mismo requisito de siempre.
 *
 * @throws RuntimeException
 */
function imprimir($impresora, $bytes)
{
    $impresora = trim((string) $impresora);

    if ($impresora === '') {
        throw new RuntimeException('Impresora no informada.');
    }

    if ($bytes === '') {
        throw new RuntimeException('Contenido vacio.');
    }

    $esWindows = strtoupper(substr(PHP_OS, 0, 3)) === 'WIN';

    $tmp = tempnam(sys_get_temp_dir(), 'prn');

    if ($tmp === false) {
        throw new RuntimeException('No se pudo crear el archivo temporal.');
    }

    try {
        if (@file_put_contents($tmp, $bytes) === false) {
            throw new RuntimeException('No se pudo escribir el archivo temporal.');
        }

        if ($esWindows) {
            $destino = destinoWindows($impresora);
            $comando = 'copy /B ' . escapeshellarg($tmp) . ' ' . escapeshellarg($destino);
        } else {
            // Linux/Mac: por si el agente corre en una caja que no es Windows.
            $comando = 'lp -d ' . escapeshellarg($impresora) . ' -o raw ' . escapeshellarg($tmp);
        }

        $salida = [];
        $codigo = 0;

        exec($comando . ' 2>&1', $salida, $codigo);

        if ($codigo !== 0) {
            throw new RuntimeException('Fallo al enviar a la impresora: ' . trim(implode(' ', $salida)));
        }
    } finally {
        @unlink($tmp);
    }

    return true;
}

/**
 * Un puerto local (LPT1, COM1) se usa tal cual; cualquier otra cosa se toma como nombre de
 * recurso compartido en esta misma maquina.
 */
function destinoWindows($impresora)
{
    if (preg_match('/^(LPT\d|COM\d|PRN)$/i', $impresora)) {
        return $impresora;
    }

    if (substr($impresora, 0, 2) === '\\\\') {
        return $impresora;
    }

    $host = gethostname() ?: 'localhost';

    return '\\\\' . $host . '\\' . $impresora;
}

// -----------------------------------------------------------------------------
// Ciclo principal
// -----------------------------------------------------------------------------

function procesarUnCiclo(array $config)
{
    $respuesta = llamar($config, 'POST', '/api/print-agent/jobs', [
        'terminal' => $config['terminal'],
        'limite'   => $config['lote'],
        'agente'   => $config['agente'],
        'versao'   => VERSION_AGENTE,
    ]);

    if (! $respuesta['ok']) {
        registrar('error', 'No se pudo consultar la cola: ' . $respuesta['error']);

        return -1; // el que llama decide esperar mas
    }

    $jobs = isset($respuesta['body']['jobs']) ? $respuesta['body']['jobs'] : [];

    if (empty($jobs)) {
        return 0;
    }

    foreach ($jobs as $job) {
        procesarJob($config, $job);
    }

    return count($jobs);
}

function procesarJob(array $config, array $job)
{
    $id     = isset($job['id']) ? $job['id'] : null;
    $titulo = isset($job['titulo']) ? $job['titulo'] : 'Impresion';

    if (! $id) {
        return;
    }

    try {
        $bytes = base64_decode((string) $job['payload'], true);

        if ($bytes === false) {
            throw new RuntimeException('Contenido ilegible (base64 invalido).');
        }

        // El protocolo no tiene contador de vias: repetir el contenido es como se sacan copias.
        $copias = max(1, (int) (isset($job['copias']) ? $job['copias'] : 1));

        if ($copias > 1) {
            $bytes = str_repeat($bytes, $copias);
        }

        imprimir($job['impressora'], $bytes);

        registrar('info', "Impreso #$id ($titulo) en {$job['impressora']}");

        $ack = llamar($config, 'POST', "/api/print-agent/jobs/$id/ack");

        if (! $ack['ok']) {
            // Se imprimio pero el ERP no se entero. Queda en "procesando" y vuelve a la cola
            // por tiempo; puede salir repetido. Es el mal menor frente a perder el ticket.
            registrar('error', "Impreso #$id pero fallo la confirmacion: " . $ack['error']);
        }
    } catch (Throwable $e) {
        registrar('error', "Fallo #$id ($titulo): " . $e->getMessage());

        llamar($config, 'POST', "/api/print-agent/jobs/$id/fail", [
            'erro' => $e->getMessage(),
        ]);
    }
}

function ticketDePrueba()
{
    $ESC = "\x1B";
    $GS  = "\x1D";

    return $ESC . '@'                     // reset
        . $ESC . 't' . chr(2)             // CP850
        . $ESC . 'a' . chr(1)             // centrado
        . $GS . '!' . chr(0x11)           // doble alto y ancho
        . "NEOSYSTEM\n"
        . $GS . '!' . chr(0)
        . "Prueba de impresion\n"
        . str_repeat('-', 32) . "\n"
        . $ESC . 'a' . chr(0)
        . 'Agente: ' . (gethostname() ?: '?') . "\n"
        . 'Fecha:  ' . date('d/m/Y H:i:s') . "\n"
        // Si estos caracteres salen bien, la codepage esta correcta.
        . "Acentos: \xa3 \xa2 \xa4 \xa8 \x82\n"
        . "         u o n ? e\n"
        . str_repeat('-', 32) . "\n"
        . "\n\n\n"
        . $GS . 'V' . chr(65) . chr(3);   // avanzar y cortar
}

// -----------------------------------------------------------------------------
// Emparejamiento
// -----------------------------------------------------------------------------

/**
 * Canjea el código corto por las credenciales y escribe el agente.ini.
 *
 * Es lo que el instalador ejecuta al final: el cliente tipea 6 caracteres y nunca ve el token.
 * El código sirve una sola vez y vale 15 minutos, así que no hay nada que resguardar después.
 */
function emparejar($url, $codigo, $rutaConfig, $verificarSsl = true)
{
    $url    = rtrim(trim((string) $url), '/');
    $codigo = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', (string) $codigo));

    if ($url === '') {
        return ['ok' => false, 'error' => 'Informe la dirección del ERP.'];
    }

    if ($codigo === '') {
        return ['ok' => false, 'error' => 'Informe el código de emparejamiento.'];
    }

    // Config mínima: emparejar es lo único que se hace sin token.
    $config = array_merge(PADROES, [
        'url'           => $url,
        'token'         => 'x',
        'verificar_ssl' => $verificarSsl ? 1 : 0,
    ]);

    $r = llamar($config, 'POST', '/api/print-agent/pair', [
        'codigo'  => $codigo,
        'maquina' => gethostname() ?: 'Agente',
        'versao'  => VERSION_AGENTE,
    ]);

    if (! $r['ok']) {
        $detalle = is_array($r['body']) && isset($r['body']['error']) ? $r['body']['error'] : $r['error'];

        return ['ok' => false, 'error' => $detalle];
    }

    $cuerpo = $r['body'];

    if (empty($cuerpo['token']) || empty($cuerpo['terminal'])) {
        return ['ok' => false, 'error' => 'El ERP respondió sin token. Verifique la versión del sistema.'];
    }

    $escrito = escribirConfig($rutaConfig, [
        'url'           => $url,
        'token'         => $cuerpo['token'],
        'terminal'      => $cuerpo['terminal'],
        'verificar_ssl' => $verificarSsl ? 1 : 0,
    ]);

    if (! $escrito) {
        return ['ok' => false, 'error' => 'No se pudo escribir ' . $rutaConfig . '. ¿Permisos de escritura?'];
    }

    return ['ok' => true, 'terminal' => $cuerpo['terminal'], 'nombre' => isset($cuerpo['nome']) ? $cuerpo['nome'] : null];
}

/**
 * Escribe el agente.ini preservando los ajustes que ya estuvieran puestos.
 *
 * Reemparejar (cambio de token, por ejemplo) no puede borrar el intervalo o la impresora que
 * alguien ajustó a mano.
 */
function escribirConfig($ruta, array $nuevos)
{
    $actuales = [];

    if (is_file($ruta)) {
        $leido = @parse_ini_file($ruta, false, INI_SCANNER_TYPED);

        if (is_array($leido)) {
            $actuales = $leido;
        }
    }

    $final = array_merge(PADROES, $actuales, $nuevos);

    $lineas = [
        '; Configuración del agente de impresión NEOSYSTEM.',
        '; Generado por el emparejamiento el ' . date('d/m/Y H:i:s') . '.',
        '; El token identifica ESTA máquina: trátelo como una contraseña.',
        '',
    ];

    foreach (['url', 'token', 'terminal', 'agente', 'intervalo', 'lote', 'timeout', 'log', 'log_nivel', 'verificar_ssl'] as $clave) {
        $valor = isset($final[$clave]) ? $final[$clave] : '';

        $lineas[] = is_int($valor) || is_float($valor)
            ? $clave . ' = ' . $valor
            : $clave . ' = "' . str_replace('"', '', (string) $valor) . '"';
    }

    return @file_put_contents($ruta, implode(PHP_EOL, $lineas) . PHP_EOL) !== false;
}

/** Lee --clave=valor de la línea de comandos. */
function argumento(array $argumentos, $nombre, $porDefecto = null)
{
    $prefijo = '--' . $nombre . '=';

    foreach ($argumentos as $arg) {
        if (strpos($arg, $prefijo) === 0) {
            return substr($arg, strlen($prefijo));
        }
    }

    return $porDefecto;
}

// -----------------------------------------------------------------------------
// Arranque
// -----------------------------------------------------------------------------

$argumentos = array_slice($argv, 1);
$rutaConfig = __DIR__ . DIRECTORY_SEPARATOR . 'agente.ini';

foreach ($argumentos as $arg) {
    if (strpos($arg, '--config=') === 0) {
        $rutaConfig = substr($arg, 9);
    }
}

// El emparejamiento corre ANTES de cargar la configuración: es justamente lo que la crea, así
// que en una instalación nueva el agente.ini todavía no existe.
if ($codigoPar = argumento($argumentos, 'pair')) {
    // `--sin-ssl` es una bandera sin valor, así que se busca por presencia y no con
    // argumento(), que lee `--clave=valor`.
    $resultado = emparejar(
        argumento($argumentos, 'url'),
        $codigoPar,
        $rutaConfig,
        ! in_array('--sin-ssl', $argumentos, true)
    );

    if (! $resultado['ok']) {
        salir('Emparejamiento fallido: ' . $resultado['error']);
    }

    echo 'Emparejado correctamente.' . PHP_EOL;
    echo '  Terminal: ' . $resultado['terminal'] . PHP_EOL;
    echo '  Configuración guardada en ' . $rutaConfig . PHP_EOL;
    exit(0);
}

$config    = cargarConfig($rutaConfig);
$LOG_RUTA  = $config['log'] ? (__DIR__ . DIRECTORY_SEPARATOR . $config['log']) : null;
$LOG_NIVEL = $config['log_nivel'] === 'error' ? 'error' : 'info';

$unaVez  = in_array('--once', $argumentos, true);
$prueba  = in_array('--test', $argumentos, true);
$soloPing = in_array('--ping', $argumentos, true);

if ($prueba) {
    $impresora = null;

    foreach ($argumentos as $arg) {
        if (strpos($arg, '--impresora=') === 0) {
            $impresora = substr($arg, 12);
        }
    }

    if (! $impresora) {
        salir("Indique la impresora: php agente.php --test --impresora=\"NombreDeLaImpresora\"");
    }

    try {
        imprimir($impresora, ticketDePrueba());
        registrar('info', "Ticket de prueba enviado a $impresora");
        exit(0);
    } catch (Throwable $e) {
        salir('Fallo la prueba: ' . $e->getMessage());
    }
}

if ($soloPing) {
    $r = llamar($config, 'GET', '/api/print-agent/ping?terminal=' . urlencode($config['terminal']));

    if (! $r['ok']) {
        salir('Ping fallido: ' . $r['error']);
    }

    registrar('info', 'Conexion OK. Pendientes: ' . (isset($r['body']['pendientes']) ? $r['body']['pendientes'] : (isset($r['body']['pendentes']) ? $r['body']['pendentes'] : '?')));
    exit(0);
}

registrar('info', sprintf(
    'Agente iniciado. Terminal=%s  Agente=%s  ERP=%s',
    $config['terminal'],
    $config['agente'],
    $config['url']
));

// Ctrl+C sale limpio en vez de dejar un trabajo a medias.
if (function_exists('pcntl_signal') && function_exists('pcntl_async_signals')) {
    pcntl_async_signals(true);
    pcntl_signal(SIGINT, function () {
        registrar('info', 'Agente detenido.');
        exit(0);
    });
    pcntl_signal(SIGTERM, function () {
        registrar('info', 'Agente detenido.');
        exit(0);
    });
}

$fallosSeguidos = 0;

do {
    $procesados = procesarUnCiclo($config);

    if ($procesados < 0) {
        // Sin conexion: espera creciente hasta 60s, para no golpear un servidor caido.
        $fallosSeguidos++;
        $espera = min(60, $config['intervalo'] * min(10, $fallosSeguidos));
    } else {
        $fallosSeguidos = 0;
        // Si hubo trabajo, vuelve a preguntar enseguida: puede haber mas en la cola.
        $espera = $procesados > 0 ? 0 : $config['intervalo'];
    }

    if (! $unaVez && $espera > 0) {
        sleep($espera);
    }
} while (! $unaVez);

registrar('info', 'Ciclo unico terminado.');
