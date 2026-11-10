# Source layout

```
  src/pascal/   Free Pascal: container, CLI, orchestration, encoder/decoder
  src/c/        C with intrinsics: CRC-32C, memory ops, AES/VMAC, SHA,
                the scan loop (last)
  src/asm/      FPC asm: prefetch, CPUID/HWCAP, single instructions
```

The rules for native code are in `docs/native-c-asm.md`: pure functions, no
libc, `cdecl` ABI, fixed-width types, `osrep_` prefix; every native function
has a Pascal reference and a `-dOSREP_NO_NATIVE` build; the bytes never
change; no `-march=native`.

The implementation is written from `spec/` and `tests/fixtures/` only. Read
`CLEAN-ROOM.md` before adding a file here.
