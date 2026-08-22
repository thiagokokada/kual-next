#define _POSIX_C_SOURCE 200809L
#include "kual.h"

#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static KualEntry *find_entry(KualEntry *parent, const char *name) {
  for (size_t i = 0; i < parent->child_count; i++) {
    KualEntry *entry = &parent->children[i];
    if (!strcmp(entry->name, name))
      return entry;
    KualEntry *nested = find_entry(entry, name);
    if (nested)
      return nested;
  }
  return NULL;
}

static void test_stderr_redirect(void) {
  char path[] = "/tmp/kual-next-stderr.XXXXXX";
  int fd = mkstemp(path);
  assert(fd >= 0);
  assert(write(fd, "before\n", 7) == 7);
  close(fd);

  pid_t pid = fork();
  assert(pid >= 0);
  if (pid == 0) {
    assert(kual_redirect_stderr(path) == 0);
    dprintf(STDERR_FILENO, "after\n");
    _exit(0);
  }
  int status;
  assert(waitpid(pid, &status, 0) == pid);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

  fd = open(path, O_RDONLY);
  assert(fd >= 0);
  char contents[32] = {0};
  assert(read(fd, contents, sizeof(contents) - 1U) == 13);
  close(fd);
  unlink(path);
  assert(!strcmp(contents, "before\nafter\n"));
}

static void test_privilege_indicator(void) {
  assert(!strcmp(kual_privilege_indicator(true), "#"));
  assert(!strcmp(kual_privilege_indicator(false), "%"));
}

static void test_power_event_unlock(void) {
  assert(kual_power_event_is_lock("goingToScreenSaver"));
  assert(!kual_power_event_is_lock("outOfScreenSaver"));
  assert(!kual_power_event_is_lock("exitingScreenSaver"));
  assert(!kual_power_event_is_lock(NULL));
  assert(!kual_power_event_is_unlock("exitingScreenSaver", false));
  assert(kual_power_event_is_unlock("exitingScreenSaver", true));
  assert(!kual_power_event_is_unlock("outOfScreenSaver", true));
  assert(!kual_power_event_is_unlock(NULL, true));
}

int main(int argc, char **argv) {
  assert(argc == 2);
  test_stderr_redirect();
  test_privilege_indicator();
  test_power_event_unlock();
  KualMenu menu;
  KualErrors errors = {0};
  kual_menu_init(&menu, argv[1], "KindlePaperWhite5");
  assert(kual_menu_load(&menu, &errors) == 0);
  assert(errors.len == 0);
  assert(menu.extension_id_count == 2);
  assert(menu.extension_alias_count == 3);

  KualEntry *quoted = find_entry(&menu.root, "Quoted options");
  assert(quoted);
  assert(quoted->priority == 7);
  assert(!quoted->exit_menu);
  assert(quoted->checked_after);
  assert(quoted->refresh_after);
  assert(!quoted->show_status);
  assert(quoted->show_date);
  assert(!quoted->hidden);

  KualEntry *beta = find_entry(&menu.root, "Beta action");
  assert(beta && beta->priority == -5);
  assert(beta->internal_kind == KUAL_INTERNAL_STATUS);
  assert(!strcmp(beta->internal, "Ready"));

  KualEntry *breadcrumb = find_entry(&menu.root, "Breadcrumb message");
  assert(breadcrumb && breadcrumb->internal_kind == KUAL_INTERNAL_BREADCRUMB);
  assert(!strcmp(breadcrumb->internal, "Ready"));
  KualEntry *empty = find_entry(&menu.root, "Empty breadcrumb");
  assert(empty && empty->internal_kind == KUAL_INTERNAL_BREADCRUMB);
  assert(!strcmp(empty->internal, ""));
  KualEntry *status = find_entry(&menu.root, "Status message");
  assert(status && status->internal_kind == KUAL_INTERNAL_STATUS);
  assert(!strcmp(status->internal, "Working"));
  assert(status->show_status);
  KualEntry *unknown = find_entry(&menu.root, "Unknown internal");
  assert(unknown && unknown->internal_kind == KUAL_INTERNAL_NONE);
  assert(!unknown->internal);

  KualEntry *shared = find_entry(&menu.root, "Shared");
  assert(shared && shared->collated);
  assert(shared->child_count == 3);
  assert(find_entry(shared, "First"));
  assert(find_entry(shared, "Second"));
  assert(find_entry(shared, "Third"));

  KualEntry *kual = find_entry(&menu.root, "KUAL");
  assert(kual);
  assert(&menu.root.children[0] == kual);
  KualEntry *sort_btn = find_entry(kual, "Sort menu ABC");
  assert(sort_btn);
  assert(sort_btn->priority == 2);
  assert(!sort_btn->exit_menu);
  assert(sort_btn->checked_after);
  assert(sort_btn->refresh_after);
  assert(!sort_btn->show_status);

  KualEntry *quit_btn = find_entry(kual, "\xc3\x97 Quit");
  assert(quit_btn);
  assert(quit_btn->priority == 99);
  assert(quit_btn->exit_menu);
  assert(quit_btn->show_status);
  assert(!strcmp(quit_btn->action, ":"));

  kual_menu_free(&menu);
  kual_errors_free(&errors);

  /* Test Save and reset KUAL log with non-empty log file */
  FILE *logf = fopen(KUAL_DEFAULT_LOG, "w");
  if (logf) {
    fputs("test log entry\n", logf);
    fclose(logf);
    kual_menu_init(&menu, argv[1], "KindlePaperWhite5");
    assert(kual_menu_load(&menu, &errors) == 0);
    KualEntry *log_btn = find_entry(&menu.root, "Save and reset KUAL log");
    assert(log_btn);
    assert(log_btn->priority == 3);
    assert(!log_btn->exit_menu);
    assert(log_btn->checked_after);
    assert(log_btn->show_date);
    assert(!log_btn->show_status);
    kual_menu_free(&menu);
    kual_errors_free(&errors);
    unlink(KUAL_DEFAULT_LOG);
  }

  /* Test KUAL ● N when errors exist */
  kual_menu_init(&menu, argv[1], "KindlePaperWhite5");
  kual_errors_add(&errors, "/path/to/test.json", "syntax error");
  assert(kual_menu_load(&menu, &errors) == 0);
  KualEntry *kual_err = find_entry(&menu.root, "KUAL \xe2\x97\x8f 1");
  assert(kual_err);
  assert(find_entry(kual_err, "test.json: syntax error"));
  kual_menu_free(&menu);
  kual_errors_free(&errors);

  puts("host unit tests passed");
  return 0;
}
