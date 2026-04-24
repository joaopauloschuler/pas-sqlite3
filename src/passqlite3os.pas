{$I passqlite3.inc}
unit passqlite3os;

{
  Port of SQLite 3.53.0 OS abstraction layer to Free Pascal (x86_64 Linux).

  Source files ported (upstream commit in ../sqlite3/):
    os.c            -- VFS dispatcher + wrapper helpers
    os_unix.c       -- POSIX VFS backend (posix advisory locking only;
                       flock/AFP/dot-file/proxy variants out of scope for Phase 1)
    mutex.c         -- mutex dispatch layer
    mutex_unix.c    -- pthread recursive-mutex implementation
    mutex_noop.c    -- no-op mutex for SQLITE_THREADSAFE=0 builds
    threads.c       -- thread-ID wrapper
  Headers mirrored: os.h, os_common.h, mutex.h

  Porting conventions:
    C struct        -> Pascal record (field order preserved bit-for-bit)
    C function ptr  -> Pascal procedural type (calling convention: default cdecl
                       not applied here; these are internal Pascal calls)
    void *          -> Pointer
    char *          -> PChar
    C malloc/free   -> called via external cdecl (task 1.5: use malloc directly
                       so that sqlite3_memory_used() accounting is correct once
                       Phase 2 malloc.c is ported).

  SQLITE_MAX_MMAP_SIZE is treated as 0 for Phase 1 (no mmap paths ported).
  SQLITE_ENABLE_LOCKING_STYLE is 0 (Linux default).
  SQLITE_THREADSAFE = 1 (serialised; SQLITE_MUTEX_PTHREADS).

  Phase 1.5 decision: allocator = direct C malloc/calloc/free via cdecl external,
  so that sqlite3_memory_used() counters match the C reference.  Replace with
  passqlite3util.sqlite3Malloc once Phase 2 is complete.
}

interface

uses
  passqlite3types,
  passqlite3internal,
  BaseUnix,          { FpOpen, FpClose, FpRead, FpWrite, FpFStat,
                       FpFcntl, FpPRead, FpPWrite, FpFtruncate, FpFsync,
                       FpUnlink, FpRename, FpStat, FpAccess ... }
  UnixType,          { cint, csize_t, ssize_t, stat, FLock, dev_t, ... }
  pthreads,          { pthread_mutex_t, pthread_mutexattr_t, pthread_t, ... }
  SysUtils;          { StrPCopy, etc. }

{ ============================================================
  Section 0: C allocator shim (Phase 1.5 decision)
  ============================================================ }

{ Direct calls to libc malloc/calloc/free avoid going through FPC's heap
  so that sqlite3_memory_used() counters (Phase 2) stay accurate.        }
function  sqlite3_malloc(n: i32): Pointer; external 'c' name 'malloc';
function  sqlite3_malloc64(n: u64): Pointer; external 'c' name 'malloc';
function  sqlite3_realloc(p: Pointer; n: i32): Pointer; external 'c' name 'realloc';
function  sqlite3_realloc64(p: Pointer; n: u64): Pointer; external 'c' name 'realloc';
procedure sqlite3_free(p: Pointer); external 'c' name 'free';
function  libc_calloc(nmemb, size: csize_t): Pointer; external 'c' name 'calloc';

function  sqlite3MallocZero(n: csize_t): Pointer;
function  sqlite3StrDup(z: PChar): PChar;

{ ============================================================
  Section 1: fcntl / flock constants not exposed by FPC's BaseUnix
  Values are for Linux x86_64 (same as glibc <fcntl.h>).
  ============================================================ }
const
  { l_type values for struct flock }
  F_RDLCK  = 0;    { shared / read lock   }
  F_WRLCK  = 1;    { exclusive / write lock }
  F_UNLCK  = 2;    { unlock               }
  { fcntl cmd values }
  F_GETLK  = 5;
  F_SETLK  = 6;
  F_SETLKW = 7;

  { Additional open() flags (glibc values for x86_64) }
  O_LARGEFILE_FLAG = 0;           { merged into O_RDWR on 64-bit; keep 0 }
  O_NOFOLLOW_FLAG  = $00020000;   { 131072 -- do not follow symlinks       }
  O_CLOEXEC_FLAG   = $00080000;   { 524288 -- close-on-exec               }
  O_SYNC_FLAG      = $00101000;   { O_SYNC for Linux                      }
  O_DSYNC_FLAG     = $00001000;   { O_DSYNC for Linux                     }

  { Default file permissions }
  SQLITE_DEFAULT_FILE_PERMISSIONS = &644;   { 0644 octal }
  MAX_PATHNAME = 512;
  SQLITE_MAX_SYMLINKS = 100;
  SQLITE_DEFAULT_SECTOR_SIZE = 4096;

{ ============================================================
  Section 2: Lock-byte ranges  (from os.h)
  These are the on-disk byte positions SQLite uses for advisory locks.
  PENDING_BYTE must match the C build exactly or .db files are incompatible.
  ============================================================ }
const
  PENDING_BYTE  : u32 = $40000000;       { first byte past 1 GB }
  RESERVED_BYTE : u32 = $40000001;       { PENDING_BYTE + 1      }
  SHARED_FIRST  : u32 = $40000002;       { PENDING_BYTE + 2      }
  SHARED_SIZE   : u32 = 510;

{ ============================================================
  Section 3: File lock level constants  (from os.h / sqlite3.h)
  ============================================================ }
const
  NO_LOCK        = 0;
  SHARED_LOCK    = 1;
  RESERVED_LOCK  = 2;
  PENDING_LOCK   = 3;
  EXCLUSIVE_LOCK = 4;

{ SQLITE_LOCK_* public aliases (sqlite3.h) }
const
  SQLITE_LOCK_NONE      = 0;
  SQLITE_LOCK_SHARED    = 1;
  SQLITE_LOCK_RESERVED  = 2;
  SQLITE_LOCK_PENDING   = 3;
  SQLITE_LOCK_EXCLUSIVE = 4;

{ ============================================================
  Section 4: Sync flags  (sqlite3.h)
  ============================================================ }
const
  SQLITE_SYNC_NORMAL   = $00002;
  SQLITE_SYNC_FULL     = $00003;
  SQLITE_SYNC_DATAONLY = $00010;

{ ============================================================
  Section 5: Device-characteristics / IOCAP flags  (sqlite3.h)
  ============================================================ }
const
  SQLITE_IOCAP_ATOMIC                 = $00000001;
  SQLITE_IOCAP_ATOMIC512              = $00000002;
  SQLITE_IOCAP_ATOMIC1K               = $00000004;
  SQLITE_IOCAP_ATOMIC2K               = $00000008;
  SQLITE_IOCAP_ATOMIC4K               = $00000010;
  SQLITE_IOCAP_ATOMIC8K               = $00000020;
  SQLITE_IOCAP_ATOMIC16K              = $00000040;
  SQLITE_IOCAP_ATOMIC32K              = $00000080;
  SQLITE_IOCAP_ATOMIC64K              = $00000100;
  SQLITE_IOCAP_SAFE_APPEND            = $00000200;
  SQLITE_IOCAP_SEQUENTIAL             = $00000400;
  SQLITE_IOCAP_UNDELETABLE_WHEN_OPEN  = $00000800;
  SQLITE_IOCAP_POWERSAFE_OVERWRITE    = $00001000;
  SQLITE_IOCAP_IMMUTABLE              = $00002000;
  SQLITE_IOCAP_BATCH_ATOMIC           = $00004000;
  SQLITE_IOCAP_SUBPAGE_READ           = $00008000;

{ ============================================================
  Section 6: File-control opcodes  (sqlite3.h, SQLITE_FCNTL_*)
  ============================================================ }
const
  SQLITE_FCNTL_LOCKSTATE              = 1;
  SQLITE_FCNTL_GET_LOCKPROXYFILE      = 2;
  SQLITE_FCNTL_SET_LOCKPROXYFILE      = 3;
  SQLITE_FCNTL_LAST_ERRNO             = 4;
  SQLITE_FCNTL_SIZE_HINT              = 5;
  SQLITE_FCNTL_CHUNK_SIZE             = 6;
  SQLITE_FCNTL_FILE_POINTER           = 7;
  SQLITE_FCNTL_SYNC_OMITTED           = 8;
  SQLITE_FCNTL_WIN32_AV_RETRY         = 9;
  SQLITE_FCNTL_PERSIST_WAL            = 10;
  SQLITE_FCNTL_OVERWRITE              = 11;
  SQLITE_FCNTL_VFSNAME                = 12;
  SQLITE_FCNTL_POWERSAFE_OVERWRITE    = 13;
  SQLITE_FCNTL_PRAGMA                 = 14;
  SQLITE_FCNTL_BUSYHANDLER            = 15;
  SQLITE_FCNTL_TEMPFILENAME           = 16;
  SQLITE_FCNTL_MMAP_SIZE              = 18;
  SQLITE_FCNTL_TRACE                  = 19;
  SQLITE_FCNTL_HAS_MOVED              = 20;
  SQLITE_FCNTL_SYNC                   = 21;
  SQLITE_FCNTL_COMMIT_PHASETWO        = 22;
  SQLITE_FCNTL_WIN32_SET_HANDLE       = 23;
  SQLITE_FCNTL_WAL_BLOCK              = 24;
  SQLITE_FCNTL_ZIPVFS                 = 25;
  SQLITE_FCNTL_RBU                    = 26;
  SQLITE_FCNTL_VFS_POINTER            = 27;
  SQLITE_FCNTL_JOURNAL_POINTER        = 28;
  SQLITE_FCNTL_WIN32_GET_HANDLE       = 29;
  SQLITE_FCNTL_PDB                    = 30;
  SQLITE_FCNTL_BEGIN_ATOMIC_WRITE     = 31;
  SQLITE_FCNTL_COMMIT_ATOMIC_WRITE    = 32;
  SQLITE_FCNTL_ROLLBACK_ATOMIC_WRITE  = 33;
  SQLITE_FCNTL_LOCK_TIMEOUT           = 34;
  SQLITE_FCNTL_DATA_VERSION           = 35;
  SQLITE_FCNTL_SIZE_LIMIT             = 36;
  SQLITE_FCNTL_CKPT_DONE              = 37;
  SQLITE_FCNTL_RESERVE_BYTES          = 38;
  SQLITE_FCNTL_CKPT_START             = 39;
  SQLITE_FCNTL_EXTERNAL_READER        = 40;
  SQLITE_FCNTL_CKSM_FILE              = 41;
  SQLITE_FCNTL_RESET_CACHE            = 42;
  SQLITE_FCNTL_NULL_IO                = 43;
  SQLITE_FCNTL_BLOCK_ON_CONNECT       = 44;
  SQLITE_FCNTL_FILESTAT               = 45;

{ VFS access() flags }
const
  SQLITE_ACCESS_EXISTS    = 0;
  SQLITE_ACCESS_READWRITE = 1;
  SQLITE_ACCESS_READ      = 2;

{ Shared-memory lock flags }
const
  SQLITE_SHM_UNLOCK   = 1;
  SQLITE_SHM_LOCK     = 2;
  SQLITE_SHM_SHARED   = 4;
  SQLITE_SHM_EXCLUSIVE = 8;
  SQLITE_SHM_NLOCK    = 8;

{ ============================================================
  Section 7: Mutex type IDs  (sqlite3.h)
  ============================================================ }
const
  SQLITE_MUTEX_FAST         = 0;
  SQLITE_MUTEX_RECURSIVE    = 1;
  SQLITE_MUTEX_STATIC_MAIN  = 2;
  SQLITE_MUTEX_STATIC_MEM   = 3;
  SQLITE_MUTEX_STATIC_OPEN  = 4;
  SQLITE_MUTEX_STATIC_PRNG  = 5;
  SQLITE_MUTEX_STATIC_LRU   = 6;
  SQLITE_MUTEX_STATIC_PMEM  = 7;
  SQLITE_MUTEX_STATIC_APP1  = 8;
  SQLITE_MUTEX_STATIC_APP2  = 9;
  SQLITE_MUTEX_STATIC_APP3  = 10;
  SQLITE_MUTEX_STATIC_VFS1  = 11;
  SQLITE_MUTEX_STATIC_VFS2  = 12;
  SQLITE_MUTEX_STATIC_VFS3  = 13;

{ ============================================================
  Section 8: Public type declarations (sqlite3.h order)
  These mirror the C typedef/struct declarations exactly.
  ============================================================ }

type
  { Forward declarations }
  Psqlite3_file         = ^sqlite3_file;
  Psqlite3_io_methods   = ^sqlite3_io_methods;
  Psqlite3_vfs          = ^sqlite3_vfs;
  Psqlite3_mutex        = ^sqlite3_mutex;
  Psqlite3_mutex_methods = ^sqlite3_mutex_methods;

  { sqlite3_syscall_ptr (sqlite3.h) }
  sqlite3_syscall_ptr = procedure; cdecl;

  { sqlite3_filename: opaque alias for char* in public API }
  sqlite3_filename = PChar;

  { sqlite3_file (sqlite3.h §746)
    Subclassed by unixFile; pMethods must be the first field. }
  sqlite3_file = record
    pMethods : Psqlite3_io_methods;  { methods for an open file }
  end;

  { Procedural types for sqlite3_io_methods function pointers }
  TxClose            = function(pFile: Psqlite3_file): cint; cdecl;
  TxRead             = function(pFile: Psqlite3_file; pBuf: Pointer;
                                iAmt: cint; iOfst: i64): cint; cdecl;
  TxWrite            = function(pFile: Psqlite3_file; pBuf: Pointer;
                                iAmt: cint; iOfst: i64): cint; cdecl;
  TxTruncate         = function(pFile: Psqlite3_file; size: i64): cint; cdecl;
  TxSync             = function(pFile: Psqlite3_file; flags: cint): cint; cdecl;
  TxFileSize         = function(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
  TxLock             = function(pFile: Psqlite3_file; lockType: cint): cint; cdecl;
  TxUnlock           = function(pFile: Psqlite3_file; lockType: cint): cint; cdecl;
  TxCheckReservedLock = function(pFile: Psqlite3_file;
                                 pResOut: PcInt): cint; cdecl;
  TxFileControl      = function(pFile: Psqlite3_file; op: cint;
                                pArg: Pointer): cint; cdecl;
  TxSectorSize       = function(pFile: Psqlite3_file): cint; cdecl;
  TxDeviceCharacteristics = function(pFile: Psqlite3_file): cint; cdecl;
  TxShmMap           = function(pFile: Psqlite3_file; iPg: cint; pgsz: cint;
                                bExtend: cint; pp: PPointer): cint; cdecl;
  TxShmLock          = function(pFile: Psqlite3_file; offset: cint;
                                n: cint; flags: cint): cint; cdecl;
  TxShmBarrier       = procedure(pFile: Psqlite3_file); cdecl;
  TxShmUnmap         = function(pFile: Psqlite3_file;
                                deleteFlag: cint): cint; cdecl;
  TxFetch            = function(pFile: Psqlite3_file; iOfst: i64;
                                iAmt: cint; pp: PPointer): cint; cdecl;
  TxUnfetch          = function(pFile: Psqlite3_file; iOfst: i64;
                                p: Pointer): cint; cdecl;

  { sqlite3_io_methods (sqlite3.h §854)
    Field order matches C struct exactly — do not reorder. }
  sqlite3_io_methods = record
    iVersion             : cint;
    xClose               : TxClose;
    xRead                : TxRead;
    xWrite               : TxWrite;
    xTruncate            : TxTruncate;
    xSync                : TxSync;
    xFileSize            : TxFileSize;
    xLock                : TxLock;
    xUnlock              : TxUnlock;
    xCheckReservedLock   : TxCheckReservedLock;
    xFileControl         : TxFileControl;
    xSectorSize          : TxSectorSize;
    xDeviceCharacteristics : TxDeviceCharacteristics;
    { v2 methods }
    xShmMap              : TxShmMap;
    xShmLock             : TxShmLock;
    xShmBarrier          : TxShmBarrier;
    xShmUnmap            : TxShmUnmap;
    { v3 methods }
    xFetch               : TxFetch;
    xUnfetch             : TxUnfetch;
  end;

  { Procedural types for sqlite3_vfs function pointers }
  TvxOpen = function(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                     pFile: Psqlite3_file; flags: cint;
                     pOutFlags: PcInt): cint; cdecl;
  TvxDelete = function(pVfs: Psqlite3_vfs; zName: PChar;
                       syncDir: cint): cint; cdecl;
  TvxAccess = function(pVfs: Psqlite3_vfs; zName: PChar;
                       flags: cint; pResOut: PcInt): cint; cdecl;
  TvxFullPathname = function(pVfs: Psqlite3_vfs; zName: PChar;
                             nOut: cint; zOut: PChar): cint; cdecl;
  TvxDlOpen  = function(pVfs: Psqlite3_vfs; zFilename: PChar): Pointer; cdecl;
  TvxDlError = procedure(pVfs: Psqlite3_vfs; nByte: cint;
                         zErrMsg: PChar); cdecl;
  TvxDlSym   = function(pVfs: Psqlite3_vfs; p: Pointer;
                        zSymbol: PChar): sqlite3_syscall_ptr; cdecl;
  TvxDlClose = procedure(pVfs: Psqlite3_vfs; p: Pointer); cdecl;
  TvxRandomness = function(pVfs: Psqlite3_vfs; nByte: cint;
                           zOut: PChar): cint; cdecl;
  TvxSleep      = function(pVfs: Psqlite3_vfs;
                           microseconds: cint): cint; cdecl;
  TvxCurrentTime = function(pVfs: Psqlite3_vfs; pTime: PDouble): cint; cdecl;
  TvxGetLastError = function(pVfs: Psqlite3_vfs; n: cint;
                             zBuf: PChar): cint; cdecl;
  TvxCurrentTimeInt64 = function(pVfs: Psqlite3_vfs;
                                 pTime: Pi64): cint; cdecl;
  TvxSetSystemCall = function(pVfs: Psqlite3_vfs; zName: PChar;
                              pNewFunc: sqlite3_syscall_ptr): cint; cdecl;
  TvxGetSystemCall = function(pVfs: Psqlite3_vfs;
                              zName: PChar): sqlite3_syscall_ptr; cdecl;
  TvxNextSystemCall = function(pVfs: Psqlite3_vfs;
                               zName: PChar): PChar; cdecl;

  { sqlite3_vfs (sqlite3.h §1513)
    Field order matches C struct exactly — do not reorder. }
  sqlite3_vfs = record
    iVersion        : cint;
    szOsFile        : cint;
    mxPathname      : cint;
    pNext           : Psqlite3_vfs;
    zName           : PChar;
    pAppData        : Pointer;
    xOpen           : TvxOpen;
    xDelete         : TvxDelete;
    xAccess         : TvxAccess;
    xFullPathname   : TvxFullPathname;
    xDlOpen         : TvxDlOpen;
    xDlError        : TvxDlError;
    xDlSym          : TvxDlSym;
    xDlClose        : TvxDlClose;
    xRandomness     : TvxRandomness;
    xSleep          : TvxSleep;
    xCurrentTime    : TvxCurrentTime;
    xGetLastError   : TvxGetLastError;
    { v2 }
    xCurrentTimeInt64 : TvxCurrentTimeInt64;
    { v3 }
    xSetSystemCall  : TvxSetSystemCall;
    xGetSystemCall  : TvxGetSystemCall;
    xNextSystemCall : TvxNextSystemCall;
  end;

{ ============================================================
  Section 9: sqlite3_mutex (mutex_unix.c §struct sqlite3_mutex)
  pthread-based recursive mutex.  Field order matches C struct.
  (Continues the same type block to resolve Psqlite3_mutex/Psqlite3_mutex_methods
  forward pointer declarations from Section 8.)
  ============================================================ }

  { sqlite3_mutex — the public opaque type is backed by this concrete record. }
  sqlite3_mutex = record
    mutex : pthread_mutex_t;  { pthread mutex handle          }
    id    : cint;             { SQLITE_MUTEX_* type id        }
    nRef  : cint;             { recursion depth (debug/NREF)  }
    owner : pthread_t;        { owning thread (debug/NREF)    }
  end;

  { sqlite3_mutex_methods (sqlite3.h §8524) }
  sqlite3_mutex_methods = record
    xMutexInit    : function: cint;
    xMutexEnd     : function: cint;
    xMutexAlloc   : function(iType: cint): Psqlite3_mutex;
    xMutexFree    : procedure(p: Psqlite3_mutex);
    xMutexEnter   : procedure(p: Psqlite3_mutex);
    xMutexTry     : function(p: Psqlite3_mutex): cint;
    xMutexLeave   : procedure(p: Psqlite3_mutex);
    xMutexHeld    : function(p: Psqlite3_mutex): cint;
    xMutexNotheld : function(p: Psqlite3_mutex): cint;
  end;

{ ============================================================
  Section 10: Internal unix VFS types (os_unix.c)
  ============================================================ }
type
  PUnixUnusedFd   = ^UnixUnusedFd;
  PunixInodeInfo  = ^unixInodeInfo;
  PunixShmNode    = ^unixShmNode;
  PunixShm        = ^unixShm;
  PunixFile       = ^unixFile;
  PPPointer       = ^PPointer;   { pointer-to-pointer-to-pointer helper }

  { UnixUnusedFd (os_unix.c §247) — deferred-close file descriptor }
  UnixUnusedFd = record
    fd    : cint;           { file descriptor to close }
    flags : cint;           { flags this fd was opened with }
    pNext : PUnixUnusedFd;  { next in list }
  end;

  { unixFileId (os_unix.c §1282) — inode lookup key }
  unixFileId = record
    dev : dev_t;   { device number }
    ino : u64;     { inode number (always 64-bit even on 32-bit systems) }
  end;

  { unixInodeInfo (os_unix.c §1323)
    One per open inode.  Protected by unixBigLock + pLockMutex.  }
  unixInodeInfo = record
    fileId       : unixFileId;      { lookup key                           }
    pLockMutex   : Psqlite3_mutex;  { protects lock fields below           }
    nShared      : cint;            { number of SHARED locks held          }
    nLock        : cint;            { number of outstanding file locks     }
    eFileLock    : u8;              { one of *_LOCK constants              }
    bProcessLock : u8;              { exclusive process lock held          }
    pUnused      : PUnixUnusedFd;   { unused file descriptors to close     }
    nRef         : cint;            { number of pointers to this structure }
    pShmNode     : PunixShmNode;    { shared memory associated with inode  }
    pNext        : PunixInodeInfo;  { doubly-linked list of all inodes     }
    pPrev        : PunixInodeInfo;
  end;

  { unixShmNode (os_unix.c §4556) — shared-memory node }
  unixShmNode = record
    pInode      : PunixInodeInfo;
    pShmMutex   : Psqlite3_mutex;
    zFilename   : PChar;
    hShm        : cint;
    szRegion    : cint;
    nRegion     : u16;
    isReadonly  : u8;
    isUnlocked  : u8;
    apRegion    : PPointer;
    nRef        : cint;
    pFirst      : PunixShm;
    aLock       : array[0..SQLITE_SHM_NLOCK-1] of cint;
  end;

  { unixShm (os_unix.c §4590) — per-connection SHM state }
  unixShm = record
    pShmNode   : PunixShmNode;
    pNext      : PunixShm;
    hasMutex   : u8;
    id         : u8;
    sharedMask : u16;
    exclMask   : u16;
  end;

  { unixFile (os_unix.c §257)
    Subclass of sqlite3_file for the unix VFS.
    pMethod MUST remain the first field (C ABI: first field = base struct). }
  unixFile = record
    pMethod              : Psqlite3_io_methods; { always first (= sqlite3_file.pMethods) }
    pVfs                 : Psqlite3_vfs;
    pInode               : PunixInodeInfo;
    h                    : cint;               { file descriptor                }
    eFileLock            : u8;                 { lock level held on this fd     }
    ctrlFlags            : u16;                { UNIXFILE_* behavioural flags   }
    lastErrno            : cint;               { last unix errno on I/O error   }
    lockingContext       : Pointer;            { locking-style specific data    }
    pPreallocatedUnused  : PUnixUnusedFd;      { pre-allocated UnixUnusedFd     }
    zPath                : PChar;              { name of the file               }
    pShm                 : PunixShm;           { shared-memory state            }
    szChunk              : cint;               { FCNTL_CHUNK_SIZE value         }
    sectorSize           : cint;               { device sector size             }
    deviceCharacteristics : cint;              { precomputed dev. characteristics }
  end;

{ unixFile.ctrlFlags bit positions }
const
  UNIXFILE_EXCL        = $01;   { connections from one process only }
  UNIXFILE_RDONLY      = $02;   { connection is read only           }
  UNIXFILE_PERSIST_WAL = $04;   { persistent WAL mode               }
  UNIXFILE_DIRSYNC     = $08;   { directory sync needed             }
  UNIXFILE_PSOW        = $10;   { IOCAP_POWERSAFE_OVERWRITE         }
  UNIXFILE_DELETE      = $20;   { delete on close                   }
  UNIXFILE_URI         = $40;   { filename may have query params    }
  UNIXFILE_NOLOCK      = $80;   { no file locking                   }
  SQLITE_FSFLAGS_IS_MSDOS = $1;

{ ============================================================
  Section 11: Mutex public API  (mutex.c / sqlite3.h)
  ============================================================ }

function  sqlite3_mutex_alloc(id: cint): Psqlite3_mutex;
procedure sqlite3_mutex_free(p: Psqlite3_mutex);
procedure sqlite3_mutex_enter(p: Psqlite3_mutex);
function  sqlite3_mutex_try(p: Psqlite3_mutex): cint;
procedure sqlite3_mutex_leave(p: Psqlite3_mutex);
function  sqlite3_mutex_held(p: Psqlite3_mutex): cint;
function  sqlite3_mutex_notheld(p: Psqlite3_mutex): cint;

{ Internal mutex helpers }
function  sqlite3MutexAlloc(id: cint): Psqlite3_mutex;
function  sqlite3MutexInit: cint;
function  sqlite3MutexEnd: cint;
procedure sqlite3MemoryBarrier;

{ Default mutex implementation (pthread) }
function  sqlite3DefaultMutex: Psqlite3_mutex_methods;

{ ============================================================
  Section 12: OS layer wrappers  (os.c)
  ============================================================ }

procedure sqlite3OsClose(pId: Psqlite3_file);
function  sqlite3OsRead(id: Psqlite3_file; pBuf: Pointer;
                        amt: cint; offset: i64): cint;
function  sqlite3OsWrite(id: Psqlite3_file; pBuf: Pointer;
                         amt: cint; offset: i64): cint;
function  sqlite3OsTruncate(id: Psqlite3_file; size: i64): cint;
function  sqlite3OsSync(id: Psqlite3_file; flags: cint): cint;
function  sqlite3OsFileSize(id: Psqlite3_file; pSize: Pi64): cint;
function  sqlite3OsLock(id: Psqlite3_file; lockType: cint): cint;
function  sqlite3OsUnlock(id: Psqlite3_file; lockType: cint): cint;
function  sqlite3OsCheckReservedLock(id: Psqlite3_file;
                                     pResOut: PcInt): cint;
function  sqlite3OsOpen(pVfs: Psqlite3_vfs; zPath: PChar;
                        pFile: Psqlite3_file; flags: cint;
                        pFlagsOut: PcInt): cint;
function  sqlite3OsDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                          dirSync: cint): cint;
function  sqlite3OsAccess(pVfs: Psqlite3_vfs; zPath: PChar;
                          flags: cint; pResOut: PcInt): cint;
function  sqlite3OsFullPathname(pVfs: Psqlite3_vfs; zPath: PChar;
                                nPathOut: cint; zPathOut: PChar): cint;
function  sqlite3OsInit: cint;
function  sqlite3OsSectorSize(id: Psqlite3_file): cint;
function  sqlite3OsDeviceCharacteristics(id: Psqlite3_file): cint;
function  sqlite3OsFileControl(id: Psqlite3_file; op: cint; pArg: Pointer): cint;
procedure sqlite3OsFileControlHint(id: Psqlite3_file; op: cint; pArg: Pointer);
function  sqlite3OsFetch(id: Psqlite3_file; iOff: i64; iAmt: cint; pp: PPointer): cint;
function  sqlite3OsUnfetch(id: Psqlite3_file; iOff: i64; p: Pointer): cint;
function  sqlite3OsShmMap(id: Psqlite3_file; iPg: cint; pgsz: cint;
                          bExtend: cint; pp: PPointer): cint;
function  sqlite3OsShmLock(id: Psqlite3_file; offset: cint; n: cint;
                           flags: cint): cint;
procedure sqlite3OsShmBarrier(id: Psqlite3_file);
function  sqlite3OsShmUnmap(id: Psqlite3_file; deleteFlag: cint): cint;
function  sqlite3OsSleep(pVfs: Psqlite3_vfs; nMicrosec: cint): cint;

{ ============================================================
  Section 13: VFS registration (os.c)
  ============================================================ }

function  sqlite3_vfs_find(zVfs: PChar): Psqlite3_vfs;
function  sqlite3_vfs_register(pVfs: Psqlite3_vfs; makeDflt: cint): cint;
function  sqlite3_vfs_unregister(pVfs: Psqlite3_vfs): cint;

{ sqlite3_os_init / sqlite3_os_end (os_unix.c §8680) }
function  sqlite3_os_init: cint;
function  sqlite3_os_end: cint;

{ ============================================================
  Section 14: Direct unix VFS methods (exported for testing)
  ============================================================ }
function  unixOpen(pVfs: Psqlite3_vfs; zPath: sqlite3_filename;
                   pFile: Psqlite3_file; flags: cint;
                   pOutFlags: PcInt): cint; cdecl;
function  unixDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                     dirSync: cint): cint; cdecl;
function  unixAccess(pVfs: Psqlite3_vfs; zPath: PChar;
                     flags: cint; pResOut: PcInt): cint; cdecl;
function  unixFullPathname(pVfs: Psqlite3_vfs; zPath: PChar;
                           nOut: cint; zOut: PChar): cint; cdecl;
function  unixRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                         zOut: PChar): cint; cdecl;
function  unixSleep(pVfs: Psqlite3_vfs;
                    microseconds: cint): cint; cdecl;
function  unixCurrentTime(pVfs: Psqlite3_vfs;
                          pTime: PDouble): cint; cdecl;
function  unixGetLastError(pVfs: Psqlite3_vfs; n: cint;
                           zBuf: PChar): cint; cdecl;

{ The singleton unix VFS object }
var
  unixVfsObj : sqlite3_vfs;

{ ============================================================
  Section 15: Global mutex state
  ============================================================ }
var
  { Filled by sqlite3MutexInit with the current method table }
  gMutexMethods : sqlite3_mutex_methods;



implementation

{ ============================================================
  Internal types
  ============================================================ }

type
  { struct timespec (POSIX) }
  TTimeSpec = packed record
    tv_sec  : Int64;
    tv_nsec : Int64;
  end;

  { struct timeval (POSIX) }
  TTimeVal = packed record
    tv_sec  : Int64;
    tv_usec : Int64;
  end;

{ ============================================================
  External C runtime shims
  ============================================================ }

const
  { PTHREAD_MUTEX_RECURSIVE on Linux x86_64 = 1 }
  PTHREAD_MUTEX_RECURSIVE_KIND = 1;

function c_nanosleep(req: Pointer; rem: Pointer): cint; cdecl;
  external 'c' name 'nanosleep';
function c_gettimeofday(tv: Pointer; tz: Pointer): cint; cdecl;
  external 'c' name 'gettimeofday';
function c_strerror(err: cint): PChar; cdecl;
  external 'c' name 'strerror';
function c_fsync(fd: cint): cint; cdecl;
  external 'c' name 'fsync';

{ ============================================================
  Private module-level variables
  ============================================================ }

var
  { Head of the VFS linked list (os.c: static sqlite3_vfs *vfsList) }
  vfsList : Psqlite3_vfs = nil;

  { Static mutexes for SQLITE_MUTEX_STATIC_MAIN(2) .. SQLITE_MUTEX_STATIC_VFS3(13).
    Index 0 = id 2, index 11 = id 13.
    On Linux, PTHREAD_MUTEX_INITIALIZER is all-zeros, so zero-initialised records
    are valid as un-initialised fast mutexes until pthreadMutexInit calls
    pthread_mutex_init on each one. }
  staticMutexes : array[0..11] of sqlite3_mutex;

  { Unix I/O methods vtable — filled in InitUnixIoMethods (called from
    initialization). Declared as var rather than typed-const so that the
    function-pointer fields can reference functions that appear later in this
    compilation unit. }
  unixIoMethods : sqlite3_io_methods;

  { Per-file pthreadMutexMethods table returned by sqlite3DefaultMutex }
  pthreadMutexMethodsData : sqlite3_mutex_methods;

  { Counter for generating unique temp-file names }
  tempFileSeq : cint = 0;

{ ============================================================
  Forward declarations — unix I/O vtable methods (cdecl)
  ============================================================ }

function  unixClose_impl(pFile: Psqlite3_file): cint; cdecl; forward;
function  unixRead_impl(pFile: Psqlite3_file; pBuf: Pointer;
            iAmt: cint; iOfst: i64): cint; cdecl; forward;
function  unixWrite_impl(pFile: Psqlite3_file; pBuf: Pointer;
            iAmt: cint; iOfst: i64): cint; cdecl; forward;
function  unixTruncate_impl(pFile: Psqlite3_file; size: i64): cint; cdecl; forward;
function  unixSync_impl(pFile: Psqlite3_file; flags: cint): cint; cdecl; forward;
function  unixFileSize_impl(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;
function  unixLock_impl(pFile: Psqlite3_file; eFileLock: cint): cint; cdecl; forward;
function  unixUnlock_impl(pFile: Psqlite3_file; eFileLock: cint): cint; cdecl; forward;
function  unixCheckReservedLock_impl(pFile: Psqlite3_file;
            pResOut: PcInt): cint; cdecl; forward;
function  unixFileControl_impl(pFile: Psqlite3_file; op: cint;
            pArg: Pointer): cint; cdecl; forward;
function  unixSectorSize_impl(pFile: Psqlite3_file): cint; cdecl; forward;
function  unixDeviceCharacteristics_impl(pFile: Psqlite3_file): cint; cdecl; forward;

{ ============================================================
  Section 0: Memory helpers
  ============================================================ }

{ os.c ~400: sqlite3MallocZero — wraps calloc(1, n) }
function sqlite3MallocZero(n: csize_t): Pointer;
begin
  Result := libc_calloc(1, n);
end;

{ os.c ~410: sqlite3StrDup — duplicate a C string (caller frees with sqlite3_free) }
function sqlite3StrDup(z: PChar): PChar;
var
  n : SizeInt;
  p : PChar;
begin
  if z = nil then begin
    Result := nil;
    Exit;
  end;
  n := StrLen(z) + 1;
  p := PChar(sqlite3_malloc(n));
  if p <> nil then
    Move(z^, p^, n);
  Result := p;
end;

{ ============================================================
  Section 11a: pthread-based mutex primitives (mutex_unix.c)
  ============================================================ }

{ mutex_unix.c ~130: pthreadMutexInit }
function pthreadMutexInit: cint;
var
  i   : Integer;
  attr: pthread_mutexattr_t;
begin
  { Initialise static mutexes with a fast (non-recursive) pthread mutex.
    PTHREAD_MUTEX_INITIALIZER is all-zeros on Linux; the records are already
    zero-filled, but calling pthread_mutex_init makes it official. }
  pthread_mutexattr_init(@attr);
  for i := 0 to 11 do begin
    if staticMutexes[i].id = 0 then begin
      staticMutexes[i].id := i + 2;
      pthread_mutex_init(@staticMutexes[i].mutex, @attr);
    end;
  end;
  pthread_mutexattr_destroy(@attr);
  Result := SQLITE_OK;
end;

{ mutex_unix.c ~131: pthreadMutexEnd }
function pthreadMutexEnd: cint;
begin
  Result := SQLITE_OK;
end;

{ mutex_unix.c ~117: pthreadMutexHeld — returns 1 if p is held by this thread }
function pthreadMutexHeld(p: Psqlite3_mutex): cint;
begin
  if (p^.nRef <> 0) and (pthread_equal(p^.owner, pthread_self()) <> 0) then
    Result := 1
  else
    Result := 0;
end;

{ mutex_unix.c ~121: pthreadMutexNotheld — returns 1 if p is NOT held by this thread }
function pthreadMutexNotheld(p: Psqlite3_mutex): cint;
begin
  if (p^.nRef = 0) or (pthread_equal(p^.owner, pthread_self()) = 0) then
    Result := 1
  else
    Result := 0;
end;

{ mutex_unix.c ~155: pthreadMutexAlloc }
function pthreadMutexAlloc(iType: cint): Psqlite3_mutex;
var
  p    : Psqlite3_mutex;
  attr : pthread_mutexattr_t;
begin
  case iType of
    SQLITE_MUTEX_RECURSIVE: begin
      { mutex_unix.c ~174 }
      p := Psqlite3_mutex(sqlite3MallocZero(SizeOf(sqlite3_mutex)));
      if p <> nil then begin
        pthread_mutexattr_init(@attr);
        pthread_mutexattr_settype(@attr, PTHREAD_MUTEX_RECURSIVE_KIND);
        pthread_mutex_init(@p^.mutex, @attr);
        pthread_mutexattr_destroy(@attr);
        p^.id := SQLITE_MUTEX_RECURSIVE;
      end;
    end;
    SQLITE_MUTEX_FAST: begin
      { mutex_unix.c ~185 }
      p := Psqlite3_mutex(sqlite3MallocZero(SizeOf(sqlite3_mutex)));
      if p <> nil then begin
        pthread_mutex_init(@p^.mutex, nil);
        p^.id := SQLITE_MUTEX_FAST;
      end;
    end;
    else begin
      { mutex_unix.c ~192: static mutex }
      if (iType - 2 < 0) or (iType - 2 > 11) then begin
        Result := nil;
        Exit;
      end;
      p := @staticMutexes[iType - 2];
    end;
  end;
  Result := p;
end;

{ mutex_unix.c ~214: pthreadMutexFree }
procedure pthreadMutexFree(p: Psqlite3_mutex);
begin
  { Only destroy and free dynamic mutexes; static ones persist for the process lifetime }
  if (p^.id = SQLITE_MUTEX_FAST) or (p^.id = SQLITE_MUTEX_RECURSIVE) then begin
    pthread_mutex_destroy(@p^.mutex);
    sqlite3_free(p);
  end;
end;

{ mutex_unix.c ~232: pthreadMutexEnter }
procedure pthreadMutexEnter(p: Psqlite3_mutex);
begin
  pthread_mutex_lock(@p^.mutex);
  p^.owner := pthread_self();
  Inc(p^.nRef);
end;

{ mutex_unix.c ~282: pthreadMutexTry }
function pthreadMutexTry(p: Psqlite3_mutex): cint;
begin
  if pthread_mutex_trylock(@p^.mutex) = 0 then begin
    p^.owner := pthread_self();
    Inc(p^.nRef);
    Result := SQLITE_OK;
  end else
    Result := SQLITE_BUSY;
end;

{ mutex_unix.c ~316: pthreadMutexLeave }
procedure pthreadMutexLeave(p: Psqlite3_mutex);
begin
  Dec(p^.nRef);
  if p^.nRef = 0 then
    p^.owner := pthread_t(0);
  pthread_mutex_unlock(@p^.mutex);
end;

{ mutex_unix.c ~350: sqlite3DefaultMutex — returns pointer to the pthread implementation }
function sqlite3DefaultMutex: Psqlite3_mutex_methods;
begin
  Result := @pthreadMutexMethodsData;
end;

{ ============================================================
  Section 11b: Mutex public API  (mutex.c)
  ============================================================ }

{ mutex.c ~170: sqlite3MutexInit }
function sqlite3MutexInit: cint;
var
  pFrom : Psqlite3_mutex_methods;
begin
  if not Assigned(gMutexMethods.xMutexAlloc) then begin
    pFrom := sqlite3DefaultMutex();
    gMutexMethods := pFrom^;
  end;
  Result := gMutexMethods.xMutexInit();
end;

{ mutex.c ~190: sqlite3MutexEnd }
function sqlite3MutexEnd: cint;
begin
  if Assigned(gMutexMethods.xMutexEnd) then
    Result := gMutexMethods.xMutexEnd()
  else
    Result := SQLITE_OK;
end;

{ mutex.c ~202: sqlite3_mutex_alloc (public API) }
function sqlite3_mutex_alloc(id: cint): Psqlite3_mutex;
begin
  if not Assigned(gMutexMethods.xMutexAlloc) then begin
    sqlite3MutexInit;
  end;
  Result := gMutexMethods.xMutexAlloc(id);
end;

{ mutex.c ~213: sqlite3MutexAlloc (internal) }
function sqlite3MutexAlloc(id: cint): Psqlite3_mutex;
begin
  if not Assigned(gMutexMethods.xMutexAlloc) then begin
    Result := nil;
    Exit;
  end;
  Result := gMutexMethods.xMutexAlloc(id);
end;

{ mutex.c ~222: sqlite3_mutex_free }
procedure sqlite3_mutex_free(p: Psqlite3_mutex);
begin
  if (p <> nil) and Assigned(gMutexMethods.xMutexFree) then
    gMutexMethods.xMutexFree(p);
end;

{ mutex.c ~232: sqlite3_mutex_enter }
procedure sqlite3_mutex_enter(p: Psqlite3_mutex);
begin
  if (p <> nil) and Assigned(gMutexMethods.xMutexEnter) then
    gMutexMethods.xMutexEnter(p);
end;

{ mutex.c ~242: sqlite3_mutex_try }
function sqlite3_mutex_try(p: Psqlite3_mutex): cint;
begin
  if (p <> nil) and Assigned(gMutexMethods.xMutexTry) then
    Result := gMutexMethods.xMutexTry(p)
  else
    Result := SQLITE_OK;
end;

{ mutex.c ~252: sqlite3_mutex_leave }
procedure sqlite3_mutex_leave(p: Psqlite3_mutex);
begin
  if (p <> nil) and Assigned(gMutexMethods.xMutexLeave) then
    gMutexMethods.xMutexLeave(p);
end;

{ mutex.c ~262: sqlite3_mutex_held }
function sqlite3_mutex_held(p: Psqlite3_mutex): cint;
begin
  if (p = nil) or (not Assigned(gMutexMethods.xMutexHeld)) then
    Result := 1
  else
    Result := gMutexMethods.xMutexHeld(p);
end;

{ mutex.c ~272: sqlite3_mutex_notheld }
function sqlite3_mutex_notheld(p: Psqlite3_mutex): cint;
begin
  if (p = nil) or (not Assigned(gMutexMethods.xMutexNotheld)) then
    Result := 1
  else
    Result := gMutexMethods.xMutexNotheld(p);
end;

{ mutex_unix.c ~135: sqlite3MemoryBarrier }
procedure sqlite3MemoryBarrier;
begin
  { Phase 1: best-effort barrier via compiler fence.
    Real sync_synchronize comes with Phase 2 atomics. }
  asm
    lfence
    sfence
    mfence
  end;
end;

{ ============================================================
  Section 12: OS dispatcher wrappers  (os.c)
  These are thin wrappers that call through the pMethods vtable.
  ============================================================ }

{ os.c ~79: sqlite3OsClose }
procedure sqlite3OsClose(pId: Psqlite3_file);
begin
  if pId^.pMethods <> nil then begin
    pId^.pMethods^.xClose(pId);
    pId^.pMethods := nil;
  end;
end;

{ os.c ~84: sqlite3OsRead }
function sqlite3OsRead(id: Psqlite3_file; pBuf: Pointer; amt: cint; offset: i64): cint;
begin
  Result := id^.pMethods^.xRead(id, pBuf, amt, offset);
end;

{ os.c ~89: sqlite3OsWrite }
function sqlite3OsWrite(id: Psqlite3_file; pBuf: Pointer; amt: cint; offset: i64): cint;
begin
  Result := id^.pMethods^.xWrite(id, pBuf, amt, offset);
end;

{ os.c ~94: sqlite3OsTruncate }
function sqlite3OsTruncate(id: Psqlite3_file; size: i64): cint;
begin
  Result := id^.pMethods^.xTruncate(id, size);
end;

{ os.c ~97: sqlite3OsSync }
function sqlite3OsSync(id: Psqlite3_file; flags: cint): cint;
begin
  if flags <> 0 then
    Result := id^.pMethods^.xSync(id, flags)
  else
    Result := SQLITE_OK;
end;

{ os.c ~102: sqlite3OsFileSize }
function sqlite3OsFileSize(id: Psqlite3_file; pSize: Pi64): cint;
begin
  Result := id^.pMethods^.xFileSize(id, pSize);
end;

{ os.c ~106: sqlite3OsLock }
function sqlite3OsLock(id: Psqlite3_file; lockType: cint): cint;
begin
  Result := id^.pMethods^.xLock(id, lockType);
end;

{ os.c ~111: sqlite3OsUnlock }
function sqlite3OsUnlock(id: Psqlite3_file; lockType: cint): cint;
begin
  Result := id^.pMethods^.xUnlock(id, lockType);
end;

{ os.c ~115: sqlite3OsCheckReservedLock }
function sqlite3OsCheckReservedLock(id: Psqlite3_file; pResOut: PcInt): cint;
begin
  Result := id^.pMethods^.xCheckReservedLock(id, pResOut);
end;

{ os.c ~278: sqlite3OsOpen }
function sqlite3OsOpen(pVfs: Psqlite3_vfs; zPath: PChar; pFile: Psqlite3_file;
                       flags: cint; pFlagsOut: PcInt): cint;
begin
  Result := pVfs^.xOpen(pVfs, zPath, pFile, flags and $1087f7f, pFlagsOut);
end;

{ os.c ~289: sqlite3OsDelete }
function sqlite3OsDelete(pVfs: Psqlite3_vfs; zPath: PChar; dirSync: cint): cint;
begin
  if Assigned(pVfs^.xDelete) then
    Result := pVfs^.xDelete(pVfs, zPath, dirSync)
  else
    Result := SQLITE_OK;
end;

{ os.c ~295: sqlite3OsAccess }
function sqlite3OsAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint;
                         pResOut: PcInt): cint;
begin
  Result := pVfs^.xAccess(pVfs, zPath, flags, pResOut);
end;

{ os.c ~302: sqlite3OsFullPathname }
function sqlite3OsFullPathname(pVfs: Psqlite3_vfs; zPath: PChar;
                               nPathOut: cint; zPathOut: PChar): cint;
begin
  zPathOut[0] := #0;
  Result := pVfs^.xFullPathname(pVfs, zPath, nPathOut, zPathOut);
end;

{ os.c ~378: sqlite3OsInit — initialise the OS layer }
function sqlite3OsInit: cint;
begin
  Result := sqlite3_os_init();
end;

{ os.c: sqlite3OsSectorSize }
function sqlite3OsSectorSize(id: Psqlite3_file): cint;
begin
  if Assigned(id^.pMethods) and Assigned(id^.pMethods^.xSectorSize) then
    Result := id^.pMethods^.xSectorSize(id)
  else
    Result := SQLITE_DEFAULT_SECTOR_SIZE;
end;

{ os.c: sqlite3OsDeviceCharacteristics }
function sqlite3OsDeviceCharacteristics(id: Psqlite3_file): cint;
begin
  if Assigned(id^.pMethods) and Assigned(id^.pMethods^.xDeviceCharacteristics) then
    Result := id^.pMethods^.xDeviceCharacteristics(id)
  else
    Result := 0;
end;

{ os.c: sqlite3OsFileControl }
function sqlite3OsFileControl(id: Psqlite3_file; op: cint; pArg: Pointer): cint;
begin
  if Assigned(id^.pMethods) and Assigned(id^.pMethods^.xFileControl) then
    Result := id^.pMethods^.xFileControl(id, op, pArg)
  else
    Result := SQLITE_NOTFOUND;
end;

{ os.c: sqlite3OsFileControlHint -- like FileControl but ignores errors }
procedure sqlite3OsFileControlHint(id: Psqlite3_file; op: cint; pArg: Pointer);
begin
  if Assigned(id^.pMethods) and Assigned(id^.pMethods^.xFileControl) then
    id^.pMethods^.xFileControl(id, op, pArg);
end;

{ os.c: sqlite3OsFetch }
function sqlite3OsFetch(id: Psqlite3_file; iOff: i64; iAmt: cint; pp: PPointer): cint;
begin
  if Assigned(id^.pMethods) and (id^.pMethods^.iVersion >= 3)
    and Assigned(id^.pMethods^.xFetch)
  then
    Result := id^.pMethods^.xFetch(id, iOff, iAmt, pp)
  else
  begin
    pp^ := nil;
    Result := SQLITE_OK;
  end;
end;

{ os.c: sqlite3OsUnfetch }
function sqlite3OsUnfetch(id: Psqlite3_file; iOff: i64; p: Pointer): cint;
begin
  if Assigned(id^.pMethods) and (id^.pMethods^.iVersion >= 3)
    and Assigned(id^.pMethods^.xUnfetch)
  then
    Result := id^.pMethods^.xUnfetch(id, iOff, p)
  else
    Result := SQLITE_OK;
end;

{ os.c: sqlite3OsShmMap }
function sqlite3OsShmMap(id: Psqlite3_file; iPg: cint; pgsz: cint;
                         bExtend: cint; pp: PPointer): cint;
begin
  if Assigned(id^.pMethods) and (id^.pMethods^.iVersion >= 2)
    and Assigned(id^.pMethods^.xShmMap)
  then
    Result := id^.pMethods^.xShmMap(id, iPg, pgsz, bExtend, pp)
  else
  begin
    pp^ := nil;
    Result := SQLITE_IOERR;
  end;
end;

{ os.c: sqlite3OsShmLock }
function sqlite3OsShmLock(id: Psqlite3_file; offset: cint; n: cint;
                          flags: cint): cint;
begin
  if Assigned(id^.pMethods) and (id^.pMethods^.iVersion >= 2)
    and Assigned(id^.pMethods^.xShmLock)
  then
    Result := id^.pMethods^.xShmLock(id, offset, n, flags)
  else
    Result := SQLITE_OK;
end;

{ os.c: sqlite3OsShmBarrier }
procedure sqlite3OsShmBarrier(id: Psqlite3_file);
begin
  if Assigned(id^.pMethods) and (id^.pMethods^.iVersion >= 2)
    and Assigned(id^.pMethods^.xShmBarrier)
  then
    id^.pMethods^.xShmBarrier(id);
end;

{ os.c: sqlite3OsShmUnmap }
function sqlite3OsShmUnmap(id: Psqlite3_file; deleteFlag: cint): cint;
begin
  if Assigned(id^.pMethods) and (id^.pMethods^.iVersion >= 2)
    and Assigned(id^.pMethods^.xShmUnmap)
  then
    Result := id^.pMethods^.xShmUnmap(id, deleteFlag)
  else
    Result := SQLITE_OK;
end;

{ os.c ~284: sqlite3OsSleep }
function sqlite3OsSleep(pVfs: Psqlite3_vfs; nMicrosec: cint): cint;
begin
  Result := pVfs^.xSleep(pVfs, nMicrosec);
end;

{ ============================================================
  Section 13: VFS registration  (os.c ~390)
  ============================================================ }

{ os.c ~410: vfsUnlink — remove pVfs from the singly-linked list (caller holds mutex) }
procedure vfsUnlink(pVfs: Psqlite3_vfs);
var
  p : Psqlite3_vfs;
begin
  if pVfs = nil then
    { no-op }
  else if vfsList = pVfs then
    vfsList := pVfs^.pNext
  else if vfsList <> nil then begin
    p := vfsList;
    while (p^.pNext <> nil) and (p^.pNext <> pVfs) do
      p := p^.pNext;
    if p^.pNext = pVfs then
      p^.pNext := pVfs^.pNext;
  end;
end;

{ os.c ~424: sqlite3_vfs_find }
function sqlite3_vfs_find(zVfs: PChar): Psqlite3_vfs;
var
  pVfs  : Psqlite3_vfs;
  mutex : Psqlite3_mutex;
begin
  mutex := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(mutex);
  pVfs := vfsList;
  while pVfs <> nil do begin
    if (zVfs = nil) or (StrComp(zVfs, pVfs^.zName) = 0) then
      break;
    pVfs := pVfs^.pNext;
  end;
  sqlite3_mutex_leave(mutex);
  Result := pVfs;
end;

{ os.c ~452: sqlite3_vfs_register }
function sqlite3_vfs_register(pVfs: Psqlite3_vfs; makeDflt: cint): cint;
var
  mutex : Psqlite3_mutex;
begin
  if pVfs = nil then begin
    Result := SQLITE_MISUSE;
    Exit;
  end;
  mutex := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(mutex);
  vfsUnlink(pVfs);
  if (makeDflt <> 0) or (vfsList = nil) then begin
    pVfs^.pNext := vfsList;
    vfsList := pVfs;
  end else begin
    pVfs^.pNext := vfsList^.pNext;
    vfsList^.pNext := pVfs;
  end;
  sqlite3_mutex_leave(mutex);
  Result := SQLITE_OK;
end;

{ os.c ~479: sqlite3_vfs_unregister }
function sqlite3_vfs_unregister(pVfs: Psqlite3_vfs): cint;
var
  mutex : Psqlite3_mutex;
begin
  mutex := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(mutex);
  vfsUnlink(pVfs);
  sqlite3_mutex_leave(mutex);
  Result := SQLITE_OK;
end;

{ ============================================================
  Section 14a: Low-level POSIX advisory locking helper  (os_unix.c)

  Phase 1 simplification: each unixFile owns a private unixInodeInfo
  (no sharing between multiple sqlite3* handles on the same file within
  one process).  Cross-process advisory locking via fcntl still works
  correctly.  Full inodeInfo sharing is deferred to Phase 3.
  ============================================================ }

{ os_unix.c ~1857: unixFileLock — issue a POSIX advisory lock via F_SETLK }
function unixFileLock(pFile: PunixFile; var lock: FLock): cint;
begin
  { F_SETLK = 6 (Linux x86_64); we use our own constant which equals F_SetLk }
  Result := FpFcntl(pFile^.h, F_SETLK, lock);
end;

{ ============================================================
  Section 14b: unix I/O method implementations  (os_unix.c)
  These are the cdecl functions stored in the unixIoMethods vtable.
  ============================================================ }

{ os_unix.c ~2341: unixClose_impl
  Unlocks, frees the private inodeInfo, closes the fd, and zeroes the struct. }
function unixClose_impl(pFile: Psqlite3_file): cint; cdecl;
var
  pf    : PunixFile;
  pInode: PunixInodeInfo;
begin
  pf := PunixFile(pFile);
  { Unlock: release any held lock }
  unixUnlock_impl(pFile, NO_LOCK);

  pInode := pf^.pInode;
  if pInode <> nil then begin
    { Free the lock mutex }
    if pInode^.pLockMutex <> nil then
      sqlite3_mutex_free(pInode^.pLockMutex);
    { Phase 1: private inodeInfo — free it directly }
    sqlite3_free(pInode);
  end;

  if pf^.pPreallocatedUnused <> nil then
    sqlite3_free(pf^.pPreallocatedUnused);

  if pf^.h >= 0 then
    FpClose(pf^.h);

  FillChar(pf^, SizeOf(unixFile), 0);
  Result := SQLITE_OK;
end;

{ os_unix.c ~3512: unixRead_impl — positional read using pread(2) }
function unixRead_impl(pFile: Psqlite3_file; pBuf: Pointer;
                       iAmt: cint; iOfst: i64): cint; cdecl;
var
  pf  : PunixFile;
  got : ssize_t;
begin
  pf := PunixFile(pFile);
  repeat
    got := FpPRead(pf^.h, pBuf, iAmt, iOfst);
  until not ((got < 0) and (fpgeterrno = ESysEINTR));

  if got = ssize_t(iAmt) then
    Result := SQLITE_OK
  else if got < 0 then begin
    pf^.lastErrno := fpgeterrno;
    Result := SQLITE_IOERR_READ;
  end else begin
    { Short read — zero-fill the remainder (os_unix.c ~3565) }
    pf^.lastErrno := 0;
    FillChar((PByte(pBuf) + got)^, iAmt - got, 0);
    Result := SQLITE_IOERR_SHORT_READ;
  end;
end;

{ os_unix.c ~3643: unixWrite_impl — positional write using pwrite(2) }
function unixWrite_impl(pFile: Psqlite3_file; pBuf: Pointer;
                        iAmt: cint; iOfst: i64): cint; cdecl;
var
  pf           : PunixFile;
  wrote        : ssize_t;
  totalWritten : cint;
begin
  pf := PunixFile(pFile);
  totalWritten := 0;
  while totalWritten < iAmt do begin
    repeat
      wrote := FpPWrite(pf^.h, (PByte(pBuf) + totalWritten)^,
                        iAmt - totalWritten, iOfst + totalWritten);
    until not ((wrote < 0) and (fpgeterrno = ESysEINTR));
    if wrote <= 0 then begin
      pf^.lastErrno := fpgeterrno;
      Result := SQLITE_IOERR_WRITE;
      Exit;
    end;
    Inc(totalWritten, cint(wrote));
  end;
  Result := SQLITE_OK;
end;

{ os_unix.c ~3961: unixTruncate_impl — truncate open file to nByte bytes }
function unixTruncate_impl(pFile: Psqlite3_file; size: i64): cint; cdecl;
var
  pf : PunixFile;
  rc : cint;
begin
  pf := PunixFile(pFile);
  { If a chunk-size is set, round up to the next multiple }
  if pf^.szChunk > 0 then
    size := ((size + pf^.szChunk - 1) div pf^.szChunk) * pf^.szChunk;
  rc := FpFtruncate(pf^.h, size);
  if rc <> 0 then begin
    pf^.lastErrno := fpgeterrno;
    Result := SQLITE_IOERR_TRUNCATE;
  end else
    Result := SQLITE_OK;
end;

{ os_unix.c ~3911: unixSync_impl — fsync the file }
function unixSync_impl(pFile: Psqlite3_file; flags: cint): cint; cdecl;
var
  pf : PunixFile;
  rc : cint;
begin
  pf := PunixFile(pFile);
  rc := c_fsync(pf^.h);
  if rc <> 0 then begin
    pf^.lastErrno := fpgeterrno;
    Result := SQLITE_IOERR_FSYNC;
  end else
    Result := SQLITE_OK;
end;

{ os_unix.c ~4011: unixFileSize_impl — return current file size in bytes }
function unixFileSize_impl(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
var
  pf  : PunixFile;
  buf : Stat;
  rc  : cint;
begin
  pf := PunixFile(pFile);
  rc := FpFStat(pf^.h, buf);
  if rc <> 0 then begin
    pf^.lastErrno := fpgeterrno;
    Result := SQLITE_IOERR_FSTAT;
    Exit;
  end;
  pSize^ := buf.st_size;
  { Ticket #3260: OS-X msdos workaround — report 1-byte file as empty }
  if pSize^ = 1 then pSize^ := 0;
  Result := SQLITE_OK;
end;

{ os_unix.c ~1960: unixLock_impl — escalate advisory lock.
  Phase 1: private per-file inodeInfo; cross-process locking via POSIX fcntl.

  Locking state machine (os_unix.c commentary):
    UNLOCKED  → SHARED
    SHARED    → RESERVED
    SHARED    → EXCLUSIVE
    RESERVED  → (PENDING) → EXCLUSIVE
    PENDING   → EXCLUSIVE
}
function unixLock_impl(pFile: Psqlite3_file; eFileLock: cint): cint; cdecl;
label
  end_lock;
var
  pf     : PunixFile;
  pInode : PunixInodeInfo;
  lock   : FLock;
  tErrno : cint;
  rc     : cint;
begin
  pf := PunixFile(pFile);
  rc := SQLITE_OK;
  tErrno := 0;

  { Already at this level or higher — nothing to do }
  if pf^.eFileLock >= eFileLock then begin
    Result := SQLITE_OK;
    Exit;
  end;

  pInode := pf^.pInode;
  sqlite3_mutex_enter(pInode^.pLockMutex);

  { Check inode-level lock compatibility (os_unix.c ~2040) }
  if (pf^.eFileLock <> pInode^.eFileLock) and
     ((pInode^.eFileLock >= PENDING_LOCK) or (eFileLock > SHARED_LOCK)) then begin
    rc := SQLITE_BUSY;
    goto end_lock;
  end;

  { Fast path: another connection in this process already holds SHARED/RESERVED;
    just increment the counter (os_unix.c ~2055). }
  if (eFileLock = SHARED_LOCK) and
     ((pInode^.eFileLock = SHARED_LOCK) or
      (pInode^.eFileLock = RESERVED_LOCK)) then begin
    pf^.eFileLock := SHARED_LOCK;
    Inc(pInode^.nShared);
    Inc(pInode^.nLock);
    goto end_lock;
  end;

  FillChar(lock, SizeOf(lock), 0);
  lock.l_len    := 1;
  lock.l_whence := SEEK_SET;

  { Acquire PENDING lock as an intermediate step (os_unix.c ~2075) }
  if (eFileLock = SHARED_LOCK) or
     ((eFileLock = EXCLUSIVE_LOCK) and
      (pf^.eFileLock = RESERVED_LOCK)) then begin
    if eFileLock = SHARED_LOCK then
      lock.l_type := SmallInt(F_RDLCK)
    else
      lock.l_type := SmallInt(F_WRLCK);
    lock.l_start := PENDING_BYTE;
    if unixFileLock(pf, lock) <> 0 then begin
      tErrno := fpgeterrno;
      if (tErrno = ESysEAGAIN) or (tErrno = ESysEACCES) then
        rc := SQLITE_BUSY
      else begin
        rc := SQLITE_IOERR_LOCK;
        pf^.lastErrno := tErrno;
      end;
      goto end_lock;
    end else if eFileLock = EXCLUSIVE_LOCK then begin
      pf^.eFileLock := PENDING_LOCK;
      pInode^.eFileLock := PENDING_LOCK;
    end;
  end;

  if eFileLock = SHARED_LOCK then begin
    { os_unix.c ~2095: obtain the read (shared) lock on the shared byte range }
    lock.l_type  := SmallInt(F_RDLCK);
    lock.l_start := SHARED_FIRST;
    lock.l_len   := SHARED_SIZE;
    if unixFileLock(pf, lock) <> 0 then begin
      tErrno := fpgeterrno;
      if (tErrno = ESysEAGAIN) or (tErrno = ESysEACCES) then
        rc := SQLITE_BUSY
      else begin
        rc := SQLITE_IOERR_LOCK;
        pf^.lastErrno := tErrno;
      end;
    end;

    { Release the PENDING lock regardless of result (os_unix.c ~2111) }
    lock.l_start := PENDING_BYTE;
    lock.l_len   := 1;
    lock.l_type  := SmallInt(F_UNLCK);
    if (unixFileLock(pf, lock) <> 0) and (rc = SQLITE_OK) then
      rc := SQLITE_IOERR_UNLOCK;

    if rc <> SQLITE_OK then
      goto end_lock;

    pf^.eFileLock := SHARED_LOCK;
    Inc(pInode^.nLock);
    pInode^.nShared := 1;

  end else if (eFileLock = EXCLUSIVE_LOCK) and (pInode^.nShared > 1) then begin
    { os_unix.c ~2127: another connection in this process holds SHARED }
    rc := SQLITE_BUSY;

  end else begin
    { os_unix.c ~2131: RESERVED or EXCLUSIVE lock }
    lock.l_type := SmallInt(F_WRLCK);
    if eFileLock = RESERVED_LOCK then begin
      lock.l_start := RESERVED_BYTE;
      lock.l_len   := 1;
    end else begin
      lock.l_start := SHARED_FIRST;
      lock.l_len   := SHARED_SIZE;
    end;
    if unixFileLock(pf, lock) <> 0 then begin
      tErrno := fpgeterrno;
      if (tErrno = ESysEAGAIN) or (tErrno = ESysEACCES) then
        rc := SQLITE_BUSY
      else begin
        rc := SQLITE_IOERR_LOCK;
        pf^.lastErrno := tErrno;
      end;
    end;
  end;

  if rc = SQLITE_OK then begin
    pf^.eFileLock    := eFileLock;
    pInode^.eFileLock := eFileLock;
  end;

end_lock:
  sqlite3_mutex_leave(pInode^.pLockMutex);
  Result := rc;
end;

{ os_unix.c ~2225: unixUnlock_impl — reduce advisory lock level.
  eFileLock must be NO_LOCK or SHARED_LOCK.
  Phase 1: simplified posixUnlock without closePendingFds. }
function unixUnlock_impl(pFile: Psqlite3_file; eFileLock: cint): cint; cdecl;
label
  end_unlock;
var
  pf     : PunixFile;
  pInode : PunixInodeInfo;
  lock   : FLock;
  rc     : cint;
begin
  pf := PunixFile(pFile);
  rc := SQLITE_OK;

  if pf^.eFileLock <= eFileLock then begin
    Result := SQLITE_OK;
    Exit;
  end;

  pInode := pf^.pInode;
  sqlite3_mutex_enter(pInode^.pLockMutex);

  FillChar(lock, SizeOf(lock), 0);
  lock.l_whence := SEEK_SET;

  if pf^.eFileLock > SHARED_LOCK then begin
    { Downgrade to SHARED: set a read lock on the shared range (os_unix.c ~2256) }
    if eFileLock = SHARED_LOCK then begin
      lock.l_type  := SmallInt(F_RDLCK);
      lock.l_start := SHARED_FIRST;
      lock.l_len   := SHARED_SIZE;
      if unixFileLock(pf, lock) <> 0 then begin
        rc := SQLITE_IOERR_RDLOCK;
        pf^.lastErrno := fpgeterrno;
        goto end_unlock;
      end;
    end;

    { Release PENDING + RESERVED bytes (os_unix.c ~2289).
      assert( PENDING_BYTE+1==RESERVED_BYTE ) holds by definition. }
    lock.l_type  := SmallInt(F_UNLCK);
    lock.l_start := PENDING_BYTE;
    lock.l_len   := 2;
    if unixFileLock(pf, lock) = 0 then
      pInode^.eFileLock := SHARED_LOCK
    else begin
      rc := SQLITE_IOERR_UNLOCK;
      pf^.lastErrno := fpgeterrno;
      goto end_unlock;
    end;
  end;

  if eFileLock = NO_LOCK then begin
    { os_unix.c ~2302: decrement shared counter; fully unlock when zero }
    Dec(pInode^.nShared);
    if pInode^.nShared = 0 then begin
      lock.l_type  := SmallInt(F_UNLCK);
      lock.l_start := 0;
      lock.l_len   := 0;    { 0 = entire file }
      if unixFileLock(pf, lock) = 0 then
        pInode^.eFileLock := NO_LOCK
      else begin
        rc := SQLITE_IOERR_UNLOCK;
        pf^.lastErrno := fpgeterrno;
        pInode^.eFileLock := NO_LOCK;
        pf^.eFileLock := NO_LOCK;
      end;
    end;
    Dec(pInode^.nLock);
    { Phase 1: closePendingFds omitted — deferred to Phase 3 }
  end;

end_unlock:
  sqlite3_mutex_leave(pInode^.pLockMutex);
  if rc = SQLITE_OK then
    pf^.eFileLock := eFileLock;
  Result := rc;
end;

{ os_unix.c ~1720: unixCheckReservedLock_impl }
function unixCheckReservedLock_impl(pFile: Psqlite3_file;
                                    pResOut: PcInt): cint; cdecl;
var
  pf       : PunixFile;
  reserved : cint;
  lock     : FLock;
  pInode   : PunixInodeInfo;
begin
  pf := PunixFile(pFile);
  reserved := 0;
  pInode := pf^.pInode;

  sqlite3_mutex_enter(pInode^.pLockMutex);

  { Check if any connection in this process holds RESERVED or higher }
  if pInode^.eFileLock > SHARED_LOCK then
    reserved := 1;

  { Ask the kernel whether another process holds it (os_unix.c ~1738) }
  if reserved = 0 then begin
    FillChar(lock, SizeOf(lock), 0);
    lock.l_whence := SEEK_SET;
    lock.l_start  := RESERVED_BYTE;
    lock.l_len    := 1;
    lock.l_type   := SmallInt(F_WRLCK);
    if FpFcntl(pf^.h, F_GETLK, lock) <> 0 then begin
      sqlite3_mutex_leave(pInode^.pLockMutex);
      pf^.lastErrno := fpgeterrno;
      pResOut^ := 0;
      Result := SQLITE_IOERR_CHECKRESERVEDLOCK;
      Exit;
    end else if lock.l_type <> SmallInt(F_UNLCK) then
      reserved := 1;
  end;

  sqlite3_mutex_leave(pInode^.pLockMutex);
  pResOut^ := reserved;
  Result := SQLITE_OK;
end;

{ os_unix.c ~4050: unixFileControl_impl — handle FCNTL opcodes }
function unixFileControl_impl(pFile: Psqlite3_file; op: cint;
                              pArg: Pointer): cint; cdecl;
var
  pf : PunixFile;
begin
  pf := PunixFile(pFile);
  case op of
    SQLITE_FCNTL_LOCKSTATE: begin
      PcInt(pArg)^ := pf^.eFileLock;
      Result := SQLITE_OK;
    end;
    SQLITE_FCNTL_LAST_ERRNO: begin
      PcInt(pArg)^ := pf^.lastErrno;
      Result := SQLITE_OK;
    end;
    SQLITE_FCNTL_SIZE_HINT: begin
      { Ignore for Phase 1 }
      Result := SQLITE_OK;
    end;
    SQLITE_FCNTL_CHUNK_SIZE: begin
      pf^.szChunk := PcInt(pArg)^;
      Result := SQLITE_OK;
    end;
    SQLITE_FCNTL_VFS_POINTER: begin
      PPointer(pArg)^ := pf^.pVfs;
      Result := SQLITE_OK;
    end;
    else
      Result := SQLITE_NOTFOUND;
  end;
end;

{ os_unix.c ~4460: unixSectorSize_impl }
function unixSectorSize_impl(pFile: Psqlite3_file): cint; cdecl;
begin
  Result := 4096;
end;

{ os_unix.c ~4470: unixDeviceCharacteristics_impl }
function unixDeviceCharacteristics_impl(pFile: Psqlite3_file): cint; cdecl;
begin
  Result := 0;
end;

{ ============================================================
  Section 14c: Public unix VFS methods  (os_unix.c ~6538)
  ============================================================ }

{ os_unix.c ~6538: unixOpen — open (or create) a database file.

  Phase 1 simplification:
  - Each open file gets its own private unixInodeInfo (no process-wide sharing;
    cross-process locking via fcntl still works).
  - No Apple/VxWorks code paths.
  - Temp-file names use /tmp/sqlite_<pid>_<seq>.
  - zPath stored verbatim (caller responsible for lifetime). }
function unixOpen(pVfs: Psqlite3_vfs; zPath: sqlite3_filename;
                  pFile: Psqlite3_file; flags: cint;
                  pOutFlags: PcInt): cint; cdecl;
var
  p          : PunixFile;
  fd         : cint;
  openFlags  : cint;
  isReadonly : Boolean;
  isReadWrite: Boolean;
  isCreate   : Boolean;
  isExclusive: Boolean;
  isDelete   : Boolean;
  eType      : cint;
  zName      : PChar;
  pUnused    : PUnixUnusedFd;
  pInode     : PunixInodeInfo;
  ctrlFlags  : u16;
  tmpNameBuf : array[0..MAX_PATHNAME+1] of char;
  tmpNameStr : String;
begin
  p := PunixFile(pFile);
  FillChar(p^, SizeOf(unixFile), 0);
  p^.h := -1;

  isReadonly   := (flags and SQLITE_OPEN_READONLY)    <> 0;
  isReadWrite  := (flags and SQLITE_OPEN_READWRITE)   <> 0;
  isCreate     := (flags and SQLITE_OPEN_CREATE)      <> 0;
  isExclusive  := (flags and SQLITE_OPEN_EXCLUSIVE)   <> 0;
  isDelete     := (flags and SQLITE_OPEN_DELETEONCLOSE) <> 0;
  eType        := flags and $0FFF00;
  ctrlFlags    := 0;
  pUnused      := nil;
  pInode       := nil;

  zName := zPath;

  { Generate a temporary file name when zPath is nil (os_unix.c ~6616) }
  if zName = nil then begin
    Inc(tempFileSeq);
    tmpNameStr := Format('/tmp/sqlite_%d_%d', [Integer(FpGetPid), tempFileSeq]);
    StrLCopy(@tmpNameBuf[0], PChar(tmpNameStr), MAX_PATHNAME);
    zName := @tmpNameBuf[0];
    isDelete := True;
  end;

  { Build the open(2) flags (os_unix.c ~6660) }
  openFlags := 0;
  if isReadonly  then openFlags := openFlags or O_RDONLY;
  if isReadWrite then openFlags := openFlags or O_RDWR;
  if isCreate    then openFlags := openFlags or O_CREAT;
  if isExclusive then openFlags := openFlags or O_EXCL or O_NOFOLLOW_FLAG;

  { Pre-allocate the UnixUnusedFd for MAIN_DB (os_unix.c ~6634) }
  if eType = SQLITE_OPEN_MAIN_DB then begin
    pUnused := PUnixUnusedFd(sqlite3_malloc(SizeOf(UnixUnusedFd)));
    if pUnused = nil then begin
      Result := SQLITE_NOMEM;
      Exit;
    end;
    FillChar(pUnused^, SizeOf(UnixUnusedFd), 0);
    p^.pPreallocatedUnused := pUnused;
  end;

  { Open the file (os_unix.c ~6678) }
  fd := FpOpen(zName, openFlags, SQLITE_DEFAULT_FILE_PERMISSIONS);

  { Retry as read-only if read-write open failed (os_unix.c ~6693) }
  if (fd < 0) and isReadWrite and (fpgeterrno <> ESysEISDIR) then begin
    openFlags := (openFlags and not (O_RDWR or O_CREAT)) or O_RDONLY;
    fd := FpOpen(zName, openFlags, SQLITE_DEFAULT_FILE_PERMISSIONS);
    if fd >= 0 then
      isReadonly := True;
  end;

  if fd < 0 then begin
    if p^.pPreallocatedUnused <> nil then
      sqlite3_free(p^.pPreallocatedUnused);
    Result := SQLITE_CANTOPEN;
    Exit;
  end;

  if p^.pPreallocatedUnused <> nil then begin
    p^.pPreallocatedUnused^.fd    := fd;
    p^.pPreallocatedUnused^.flags :=
      flags and (SQLITE_OPEN_READONLY or SQLITE_OPEN_READWRITE);
  end;

  { Delete-on-close: unlink immediately on Linux (os_unix.c ~6707) }
  if isDelete then
    FpUnlink(zName);

  { Build ctrlFlags }
  if isDelete   then ctrlFlags := ctrlFlags or UNIXFILE_DELETE;
  if isReadonly then ctrlFlags := ctrlFlags or UNIXFILE_RDONLY;
  if eType <> SQLITE_OPEN_MAIN_DB then
    ctrlFlags := ctrlFlags or UNIXFILE_NOLOCK;
  if (flags and SQLITE_OPEN_URI) <> 0 then
    ctrlFlags := ctrlFlags or UNIXFILE_URI;

  { Allocate a private inodeInfo (Phase 1 simplification: one per file) }
  pInode := PunixInodeInfo(sqlite3_malloc(SizeOf(unixInodeInfo)));
  if pInode = nil then begin
    FpClose(fd);
    if p^.pPreallocatedUnused <> nil then
      sqlite3_free(p^.pPreallocatedUnused);
    Result := SQLITE_NOMEM;
    Exit;
  end;
  FillChar(pInode^, SizeOf(unixInodeInfo), 0);
  pInode^.nRef := 1;
  pInode^.pLockMutex := sqlite3_mutex_alloc(SQLITE_MUTEX_FAST);
  if pInode^.pLockMutex = nil then begin
    FpClose(fd);
    sqlite3_free(pInode);
    if p^.pPreallocatedUnused <> nil then
      sqlite3_free(p^.pPreallocatedUnused);
    Result := SQLITE_NOMEM;
    Exit;
  end;

  { Fill in the unixFile record (os_unix.c: fillInUnixFile) }
  p^.pMethod   := @unixIoMethods;
  p^.pVfs      := pVfs;
  p^.pInode    := pInode;
  p^.h         := fd;
  p^.eFileLock := 0;
  p^.ctrlFlags := ctrlFlags;
  p^.lastErrno := 0;
  { zPath: for delete-on-close files the name is gone; store nil.
    For normal files, the caller owns the string for the db handle lifetime. }
  if isDelete then
    p^.zPath := nil
  else
    p^.zPath := zName;

  if pOutFlags <> nil then
    pOutFlags^ := flags;

  Result := SQLITE_OK;
end;

{ os_unix.c ~6833: unixDelete — remove a file, optionally fsync the directory }
function unixDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                    dirSync: cint): cint; cdecl;
var
  dfd : cint;
  dir : array[0..MAX_PATHNAME] of char;
  sep : PChar;
begin
  if FpUnlink(zPath) <> 0 then begin
    if fpgeterrno = ESysENOENT then
      Result := SQLITE_IOERR_DELETE_NOENT
    else
      Result := SQLITE_IOERR_DELETE;
    Exit;
  end;

  { If dirSync requested, fsync the parent directory (os_unix.c ~6854) }
  if (dirSync and 1) <> 0 then begin
    StrLCopy(@dir[0], zPath, MAX_PATHNAME);
    sep := StrRScan(@dir[0], '/');
    if sep = nil then
      StrCopy(@dir[0], '.')
    else if sep = @dir[0] then
      dir[1] := #0
    else
      sep^ := #0;
    dfd := FpOpen(@dir[0], O_RDONLY, 0);
    if dfd >= 0 then begin
      c_fsync(dfd);
      FpClose(dfd);
    end;
  end;

  Result := SQLITE_OK;
end;

{ os_unix.c ~6881: unixAccess — check file existence/permissions }
function unixAccess(pVfs: Psqlite3_vfs; zPath: PChar;
                    flags: cint; pResOut: PcInt): cint; cdecl;
var
  buf : Stat;
begin
  if flags = SQLITE_ACCESS_EXISTS then begin
    { os_unix.c ~6910: stat succeeds AND (not a regular zero-size file) }
    if (FpStat(zPath, buf) = 0) and
       (((buf.st_mode and $F000) <> $8000) or (buf.st_size > 0)) then
      pResOut^ := 1
    else
      pResOut^ := 0;
  end else begin
    { SQLITE_ACCESS_READWRITE or READ }
    if FpAccess(zPath, W_OK or R_OK) = 0 then
      pResOut^ := 1
    else
      pResOut^ := 0;
  end;
  Result := SQLITE_OK;
end;

{ os_unix.c ~7008: unixFullPathname — resolve to an absolute path.
  Phase 1: getcwd (via libc) + concat; does not resolve symlinks.
  Note: FPC's FpGetCwd on Linux returns path length (not pointer) on success
  (the kernel getcwd syscall writes to the buffer and returns the length).
  Use the libc getcwd directly to get the correct pointer semantics. }
function libc_getcwd(buf: PChar; size: csize_t): PChar;
  cdecl; external 'c' name 'getcwd';

function unixFullPathname(pVfs: Psqlite3_vfs; zPath: PChar;
                          nOut: cint; zOut: PChar): cint; cdecl;
var
  cwd    : array[0..MAX_PATHNAME+1] of char;
  cwdPtr : PChar;
  pathLen: SizeInt;
  remLen : SizeInt;
begin
  zOut[0] := #0;

  if (zPath <> nil) and (zPath[0] = '/') then begin
    { Already absolute — copy verbatim }
    StrLCopy(zOut, zPath, nOut - 1);
    zOut[nOut - 1] := #0;
    Result := SQLITE_OK;
    Exit;
  end;

  { Relative path — prepend current working directory via libc getcwd }
  cwdPtr := libc_getcwd(@cwd[0], SizeOf(cwd) - 2);
  if cwdPtr = nil then begin
    Result := SQLITE_CANTOPEN;
    Exit;
  end;

  pathLen := StrLen(cwdPtr);
  remLen  := nOut - pathLen - 2;
  if (zPath <> nil) and (SizeInt(StrLen(zPath)) > remLen) then begin
    Result := SQLITE_CANTOPEN;
    Exit;
  end;

  StrLCopy(zOut, cwdPtr, nOut - 1);
  if zPath <> nil then begin
    zOut[pathLen] := '/';
    StrLCopy(zOut + pathLen + 1, zPath, remLen);
  end;
  zOut[nOut - 1] := #0;
  Result := SQLITE_OK;
end;

{ os_unix.c ~7100: unixRandomness — read from /dev/urandom }
function unixRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                        zOut: PChar): cint; cdecl;
var
  fd  : cint;
  got : ssize_t;
begin
  FillChar(zOut^, nByte, 0);
  fd := FpOpen('/dev/urandom', O_RDONLY, 0);
  if fd >= 0 then begin
    repeat
      got := FpRead(fd, zOut^, nByte);
    until not ((got < 0) and (fpgeterrno = ESysEINTR));
    FpClose(fd);
    if got > 0 then begin
      Result := cint(got);
      Exit;
    end;
  end;
  Result := nByte;  { fallback: return nByte (zOut filled with zeros) }
end;

{ os_unix.c ~7147: unixSleep — sleep for microseconds using nanosleep }
function unixSleep(pVfs: Psqlite3_vfs; microseconds: cint): cint; cdecl;
var
  ts : TTimeSpec;
begin
  ts.tv_sec  := microseconds div 1000000;
  ts.tv_nsec := Int64(microseconds mod 1000000) * 1000;
  c_nanosleep(@ts, nil);
  Result := microseconds;
end;

{ os_unix.c ~7225: unixCurrentTime — Julian day number as a Double }
function unixCurrentTime(pVfs: Psqlite3_vfs; pTime: PDouble): cint; cdecl;
const
  unixEpoch : i64 = 210866760000000;
var
  tv   : TTimeVal;
  iNow : i64;
begin
  c_gettimeofday(@tv, nil);
  iNow   := unixEpoch + i64(1000) * tv.tv_sec + tv.tv_usec div 1000;
  pTime^ := iNow / 86400000.0;
  Result := 0;
end;

{ os_unix.c ~7243: unixGetLastError — return the errno from the last failed call }
function unixGetLastError(pVfs: Psqlite3_vfs; n: cint; zBuf: PChar): cint; cdecl;
begin
  Result := fpgeterrno;
end;

{ ============================================================
  Section 14d: sqlite3_os_init / sqlite3_os_end  (os_unix.c ~8448)
  ============================================================ }

{ os_unix.c ~8448: sqlite3_os_init — register the unix VFS as the default }
function sqlite3_os_init: cint;
begin
  { Fill in the singleton unixVfsObj (declared in interface section) }
  FillChar(unixVfsObj, SizeOf(unixVfsObj), 0);
  unixVfsObj.iVersion        := 1;    { Phase 1: v1 only (no WAL/SHM/mmap) }
  unixVfsObj.szOsFile        := SizeOf(unixFile);
  unixVfsObj.mxPathname      := MAX_PATHNAME;
  unixVfsObj.pNext           := nil;
  unixVfsObj.zName           := 'unix';
  unixVfsObj.pAppData        := nil;
  unixVfsObj.xOpen           := @unixOpen;
  unixVfsObj.xDelete         := @unixDelete;
  unixVfsObj.xAccess         := @unixAccess;
  unixVfsObj.xFullPathname   := @unixFullPathname;
  unixVfsObj.xDlOpen         := nil;   { SQLITE_OMIT_LOAD_EXTENSION }
  unixVfsObj.xDlError        := nil;
  unixVfsObj.xDlSym          := nil;
  unixVfsObj.xDlClose        := nil;
  unixVfsObj.xRandomness     := @unixRandomness;
  unixVfsObj.xSleep          := @unixSleep;
  unixVfsObj.xCurrentTime    := @unixCurrentTime;
  unixVfsObj.xGetLastError   := @unixGetLastError;
  unixVfsObj.xCurrentTimeInt64 := nil; { Phase 2 TODO }
  unixVfsObj.xSetSystemCall  := nil;
  unixVfsObj.xGetSystemCall  := nil;
  unixVfsObj.xNextSystemCall := nil;

  { Register as the default VFS }
  sqlite3_vfs_register(@unixVfsObj, 1);
  Result := SQLITE_OK;
end;

{ os_unix.c ~8581: sqlite3_os_end — no-op on Linux }
function sqlite3_os_end: cint;
begin
  Result := SQLITE_OK;
end;

{ ============================================================
  Section 15: Shared-memory (SHM) functions  (os_unix.c §4550–5550)
  Used by the WAL module (Phase 3.B.3).

  UNIX_SHM_BASE: first locking byte in the -shm file (byte offset 120).
  UNIX_SHM_DMS : the "dead man's switch" byte (offset 128).
  ============================================================ }

const
  UNIX_SHM_BASE = (22 + SQLITE_SHM_NLOCK) * 4;   { = 120 }
  UNIX_SHM_DMS  = UNIX_SHM_BASE + SQLITE_SHM_NLOCK; { = 128 }

{ libc getpagesize() }
function libc_getpagesize: cint; external 'c' name 'getpagesize';

{ FpMmap / FpMunmap are in BaseUnix }
{ pwrite / pread wrappers already available as FpPWrite / FpPRead }

{ os_unix.c ~4709: unixShmSystemLock
  Apply a POSIX F_RDLCK/F_WRLCK/F_UNLCK fcntl on pShmNode->hShm.
  ofst is the byte offset in the file; n is the span. }
function unixShmSystemLock(pDbFd: PunixFile; lockType: cint;
                           ofst: cint; n: cint): cint;
var
  pShmNode : PunixShmNode;
  f        : FLock;
  res      : cint;
begin
  pShmNode := pDbFd^.pInode^.pShmNode;
  if pShmNode^.hShm < 0 then
  begin
    Result := SQLITE_OK;
    Exit;
  end;
  f.l_type   := SmallInt(lockType);
  f.l_whence := SEEK_SET;
  f.l_start  := ofst;
  f.l_len    := n;
  f.l_pid    := 0;
  res := FpFcntl(pShmNode^.hShm, F_SETLK, f);
  if res = -1 then
    Result := SQLITE_BUSY
  else
    Result := SQLITE_OK;
end;

{ os_unix.c ~4820: unixShmRegionPerMap
  Returns the minimum number of 32KB regions per mmap() call.
  On most systems (4K pages) this is 1; on 64K-page systems it is 2. }
function unixShmRegionPerMap: cint;
var
  shmsz : cint;
  pgsz  : cint;
begin
  shmsz := 32 * 1024;
  pgsz  := libc_getpagesize;
  if pgsz < shmsz then
    Result := 1
  else
    Result := pgsz div shmsz;
end;

{ os_unix.c ~4806: unixShmPurge
  Free a pShmNode whose nRef has dropped to 0. }
procedure unixShmPurge(pDbFd: PunixFile);
var
  p          : PunixShmNode;
  nShmPerMap : cint;
  i          : cint;
begin
  p := pDbFd^.pInode^.pShmNode;
  if p = nil then Exit;
  if p^.nRef <> 0 then Exit;

  nShmPerMap := unixShmRegionPerMap;
  i := 0;
  while i < p^.nRegion do
  begin
    if p^.hShm >= 0 then
      fpmunmap(PPPointer(p^.apRegion)[i], p^.szRegion * nShmPerMap)
    else
      sqlite3_free(PPPointer(p^.apRegion)[i]);
    Inc(i, nShmPerMap);
  end;
  sqlite3_free(p^.apRegion);
  if p^.pShmMutex <> nil then
    sqlite3_mutex_free(p^.pShmMutex);
  if p^.hShm >= 0 then
    FpClose(p^.hShm);
  { zFilename is NOT freed separately: it lives in the extra bytes of the
    pShmNode allocation (see unixOpenSharedMemory). sqlite3_free(p) frees all. }
  sqlite3_free(p);
  pDbFd^.pInode^.pShmNode := nil;
end;

{ os_unix.c ~4850: unixLockSharedMemory
  Implements the DMS (dead-man's-switch) locking protocol for a new pShmNode.
  Returns SQLITE_OK, SQLITE_BUSY, SQLITE_READONLY_CANTINIT, or SQLITE_IOERR_LOCK. }
function unixLockSharedMemory(pDbFd: PunixFile; pShmNode: PunixShmNode): cint;
var
  lock    : FLock;
  rc      : cint;
  shmStat : Stat;
begin
  rc := SQLITE_OK;
  lock.l_whence := SEEK_SET;
  lock.l_start  := UNIX_SHM_DMS;
  lock.l_len    := 1;
  lock.l_pid    := 0;
  lock.l_type   := SmallInt(F_WRLCK);

  if FpFcntl(pShmNode^.hShm, F_GETLK, lock) <> 0 then
  begin
    Result := SQLITE_IOERR_LOCK;
    Exit;
  end;

  if lock.l_type = SmallInt(F_UNLCK) then
  begin
    { No other process holds the DMS. We are first — truncate and take exclusive. }
    if pShmNode^.isReadonly <> 0 then
    begin
      pShmNode^.isUnlocked := 1;
      Result := SQLITE_READONLY_CANTINIT;
      Exit;
    end;
    rc := unixShmSystemLock(pDbFd, F_WRLCK, UNIX_SHM_DMS, 1);
    if rc = SQLITE_OK then
    begin
      { Only truncate when the SHM is truly empty (<= 3 bytes).
        F_GETLK does not report locks held by the calling process
        (Linux POSIX advisory lock semantics), so when two connections
        in the same process race here the second one sees F_UNLCK and
        would incorrectly truncate an already-initialized SHM.
        Checking the file size is the reliable in-process proxy. }
      if (FpFStat(pShmNode^.hShm, shmStat) <> 0) or (shmStat.st_size <= 3) then
      begin
        if FpFtruncate(pShmNode^.hShm, 3) <> 0 then
          rc := SQLITE_IOERR_SHMOPEN;
      end;
    end;
  end
  else if lock.l_type = SmallInt(F_WRLCK) then
  begin
    Result := SQLITE_BUSY;
    Exit;
  end;

  { Downgrade / take the shared DMS lock }
  if rc = SQLITE_OK then
    rc := unixShmSystemLock(pDbFd, F_RDLCK, UNIX_SHM_DMS, 1);
  Result := rc;
end;

{ os_unix.c ~4953: unixOpenSharedMemory
  Open (or attach to an existing) shared-memory segment for pDbFd.
  Creates the -shm file alongside the database file.
  Simplified from C: no global inode list; each pDbFd owns its own pShmNode
  (intra-process sharing deferred — cross-process works via mmap MAP_SHARED). }
function unixOpenSharedMemory(pDbFd: PunixFile): cint;
var
  p        : PunixShm;
  pShmNode : PunixShmNode;
  rc       : cint;
  sb       : Stat;
  zShm     : PChar;
  nShm     : cint;
  flags    : cint;
begin
  rc := SQLITE_OK;
  p  := nil;

  p := sqlite3_malloc(SizeOf(unixShm));
  if p = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
  FillChar(p^, SizeOf(unixShm), 0);

  { If pInode already has a pShmNode (intra-process sharing), reuse it }
  pShmNode := pDbFd^.pInode^.pShmNode;
  if pShmNode = nil then
  begin
    { Stat the database file to get permissions }
    if FpFStat(pDbFd^.h, sb) <> 0 then
    begin
      sqlite3_free(p);
      Result := SQLITE_IOERR_FSTAT;
      Exit;
    end;

    { Build the -shm filename: zPath + "-shm\0" }
    nShm := StrLen(pDbFd^.zPath) + 5;   { 4 for "-shm" + 1 for NUL }
    pShmNode := sqlite3_malloc(SizeOf(unixShmNode) + nShm);
    if pShmNode = nil then
    begin
      sqlite3_free(p);
      Result := SQLITE_NOMEM_BKPT;
      Exit;
    end;
    FillChar(pShmNode^, SizeOf(unixShmNode), 0);
    { zFilename sits in the extra bytes after the struct }
    zShm := PChar(PByte(pShmNode) + SizeOf(unixShmNode));
    pShmNode^.zFilename := zShm;
    StrCopy(zShm, pDbFd^.zPath);
    StrCat(zShm, '-shm');

    pShmNode^.hShm := -1;
    pShmNode^.pInode := pDbFd^.pInode;
    pDbFd^.pInode^.pShmNode := pShmNode;

    { Allocate the mutex }
    pShmNode^.pShmMutex := sqlite3_mutex_alloc(SQLITE_MUTEX_FAST);
    if pShmNode^.pShmMutex = nil then
    begin
      unixShmPurge(pDbFd);
      sqlite3_free(p);
      Result := SQLITE_NOMEM_BKPT;
      Exit;
    end;

    { Open (or create) the -shm file }
    flags := O_RDWR or O_CREAT or O_NOFOLLOW_FLAG;
    pShmNode^.hShm := FpOpen(pShmNode^.zFilename, flags,
                             sb.st_mode and $1FF);
    if pShmNode^.hShm < 0 then
    begin
      { Try read-only }
      pShmNode^.hShm := FpOpen(pShmNode^.zFilename, O_RDONLY or O_NOFOLLOW_FLAG,
                               sb.st_mode and $1FF);
      if pShmNode^.hShm < 0 then
      begin
        unixShmPurge(pDbFd);
        sqlite3_free(p);
        Result := SQLITE_CANTOPEN_BKPT;
        Exit;
      end;
      pShmNode^.isReadonly := 1;
    end;

    rc := unixLockSharedMemory(pDbFd, pShmNode);
    if (rc <> SQLITE_OK) and (rc <> SQLITE_READONLY_CANTINIT) then
    begin
      unixShmPurge(pDbFd);
      sqlite3_free(p);
      Result := rc;
      Exit;
    end;
  end;

  { Attach p to pShmNode }
  p^.pShmNode := pShmNode;
  sqlite3_mutex_enter(pShmNode^.pShmMutex);
  p^.pNext := pShmNode^.pFirst;
  pShmNode^.pFirst := p;
  Inc(pShmNode^.nRef);
  sqlite3_mutex_leave(pShmNode^.pShmMutex);
  pDbFd^.pShm := p;
  Result := rc;
end;

{ os_unix.c ~5106: unixShmMap_impl — map a 32KB wal-index page into memory.
  iPg=0 is the header page; each page is szRegion=WALINDEX_PGSZ=32768 bytes. }
function unixShmMap_impl(fd: Psqlite3_file; iRegion: cint; szRegion: cint;
                         bExtend: cint; pp: PPointer): cint; cdecl;
var
  pDbFd    : PunixFile;
  pShmNode : PunixShmNode;
  p        : PunixShm;
  rc       : cint;
  nShmPerMap : cint;
  nReqRegion : cint;
  sb       : Stat;
  nByte    : cint;
  apNew    : PPointer;
  pMem     : Pointer;
  nMap     : cint;
  pgsz     : cint;
  iPg      : cint;
  xbuf     : array[0..0] of Byte;
begin
  pp^ := nil;
  pDbFd := PunixFile(fd);
  rc := SQLITE_OK;
  nShmPerMap := unixShmRegionPerMap;

  if pDbFd^.pShm = nil then
  begin
    rc := unixOpenSharedMemory(pDbFd);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  p := pDbFd^.pShm;
  pShmNode := p^.pShmNode;
  sqlite3_mutex_enter(pShmNode^.pShmMutex);

  if pShmNode^.isUnlocked <> 0 then
  begin
    rc := unixLockSharedMemory(pDbFd, pShmNode);
    if rc <> SQLITE_OK then
    begin
      sqlite3_mutex_leave(pShmNode^.pShmMutex);
      Result := rc;
      Exit;
    end;
    pShmNode^.isUnlocked := 0;
  end;

  nReqRegion := ((iRegion + nShmPerMap) div nShmPerMap) * nShmPerMap;

  if pShmNode^.nRegion < nReqRegion then
  begin
    nByte := nReqRegion * szRegion;
    pShmNode^.szRegion := szRegion;

    if pShmNode^.hShm >= 0 then
    begin
      if FpFStat(pShmNode^.hShm, sb) <> 0 then
      begin
        rc := SQLITE_IOERR_SHMSIZE;
        sqlite3_mutex_leave(pShmNode^.pShmMutex);
        Result := rc;
        Exit;
      end;

      if sb.st_size < nByte then
      begin
        if bExtend = 0 then
        begin
          sqlite3_mutex_leave(pShmNode^.pShmMutex);
          Result := SQLITE_OK;   { *pp stays nil }
          Exit;
        end;
        { Extend: write one byte at the end of each 4096-byte page }
        pgsz := 4096;
        xbuf[0] := 0;
        iPg := sb.st_size div pgsz;
        while iPg < (nByte div pgsz) do
        begin
          if FpPWrite(pShmNode^.hShm, @xbuf[0], 1,
                      i64(iPg) * pgsz + pgsz - 1) <> 1 then
          begin
            rc := SQLITE_IOERR_SHMSIZE;
            sqlite3_mutex_leave(pShmNode^.pShmMutex);
            Result := rc;
            Exit;
          end;
          Inc(iPg);
        end;
      end;
    end;

    { Expand apRegion array }
    apNew := sqlite3_realloc(pShmNode^.apRegion,
                             nReqRegion * SizeOf(Pointer));
    if apNew = nil then
    begin
      rc := SQLITE_NOMEM_BKPT;
      sqlite3_mutex_leave(pShmNode^.pShmMutex);
      Result := rc;
      Exit;
    end;
    pShmNode^.apRegion := apNew;

    { Map new regions }
    while pShmNode^.nRegion < nReqRegion do
    begin
      nMap := szRegion * nShmPerMap;
      if pShmNode^.hShm >= 0 then
      begin
        pMem := fpmmap(nil, nMap,
            PROT_READ or PROT_WRITE,
            MAP_SHARED,
            pShmNode^.hShm,
            i64(pShmNode^.nRegion) * szRegion);
        if pMem = MAP_FAILED then
        begin
          rc := SQLITE_IOERR_SHMMAP;
          sqlite3_mutex_leave(pShmNode^.pShmMutex);
          Result := rc;
          Exit;
        end;
      end
      else
      begin
        pMem := sqlite3_malloc(nMap);
        if pMem = nil then
        begin
          rc := SQLITE_NOMEM_BKPT;
          sqlite3_mutex_leave(pShmNode^.pShmMutex);
          Result := rc;
          Exit;
        end;
        FillChar(pMem^, nMap, 0);
      end;

      { Store pointer for each sub-region within this mmap }
      iPg := 0;
      while iPg < nShmPerMap do
      begin
        PPPointer(pShmNode^.apRegion)[pShmNode^.nRegion + iPg] :=
          Pointer(PByte(pMem) + szRegion * iPg);
        Inc(iPg);
      end;
      Inc(pShmNode^.nRegion, nShmPerMap);
    end;
  end;

  if pShmNode^.nRegion > iRegion then
    pp^ := PPPointer(pShmNode^.apRegion)[iRegion];
  { else pp^ stays nil, rc stays SQLITE_OK }

  if (pShmNode^.isReadonly <> 0) and (rc = SQLITE_OK) then
    rc := SQLITE_READONLY;
  sqlite3_mutex_leave(pShmNode^.pShmMutex);
  Result := rc;
end;

{ os_unix.c ~5284: unixShmLock_impl — change lock state on SHM lock slots.
  flags: SQLITE_SHM_LOCK/UNLOCK | SQLITE_SHM_SHARED/EXCLUSIVE. }
function unixShmLock_impl(fd: Psqlite3_file; ofst: cint; n: cint;
                          flags: cint): cint; cdecl;
var
  pDbFd    : PunixFile;
  p        : PunixShm;
  pShmNode : PunixShmNode;
  rc       : cint;
  mask     : u16;
  ii       : cint;
  aLock    : PcInt;
  bUnlock  : cint;
begin
  pDbFd := PunixFile(fd);
  p := pDbFd^.pShm;
  if p = nil then begin Result := SQLITE_IOERR_SHMLOCK; Exit; end;
  pShmNode := p^.pShmNode;
  if pShmNode = nil then begin Result := SQLITE_IOERR_SHMLOCK; Exit; end;
  aLock := @pShmNode^.aLock[0];
  mask  := u16(((1 shl (ofst + n)) - (1 shl ofst)));
  rc    := SQLITE_OK;

  sqlite3_mutex_enter(pShmNode^.pShmMutex);

  if (flags and SQLITE_SHM_UNLOCK) <> 0 then
  begin
    { Unlock }
    bUnlock := 1;
    if (flags and SQLITE_SHM_SHARED) <> 0 then
    begin
      { Shared unlock: might be held by other sibling connections }
      if aLock[ofst] > 1 then
      begin
        bUnlock := 0;
        Dec(aLock[ofst]);
        p^.sharedMask := p^.sharedMask and not mask;
      end;
    end;
    if bUnlock <> 0 then
    begin
      rc := unixShmSystemLock(pDbFd, F_UNLCK, ofst + UNIX_SHM_BASE, n);
      if rc = SQLITE_OK then
      begin
        FillChar(aLock[ofst], SizeOf(cint) * n, 0);
        p^.sharedMask := p^.sharedMask and not mask;
        p^.exclMask   := p^.exclMask   and not mask;
      end;
    end;
  end
  else if (flags and SQLITE_SHM_SHARED) <> 0 then
  begin
    { Shared lock }
    if aLock[ofst] < 0 then
      rc := SQLITE_BUSY
    else if aLock[ofst] = 0 then
      rc := unixShmSystemLock(pDbFd, F_RDLCK, ofst + UNIX_SHM_BASE, n);
    if rc = SQLITE_OK then
    begin
      p^.sharedMask := p^.sharedMask or mask;
      Inc(aLock[ofst]);
    end;
  end
  else
  begin
    { Exclusive lock }
    for ii := ofst to ofst + n - 1 do
    begin
      if aLock[ii] <> 0 then
      begin
        rc := SQLITE_BUSY;
        Break;
      end;
    end;
    if rc = SQLITE_OK then
    begin
      rc := unixShmSystemLock(pDbFd, F_WRLCK, ofst + UNIX_SHM_BASE, n);
      if rc = SQLITE_OK then
      begin
        p^.exclMask := p^.exclMask or mask;
        for ii := ofst to ofst + n - 1 do
          aLock[ii] := -1;
      end;
    end;
  end;

  sqlite3_mutex_leave(pShmNode^.pShmMutex);
  Result := rc;
end;

{ os_unix.c ~5480: unixShmBarrier_impl — memory barrier. }
procedure unixShmBarrier_impl(fd: Psqlite3_file); cdecl;
begin
  { A compiler/memory barrier. On x86_64 loads/stores are ordered,
    so this only needs to prevent compiler reordering. }
  ReadWriteBarrier;  { FPC built-in memory barrier }
end;

{ os_unix.c ~5490: unixShmUnmap_impl — close shared-memory connection. }
function unixShmUnmap_impl(fd: Psqlite3_file; deleteFlag: cint): cint; cdecl;
var
  pDbFd    : PunixFile;
  p        : PunixShm;
  pShmNode : PunixShmNode;
  pp       : ^PunixShm;
begin
  pDbFd := PunixFile(fd);
  p := pDbFd^.pShm;
  if p = nil then begin Result := SQLITE_OK; Exit; end;
  pShmNode := p^.pShmNode;

  { Remove p from the pShmNode's list }
  sqlite3_mutex_enter(pShmNode^.pShmMutex);
  pp := @pShmNode^.pFirst;
  while pp^ <> p do pp := @pp^^.pNext;
  pp^ := p^.pNext;
  sqlite3_mutex_leave(pShmNode^.pShmMutex);
  sqlite3_free(p);
  pDbFd^.pShm := nil;

  { Decrement nRef and purge if zero }
  Dec(pShmNode^.nRef);
  if pShmNode^.nRef = 0 then
  begin
    if (deleteFlag <> 0) and (pShmNode^.hShm >= 0) then
      FpUnlink(pShmNode^.zFilename);
    unixShmPurge(pDbFd);
  end;
  Result := SQLITE_OK;
end;

{ ============================================================
  InitUnixIoMethods — build the unixIoMethods vtable.
  Called from the initialization section once all functions are known.
  ============================================================ }

procedure InitUnixIoMethods;
begin
  FillChar(unixIoMethods, SizeOf(unixIoMethods), 0);
  unixIoMethods.iVersion             := 2;  { v2: SHM methods active for WAL }
  unixIoMethods.xClose               := @unixClose_impl;
  unixIoMethods.xRead                := @unixRead_impl;
  unixIoMethods.xWrite               := @unixWrite_impl;
  unixIoMethods.xTruncate            := @unixTruncate_impl;
  unixIoMethods.xSync                := @unixSync_impl;
  unixIoMethods.xFileSize            := @unixFileSize_impl;
  unixIoMethods.xLock                := @unixLock_impl;
  unixIoMethods.xUnlock              := @unixUnlock_impl;
  unixIoMethods.xCheckReservedLock   := @unixCheckReservedLock_impl;
  unixIoMethods.xFileControl         := @unixFileControl_impl;
  unixIoMethods.xSectorSize          := @unixSectorSize_impl;
  unixIoMethods.xDeviceCharacteristics := @unixDeviceCharacteristics_impl;
  unixIoMethods.xShmMap     := @unixShmMap_impl;
  unixIoMethods.xShmLock    := @unixShmLock_impl;
  unixIoMethods.xShmBarrier := @unixShmBarrier_impl;
  unixIoMethods.xShmUnmap   := @unixShmUnmap_impl;
  unixIoMethods.xFetch      := nil;
  unixIoMethods.xUnfetch    := nil;
end;

{ ============================================================
  InitPthreadMutexMethods — fill in pthreadMutexMethodsData.
  ============================================================ }

procedure InitPthreadMutexMethods;
begin
  FillChar(pthreadMutexMethodsData, SizeOf(pthreadMutexMethodsData), 0);
  pthreadMutexMethodsData.xMutexInit    := @pthreadMutexInit;
  pthreadMutexMethodsData.xMutexEnd     := @pthreadMutexEnd;
  pthreadMutexMethodsData.xMutexAlloc   := @pthreadMutexAlloc;
  pthreadMutexMethodsData.xMutexFree    := @pthreadMutexFree;
  pthreadMutexMethodsData.xMutexEnter   := @pthreadMutexEnter;
  pthreadMutexMethodsData.xMutexTry     := @pthreadMutexTry;
  pthreadMutexMethodsData.xMutexLeave   := @pthreadMutexLeave;
  pthreadMutexMethodsData.xMutexHeld    := @pthreadMutexHeld;
  pthreadMutexMethodsData.xMutexNotheld := @pthreadMutexNotheld;
end;

{ ============================================================
  Initialization
  ============================================================ }

initialization
  { Build the pthreadMutex method table }
  InitPthreadMutexMethods;

  { Seed gMutexMethods so callers don't need to invoke sqlite3MutexInit first }
  gMutexMethods := pthreadMutexMethodsData;

  { Initialise static mutexes (pthreadMutexInit does the pthread_mutex_init) }
  pthreadMutexInit;

  { Build the unix I/O methods vtable }
  InitUnixIoMethods;

end.
