#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/// Spawns `argv` in a fresh pseudo-terminal.
/// Returns 0 on success and fills `pid_out` / `master_fd_out`; returns errno on failure.
int cpty_spawn(char *const argv[],
               char *const envp[],
               const char *cwd,
               unsigned short cols,
               unsigned short rows,
               pid_t *pid_out,
               int *master_fd_out);

/// Updates the terminal window size on the pty master.
int cpty_resize(int master_fd, unsigned short cols, unsigned short rows);

#endif
