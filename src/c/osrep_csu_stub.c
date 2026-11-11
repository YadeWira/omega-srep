/* FPC's aarch64 cprt0.o still calls the old glibc __libc_csu_init/fini,
   removed from modern glibc. The functions are no-ops for a console program;
   the cross build links this stub only for that toolchain. */
void __libc_csu_init(void) {}
void __libc_csu_fini(void) {}
