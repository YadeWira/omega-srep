unit CpuFeat;
{ Si la CPU tiene SSE4.2: lo que pregunta crc32c() (hashes.cpp:226) y lo que
  decide cual de los dos hashes de frontera usa CDC (-m1/-m2). Las dos rutas
  dan archivos DISTINTOS, asi que el port tiene que hacer la misma pregunta
  que el C++ y el Rust (`is_x86_feature_detected!("sse4.2")`): CPUID hoja 1,
  bit 20 de ECX. La unidad cpu de FPC 3.2.2 no la trae.

  Como en spillfile.pas, la cadena de $IF termina en $FATAL: un simbolo mal
  escrito no puede caer en silencio en la rama equivocada. }

{$MODE OBJFPC}{$H+}
interface

function HasSse42: Boolean;

implementation

{$asmmode intel}

{$IF DEFINED(CPUX86_64)}
function CpuidEcx1: DWord; assembler; nostackframe;
asm
  push rbx
  mov eax, 1
  cpuid
  mov eax, ecx
  pop rbx
end;
{$ELSEIF DEFINED(CPUI386)}
function CpuidEcx1: DWord; assembler; nostackframe;
asm
  push ebx
  mov eax, 1
  cpuid
  mov eax, ecx
  pop ebx
end;
{$ELSE}
  {$FATAL cpufeat.pas: no hay CPUID para esta arquitectura}
{$ENDIF}

function HasSse42: Boolean;
begin
  Result := (CpuidEcx1 and (DWord(1) shl 20)) <> 0;
end;

end.
