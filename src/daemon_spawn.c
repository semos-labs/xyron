/* daemon_spawn.c — Double-fork daemon launcher.
 *
 * Pure C to avoid Zig runtime interference in forked children.
 * Closes all inherited fds and detaches from the terminal completely.
 */

#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <signal.h>

int daemon_spawn(const char *script, const char *logfile, const char *pidfile) {
    /* Block SIGCHLD temporarily so waitpid works reliably */
    sigset_t mask, oldmask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGCHLD);
    sigprocmask(SIG_BLOCK, &mask, &oldmask);

    pid_t p1 = fork();
    if (p1 < 0) {
        sigprocmask(SIG_SETMASK, &oldmask, NULL);
        return -1;
    }

    if (p1 == 0) {
        /* First child: detach everything immediately */
        setsid();

        /* Reset signals */
        signal(SIGCHLD, SIG_DFL);
        sigprocmask(SIG_SETMASK, &oldmask, NULL);

        /* Redirect stdin/stdout/stderr to /dev/null BEFORE second fork */
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > 2) close(devnull);
        }

        /* Close all other inherited fds */
        for (int fd = 3; fd < 1024; fd++) close(fd);

        /* Second fork */
        pid_t p2 = fork();
        if (p2 < 0) _exit(127);

        if (p2 == 0) {
            /* Grandchild: becomes the daemon */

            /* Redirect stdout/stderr to log file */
            int logfd = open(logfile, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (logfd >= 0) {
                dup2(logfd, STDOUT_FILENO);
                dup2(logfd, STDERR_FILENO);
                if (logfd > 2) close(logfd);
            }

            /* Write pid */
            int pfd = open(pidfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (pfd >= 0) {
                char buf[32];
                int n = snprintf(buf, sizeof(buf), "%d", getpid());
                write(pfd, buf, n);
                close(pfd);
            }

            /* Exec the launcher script */
            execl("/bin/sh", "/bin/sh", script, (char *)NULL);
            _exit(127);
        }

        /* First child: done */
        _exit(0);
    }

    /* Parent: wait for first child */
    int status;
    waitpid(p1, &status, 0);

    /* Restore signal mask */
    sigprocmask(SIG_SETMASK, &oldmask, NULL);

    /* Read grandchild pid from pid file */
    usleep(100000); /* 100ms for pid file write */
    int pfd = open(pidfile, O_RDONLY);
    if (pfd < 0) return -1;
    char buf[32];
    int n = read(pfd, buf, sizeof(buf) - 1);
    close(pfd);
    if (n <= 0) return -1;
    buf[n] = '\0';
    return atoi(buf);
}
