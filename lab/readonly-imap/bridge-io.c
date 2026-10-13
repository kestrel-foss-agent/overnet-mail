/* GPL-3.0-only. Bounded synchronous IPC for the local-only IMAP lab. */
#define _GNU_SOURCE
#include "bridge-io.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define BRIDGE_TIMEOUT_MS 10000
#define BRIDGE_MAX_BYTES (10485760U + 64U)

static int64_t monotonic_ms(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) < 0)
        return -1;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void close_fd(int *fd)
{
    if (*fd >= 0) {
        close(*fd);
        *fd = -1;
    }
}

int overnet_bridge_request(const char *helper, const char *config,
                          const char *request, size_t limit,
                          unsigned char **response, size_t *length)
{
    int in[2] = {-1, -1}, out[2] = {-1, -1};
    int status = 0, result = -1;
    pid_t pid = -1;
    unsigned char *buffer = NULL;
    size_t used = 0, sent = 0, request_len;
    int64_t now = monotonic_ms(), deadline;
    int exited = 0, eof = 0;
    char *perl_env = NULL;
    const char *perl_lib = getenv("PERL5LIB");
    *response = NULL;
    *length = 0;
    if (now < 0 || helper == NULL || helper[0] != '/' ||
        config == NULL || config[0] != '/' || request == NULL ||
        limit == 0 || limit > BRIDGE_MAX_BYTES)
        return -1;
    request_len = strlen(request);
    if (request_len == 0 || request_len > 32)
        return -1;
    deadline = now + BRIDGE_TIMEOUT_MS;
    buffer = malloc(limit + 1);
    if (buffer == NULL)
        goto done;
    if (perl_lib != NULL) {
        if (strlen(perl_lib) > 16384 || asprintf(&perl_env, "PERL5LIB=%s", perl_lib) < 0)
            goto done;
    }
    if (pipe2(in, O_CLOEXEC) < 0 || pipe2(out, O_CLOEXEC) < 0)
        goto done;
    pid = fork();
    if (pid < 0)
        goto done;
    if (pid == 0) {
        struct rlimit memory = {256U * 1024U * 1024U, 256U * 1024U * 1024U};
        struct rlimit cpu = {8, 8}, core = {0, 0};
        char *const argv[] = {(char *)helper, (char *)config, NULL};
        char *const env[] = {"PATH=/usr/bin:/bin", perl_env, NULL};
        int nullfd;
        if (setpgid(0, 0) < 0 || setrlimit(RLIMIT_AS, &memory) < 0 ||
            setrlimit(RLIMIT_CPU, &cpu) < 0 || setrlimit(RLIMIT_CORE, &core) < 0)
            _exit(126);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        nullfd = open("/dev/null", O_WRONLY);
        if (nullfd < 0 || dup2(in[0], STDIN_FILENO) < 0 ||
            dup2(out[1], STDOUT_FILENO) < 0 || dup2(nullfd, STDERR_FILENO) < 0)
            _exit(126);
        /* Do not leak Dovecot's client, index, log or control descriptors. */
        closefrom(3);
        execve(helper, argv, env);
        _exit(127);
    }
    /* Either side may win the race to establish the child's private group. */
    if (setpgid(pid, pid) < 0 && errno != EACCES && errno != ESRCH)
        goto done;
    close_fd(&in[0]);
    close_fd(&out[1]);
    if (fcntl(in[1], F_SETFL, O_NONBLOCK) < 0 || fcntl(out[0], F_SETFL, O_NONBLOCK) < 0)
        goto done;
    /* Request is tiny and cannot fill a fresh pipe. Poll before writing; block
     * SIGPIPE only around write so an early-exiting helper cannot kill IMAP. */
    while (!exited || !eof) {
        struct pollfd fds[2] = {{out[0], POLLIN, 0}, {in[1], POLLOUT, 0}};
        int left, ready;
        pid_t waited;
        now = monotonic_ms();
        if (now < 0 || now >= deadline)
            goto done;
        left = (int)(deadline - now);
        if (left > 50)
            left = 50;
        ready = poll(fds, 2, left);
        if (ready < 0 && errno != EINTR)
            goto done;
        if (fds[1].revents != 0 && in[1] >= 0) {
            sigset_t mask, old, pending;
            ssize_t n;
            int had_pending;
            struct timespec zero = {0, 0};
            sigemptyset(&mask);
            sigaddset(&mask, SIGPIPE);
            if (sigprocmask(SIG_BLOCK, &mask, &old) < 0)
                goto done;
            sigpending(&pending);
            had_pending = sigismember(&pending, SIGPIPE);
            n = write(in[1], request + sent, request_len - sent);
            if (n < 0 && errno == EPIPE && !had_pending)
                (void)sigtimedwait(&mask, NULL, &zero);
            sigprocmask(SIG_SETMASK, &old, NULL);
            if (n <= 0)
                goto done;
            sent += (size_t)n;
            if (sent == request_len)
                close_fd(&in[1]);
        }
        if (fds[0].revents != 0 && out[0] >= 0) {
            ssize_t n = read(out[0], buffer + used, limit + 1 - used);
            if (n == 0) {
                eof = 1;
                close_fd(&out[0]);
            } else if (n > 0) {
                used += (size_t)n;
                if (used > limit)
                    goto done;
            } else if (errno != EINTR && errno != EAGAIN)
                goto done;
        }
        if (!exited) {
            waited = waitpid(pid, &status, WNOHANG);
            if (waited == pid)
                exited = 1;
            else if (waited < 0 && errno != EINTR)
                goto done;
        }
    }
    if (sent != request_len || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        goto done;
    buffer[used] = 0;
    *response = buffer;
    *length = used;
    buffer = NULL;
    result = 0;
done:
    close_fd(&in[0]); close_fd(&in[1]);
    close_fd(&out[0]); close_fd(&out[1]);
    if (pid > 0) {
        /* Clean any same-group descendant retaining a pipe, even after the
         * direct helper exited; the helper itself is deliberately childless. */
        kill(-pid, SIGKILL);
        if (!exited) {
            kill(pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { }
        }
    }
    free(buffer);
    free(perl_env);
    return result;
}
