program V6FrameSelftest;
{ Prueba de la capa de contenedor v6 (Container.pas): cabecera, header de
  bloque, footer y el encadenado de CRC. No toca el encoder ni el decoder
  todavia; lo que verifica es que el armazon detecta corrupcion en cada campo
  y que los valores sobreviven el round-trip.

  Lo compila y corre tests/v6_frame_selftest.sh. }
{$MODE OBJFPC}{$H+}
{$RANGECHECKS ON}{$OVERFLOWCHECKS ON}

uses SysUtils, Container, Widths;

var
  pass, bad: LongInt;

procedure Ok(Cond: Boolean; const Name: AnsiString);
begin
  if Cond then Inc(pass)
  else begin Inc(bad); WriteLn(StdErr, 'FAIL: ', Name); end;
end;

function SameHeader(const A, B: TV6Header): Boolean;
begin
  Result := (A.Version = B.Version) and (A.Flags = B.Flags) and
            (A.HashId = B.HashId) and (A.HashSize = B.HashSize) and
            (A.MaxMatch = B.MaxMatch) and (A.BlockCount = B.BlockCount) and
            (A.OriginalSize = B.OriginalSize);
end;

function SameFooter(const A, B: TV6Footer): Boolean;
begin
  Result := (A.BlockCount = B.BlockCount) and (A.StatSize = B.StatSize) and
            (A.MetaOffset = B.MetaOffset) and (A.MetaSize = B.MetaSize) and
            (A.BlocksCrc = B.BlocksCrc);
end;

var
  h, h2: TV6Header;
  f, f2: TV6Footer;
  bh, bh2: TBlockHeader;
  b, payload: TBytes;
  crc, crc2, c: DWord;
  i: LongInt;
  ce: TContainerError;
begin
  pass := 0; bad := 0;

  { --- cabecera --- }
  h.Version := 6; h.Flags := V6_FLAG_HAS_DUP; h.HashId := 4; h.HashSize := 16;
  h.MaxMatch := 8388584; h.BlockCount := 3; h.OriginalSize := QWord(123456789);
  b := EncodeV6Header(h);
  Ok(QWord(Length(b)) = V6_HEADER_SIZE, 'v6 header size');
  Ok(IsV6(b), 'IsV6');
  Ok(not IsV5(b), 'IsV5 false on v6');
  ce := DecodeV6Header(b, h2);
  Ok(ce = ceOK, 'v6 header decodes');
  Ok(SameHeader(h, h2), 'v6 header round-trip');

  { un byte cambiado en cada zona: datos, version, flags, CRC }
  for i := 0 to V6_HEADER_SIZE - 1 do
  begin
    payload := Copy(b);
    payload[i] := payload[i] xor $5A;
    ce := DecodeV6Header(payload, h2);
    if i < 4 then
      { la magia no es un CRC: el lector dice "no es un .osr" }
      Ok(ce = ceNotAnOsrepFile, 'header magic byte rejected at ' + IntToStr(i))
    else if i = 4 then
      Ok(ce = ceUnsupportedVersion, 'header version byte rejected')
    else if i = 5 then
      Ok(ce = ceBadFlags, 'header flags byte rejected')
    else
      Ok(ce = ceBadCrc, 'header flip rejected at ' + IntToStr(i));
  end;

  { version 5 con magia OSR6: se rechaza por version, no se adivina }
  payload := Copy(b);
  payload[4] := 5;
  Ok(DecodeV6Header(payload, h2) = ceUnsupportedVersion, 'OSR6 with version 5 rejected');

  { --- header de bloque --- }
  bh.LiteralBytes := 4096; bh.OrigSize := 8192; bh.StatSize := 128;
  crc := Crc32cUpdate(0, b, 0, QWord(Length(b)));
  b := EncodeV6BlockHeader(bh, crc);
  Ok(QWord(Length(b)) = V6_BLOCK_HEADER_SIZE, 'v6 block header size');
  ce := DecodeV6BlockHeader(b, 0, bh2, crc2);
  Ok(ce = ceOK, 'v6 block header decodes');
  Ok((bh2.LiteralBytes = bh.LiteralBytes) and (bh2.OrigSize = bh.OrigSize) and
     (bh2.StatSize = bh.StatSize) and (crc2 = crc), 'v6 block header round-trip');

  { --- footer y cadena de CRC de bloques --- }
  f.BlockCount := 3; f.StatSize := 384; f.MetaOffset := 0; f.MetaSize := 0;
  f.BlocksCrc := Crc32cUpdateDWord(Crc32cUpdateDWord(0, $11111111), $22222222);
  b := EncodeV6Footer(f);
  Ok(QWord(Length(b)) = V6_FOOTER_SIZE, 'v6 footer size');
  ce := DecodeV6Footer(b, 0, f2);
  Ok(ce = ceOK, 'v6 footer decodes');
  Ok(SameFooter(f, f2), 'v6 footer round-trip');
  for i := 0 to V6_FOOTER_SIZE - 1 do
  begin
    payload := Copy(b);
    payload[i] := payload[i] xor $A5;
    if i < 4 then
      Ok(DecodeV6Footer(payload, 0, f2) = ceNoFooter, 'footer magic rejected at ' + IntToStr(i))
    else
      Ok(DecodeV6Footer(payload, 0, f2) = ceBadCrc, 'footer flip rejected at ' + IntToStr(i));
  end;

  { la cadena depende del orden: los mismos dos CRC al reves dan otra }
  c := Crc32cUpdateDWord(Crc32cUpdateDWord(0, $22222222), $11111111);
  Ok(c <> f.BlocksCrc, 'blocks_crc depends on order');

  { un payload con un byte cambiado cambia su CRC (el caso del bloque
    guardado sin comprimir que --verify tiene que ver) }
  SetLength(payload, 1000);
  for i := 0 to 999 do payload[i] := Byte(i);
  crc := Crc32cUpdate(0, payload, 0, 1000);
  payload[500] := payload[500] xor $01;
  crc2 := Crc32cUpdate(0, payload, 0, 1000);
  Ok(crc <> crc2, 'stored-block byte flip changes the block crc');

  WriteLn('  v6_frame_selftest: passed=', pass, ' mismatches=', bad);
  if bad <> 0 then Halt(1);
end.
