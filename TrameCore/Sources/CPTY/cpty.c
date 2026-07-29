#include "include/cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <util.h>

int cpty_spawn(char *const argv[],
               char *const envp[],
               const char *cwd,
               unsigned short cols,
               unsigned short rows,
               pid_t *pid_out,
               int *master_fd_out)
{
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols;
    ws.ws_row = rows;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return errno;
    }

    if (pid == 0) {
        /* Child: reset signal dispositions inherited from the daemon. */
        for (int sig = 1; sig < NSIG; sig++) {
            signal(sig, SIG_DFL);
        }
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);

        if (cwd != NULL && chdir(cwd) != 0) {
            _exit(126);
        }
        execve(argv[0], argv, envp);
        _exit(127);
    }

    /* Parent: hand the master fd over in non-blocking mode. */
    int flags = fcntl(master, F_GETFL, 0);
    fcntl(master, F_SETFL, flags | O_NONBLOCK);

    *pid_out = pid;
    *master_fd_out = master;
    return 0;
}

int cpty_resize(int master_fd, unsigned short cols, unsigned short rows)
{
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols;
    ws.ws_row = rows;
    if (ioctl(master_fd, TIOCSWINSZ, &ws) != 0) {
        return errno;
    }
    return 0;
}
