#!/usr/bin/env -vS make -f

PREFIX?=/usr/local

STATIC= -static

# Platform detection. uname -s is reported by MSYS/MinGW/Cygwin too,
# so we can pick FREEARC_UNIX vs FREEARC_WIN at build time.
UNAME_S:=$(shell uname -s 2>/dev/null || echo Unknown)
ifneq (,$(filter MINGW% MSYS% CYGWIN% Windows%,$(UNAME_S)))
  # FREEARC_WIN goes through Common.h's TCHAR-based filename API; that
  # path assumes UNICODE so tchar.h resolves TCHAR to wchar_t and the
  # *W function variants line up with the codebase's _wopen/MoveFileW
  # call sites. Common.cpp also calls COM APIs (CoInitialize* /
  # CoCreateInstance) for shell integration so we link ole32 + uuid.
  OS_DEFINE= -DFREEARC_WIN -DUNICODE -D_UNICODE
  LDFLAGS+= -lstdc++ -lole32 -luuid -lshell32 -ladvapi32 $(STATIC)
  CXX?= g++
else
  OS_DEFINE= -DFREEARC_UNIX
  LDFLAGS+= -lpthread -lstdc++ $(STATIC)
  # `which c++` fails on MinGW; fall back to g++ if missing.
  CXX_CANDIDATE!=which c++ 2>/dev/null || which g++ 2>/dev/null || which clang++ 2>/dev/null || echo g++
  CXX?= $(CXX_CANDIDATE)
endif

OPTIMISATION+= -O3 -flto -mtune=generic -funroll-all-loops -msse2
DEBUGGING= -ggdb3 -fverbose-asm
VERBOSITY= -v
WARNINGS= -Wno-write-strings -Wno-unused-result
CFLAGS+= $(OPTIMISATION) $(DEBUGGING) $(WARNINGS) $(VERBOSITY)

INCLUDES+= -ICompression -ICompression/_Encryption -ICompression/_Encryption/headers -ICompression/_Encryption/hashes
DEFINES+= $(OS_DEFINE) -DFREEARC_INTEL_BYTE_ORDER -D_FILE_OFFSET_BITS=64
CPPFLAGS+= $(DEFINES) $(INCLUDES)

CXXSOURCES= Compression/Common.cpp Compression/SREP/srep.cpp 
CXXDEPS= Compression/SREP/compress.cpp Compression/SREP/compress_inmem.cpp Compression/SREP/hash_table.cpp Compression/SREP/decompress.cpp Compression/SREP/compress_cdc.cpp Compression/SREP/io.cpp Compression/SREP/hashes.cpp Compression/SREP/dedup.cpp Compression/SREP/dup_wrapper.cpp Compression/MultiThreading.cpp $(CXXSOURCES)
HDEPS= Compression/MultiThreading.h Compression/LZMA2/C/ThreadsUnix.h Compression/LZMA2/C/Threads.h Compression/LZMA2/C/MyGuidDef.h Compression/LZMA2/C/Types.h Compression/LZMA2/C/basetyps.h Compression/LZMA2/C/windows.h Compression/LZMA2/C/MyWindows.h Compression/LZMA2/MultiThreading/Synchronization.h Compression/LZMA2/MultiThreading/Thread.h Compression/LZMA2/MultiThreading/Defs.h Compression/_Encryption/hashes/siphash/siphash_impl.h Compression/_Encryption/hashes/vmac/vmac.h Compression/_Encryption/headers/tomcrypt_cfg.h Compression/_Encryption/headers/tomcrypt_argchk.h Compression/_Encryption/headers/tomcrypt_cipher.h Compression/_Encryption/headers/tomcrypt_macros.h Compression/_Encryption/headers/tomcrypt_hash.h Compression/_Encryption/headers/tomcrypt_misc.h Compression/_Encryption/headers/tomcrypt_custom.h Compression/_Encryption/headers/tomcrypt_pkcs.h Compression/_Encryption/headers/tomcrypt_mac.h Compression/_Encryption/headers/tomcrypt_prng.h Compression/_Encryption/headers/tomcrypt.h Compression/Compression.h Compression/Common.h 
CDEPS= Compression/LZMA2/C/ThreadsUnix.c Compression/LZMA2/C/ThreadsWin32.c Compression/LZMA2/C/Threads.c Compression/_Encryption/ciphers/aes/aes.c Compression/_Encryption/ciphers/aes/aes_tab.c Compression/_Encryption/hashes/siphash/siphash.c Compression/_Encryption/hashes/sha1.c Compression/_Encryption/hashes/vmac/vmac.c Compression/_Encryption/hashes/sha2/sha512.c Compression/_Encryption/hashes/md5.c Compression/_Encryption/crypt/crypt_argchk.c Compression/_Encryption/prngs/fortuna.c Compression/_Encryption/misc/zeromem.c
DEPS= $(CXXDEPS) $(HDEPS) $(CDEPS) 

bin/osrep: Makefile $(DEPS)
	mkdir -p -v bin
	$(CXX) $(CPPFLAGS) $(CFLAGS) $(CXXSOURCES) $(LDFLAGS) -o bin/osrep

bin/dedup_test: Makefile tests/dedup_test.cpp Compression/SREP/dedup.cpp
	mkdir -p -v bin
	$(CXX) -O2 -Wall -Wextra -Wno-unused-parameter tests/dedup_test.cpp -lstdc++ $(STATIC) -o bin/dedup_test

clean:
	rm -f -v bin/osrep bin/dedup_test

all: bin/osrep bin/dedup_test

# Profile-guided optimization -- maintainer-only release-build step, NOT part
# of `all`/`install`. Ordinary from-source builds want a fast single-pass
# `make bin/osrep`; the instrumented binary is slower and leaves .gcda profile
# data as a side effect, which plain contributors don't want in their tree.
#
#   make bin/osrep-pgo   -- runs the full instrument -> train -> rebuild cycle
#   make pgo-clean       -- removes all PGO intermediates
PGO_DIR= pgo-data

bin/osrep-pgo-instrumented: Makefile $(DEPS)
	mkdir -p -v bin
	$(CXX) $(CPPFLAGS) $(CFLAGS) -fprofile-generate=$(PGO_DIR) $(CXXSOURCES) $(LDFLAGS) -o bin/osrep-pgo-instrumented

pgo-train: bin/osrep-pgo-instrumented
	bash tests/pgo_train.sh bin/osrep-pgo-instrumented $(PGO_DIR)

# -fprofile-correction tolerates the minor training/production profile
# mismatches a multi-threaded program's non-deterministic thread interleaving
# naturally introduces (-m1/-m2/-m3/-m5 all have real thread-pool activity);
# GCC's PGO is otherwise strict about profile inconsistencies.
bin/osrep-pgo: pgo-train
	$(CXX) $(CPPFLAGS) $(CFLAGS) -fprofile-use=$(PGO_DIR) -fprofile-correction $(CXXSOURCES) $(LDFLAGS) -o bin/osrep-pgo

pgo-clean:
	rm -rf -v $(PGO_DIR) bin/osrep-pgo-instrumented bin/osrep-pgo

install: all
	mkdir -p -v "$(PREFIX)"/bin/
	install -p -m 0755 -v bin/osrep "$(PREFIX)"/bin/
	mkdir -p -v "$(PREFIX)"/share/man/man1/
	install -p -m 0644 -v man/osrep.1 "$(PREFIX)"/share/man/man1/
	mkdir -p -v "$(PREFIX)"/share/bash-completion/completions/
	install -p -m 0644 -v completions/osrep.bash "$(PREFIX)"/share/bash-completion/completions/osrep
	mkdir -p -v "$(PREFIX)"/share/zsh/site-functions/
	install -p -m 0644 -v completions/_osrep "$(PREFIX)"/share/zsh/site-functions/_osrep
