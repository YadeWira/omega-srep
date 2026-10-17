unit StdFds;
{ Los descriptores 0, 1 y 2 cerrados al arrancar (`osrep x x.osr 2>&-`).

  El primer open de un proceso toma el descriptor libre mas bajo. Si el 2
  esta cerrado y el 0 o el 1 tambien, el archivo de salida queda en el fd 2,
  y todo lo que el programa escribe a stderr (el progreso, el resumen) va a
  parar ADENTRO del archivo: `osrep x x.osr <&- 2>&-` daba un archivo con 51
  bytes de texto en el medio que no descomprimia, con exit 0; `-d` metia el
  texto en los datos descomprimidos. El C++ 1.0.7 hace lo mismo. El Rust no,
  porque su runtime, antes de main, reabre en /dev/null todo fd 0-2 cerrado.

  Esta unidad hace eso mismo al inicializarse, y por eso va PRIMERA en el
  uses de osrep.lpr (no depende de nada mas que BaseUnix, asi que nada se
  inicializa antes salvo la RTL, que no abre archivos). En el mismo orden y
  con el mismo /dev/null que el Rust, asi que cada open cae en el fd que
  reemplaza; si /dev/null no se puede abrir, el Rust aborta y aca tambien.

  Una diferencia, que el Rust tambien hace (oracles/rust/.../stdio.rs, que
  corre antes que su runtime): el fd 1 se reabre SOLO LECTURA. Escribir ahi
  falla con EBADF, que es lo que da escribir a un fd cerrado, asi que el
  archivo o los datos mandados a un stdout cerrado son un error ("Io" o
  "Can't write to stdout"), como con un lector que se fue, y no un descarte
  con exit 0: con /dev/null, `osrep -delete x - >&-` no escribia nada en
  ningun lado y borraba x. Los mensajes a un stdout o stderr que falla se
  pierden sin error, como siempre. Un stdin cerrado se lee vacio.

  En Windows no hay nada que reservar: los handles no se numeran como los
  fds, y uno que falta es nulo. El handle nulo o invalido se trata en
  osrep.lpr (StdinRead) y en las escrituras de datos, que fallan solas. }

{$MODE OBJFPC}{$H+}
interface

implementation

{$IF DEFINED(UNIX)}
uses BaseUnix;

procedure ReserveStdFds;
var fd, flags: cint;
begin
  for fd := 0 to 2 do
    if (FpFcntl(fd, F_GETFD) = -1) and (FpGetErrno = ESysEBADF) then
    begin
      if fd = 1 then flags := O_RDONLY else flags := O_RDWR;
      if FpOpen('/dev/null', flags) = -1 then
      begin
        { libc::abort() del Rust: SIGABRT con la accion por defecto }
        FpSignal(SIGABRT, signalhandler(SIG_DFL));
        FpKill(FpGetPid, SIGABRT);
        FpExit(134);
      end;
    end;
end;

initialization
  ReserveStdFds;
{$ELSEIF DEFINED(WINDOWS)}
{$ELSE}
  {$FATAL stdfds.pas: no hay implementacion para esta plataforma}
{$ENDIF}
end.
