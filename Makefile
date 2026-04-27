#!/usr/bin/env -vS make -f

PREFIX?=/usr/local

STATIC= -static

# Platform detection. uname -s is reported by MSYS/MinGW/Cygwin too,
# so we can pick FREEARC_UNIX vs FREEARC_WIN at build time.
UNAME_S:=$(shell uname -s 2>/dev/null || echo Unknown)
ifneq (,$(filter MINGW% MSYS% CYGWIN% Windows%,$(UNAME_S)))
  OS_DEFINE= -DFREEARC_WIN
  LDFLAGS+= -lstdc++ $(STATIC)
  CXX?= g++
else
  OS_DEFINE= -DFREEARC_UNIX
  LDFLAGS+= -lpthread -lstdc++ $(STATIC)
  # `which c++` fails on MinGW; fall back to g++ if missing.
  CXX_CANDIDATE!=which c++ 2>/dev/null || which g++ 2>/dev/null || which clang++ 2>/dev/null || echo g++
  CXX?= $(CXX_CANDIDATE)
endif

OPTIMISATION+= -O3 -mtune=generic -funroll-all-loops -msse2
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
CDEPS= Compression/LZMA2/C/ThreadsUnix.c Compression/LZMA2/C/Threads.c Compression/_Encryption/ciphers/aes/aes.c Compression/_Encryption/ciphers/aes/aes_tab.c Compression/_Encryption/hashes/siphash/siphash.c Compression/_Encryption/hashes/sha1.c Compression/_Encryption/hashes/vmac/vmac.c Compression/_Encryption/hashes/sha2/sha512.c Compression/_Encryption/hashes/md5.c Compression/_Encryption/crypt/crypt_argchk.c Compression/_Encryption/prngs/fortuna.c Compression/_Encryption/misc/zeromem.c 
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

install: all
	mkdir -p -v "$(PREFIX)"/bin/
	install -p -m 0755 -v bin/osrep "$(PREFIX)"/bin/
