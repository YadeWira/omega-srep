// Copyright (C) 2009-2014 Bulat Ziganshin. All rights reserved.
// Mail Bulat.Ziganshin@gmail.com if you have any questions or want to buy a commercial license for the source code.

// //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Error handling ***********************************************************************************************************************************
// //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Exit on error
void error (int ExitCode, char *ErrmsgFormat...)
{
  va_list argp;
  va_start(argp, ErrmsgFormat);
  fprintf  (stderr, "\n  ERROR! ");
  vfprintf (stderr, ErrmsgFormat, argp);
  fprintf  (stderr, "\n");
  va_end(argp);

  exit(ExitCode);
}

#define checked_file_read(f, buf, size)                                           \
{                                                                                 \
  if (file_read(f, (buf), (size)) != (size))                                      \
  {                                                                               \
    fprintf (stderr, "\n  ERROR! Can't read from input file");                    \
    errcode = ERROR_IO;                                                           \
    goto cleanup;                                                                 \
  }                                                                               \
}                                                                                 \

#define checked_file_write(f, buf, size)                                          \
{                                                                                 \
  if (file_write(f, (buf), (size)) != (size))                                     \
  {                                                                               \
    fprintf (stderr, "\n  ERROR! Can't write to output file (disk full?)");       \
    errcode = ERROR_IO;                                                           \
    goto cleanup;                                                                 \
  }                                                                               \
}                                                                                 \



// //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Stripe-parallel prepare_buffer (task F3.3d) *********************************************************************************************************
// //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Chunk-index granularity of one stripe job. Similar order of magnitude to compress_cdc.cpp's CDC
// STRIPE (116*kb): large enough that per-job thread hand-off cost (queue push/pop + Event wait) is
// amortized against real per-chunk work, small enough to spread work over many worker threads.
const int PREPARE_BUFFER_STRIPE = 128*kb;

// Job: run HashTable::prepare_buffer_stripe() (digest precompute + SliceHash, hash_table.cpp) over
// one disjoint chunk sub-range of the block the BG thread just read. `digest` points at this job's
// worker slot's own persistent VDigest -- see HashTable::MainDigest/PrepDigest comment (hash_table.cpp):
// VDigest/VHash carry internal state mutated by hashing, so >1 thread must never share one instance.
struct PrepBufJob
{
  HashTable *h;
  VDigest   *digest;
  char      *p;
  Chunk      chunk_start, chunk_end;

  void process()  {h->prepare_buffer_stripe (p, chunk_start, chunk_end, *digest);}
};



// //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Background thread ***********************************************************************************************************************************
// //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

struct BG_COMPRESSION_THREAD : BackgroundThread
{
  static const int BUFFERS = 2;
  unsigned k;
  char *dict;
  STAT *aux_statbuf;
  TIndex *hashtable[BUFFERS];    // Place for saving info about maximum hashes and their indexes
  char *bufptr[BUFFERS];
  char *buf[BUFFERS];
  STAT *statbuf[BUFFERS];
  STAT *stat_end[BUFFERS];
  STAT *header[BUFFERS];
  unsigned len[BUFFERS];
  unsigned stat_size[BUFFERS];
  unsigned outsize[BUFFERS];

  volatile int errcode;
  bool ROUND_MATCHES, COMPARE_DIGESTS, no_writes;
  hash_func_t hash_func;
  void *hash_obj;
  unsigned BASE_LEN, bufsize, header_size;
  Offset filesize;
  Offset dictsize;
  Offset memreqs;
  HashTable& h;
  DictionaryCompressor &inmem;
  MMAP_FILE &infile;
  FILE *fin, *fout, *fstat;
  Event ReadDone, WriteReady, BgThreadFinished;

  int PrepThreadsCount;                          // task F3.3d: worker threads striping prepare_buffer; <=1 means "run inline, no pool"
  bool PrepPoolActive;                           // true iff a pool was actually created below (PrepThreadsCount>1 AND this mode's prepare_buffer does real work)
  VDigest *PrepDigests;                          // one persistent VDigest per stripe worker slot (own VMAC state)
  MultipleProcessingThreads<PrepBufJob> PrepThreads;


  BG_COMPRESSION_THREAD (bool _ROUND_MATCHES, bool _COMPARE_DIGESTS, unsigned _BASE_LEN, unsigned dict_min_match, bool _no_writes, hash_func_t _hash_func, void* _hash_obj, Offset _filesize, Offset inmem_dictsize, unsigned _bufsize, unsigned _header_size, HashTable& _h, DictionaryCompressor& _inmem, MMAP_FILE& _infile, FILE* _fin, FILE* _fout, FILE* _fstat, LPType LargePageMode, int NumThreads)
    : errcode(NO_ERRORS), k(0), ROUND_MATCHES(_ROUND_MATCHES), COMPARE_DIGESTS(_COMPARE_DIGESTS), BASE_LEN(_BASE_LEN), no_writes(_no_writes), hash_func(_hash_func), hash_obj(_hash_obj), filesize(_filesize), bufsize(_bufsize), header_size(_header_size), h (_h), inmem(_inmem), infile(_infile), fin(_fin), fout(_fout), fstat(_fstat), PrepThreadsCount(mymax(1,NumThreads)), PrepPoolActive(false), PrepDigests(NULL)
  {
    dictsize = roundUp(inmem_dictsize,bufsize) + BUFFERS*bufsize;   // Dictionary size should be divisible by bufsize and has additional BUFFERS*bufsize space reserved for background I/O
    dict = (char*) BigAlloc (dictsize, LargePageMode);

    size_t aux_statbuf_size  =  sizeof(STAT) * (inmem_dictsize==0?  STATS_PER_MATCH(ROUND_MATCHES) : MAX_STATS_PER_BLOCK(bufsize,dict_min_match)+10);
    aux_statbuf = (STAT *) malloc(aux_statbuf_size);   // We need to store only one "fence" match if there is no in-memory compression involved

    size_t hashtable_size =  (inmem_dictsize==0?  1 : sizeof(TIndex) * (bufsize/inmem.L + INMEM_PREFETCH) * 2);   // For every L bytes in the buffer, we need 2 hash table elements
    size_t statbuf_size   =  sizeof(STAT) * (MAX_STATS_PER_BLOCK(bufsize,BASE_LEN) + 10);

    for (int i=0; i<BUFFERS; i++)
    {
      hashtable[i] = (TIndex*) malloc(hashtable_size);
      statbuf  [i] = (STAT*)   malloc(statbuf_size);
      header   [i] = (STAT*)   calloc(header_size,1);
      if (!dict || !aux_statbuf || !hashtable[i] || !statbuf[i] || !header[i])
        {errcode=ERROR_MEMORY; return;}
    }

    memreqs = dictsize + aux_statbuf_size + BUFFERS*(hashtable_size + statbuf_size + header_size);

    // Task F3.3d: stripe HashTable::prepare_buffer's two independent, disjoint-index loops (digest
    // precompute + SliceHash, hash_table.cpp) across PrepThreadsCount worker threads. Each worker slot
    // gets its own VDigest, cloned from h.MainDigest (already .init()-ed by HashTable's constructor,
    // which ran before this one) so every clone shares the same VMAC key -- required for the digests
    // computed here to match what match_len()/find_match() compute later, on the main thread, from
    // MainDigest itself (same comment/rationale as MainDigest/PrepDigest in hash_table.cpp). Skipped
    // entirely when there's only one thread to use (default -t1 or a single-core host), OR when this
    // mode's prepare_buffer is a no-op to begin with (e.g. -m0/-m1/-m2/-m4: PRECOMPUTE_DIGESTS is false
    // and slicehash.h is NULL) -- otherwise every single invocation, regardless of method, would pay a
    // fixed thread-pool create/destroy cost for a pool it never uses. prepare_buffer() then just runs
    // inline on the BG thread exactly as before, with no added overhead of any kind.
    PrepPoolActive = (PrepThreadsCount > 1) && (h.PRECOMPUTE_DIGESTS || h.slicehash.h != NULL);
    if (PrepPoolActive)
    {
      PrepDigests = new VDigest[PrepThreadsCount];
      for (int i=0; i<PrepThreadsCount; i++)  PrepDigests[i] = h.MainDigest;
      PrepThreads.MaxJobs = PrepThreadsCount;  PrepThreads.NumThreads = PrepThreadsCount;
      if (!PrepDigests || PrepThreads.start()!=0)  {errcode=ERROR_MEMORY; return;}
    }
  }

  Offset memreq()  {return memreqs;}

  void wait()
  {
    BgThreadFinished.Wait();
    if (PrepPoolActive)
    {
      PrepThreads.finish();
      delete[] PrepDigests;
    }
    for (int i=BUFFERS; --i>=0; )
    {
      free(header[i]);
      free(statbuf[i]);
      free(hashtable[i]);
    }
    free(aux_statbuf);
    BigFree(dict);
  }

  // Task F3.3d: run HashTable::prepare_buffer() striped across PrepThreads.NumThreads worker threads
  // instead of inline on the BG thread. Splits the block's chunk range into disjoint PREPARE_BUFFER_STRIPE
  // -sized sub-ranges and hands each to a worker via PrepThreads; the loop below never has more than
  // PrepThreads.NumThreads jobs in flight (mirroring compress_cdc.cpp's compress_CDC credit/window
  // pattern), so no two concurrently-running jobs ever share the same PrepDigests[] slot. The final
  // PrepThreads.Get() drains the very last outstanding job before this function returns, i.e. before
  // io.cpp's run() reaches ReadDone.Signal() -- a hard barrier, so the main thread can never observe a
  // partially-filled digestarr[]/slicehash.h[].
  void prepare_buffer_striped (Offset offset, char *buf, int size)
  {
    // No pool: either PrepThreadsCount<=1 (default -t1 / single-core host), or this mode's
    // prepare_buffer is a no-op to begin with (e.g. -m4, see PrepPoolActive above) -- either way,
    // identical to the pre-F3.3d code path (a no-op call costs nothing: both of prepare_buffer's
    // loops are already gated on the same PRECOMPUTE_DIGESTS/slicehash.h checks).
    if (!PrepPoolActive)  {h.prepare_buffer (offset, buf, size);  return;}

    size_t L = h.L;
    Chunk chunk0            = Chunk(offset/L);
    Chunk nchunks           = Chunk(size/L);
    Chunk chunks_per_stripe = Chunk(mymax (size_t(1), size_t(PREPARE_BUFFER_STRIPE)/L));

    Chunk pos = 0;
    int free_jobs = PrepThreads.NumThreads, num_thread = 0, in_flight = 0;
    for (;;)
    {
      while (free_jobs>0 && pos<nchunks)
      {
        Chunk stripe = mymin (chunks_per_stripe, Chunk(nchunks-pos));
        PrepBufJob job = {&h, &PrepDigests[num_thread], buf + size_t(pos)*L, chunk0+pos, chunk0+pos+stripe};
        PrepThreads.Put (job);
        pos += stripe;  free_jobs--;  in_flight++;  num_thread = (num_thread+1) % PrepThreads.NumThreads;
      }
      if (in_flight==0)  break;             // every stripe has been pushed and retrieved: barrier complete
      PrepThreads.Get();                     // block until the oldest outstanding stripe's worker signals completion
      free_jobs++;  in_flight--;
    }
  }

  int read (char **_buf, STAT **_statbuf, STAT **_header, TIndex **_hashtable)
  {
    ReadDone.Wait();
    k = (k+1)%BUFFERS;
    *_buf     = bufptr[k];
    *_statbuf = statbuf[k];
    *_header  = header[k];
    *_hashtable = hashtable[k];
    return len[k];
  }

  void write (unsigned _stat_size, STAT *_statend, unsigned _outsize)
  {
    stat_size[k] = _stat_size;
    stat_end[k]  = _statend;
    outsize[k]   = _outsize;
    WriteReady.Signal();
  }


private:   // Background thread code
  void run()
  {
    Offset pos = 0;  TIndex buf_offset = 0;
    for(int i=1, first_block=1;  ;  buf_offset=(buf_offset+bufsize)%dictsize, i=(i+1)%BUFFERS, first_block=0)    // i = 1 0 1 0 1...  first_block = 1 0 0 0...
    {
      // 1. Read input data
      buf[i] = dict + buf_offset;
      len[i] = infile.read (&bufptr[i], buf[i], pos, bufsize, fin);       // mmap
      if (!COMPARE_DIGESTS  &&  infile.mmapped()) {
        len[i] = file_read (fin, buf[i], bufsize);  bufptr[i] = buf[i];   // file_read
      }
      if (filesize-pos < len[i])  {fprintf (stderr, "\n  ERROR! Input file is larger than filesize specified"); errcode=ERROR_IO; ReadDone.Signal(); break;}  // Ensure that we don't read more than `filesize` bytes

      // 2. Perform b/g processing of input data
      if (hash_func)                                                      // Save checksum of every input block for error-checking during decompression
        hash_func (hash_obj, bufptr[i],len[i], header[i]+3);
      prepare_buffer_striped (pos, bufptr[i], len[i]);                    // task F3.3d: striped across worker threads when PrepThreadsCount>1; barrier completes before ReadDone.Signal() below
      inmem.prepare_buffer (hashtable[i], bufptr[i], len[i]);

      // 3. Wait for output data from prev. block and write them
      if (!first_block)
        WriteReady.Wait();                          // Wait for output data from prev. block
      ReadDone.Signal();                            // Allow to use input data
      if (!first_block && !no_writes)
        {if (!save_data((i-1+BUFFERS)%BUFFERS))  goto cleanup;}

      // 4. Stop thread on EOF
      if (len[i]==0) break;
      pos += len[i];
    }
cleanup:
    BgThreadFinished.Signal();
  }

  // Write compressed block, returning TRUE on success
  bool save_data (int k)
  {
    char *in   = bufptr [k],  *inend   = bufptr [k] + len[k];
    STAT *stat = statbuf[k],  *statend = stat_end[k];

    checked_file_write (fout,  header [k], header_size);
    checked_file_write (fstat, statbuf[k], stat_size[k]);

    while (statend-stat >= STATS_PER_MATCH(ROUND_MATCHES))
    {
      // Like in original LZ77, LZ matches and literals are strictly interleaved
      DECODE_LZ_MATCH(stat, false, ROUND_MATCHES, BASE_LEN, 0,  lit_len, LZ_MATCH, lz_match);
      if (lit_len > inend-in)  return false;   // Bad compressed data

      // Save literal data
      checked_file_write (fout, in, lit_len);
      in += lit_len+lz_match.len;
    }

    // Copy literal data up to the block end
    checked_file_write (fout, in, inend-in);
    return true;

cleanup:
    return false;
  }
};
