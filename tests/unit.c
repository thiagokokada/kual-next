#define _POSIX_C_SOURCE 200809L
#include "kual.h"

#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
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

  /* Opening a directory succeeds on Linux, so this exercises cleanup after
   * the temporary archive has been created and the subsequent read fails. */
  assert(kual_archive_log(directory, documents, 0, NULL) == -1);
  assert_text(expected, "first line\nsecond line\n");

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

  assert(kual_privilege_mode(true, false) == KUAL_PRIVILEGE_ROOT);
  assert(kual_privilege_mode(true, true) == KUAL_PRIVILEGE_ROOT);
  assert(kual_privilege_mode(false, true) == KUAL_PRIVILEGE_GANDALF);
  assert(kual_privilege_mode(false, false) == KUAL_PRIVILEGE_USER);
  assert(!strcmp(kual_privilege_mode_indicator(KUAL_PRIVILEGE_ROOT), "#"));
  assert(!strcmp(kual_privilege_mode_indicator(KUAL_PRIVILEGE_GANDALF), "$"));
  assert(!strcmp(kual_privilege_mode_indicator(KUAL_PRIVILEGE_USER), "%"));
}

static void test_exec_spec(void) {
  KualExecSpec spec;
  kual_exec_spec(KUAL_PRIVILEGE_USER, "echo user", &spec);
  assert(!strcmp(spec.path, "/bin/sh"));
  assert(!strcmp(spec.argv[0], "sh"));
  assert(!strcmp(spec.argv[1], "-c"));
  assert(!strcmp(spec.argv[2], "echo user"));
  assert(!spec.argv[3]);

  kual_exec_spec(KUAL_PRIVILEGE_ROOT, "echo root", &spec);
  assert(!strcmp(spec.path, "/bin/sh"));
  assert(!strcmp(spec.argv[2], "echo root"));

  kual_exec_spec(KUAL_PRIVILEGE_GANDALF, "echo gandalf", &spec);
  assert(!strcmp(spec.path, "/var/local/mkk/su"));
  assert(!strcmp(spec.argv[0], "su"));
  assert(!strcmp(spec.argv[1], "-s"));
  assert(!strcmp(spec.argv[2], "/bin/ash"));
  assert(!strcmp(spec.argv[3], "-c"));
  assert(!strcmp(spec.argv[4], "echo gandalf"));
  assert(!spec.argv[5]);
}

static void test_known_offender_cleanup(void) {
  char script[] = "/tmp/kual-next-killall.XXXXXX";
  int fd = mkstemp(script);
  assert(fd >= 0);
  close(fd);
  write_text(script, "#!/bin/sh\nprintf '%s\\n' \"$@\" "
                     ">\"$KUAL_TEST_KILLALL_ARGS\"\n");
  assert(chmod(script, 0700) == 0);

  char output[] = "/tmp/kual-next-killall-args.XXXXXX";
  fd = mkstemp(output);
  assert(fd >= 0);
  close(fd);
  assert(setenv("KUAL_TEST_KILLALL_ARGS", output, 1) == 0);
  assert(kual_cleanup_known_offenders(script) == 0);
  assert_text(output, "matchbox-keyboard\nkterm\nskipstone\ncr3\n");
  assert(kual_cleanup_known_offenders(NULL) == -1);
  assert(errno == EINVAL);

  unsetenv("KUAL_TEST_KILLALL_ARGS");
  assert(unlink(output) == 0);
  assert(unlink(script) == 0);
}

static void test_ui_config(void) {
  KualConfig config;
  kual_config_init(&config);
  assert(kual_config_page_size(&config, KUAL_DEFAULT_PAGE_ROWS) ==
         KUAL_DEFAULT_PAGE_ROWS);
  assert(kual_config_show_status(&config));

  kual_config_set(&config, "page_size", "5");
  assert(kual_config_page_size(&config, KUAL_DEFAULT_PAGE_ROWS) == 5U);
  kual_config_set(&config, "page_size", "0");
  assert(kual_config_page_size(&config, KUAL_DEFAULT_PAGE_ROWS) ==
         KUAL_DEFAULT_PAGE_ROWS);
  kual_config_set(&config, "page_size", "invalid");
  assert(kual_config_page_size(&config, KUAL_DEFAULT_PAGE_ROWS) ==
         KUAL_DEFAULT_PAGE_ROWS);

  kual_config_set(&config, "no_show_status", "true");
  assert(!kual_config_show_status(&config));
  kual_config_set(&config, "no_show_status", "TRUE");
  assert(!kual_config_show_status(&config));
  kual_config_set(&config, "no_show_status", "false");
  assert(kual_config_show_status(&config));
  kual_config_free(&config);
}

static void test_status_routing(void) {
  char footer[32] = "footer", breadcrumb[32] = "breadcrumb";
  kual_route_status(true, footer, sizeof(footer), breadcrumb,
                    sizeof(breadcrumb), "in footer");
  assert(!strcmp(footer, "in footer"));
  assert(!strcmp(breadcrumb, "breadcrumb"));

  kual_route_status(false, footer, sizeof(footer), breadcrumb,
                    sizeof(breadcrumb), "in breadcrumb");
  assert(!strcmp(footer, "in footer"));
  assert(!strcmp(breadcrumb, "in breadcrumb"));
}

static void test_navigation(void) {
  KualNavigation navigation;
  kual_navigation_init(&navigation);
  assert(navigation.depth == 0U);
  assert(kual_navigation_page(&navigation) == 0U);

  kual_navigation_next_page(&navigation, 3U);
  assert(kual_navigation_page(&navigation) == 1U);
  assert(kual_navigation_enter(&navigation));
  assert(navigation.depth == 1U);
  assert(kual_navigation_page(&navigation) == 0U);
  kual_navigation_next_page(&navigation, 4U);
  kual_navigation_next_page(&navigation, 4U);
  assert(kual_navigation_page(&navigation) == 2U);

  kual_navigation_back(&navigation);
  assert(navigation.depth == 0U);
  assert(kual_navigation_page(&navigation) == 1U);
  assert(kual_navigation_enter(&navigation));
  assert(kual_navigation_page(&navigation) == 0U);
  kual_navigation_top(&navigation);
  assert(navigation.depth == 0U);
  assert(kual_navigation_page(&navigation) == 1U);

  navigation.depth = KUAL_MAX_DEPTH;
  assert(!kual_navigation_enter(&navigation));
}

static void test_power_event_unlock(void) {
  assert(!kual_power_event_is_unlock("exitingScreenSaver", false));
  assert(kual_power_event_is_unlock("exitingScreenSaver", true));
  assert(!kual_power_event_is_unlock("outOfScreenSaver", true));
  assert(!kual_power_event_is_unlock(NULL, true));
}

static uint16_t x11_test_get16(const unsigned char *p) {
  return (uint16_t)p[0] | (uint16_t)((uint16_t)p[1] << 8U);
}

static uint32_t x11_test_get32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8U) | ((uint32_t)p[2] << 16U) |
         ((uint32_t)p[3] << 24U);
}

static void x11_test_put16(unsigned char *p, uint16_t value) {
  p[0] = (unsigned char)(value & 0xffU);
  p[1] = (unsigned char)(value >> 8U);
}

static void x11_test_put32(unsigned char *p, uint32_t value) {
  p[0] = (unsigned char)(value & 0xffU);
  p[1] = (unsigned char)((value >> 8U) & 0xffU);
  p[2] = (unsigned char)((value >> 16U) & 0xffU);
  p[3] = (unsigned char)(value >> 24U);
}

static void x11_test_read_all(int fd, void *buffer, size_t size) {
  unsigned char *p = buffer;
  while (size) {
    ssize_t got = read(fd, p, size);
    assert(got > 0);
    p += (size_t)got;
    size -= (size_t)got;
  }
}

static void x11_test_write_all(int fd, const void *buffer, size_t size) {
  const unsigned char *p = buffer;
  while (size) {
    ssize_t written = write(fd, p, size);
    assert(written > 0);
    p += (size_t)written;
    size -= (size_t)written;
  }
}

static size_t x11_test_read_request(int fd, unsigned char *request,
                                    size_t capacity) {
  x11_test_read_all(fd, request, 4U);
  size_t size = (size_t)x11_test_get16(request + 2U) * 4U;
  assert(size >= 4U && size <= capacity);
  x11_test_read_all(fd, request + 4U, size - 4U);
  return size;
}

static void x11_test_send_setup(int fd) {
  unsigned char prefix[8] = {1, 0, 11, 0, 0, 0, 18, 0};
  unsigned char extra[72] = {0};
  x11_test_put32(extra + 4U, 0x02000000U);
  x11_test_put32(extra + 8U, 0x001fffffU);
  extra[20U] = 1U;
  x11_test_put32(extra + 32U, 0x00000100U);
  x11_test_put32(extra + 40U, 0x00ffffffU);
  x11_test_put16(extra + 52U, 1272U);
  x11_test_put16(extra + 54U, 1696U);
  x11_test_write_all(fd, prefix, sizeof(prefix));
  x11_test_write_all(fd, extra, sizeof(extra));
}

static void x11_test_server(int fd, bool shape_available) {
  unsigned char setup[12];
  x11_test_read_all(fd, setup, sizeof(setup));
  assert(setup[0] == 'l');
  assert(x11_test_get16(setup + 2U) == 11U);
  x11_test_send_setup(fd);

  unsigned char request[256];
  size_t size = x11_test_read_request(fd, request, sizeof(request));
  assert(size == 16U && request[0] == 98U);
  assert(x11_test_get16(request + 4U) == 5U);
  assert(!memcmp(request + 8U, "SHAPE", 5U));
  unsigned char extension_reply[32] = {1, 0, 1, 0};
  extension_reply[8U] = shape_available ? 1U : 0U;
  extension_reply[9U] = shape_available ? 130U : 0U;
  x11_test_write_all(fd, extension_reply, sizeof(extension_reply));
  if (!shape_available) {
    close(fd);
    _exit(0);
  }

  size = x11_test_read_request(fd, request, sizeof(request));
  assert(size == 4U && request[0] == 130U && request[1] == 0U);
  unsigned char version_reply[32] = {1, 0, 2, 0};
  x11_test_put16(version_reply + 8U, 1U);
  x11_test_put16(version_reply + 10U, 1U);
  x11_test_write_all(fd, version_reply, sizeof(version_reply));

  size = x11_test_read_request(fd, request, sizeof(request));
  assert(size == 40U && request[0] == 1U);
  assert(x11_test_get32(request + 4U) == 0x02000001U);
  assert(x11_test_get32(request + 8U) == 0x00000100U);
  assert(x11_test_get16(request + 16U) == 1272U);
  assert(x11_test_get16(request + 18U) == 1696U);

  size = x11_test_read_request(fd, request, sizeof(request));
  assert(request[0] == 18U && x11_test_get32(request + 8U) == 39U);
  assert(x11_test_get32(request + 20U) ==
         strlen("L:A_N:application_PC:N_O:UDRL_ID:kual-next-owner"));
  assert(!memcmp(request + 24U,
                 "L:A_N:application_PC:N_O:UDRL_ID:kual-next-owner",
                 strlen("L:A_N:application_PC:N_O:UDRL_ID:kual-next-owner")));
  assert(size >= 24U);

  size = x11_test_read_request(fd, request, sizeof(request));
  assert(request[0] == 18U && x11_test_get32(request + 8U) == 67U);
  assert(x11_test_get32(request + 20U) == 19U);
  assert(!memcmp(request + 24U, "kual-next\0KualNext\0", 19U));
  assert(size >= 44U);

  size = x11_test_read_request(fd, request, sizeof(request));
  assert(size == 16U && request[0] == 130U && request[1] == 1U);
  assert(request[4U] == 0U && request[5U] == 2U);
  assert(x11_test_get32(request + 8U) == 0x02000001U);

  size = x11_test_read_request(fd, request, sizeof(request));
  assert(size == 8U && request[0] == 8U);
  size = x11_test_read_request(fd, request, sizeof(request));
  assert(size == 4U && request[0] == 43U);

  unsigned char map[32] = {19, 0, 7, 0};
  x11_test_put32(map + 4U, 0x00000100U);
  x11_test_put32(map + 8U, 0x02000001U);
  unsigned char focus_reply[32] = {1, 0, 8, 0};
  x11_test_write_all(fd, map, sizeof(map));
  x11_test_write_all(fd, focus_reply, sizeof(focus_reply));

  unsigned char configure[32] = {22, 0, 9, 0};
  x11_test_put32(configure + 4U, 0x00000100U);
  x11_test_put32(configure + 8U, 0x02000001U);
  x11_test_put16(configure + 20U, 1696U);
  x11_test_put16(configure + 22U, 1272U);
  x11_test_write_all(fd, configure, sizeof(configure));

  size = x11_test_read_request(fd, request, sizeof(request));
  assert(size == 8U && request[0] == 4U);
  assert(x11_test_get32(request + 4U) == 0x02000001U);
  close(fd);
  _exit(0);
}

static void test_x11_owner(void) {
  int sockets[2];
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
  pid_t pid = fork();
  assert(pid >= 0);
  if (pid == 0) {
    close(sockets[0]);
    x11_test_server(sockets[1], true);
  }
  close(sockets[1]);
  KualX11Owner owner;
  assert(kual_x11_owner_open_fd(&owner, sockets[0]) == 0);
  assert(owner.mapped);
  assert(owner.width == 1272U && owner.height == 1696U);
  bool geometry_changed = false;
  assert(kual_x11_owner_read(&owner, &geometry_changed) == 0);
  assert(geometry_changed);
  assert(owner.width == 1696U && owner.height == 1272U);
  kual_x11_owner_close(&owner);
  int status;
  assert(waitpid(pid, &status, 0) == pid);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
  pid = fork();
  assert(pid >= 0);
  if (pid == 0) {
    close(sockets[0]);
    x11_test_server(sockets[1], false);
  }
  close(sockets[1]);
  errno = 0;
  assert(kual_x11_owner_open_fd(&owner, sockets[0]) == -1);
  assert(errno == ENOTSUP);
  kual_x11_owner_close(&owner);
  assert(waitpid(pid, &status, 0) == pid);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

int main(int argc, char **argv) {
  assert(argc == 2);
  test_stderr_redirect();
  test_privilege_indicator();
  test_exec_spec();
  test_known_offender_cleanup();
  test_ui_config();
  test_status_routing();
  test_navigation();
  test_power_event_unlock();
  test_x11_owner();
  test_sort_mode_update();
  test_log_archive();
  KualMenu menu;
  KualErrors errors = {0};
  kual_menu_init(&menu, argv[1], "KindlePaperWhite5");
  assert(kual_menu_load(&menu, &errors) == 0);
  assert(errors.len == 0);
  assert(menu.extension_id_count == 2);
  assert(menu.extension_alias_count == 3);
  assert(kual_config_page_size(&menu.config, KUAL_DEFAULT_PAGE_ROWS) == 7U);
  assert(!kual_config_show_status(&menu.config));

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
