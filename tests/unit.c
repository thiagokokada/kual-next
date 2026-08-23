#define _POSIX_C_SOURCE 200809L
#include "kual.h"

#include <assert.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
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

static void write_text(const char *path, const char *text) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  assert(fd >= 0);
  size_t len = strlen(text), used = 0;
  while (used < len) {
    ssize_t written = write(fd, text + used, len - used);
    assert(written > 0);
    used += (size_t)written;
  }
  assert(close(fd) == 0);
}

static void assert_text(const char *path, const char *expected) {
  size_t len = 0;
  char *actual = kual_read_file(path, &len);
  assert(actual);
  assert(len == strlen(expected));
  assert(!memcmp(actual, expected, len));
  free(actual);
}

static void test_sort_mode_update(void) {
  char directory[] = "/tmp/kual-next-sort.XXXXXX";
  assert(mkdtemp(directory));
  char *config_path = kual_join_path(directory, "KUAL.cfg");

  assert(kual_set_sort_mode(directory, "123") == 0);
  size_t created_len = 0;
  char *created = kual_read_file(config_path, &created_len);
  assert(created && created_len > 0);
  assert(strstr(created, "# KUAL.cfg - created by KUAL Next on "));
  assert(strstr(created, "KUAL_sort_mode=\"123\"\n"));
  free(created);

  const char *existing = "# preserved comment\n"
                         "  KUAL_sort_mode = \"ABC!\"\n"
                         "KUAL_collate=\"false\"\n"
                         "KUAL_sort_mode='ABC'\n"
                         "trailing text without newline";
  const char *updated = "# preserved comment\n"
                        "KUAL_sort_mode=\"123\"\n"
                        "KUAL_collate=\"false\"\n"
                        "KUAL_sort_mode=\"123\"\n"
                        "trailing text without newline";
  write_text(config_path, existing);
  assert(chmod(config_path, 0600) == 0);
  assert(kual_set_sort_mode(directory, "123") == 0);
  assert_text(config_path, updated);
  struct stat st;
  assert(stat(config_path, &st) == 0);
  assert((st.st_mode & 0777) == 0600);

  write_text(config_path, "KUAL_collate=\"true\"");
  assert(kual_set_sort_mode(directory, "ABC") == 0);
  assert_text(config_path, "KUAL_collate=\"true\"\nKUAL_sort_mode=\"ABC\"\n");

  write_text(config_path, "KUAL_sort_mode=\"ABC!\"\n");
  KualMenu menu;
  KualErrors errors = {0};
  kual_menu_init(&menu, directory, "KindlePaperWhite5");
  assert(kual_menu_load(&menu, &errors) == 0);
  assert(errors.len == 0);
  KualEntry *special = find_entry(&menu.root, "Sort menu 123");
  assert(special);
  assert(special->builtin_action == KUAL_BUILTIN_SORT_123);
  assert(!special->action);
  kual_menu_free(&menu);
  kual_errors_free(&errors);

  assert(kual_set_sort_mode(directory, "123") == 0);
  KualConfig config;
  kual_config_init(&config);
  assert(kual_config_load(&config, config_path, &errors) == 0);
  assert(!strcmp(kual_config_get(&config, "sort_mode"), "123"));
  kual_config_free(&config);
  kual_errors_free(&errors);

  write_text(config_path, "KUAL_sort_mode=\"ABC!\"\n# still here\n");
  assert(chmod(directory, 0500) == 0);
  assert(kual_set_sort_mode(directory, "123") == -1);
  assert(chmod(directory, 0700) == 0);
  assert_text(config_path, "KUAL_sort_mode=\"ABC!\"\n# still here\n");

  assert(unlink(config_path) == 0);
  free(config_path);
  assert(rmdir(directory) == 0);
}

static void test_log_archive(void) {
  char directory[] = "/tmp/kual-next-log.XXXXXX";
  assert(mkdtemp(directory));
  char *documents = kual_join_path(directory, "documents");
  assert(mkdir(documents, 0700) == 0);
  char *source = kual_join_path(directory, "kual-next.log");
  char *expected = kual_join_path(documents, "KUAL-1970-01-01T00.00+00.00.txt");

  write_text(expected, "old archive\n");
  write_text(source, "first line\nsecond line\n");
  assert(chmod(source, 0600) == 0);
  char *destination = NULL;
  assert(kual_archive_log(source, documents, 0, &destination) == 0);
  assert(destination && !strcmp(destination, expected));
  assert(access(source, F_OK) != 0);
  assert_text(expected, "first line\nsecond line\n");
  struct stat st;
  assert(stat(expected, &st) == 0);
  assert((st.st_mode & 0777) == 0600);
  free(destination);

  write_text(source, "preserve on failure\n");
  char *missing = kual_join_path(directory, "missing/documents");
  assert(kual_archive_log(source, missing, 0, NULL) == -1);
  assert_text(source, "preserve on failure\n");
  free(missing);

  DIR *dir = opendir(documents);
  assert(dir);
  struct dirent *entry;
  while ((entry = readdir(dir)))
    assert(strncmp(entry->d_name, ".kual-next-log.", 15));
  closedir(dir);

  assert(unlink(source) == 0);
  assert(unlink(expected) == 0);
  assert(rmdir(documents) == 0);
  assert(rmdir(directory) == 0);
  free(expected);
  free(source);
  free(documents);
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
  test_sort_mode_update();
  test_log_archive();
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
  assert(sort_btn->builtin_action == KUAL_BUILTIN_SORT_ABC);
  assert(!sort_btn->action);

  KualEntry *quit_btn = find_entry(kual, "\xc3\x97 Quit");
  assert(quit_btn);
  assert(quit_btn->priority == 99);
  assert(quit_btn->exit_menu);
  assert(quit_btn->show_status);
  assert(quit_btn->builtin_action == KUAL_BUILTIN_QUIT);
  assert(!quit_btn->action);

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
    assert(log_btn->builtin_action == KUAL_BUILTIN_SAVE_LOG);
    assert(!log_btn->action);
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
