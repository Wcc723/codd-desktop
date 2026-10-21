#include "CCoddShim.h"

#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

/// Upper bound for the close loop when proc_pidinfo is unavailable.
#define CODD_FALLBACK_FD_LIMIT 65536

int codd_highest_open_fd(void) {
    int needed = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (needed <= 0) {
        return -1;
    }
    // Leave headroom in case descriptors were opened between the two calls.
    int capacity = needed + (int)(32 * sizeof(struct proc_fdinfo));
    struct proc_fdinfo *infos = malloc((size_t)capacity);
    if (infos == NULL) {
        return -1;
    }
    int filled = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, infos, capacity);
    if (filled <= 0) {
        free(infos);
        return -1;
    }
    int count = filled / (int)sizeof(struct proc_fdinfo);
    int highest = 2;
    for (int i = 0; i < count; i++) {
        if (infos[i].proc_fd > highest) {
            highest = infos[i].proc_fd;
        }
    }
    free(infos);
    return highest;
}

/// Writes the failing stage and errno to the error pipe and terminates the child.
/// Only async-signal-safe calls.
static void codd_child_fail(int pipe_fd, int stage) {
    int payload[2] = { stage, errno };
    ssize_t ignored = write(pipe_fd, payload, sizeof(payload));
    (void)ignored;
    _exit(stage == CODD_SPAWN_STAGE_EXEC && payload[1] == ENOENT ? 127 : 126);
}

/// Runs in the forked child. Only async-signal-safe calls from here until execve.
static void codd_child_main(const codd_pty_spawn_request *request, int slave, int pipe_fd, int highest_fd) {
    // Become session leader and take the PTY slave as the controlling terminal.
    if (setsid() < 0) {
        codd_child_fail(pipe_fd, CODD_SPAWN_STAGE_TTY);
    }
    if (ioctl(slave, TIOCSCTTY, 0) < 0) {
        codd_child_fail(pipe_fd, CODD_SPAWN_STAGE_TTY);
    }
    for (int target = 0; target <= 2; target++) {
        if (dup2(slave, target) < 0) {
            codd_child_fail(pipe_fd, CODD_SPAWN_STAGE_TTY);
        }
    }
    // Close every other descriptor, including ones inherited without FD_CLOEXEC.
    // The error pipe stays open until execve (it is FD_CLOEXEC, so a successful exec closes it).
    for (int fd = 3; fd <= highest_fd; fd++) {
        if (fd != pipe_fd) {
            close(fd);
        }
    }
    // The holder ignores SIGPIPE and friends; ignored dispositions survive execve, so reset them all.
    struct sigaction default_action;
    memset(&default_action, 0, sizeof(default_action));
    default_action.sa_handler = SIG_DFL;
    sigemptyset(&default_action.sa_mask);
    for (int sig = 1; sig < NSIG; sig++) {
        if (sig != SIGKILL && sig != SIGSTOP) {
            sigaction(sig, &default_action, NULL);
        }
    }
    sigset_t empty_mask;
    sigemptyset(&empty_mask);
    sigprocmask(SIG_SETMASK, &empty_mask, NULL);

    if (request->cwd != NULL && chdir(request->cwd) < 0) {
        codd_child_fail(pipe_fd, CODD_SPAWN_STAGE_CHDIR);
    }
    execve(request->path, request->argv, request->envp);
    codd_child_fail(pipe_fd, CODD_SPAWN_STAGE_EXEC);
}

int codd_pty_spawn(const codd_pty_spawn_request *request, codd_pty_spawn_result *result) {
    memset(result, 0, sizeof(*result));
    result->master_fd = -1;

    int master = -1;
    int slave = -1;
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_col = request->cols;
    size.ws_row = request->rows;
    if (openpty(&master, &slave, NULL, NULL, &size) != 0) {
        return -1;
    }
    struct termios attributes;
    if (tcgetattr(slave, &attributes) == 0) {
        attributes.c_iflag |= IUTF8;
        tcsetattr(slave, TCSANOW, &attributes);
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    fcntl(slave, F_SETFD, FD_CLOEXEC);

    int error_pipe[2];
    if (pipe(error_pipe) != 0) {
        int saved = errno;
        close(master);
        close(slave);
        errno = saved;
        return -1;
    }
    fcntl(error_pipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(error_pipe[1], F_SETFD, FD_CLOEXEC);

    // Computed before fork: proc_pidinfo allocates, which is not allowed in the child.
    int highest_fd = codd_highest_open_fd();
    if (highest_fd < 0) {
        struct rlimit limit;
        if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < CODD_FALLBACK_FD_LIMIT) {
            highest_fd = (int)limit.rlim_cur;
        } else {
            highest_fd = CODD_FALLBACK_FD_LIMIT;
        }
    }

    pid_t pid = fork();
    if (pid < 0) {
        int saved = errno;
        close(master);
        close(slave);
        close(error_pipe[0]);
        close(error_pipe[1]);
        errno = saved;
        return -1;
    }
    if (pid == 0) {
        close(master);
        close(error_pipe[0]);
        codd_child_main(request, slave, error_pipe[1], highest_fd);
        _exit(126); // not reached
    }

    close(slave);
    close(error_pipe[1]);
    int payload[2] = { 0, 0 };
    size_t received = 0;
    while (received < sizeof(payload)) {
        ssize_t n = read(error_pipe[0], ((char *)payload) + received, sizeof(payload) - received);
        if (n > 0) {
            received += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break; // EOF: execve succeeded and closed the CLOEXEC pipe.
        }
    }
    close(error_pipe[0]);

    result->pid = pid;
    result->master_fd = master;
    if (received == sizeof(payload)) {
        result->failed_stage = payload[0];
        result->failed_errno = payload[1];
    }
    return 0;
}

int codd_set_winsize(int fd, uint16_t cols, uint16_t rows, uint16_t xpixel, uint16_t ypixel) {
    struct winsize size;
    size.ws_col = cols;
    size.ws_row = rows;
    size.ws_xpixel = xpixel;
    size.ws_ypixel = ypixel;
    return ioctl(fd, TIOCSWINSZ, &size);
}

int codd_get_winsize(int fd, uint16_t *cols, uint16_t *rows, uint16_t *xpixel, uint16_t *ypixel) {
    struct winsize size;
    memset(&size, 0, sizeof(size));
    if (ioctl(fd, TIOCGWINSZ, &size) < 0) {
        return -1;
    }
    if (cols) *cols = size.ws_col;
    if (rows) *rows = size.ws_row;
    if (xpixel) *xpixel = size.ws_xpixel;
    if (ypixel) *ypixel = size.ws_ypixel;
    return 0;
}

void codd_store_release_u64(void *address, uint64_t value) {
    atomic_store_explicit((_Atomic uint64_t *)address, value, memory_order_release);
}

uint64_t codd_load_acquire_u64(const void *address) {
    return atomic_load_explicit((const _Atomic uint64_t *)address, memory_order_acquire);
}

int codd_decode_wait_status(int status, int *value, int *signaled) {
    if (WIFEXITED(status)) {
        *value = WEXITSTATUS(status);
        *signaled = 0;
        return 1;
    }
    if (WIFSIGNALED(status)) {
        *value = WTERMSIG(status);
        *signaled = 1;
        return 1;
    }
    return 0;
}

char *const *codd_environ(void) {
    return *_NSGetEnviron();
}

int codd_executable_path(char *buffer, uint32_t size) {
    uint32_t length = size;
    return _NSGetExecutablePath(buffer, &length) == 0 ? 0 : -1;
}

int codd_process_path(pid_t pid, char *buffer, uint32_t size) {
    int length = proc_pidpath(pid, buffer, size);
    return length > 0 ? length : -1;
}

int codd_list_pids(pid_t *buffer, int capacity) {
    if (capacity < 0 || capacity > (1 << 24)) {
        return -1;
    }
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, buffer, buffer == NULL ? 0 : capacity * (int)sizeof(pid_t));
    return bytes < 0 ? -1 : bytes / (int)sizeof(pid_t);
}
