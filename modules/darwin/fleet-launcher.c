/*
 * rh7-fleet-launcher — the program the fleet's scheduled jobs' LaunchAgents
 * start (modules/darwin/fleet-launcher.nix):
 *   rh7-fleet-launcher audit   daily device audit  (com.rh7.collector-runner)
 *   rh7-fleet-launcher restic  daily restic backup (org.rh7.restic-backup)
 *
 * It exists only to give macOS privacy protection (TCC) ONE STABLE code
 * identity to attach an optional Full Disk Access grant to, so a single grant
 * per Mac covers both jobs. TCC judges the program launchd starts, and a shell
 * script runs as its interpreter: a grant on a wrapper script would really land
 * on a nix-store bash whose path and cdhash change with every nixpkgs bump.
 *
 * So this binary is copied (not symlinked) to /usr/local/libexec, ad-hoc
 * signed once with the hardened runtime, and only replaced when
 * fleet-launcher.nix bumps launcherVersion. It spawns the real job as a CHILD
 * and waits (no exec), so it stays the responsible process and a grant on it
 * covers the job and everything the job runs.
 *
 * Because a grant makes this binary a privilege boundary, it takes NOTHING
 * from its caller that could steer what runs under the grant:
 *   - one argument, a job NAME; the target and its argv are fixed below, and
 *     both targets are root-owned paths in the system profile;
 *   - a rebuilt environment: HOME/USER/LOGNAME/SHELL from the password database,
 *     TMPDIR from confstr, a fixed PATH, and only locale variables passed
 *     through — no BASH_ENV, exported bash functions, DYLD_*, CONFIG_SERVICE_URL
 *     or PATH from whoever wrote the plist;
 *   - the hardened-runtime signature makes dyld ignore DYLD_* for this binary.
 * Started by hand (not by launchd) the caller stays the responsible process,
 * so the grant does not apply: run the job's command directly instead.
 */
#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#ifndef PROFILE_BIN /* overridable only to test the launcher itself */
#define PROFILE_BIN "/run/current-system/sw/bin"
#endif

struct job {
  const char *name;
  const char *target;
  const char *arg; /* NULL = none */
};

static const struct job JOBS[] = {
    {"audit", PROFILE_BIN "/rh7-fleet-audit", NULL},
    {"restic", PROFILE_BIN "/rh7-restic-backup", "run"},
};

static const char *PASS_ENV[] = {"LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "__CF_USER_TEXT_ENCODING"};

static volatile sig_atomic_t spawned = 0;

/* launchd signals only the job's main process (this one). Relay to the whole
 * process group — launchd makes each job its own group — so restic itself gets
 * SIGTERM and releases its repository lock, instead of running on behind a
 * shell that defers the signal until its foreground child exits. Ignore our
 * own copy first. */
static void forward(int sig) {
  if (!spawned) _exit(128 + sig);
  signal(sig, SIG_IGN);
  kill(0, sig);
}

static char *kv(const char *k, const char *v) {
  size_t n = strlen(k) + strlen(v) + 2;
  char *s = malloc(n);
  if (s) snprintf(s, n, "%s=%s", k, v);
  return s;
}

int main(int argc, char **argv) {
  const struct job *job = NULL;
  struct passwd *pw;
  char *env[16], *args[3];
  size_t i, e = 0;
  pid_t pid;
  int status, rc;

  if (argc == 2)
    for (i = 0; i < sizeof JOBS / sizeof JOBS[0]; i++)
      if (strcmp(argv[1], JOBS[i].name) == 0) job = &JOBS[i];
  if (!job) {
    fprintf(stderr, "usage: rh7-fleet-launcher audit|restic\n");
    return 2;
  }
  pw = getpwuid(getuid());
  if (!pw || !pw->pw_dir || !pw->pw_name) {
    fprintf(stderr, "rh7-fleet-launcher: no password entry for uid %d\n", (int)getuid());
    return 1;
  }
  env[e++] = kv("HOME", pw->pw_dir);
  env[e++] = kv("USER", pw->pw_name);
  env[e++] = kv("LOGNAME", pw->pw_name);
  if (pw->pw_shell && pw->pw_shell[0]) env[e++] = kv("SHELL", pw->pw_shell);
  env[e++] = kv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
#ifdef _CS_DARWIN_USER_TEMP_DIR
  {
    char tmp[PATH_MAX];
    if (confstr(_CS_DARWIN_USER_TEMP_DIR, tmp, sizeof tmp) > 0) env[e++] = kv("TMPDIR", tmp);
  }
#endif
  for (i = 0; i < sizeof PASS_ENV / sizeof PASS_ENV[0]; i++) {
    const char *v = getenv(PASS_ENV[i]);
    if (v) env[e++] = kv(PASS_ENV[i], v);
  }
  env[e] = NULL;
  for (i = 0; i < e; i++)
    if (!env[i]) {
      perror("rh7-fleet-launcher: environment");
      return 1;
    }

  args[0] = (char *)job->target;
  args[1] = (char *)job->arg;
  args[2] = NULL;
  signal(SIGTERM, forward);
  signal(SIGINT, forward);
  rc = posix_spawn(&pid, job->target, NULL, NULL, args, env);
  if (rc != 0) {
    fprintf(stderr, "rh7-fleet-launcher: cannot start %s: %s\n", job->target, strerror(rc));
    return 127;
  }
  spawned = 1;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) {
      perror("rh7-fleet-launcher: waitpid");
      return 1;
    }
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}
