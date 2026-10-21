// CCoddShim: the few Darwin operations that cannot be expressed safely (or at all) from Swift.
//
// - The fork/exec path for the PTY child: between fork() and execve() the child may only call
//   async-signal-safe functions, so this lives in C where no runtime code can run.
// - ioctl requests built from function-like macros (TIOCSWINSZ / TIOCGWINSZ), which Swift cannot import.
// - Acquire/release accessors for the ring header shared with other processes through mmap.
// - libproc / crt_externs helpers that are not exposed by the Swift Darwin module.

#ifndef CCODDSHIM_H
#define CCODDSHIM_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Parameters for codd_pty_spawn. All pointers must stay valid for the duration of the call.
typedef struct {
    /// Executable path passed to execve (already resolved against PATH by the caller).
    const char *path;
    /// NULL-terminated argument vector.
    char *const *argv;
    /// NULL-terminated environment ("KEY=VALUE" entries). The child gets exactly this environment.
    char *const *envp;
    /// Working directory for the child, or NULL to keep the caller's.
    const char *cwd;
    uint16_t cols;
    uint16_t rows;
} codd_pty_spawn_request;

/// Child setup step that failed (reported back through a CLOEXEC pipe).
enum {
    CODD_SPAWN_STAGE_NONE = 0,
    CODD_SPAWN_STAGE_CHDIR = 1,
    CODD_SPAWN_STAGE_EXEC = 2,
    CODD_SPAWN_STAGE_TTY = 3,
};

typedef struct {
    /// Child pid (> 0) when the fork succeeded. The child may already have exited if exec failed.
    pid_t pid;
    /// PTY master, FD_CLOEXEC set, blocking mode (the caller switches it to O_NONBLOCK).
    int master_fd;
    /// CODD_SPAWN_STAGE_* of the failing child step, or CODD_SPAWN_STAGE_NONE when execve succeeded.
    int failed_stage;
    /// errno of the failing child step.
    int failed_errno;
} codd_pty_spawn_result;

/// openpty + fork; the child becomes a session leader with the PTY slave as its controlling terminal
/// and as fds 0/1/2, closes every other descriptor, resets signal dispositions and mask, chdirs and execs.
/// The slave termios gets IUTF8. Returns 0 on success (see result->failed_stage for exec failures)
/// or -1 with errno set when the parent-side setup (openpty, pipe, fork) failed.
int codd_pty_spawn(const codd_pty_spawn_request *request, codd_pty_spawn_result *result);

/// TIOCSWINSZ on fd. Returns 0 or -1 with errno.
int codd_set_winsize(int fd, uint16_t cols, uint16_t rows, uint16_t xpixel, uint16_t ypixel);

/// TIOCGWINSZ on fd. Returns 0 or -1 with errno.
int codd_get_winsize(int fd, uint16_t *cols, uint16_t *rows, uint16_t *xpixel, uint16_t *ypixel);

/// Release store / acquire load of an 8-byte aligned u64 in shared memory.
void codd_store_release_u64(void *address, uint64_t value);
uint64_t codd_load_acquire_u64(const void *address);

/// Decodes a waitpid status. Returns 1 when the process terminated (value = exit code or signal number,
/// *signaled = 0/1), 0 when it only stopped or continued.
int codd_decode_wait_status(int status, int *value, int *signaled);

/// Highest open file descriptor of this process (via proc_pidinfo), or -1 if unknown.
int codd_highest_open_fd(void);

/// The process environment (_NSGetEnviron), NULL-terminated.
char *const *codd_environ(void);

/// Path of the running executable into buffer. Returns 0 or -1.
int codd_executable_path(char *buffer, uint32_t size);

/// Executable path of another process into buffer (proc_pidpath). Returns the length or -1.
int codd_process_path(pid_t pid, char *buffer, uint32_t size);

/// Pids of all processes (proc_listpids(PROC_ALL_PIDS)) into buffer. Returns the number written,
/// or with buffer == NULL an estimate of the number of processes; -1 on failure.
int codd_list_pids(pid_t *buffer, int capacity);

#ifdef __cplusplus
}
#endif

#endif
