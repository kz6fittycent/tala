#include "fatal_signal.h"

#include <fcntl.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

namespace {

struct Fatal {
  int number;
  const char* line;
  struct sigaction previous;
};

Fatal fatals[] = {
    {SIGSEGV, "fatal signal SIGSEGV\n", {}},
    {SIGBUS, "fatal signal SIGBUS\n", {}},
    {SIGILL, "fatal signal SIGILL\n", {}},
    {SIGFPE, "fatal signal SIGFPE\n", {}},
    {SIGABRT, "fatal signal SIGABRT\n", {}},
};

int log_fd = -1;

// Only async-signal-safe calls here: write, sigaction and raise.
void handler(int number) {
  for (Fatal& fatal : fatals) {
    if (fatal.number != number) continue;
    if (log_fd >= 0) {
      ssize_t ignored = write(log_fd, fatal.line, strlen(fatal.line));
      (void)ignored;
    }
    // What was there before takes over, ending the process as it would have.
    sigaction(number, &fatal.previous, nullptr);
    raise(number);
    return;
  }
}

}  // namespace

void fatal_signal_install() {
  g_autofree gchar* dir =
      g_build_filename(g_get_user_config_dir(), "tala", nullptr);
  if (g_mkdir_with_parents(dir, 0700) != 0) return;
  g_autofree gchar* path = g_build_filename(dir, "fatal.log", nullptr);
  log_fd = g_open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (log_fd < 0) return;
  for (Fatal& fatal : fatals) {
    struct sigaction action = {};
    action.sa_handler = handler;
    sigemptyset(&action.sa_mask);
    sigaction(fatal.number, &action, &fatal.previous);
  }
}
