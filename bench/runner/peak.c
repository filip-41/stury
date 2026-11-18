// Runs COMMAND as its child, writes the child's peak RSS in bytes to file descriptor FD, then exits as the child did.
// The runner starts every command through it because on Linux execve keeps the high-water mark of the address space it
// replaces, even after vfork or posix_spawn, so a child of the runner never reports less than the runner's own size.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: peak FD COMMAND [ARG...]\n");
        return 2;
    }
    int fd = atoi(argv[1]);
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) == -1) {
        perror("peak: report descriptor");
        return 2;
    }
    pid_t pid = fork();
    if (pid == -1) {
        perror("peak: fork");
        return 2;
    }
    if (pid == 0) {
        execvp(argv[2], argv + 2);
        fprintf(stderr, "peak: %s: %s\n", argv[2], strerror(errno));
        _exit(127);
    }
    int status;
    struct rusage usage;
    while (wait4(pid, &status, 0, &usage) == -1) {
        if (errno != EINTR) {
            perror("peak: wait4");
            return 2;
        }
    }
#ifdef __APPLE__
    long long bytes = usage.ru_maxrss;
#else
    long long bytes = (long long)usage.ru_maxrss * 1024;
#endif
    dprintf(fd, "%lld\n", bytes);
    if (WIFSIGNALED(status)) {
        signal(WTERMSIG(status), SIG_DFL);
        raise(WTERMSIG(status));
    }
    return WEXITSTATUS(status);
}
