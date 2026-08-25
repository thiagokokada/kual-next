#ifndef KUAL_H
#define KUAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <time.h>

#ifndef KUAL_NEXT_VERSION
#error "KUAL_NEXT_VERSION must be supplied by the build system"
#endif
#define KUAL_DEFAULT_EXTENSIONS "/mnt/us/extensions"
#define KUAL_DEFAULT_LOG "/var/tmp/kual-next.log"
#define KUAL_DEFAULT_DOCUMENTS "/mnt/us/documents"
#define KUAL_MAX_DEPTH 10
#define KUAL_DEFAULT_PAGE_ROWS 10U

typedef struct {
  char *key;
  char *value;
} KualOption;

typedef struct {
  KualOption *items;
  size_t len;
  size_t cap;
} KualConfig;

typedef enum {
  KUAL_INTERNAL_NONE,
  KUAL_INTERNAL_BREADCRUMB,
  KUAL_INTERNAL_STATUS,
} KualInternalKind;

typedef enum {
  KUAL_BUILTIN_NONE,
  KUAL_BUILTIN_SORT_ABC,
  KUAL_BUILTIN_SORT_123,
  KUAL_BUILTIN_SAVE_LOG,
  KUAL_BUILTIN_QUIT,
} KualBuiltinAction;

typedef struct KualEntry {
  char *name;
  char *action;
  char *params;
  char *condition;
  char *internal;
  KualInternalKind internal_kind;
  KualBuiltinAction builtin_action;
  char *working_dir;
  char *extension_id;
  char *source;
  int priority;
  size_t order;
  bool exit_menu;
  bool checked_after;
  bool checked;
  bool refresh_after;
  bool show_status;
  bool show_date;
  bool hidden;
  bool collated;
  struct KualEntry *children;
  size_t child_count;
  size_t child_cap;
} KualEntry;

typedef struct {
  KualEntry root;
  KualConfig config;
  char **extension_aliases;
  size_t extension_alias_count;
  size_t extension_alias_cap;
  size_t extension_id_count;
  char *extensions_dir;
  char *model;
  size_t next_order;
} KualMenu;

typedef struct {
  char *source;
  char *message;
} KualError;

typedef struct {
  KualError *items;
  size_t len;
  size_t cap;
} KualErrors;

typedef struct {
  size_t depth;
  size_t page[KUAL_MAX_DEPTH + 1];
} KualNavigation;

typedef enum {
  KUAL_PRIVILEGE_USER,
  KUAL_PRIVILEGE_GANDALF,
  KUAL_PRIVILEGE_ROOT,
} KualPrivilege;

typedef struct {
  const char *path;
  char *argv[7];
} KualExecSpec;

void *kual_xcalloc(size_t count, size_t size);
void *kual_xrealloc(void *ptr, size_t size);
char *kual_xstrdup(const char *s);
char *kual_join_path(const char *a, const char *b);
char *kual_dirname(const char *path);
char *kual_read_file(const char *path, size_t *size_out);
void kual_log(const char *format, ...);
int kual_redirect_stderr(const char *path);
const char *kual_privilege_indicator(bool is_root);
KualPrivilege kual_privilege_mode(bool is_root, bool gandalf_available);
const char *kual_privilege_mode_indicator(KualPrivilege privilege);
void kual_exec_spec(KualPrivilege privilege, const char *command,
                    KualExecSpec *spec);
int kual_cleanup_known_offenders(const char *killall_path);
void kual_route_status(bool footer_enabled, char *footer, size_t footer_size,
                       char *breadcrumb, size_t breadcrumb_size,
                       const char *message);
bool kual_power_event_is_unlock(const char *event, bool screen_saver_active);
int kual_set_sort_mode(const char *extensions_dir, const char *mode);
int kual_archive_log(const char *source, const char *documents_dir, time_t when,
                     char **destination_out);
const char *kual_builtin_action_name(KualBuiltinAction action);

void kual_config_init(KualConfig *config);
void kual_config_free(KualConfig *config);
void kual_config_set(KualConfig *config, const char *key, const char *value);
const char *kual_config_get(const KualConfig *config, const char *key);
int kual_config_load(KualConfig *config, const char *path, KualErrors *errors);
size_t kual_config_page_size(const KualConfig *config, size_t fallback);
bool kual_config_show_status(const KualConfig *config);

void kual_navigation_init(KualNavigation *navigation);
size_t kual_navigation_page(const KualNavigation *navigation);
void kual_navigation_next_page(KualNavigation *navigation, size_t page_count);
bool kual_navigation_enter(KualNavigation *navigation);
void kual_navigation_back(KualNavigation *navigation);
void kual_navigation_top(KualNavigation *navigation);

void kual_errors_add(KualErrors *errors, const char *source, const char *format,
                     ...);
void kual_errors_free(KualErrors *errors);

void kual_menu_init(KualMenu *menu, const char *extensions_dir,
                    const char *model);
void kual_menu_free(KualMenu *menu);
int kual_menu_load(KualMenu *menu, KualErrors *errors);
void kual_menu_add_errors(KualMenu *menu, const KualErrors *errors);
void kual_menu_print(const KualMenu *menu, FILE *out);
bool kual_condition_eval(const char *expr, const char *working_dir,
                         const KualMenu *menu, char **error_out);

#ifndef KUAL_HOST
int kual_ui_run(KualMenu *menu, KualErrors *errors);
char *kual_device_model_probe(void);
const char *kual_model_from_fbink_name(const char *device_name);
#endif

#endif
