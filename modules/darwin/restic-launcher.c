/*
 * rh7-restic-launcher — the program org.rh7.restic-backup's LaunchAgent starts.
 *
 * It exists only to give macOS privacy protection (TCC) a STABLE code identity
 * to attach an optional Full Disk Access grant to. TCC judges the program
 * launchd starts, and a shell script runs as its interpreter: a grant on
 * /run/current-system/sw/bin/rh7-restic-backup (a script) would really land on
 * a nix-store bash whose path and cdhash change with every nixpkgs bump.
 *
 * So this binary is copied (not symlinked) to /usr/local/libexec, ad-hoc
 * signed once, and only replaced when modules/darwin/restic-backup.nix bumps
 * launcherVersion. It spawns the real job as a CHILD and waits (no exec), so it
 * stays the responsible process and a grant on it covers the script and the
 * restic it runs. Everything else lives behind the stable wrapper path below,
 * which changes freely with each generation.
 */
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#ifndef TARGET /* overridable only to test the launcher itself */
#define TARGET "/run/current-system/sw/bin/rh7-restic-backup"
#endif

extern char **environ;

static volatile sig_atomic_t spawned = 0;

/* launchd signals only the job's main process (this one). Relay to the whole
 * process group — launchd makes each job its own group — so restic itself gets
 * SIGTERM and releases its repository lock, instead of running on behind a
 * shell that defers the signal until its foreground child exits. Ignore our
 * own copy first. Started by hand (not by launchd), the group is the caller's
 * job: run rh7-restic-backup directly instead. */
static void forward(int sig) {
  if (!spawned) _exit(128 + sig);
  signal(sig, SIG_IGN);
  kill(0, sig);
}

int main(int argc, char **argv) {
  (void)argc;
  pid_t pid;
  int status, rc;

  argv[0] = TARGET;
  signal(SIGTERM, forward);
  signal(SIGINT, forward);
  rc = posix_spawn(&pid, TARGET, NULL, NULL, argv, environ);
  if (rc != 0) {
    fprintf(stderr, "rh7-restic-launcher: cannot start %s: %s\n", TARGET, strerror(rc));
    return 127;
  }
  spawned = 1;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) {
      perror("rh7-restic-launcher: waitpid");
      return 1;
    }
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}
