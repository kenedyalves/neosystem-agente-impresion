; ---------------------------------------------------------------------------
; Instalador del Agente de Impresión NEOSYSTEM.
;
; Genera un .exe único que el cliente baja y ejecuta. Lleva PHP adentro, así que
; no hay nada para instalar antes. Lo único que el cliente tipea es el código de
; emparejamiento de 6 caracteres que ve en el ERP.
;
; Para compilar:  build.ps1   (arma el PHP mínimo y llama a ISCC)
; ---------------------------------------------------------------------------

#define AppName        "Agente de Impresion NEOSYSTEM"
#define AppShortName   "NeosystemAgente"
#define AppVersion     "1.0.0"
#define AppPublisher   "NEOSYSTEM"

; La dirección la escribe el cliente en la instalación, así que el campo arranca
; VACÍO: una URL de ejemplo pre-cargada se acepta sin leer y termina instalando
; agentes apuntados al lugar equivocado.
;
; Se puede pre-cargar al compilar (build.ps1 -Url "...") o al instalar (/URL=...),
; pero eso es para despliegue desatendido, no para el uso normal.
#define DefaultUrl     ""

[Setup]
AppId={{8F3A4C21-7B95-4E13-A6D2-9C1E5F80B742}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppShortName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=.\dist
OutputBaseFilename=neosystem-agente-impresion-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Sin privilegios de administrador: instala para el usuario que corre el PDV, que
; es el mismo que después inicia sesión y necesita el agente andando.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#AppName}
SetupLogging=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Files]
; Runtime PHP mínimo (php.exe + engine + TLS + curl/mbstring): ~15 MB sin comprimir.
Source: "payload\php\*"; DestDir: "{app}\php"; Flags: ignoreversion recursesubdirs createallsubdirs
; El agente.
Source: "payload\agente.php"; DestDir: "{app}"; Flags: ignoreversion
Source: "payload\iniciar.bat"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Arranca junto con Windows: el PDV queda logueado todo el día.
Name: "{userstartup}\{#AppName}"; Filename: "{app}\iniciar.bat"; WorkingDir: "{app}"; IconFilename: "{app}\php\php.exe"; Comment: "Agente de impresión NEOSYSTEM"
Name: "{group}\Ver estado del agente"; Filename: "{app}\iniciar.bat"; WorkingDir: "{app}"
Name: "{group}\Desinstalar"; Filename: "{uninstallexe}"

[Run]
; Arranca ya, sin esperar el próximo reinicio.
Filename: "{app}\iniciar.bat"; Description: "Iniciar el agente ahora"; Flags: postinstall nowait shellexec skipifsilent

[UninstallDelete]
; Config y log son generados, no instalados: hay que borrarlos a mano.
Type: files; Name: "{app}\agente.ini"
Type: files; Name: "{app}\agente.log"
Type: files; Name: "{app}\agente.log.1"

[Code]
var
  PaginaPar: TInputQueryWizardPage;

{ Lee /CLAVE=valor de la línea de comandos del instalador.

  Sirve para dos cosas: instalación desatendida (varias sucursales de una vez) y
  para poder probar el instalador de punta a punta sin tipear en la pantalla. }
function ParametroLinea(const Nombre, PorDefecto: string): string;
var
  i: Integer;
  Prefijo, Arg: string;
begin
  Result := PorDefecto;
  Prefijo := '/' + Uppercase(Nombre) + '=';

  for i := 1 to ParamCount do
  begin
    Arg := ParamStr(i);
    if Pos(Prefijo, Uppercase(Arg)) = 1 then
    begin
      Result := Copy(Arg, Length(Prefijo) + 1, MaxInt);
      Exit;
    end;
  end;
end;

procedure InitializeWizard;
begin
  PaginaPar := CreateInputQueryPage(wpSelectDir,
    'Conectar con el sistema',
    'Vincule esta computadora con su NEOSYSTEM',
    'Escriba la dirección con la que entra al sistema desde el navegador, y el' + #13#10 +
    'código que le muestra la pantalla Agentes de impresión al hacer clic en' + #13#10 +
    '"Agregar impresora". El código vale 15 minutos.');

  PaginaPar.Add('Dirección del sistema (ej: https://miempresa.neosystem.com):', False);
  PaginaPar.Add('Código de emparejamiento:', False);

  { Vacíos salvo que vengan por línea de comandos (despliegue desatendido). }
  PaginaPar.Values[0] := ParametroLinea('URL', '{#DefaultUrl}');
  PaginaPar.Values[1] := ParametroLinea('CODIGO', '');
end;

{ Quita espacios de los dos extremos. }
function Recortar(const S: string): string;
begin
  Result := Trim(S);
end;

{ Muestra un aviso sólo cuando hay alguien mirando.

  En instalación desatendida no puede aparecer NINGUNA ventana: no hay quien la
  cierre y el instalador queda colgado esperando para siempre. El mensaje va al
  log del Setup, que es donde se mira cuando algo salió mal en un despliegue. }
procedure Avisar(const Mensaje: string; Tipo: TMsgBoxType);
begin
  if WizardSilent() then
    Log('[agente] ' + Mensaje)
  else
    MsgBox(Mensaje, Tipo, MB_OK);
end;

{ ¿La dirección es de la red interna? (localhost o rango privado)

  Importa sólo para decidir el protocolo cuando el cliente no lo escribió: en una
  red interna casi nunca hay certificado, así que asumir https dejaría el agente
  sin conectar. }
function EsDireccionInterna(const Host: string): Boolean;
var
  H: string;
begin
  H := Lowercase(Trim(Host));

  Result := (Pos('localhost', H) = 1)
         or (Pos('127.', H) = 1)
         or (Pos('192.168.', H) = 1)
         or (Pos('10.', H) = 1)
         or (Pos('172.16.', H) = 1)  or (Pos('172.17.', H) = 1)
         or (Pos('172.18.', H) = 1)  or (Pos('172.19.', H) = 1)
         or (Pos('172.20.', H) = 1)  or (Pos('172.21.', H) = 1)
         or (Pos('172.22.', H) = 1)  or (Pos('172.23.', H) = 1)
         or (Pos('172.24.', H) = 1)  or (Pos('172.25.', H) = 1)
         or (Pos('172.26.', H) = 1)  or (Pos('172.27.', H) = 1)
         or (Pos('172.28.', H) = 1)  or (Pos('172.29.', H) = 1)
         or (Pos('172.30.', H) = 1)  or (Pos('172.31.', H) = 1);
end;

{ Arregla lo que el cliente escribe a mano.

  Tres cosas pasan siempre: pega la dirección con la barra final, escribe sólo el
  dominio sin https://, o arrastra un espacio al copiar. Ninguna de las tres es un
  error del cliente, así que se corrigen en vez de rechazarlas. }
function NormalizarUrl(const S: string): string;
var
  U, Protocolo, Resto: string;
  P: Integer;
begin
  U := Trim(S);

  { El cliente casi siempre copia la dirección de la barra del navegador, y ahí
    viene con la página adentro (.../impressao/agentes). Al agente le sirve sólo
    el origen: protocolo + host + puerto. Sin esto, las llamadas irían a
    .../impressao/agentes/api/print-agent/... y darían 404. }
  P := Pos('//', U);

  if P > 0 then
  begin
    Protocolo := Copy(U, 1, P + 1);
    Resto     := Copy(U, P + 2, MaxInt);
  end
  else
  begin
    Protocolo := '';
    Resto     := U;
  end;

  P := Pos('/', Resto);
  if P > 0 then
    Resto := Copy(Resto, 1, P - 1);

  U := Protocolo + Resto;

  while (Length(U) > 0) and (U[Length(U)] = '/') do
    Delete(U, Length(U), 1);

  { Sin protocolo hay que elegir uno. https para un ERP publicado; http cuando es
    una dirección de red interna, donde casi nunca hay certificado. }
  if (Length(U) > 0)
     and (Pos('http://', Lowercase(U)) <> 1)
     and (Pos('https://', Lowercase(U)) <> 1) then
  begin
    if EsDireccionInterna(U) then
      U := 'http://' + U
    else
      U := 'https://' + U;
  end;

  Result := U;
end;

{ Valida lo mínimo para no salir a la red con una dirección sin sentido. }
function UrlParecePlausible(const S: string): Boolean;
var
  Host: string;
  P: Integer;
begin
  Result := False;

  P := Pos('//', S);
  if P = 0 then
    Exit;

  Host := Copy(S, P + 2, MaxInt);

  { Corta en la primera barra: interesa el host, no el path. }
  P := Pos('/', Host);
  if P > 0 then
    Host := Copy(Host, 1, P - 1);

  if Host = '' then
    Exit;

  { Un host sin punto sólo vale para pruebas locales (localhost, 127.0.0.1). }
  if (Pos('.', Host) = 0)
     and (Lowercase(Copy(Host, 1, 9)) <> 'localhost') then
    Exit;

  Result := True;
end;

{ Corre el emparejamiento y devuelve True si quedó configurado. }
function Emparejar(const Codigo, Url: string): Boolean;
var
  Ejecutable, Parametros, ArchivoIni: string;
  Resultado: Integer;
begin
  Ejecutable := ExpandConstant('{app}\php\php.exe');
  ArchivoIni := ExpandConstant('{app}\agente.ini');

  Parametros := '"' + ExpandConstant('{app}\agente.php') + '"' +
                ' --pair=' + Codigo +
                ' --url="' + Url + '"';

  if not Exec(Ejecutable, Parametros, ExpandConstant('{app}'),
              SW_HIDE, ewWaitUntilTerminated, Resultado) then
  begin
    Avisar('No se pudo ejecutar el agente para emparejar.' + #13#10 +
           'Código del sistema: ' + IntToStr(Resultado), mbError);
    Result := False;
    Exit;
  end;

  { El agente devuelve 0 sólo cuando llegó a escribir el agente.ini. }
  Result := (Resultado = 0) and FileExists(ArchivoIni);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Codigo, Url: string;
begin
  Result := True;

  if CurPageID <> PaginaPar.ID then
    Exit;

  Url    := NormalizarUrl(PaginaPar.Values[0]);
  Codigo := Uppercase(Recortar(PaginaPar.Values[1]));

  if Url = '' then
  begin
    MsgBox('Escriba la dirección de su sistema.' + #13#10 + #13#10 +
           'Es la misma que usa para entrar desde el navegador,' + #13#10 +
           'por ejemplo: https://miempresa.neosystem.com', mbError, MB_OK);
    Result := False;
    Exit;
  end;

  if not UrlParecePlausible(Url) then
  begin
    MsgBox('La dirección "' + Url + '" no parece válida.' + #13#10 + #13#10 +
           'Escriba la dirección completa de su sistema,' + #13#10 +
           'por ejemplo: https://miempresa.neosystem.com', mbError, MB_OK);
    Result := False;
    Exit;
  end;

  if Codigo = '' then
  begin
    MsgBox('Escriba el código de emparejamiento.' + #13#10 + #13#10 +
           'Lo obtiene en el sistema, en Agentes de impresión >' + #13#10 +
           '"Agregar impresora". Son 6 caracteres y valen 15 minutos.', mbError, MB_OK);
    Result := False;
    Exit;
  end;

  { Devuelve a la pantalla lo ya corregido, para que el cliente vea con qué se va
    a instalar en lugar de que se arregle a sus espaldas. }
  PaginaPar.Values[0] := Url;
  PaginaPar.Values[1] := Codigo;

  { El emparejamiento de verdad corre después de copiar los archivos — acá todavía
    no existe el php.exe. }
end;

{ Después de instalar los archivos, intenta emparejar. Si falla, el usuario puede
  volver atrás y corregir el código sin reinstalar nada. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Codigo, Url: string;
begin
  if CurStep <> ssPostInstall then
    Exit;

  { En modo desatendido NextButtonClick no corre, así que se normaliza también acá. }
  Url    := NormalizarUrl(PaginaPar.Values[0]);
  Codigo := Uppercase(Recortar(PaginaPar.Values[1]));

  if (Url = '') or (Codigo = '') then
  begin
    Avisar('Falta la dirección del sistema o el código de emparejamiento.' + #13#10 +
           'El agente quedó instalado pero sin vincular.', mbError);
    Exit;
  end;

  if Emparejar(Codigo, Url) then
  begin
    Avisar('¡Listo! Esta computadora quedó vinculada al sistema.' + #13#10 + #13#10 +
           'El agente se inicia solo junto con Windows.', mbInformation);
  end
  else
  begin
    Avisar('El agente se instaló, pero no se pudo vincular con el sistema.' + #13#10 + #13#10 +
           'Causas habituales:' + #13#10 +
           '  - el código ya venció (vale 15 minutos) o ya fue usado' + #13#10 +
           '  - la dirección del sistema es incorrecta' + #13#10 +
           '  - esta computadora no tiene acceso a internet' + #13#10 + #13#10 +
           'Genere un código nuevo en el sistema y vuelva a ejecutar este instalador.',
           mbError);
  end;
end;
