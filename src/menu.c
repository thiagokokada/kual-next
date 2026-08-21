#define _XOPEN_SOURCE 700
#define _POSIX_C_SOURCE 200809L
#include "jsmn.h"
#include "kual.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
  char *path;
  char *id;
} ExtensionFile;
typedef struct {
  ExtensionFile *items;
  size_t len, cap;
} ExtensionFiles;
typedef struct {
  dev_t dev;
  ino_t ino;
} VisitedDir;
typedef struct {
  VisitedDir *items;
  size_t len, cap;
} VisitedDirs;

static void entry_free(KualEntry *entry) {
  free(entry->name);
  free(entry->action);
  free(entry->params);
  free(entry->condition);
  free(entry->internal);
  free(entry->working_dir);
  free(entry->extension_id);
  free(entry->source);
  for (size_t i = 0; i < entry->child_count; i++)
    entry_free(&entry->children[i]);
  free(entry->children);
  memset(entry, 0, sizeof(*entry));
}

void kual_menu_init(KualMenu *menu, const char *extensions_dir,
                    const char *model) {
  memset(menu, 0, sizeof(*menu));
  menu->root.name = kual_xstrdup("KUAL Next");
  menu->root.exit_menu = true;
  menu->root.show_status = true;
  menu->extensions_dir = kual_xstrdup(extensions_dir);
  menu->model = kual_xstrdup(model && *model ? model : "Unknown");
  kual_config_init(&menu->config);
  kual_config_set(&menu->config, "model", menu->model);
}

void kual_menu_free(KualMenu *menu) {
  entry_free(&menu->root);
  kual_config_free(&menu->config);
  for (size_t i = 0; i < menu->extension_id_count; i++)
    free(menu->extension_ids[i]);
  free(menu->extension_ids);
  free(menu->extensions_dir);
  free(menu->model);
  memset(menu, 0, sizeof(*menu));
}

static void add_id(KualMenu *menu, const char *id) {
  if (!id || !*id)
    return;
  for (size_t i = 0; i < menu->extension_id_count; i++)
    if (!strcmp(menu->extension_ids[i], id))
      return;
  if (menu->extension_id_count == menu->extension_id_cap) {
    menu->extension_id_cap =
        menu->extension_id_cap ? menu->extension_id_cap * 2 : 16;
    menu->extension_ids =
        kual_xrealloc(menu->extension_ids,
                      menu->extension_id_cap * sizeof(*menu->extension_ids));
  }
  menu->extension_ids[menu->extension_id_count++] = kual_xstrdup(id);
}

static KualEntry *add_child(KualEntry *parent) {
  if (parent->child_count == parent->child_cap) {
    parent->child_cap = parent->child_cap ? parent->child_cap * 2 : 8;
    parent->children = kual_xrealloc(
        parent->children, parent->child_cap * sizeof(*parent->children));
  }
  KualEntry *child = &parent->children[parent->child_count++];
  memset(child, 0, sizeof(*child));
  child->exit_menu = true;
  child->show_status = true;
  return child;
}

static char *slice(const char *begin, const char *end) {
  if (!begin || !end || end < begin)
    return NULL;
  size_t n = (size_t)(end - begin);
  char *s = kual_xcalloc(n + 1, 1);
  memcpy(s, begin, n);
  return s;
}

static void replace_all(char **value, const char *needle,
                        const char *replacement) {
  char *s = *value, *hit = strstr(s, needle);
  if (!hit)
    return;
  size_t before = (size_t)(hit - s), nl = strlen(needle),
         rl = strlen(replacement);
  size_t old = strlen(s);
  char *out = kual_xcalloc(old - nl + rl + 1, 1);
  memcpy(out, s, before);
  memcpy(out + before, replacement, rl);
  memcpy(out + before + rl, hit + nl, old - before - nl + 1);
  free(s);
  *value = out;
  replace_all(value, needle, replacement);
}

static char *xml_text(const char *xml, const char *tag) {
  char open[64], close[64];
  snprintf(open, sizeof(open), "<%s", tag);
  snprintf(close, sizeof(close), "</%s>", tag);
  const char *a = strstr(xml, open);
  if (!a)
    return NULL;
  a = strchr(a, '>');
  if (!a)
    return NULL;
  a++;
  const char *b = strstr(a, close);
  if (!b)
    return NULL;
  char *out = slice(a, b);
  replace_all(&out, "&amp;", "&");
  replace_all(&out, "&lt;", "<");
  replace_all(&out, "&gt;", ">");
  replace_all(&out, "&quot;", "\"");
  replace_all(&out, "&apos;", "'");
  return out;
}

static bool xml_json_menu(const char *open, const char *gt) {
  char *header = slice(open, gt);
  bool is_json =
      strstr(header, "type=\"json\"") || strstr(header, "type='json'");
  free(header);
  return is_json;
}

static void files_add(ExtensionFiles *files, const char *path, char *id) {
  if (files->len == files->cap) {
    files->cap = files->cap ? files->cap * 2 : 16;
    files->items =
        kual_xrealloc(files->items, files->cap * sizeof(*files->items));
  }
  files->items[files->len++] = (ExtensionFile){kual_xstrdup(path), id};
}

static bool excluded_path(const char *root, const char *path,
                          const char *list) {
  if (!list || !*list)
    list = "system";
  const char *rel = path + strlen(root);
  if (*rel == '/')
    rel++;
  const char *p = list;
  while (*p) {
    const char *end = strchr(p, ';');
    if (!end)
      end = p + strlen(p);
    while (p < end && isspace((unsigned char)*p))
      p++;
    while (end > p && isspace((unsigned char)end[-1]))
      end--;
    size_t n = (size_t)(end - p);
    if (n && !strncmp(rel, p, n) && (rel[n] == '\0' || rel[n] == '/'))
      return true;
    p = *end ? end + 1 : end;
  }
  return false;
}

static bool visited(VisitedDirs *seen, const struct stat *st) {
  for (size_t i = 0; i < seen->len; i++)
    if (seen->items[i].dev == st->st_dev && seen->items[i].ino == st->st_ino)
      return true;
  if (seen->len == seen->cap) {
    seen->cap = seen->cap ? seen->cap * 2 : 16;
    seen->items = kual_xrealloc(seen->items, seen->cap * sizeof(*seen->items));
  }
  seen->items[seen->len++] = (VisitedDir){st->st_dev, st->st_ino};
  return false;
}

static void discover_dir(KualMenu *menu, const char *path, int depth,
                         int max_depth, bool follow, const char *exclude,
                         ExtensionFiles *files, VisitedDirs *seen,
                         KualErrors *errors) {
  struct stat st;
  int rc = follow ? stat(path, &st) : lstat(path, &st);
  if (rc || !S_ISDIR(st.st_mode) || visited(seen, &st))
    return;
  DIR *dir = opendir(path);
  if (!dir) {
    kual_errors_add(errors, path, "cannot open directory: %s", strerror(errno));
    return;
  }
  struct dirent *de;
  while ((de = readdir(dir))) {
    if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
      continue;
    char *child = kual_join_path(path, de->d_name);
    if (excluded_path(menu->extensions_dir, child, exclude)) {
      free(child);
      continue;
    }
    struct stat cs;
    int src = follow ? stat(child, &cs) : lstat(child, &cs);
    if (!src && S_ISDIR(cs.st_mode) && depth < max_depth) {
      discover_dir(menu, child, depth + 1, max_depth, follow, exclude, files,
                   seen, errors);
    } else if (!src && S_ISREG(cs.st_mode) &&
               !strcmp(de->d_name, "config.xml")) {
      char *xml = kual_read_file(child, NULL);
      if (!xml)
        kual_errors_add(errors, child, "cannot read config.xml: %s",
                        strerror(errno));
      else if (!strstr(xml, "<extension"))
        kual_errors_add(errors, child, "not a KUAL extension config");
      else {
        char *id = xml_text(xml, "id");
        if (!id)
          id = kual_xstrdup("");
        add_id(menu, id);
        files_add(files, child, id);
        id = NULL;
      }
      free(xml);
    }
    free(child);
  }
  closedir(dir);
}

static int tok_skip(const jsmntok_t *tokens, int count, int index) {
  int end = tokens[index].end, next = index + 1;
  while (next < count && tokens[next].start < end)
    next++;
  return next;
}

static bool tok_is(const char *json, const jsmntok_t *tok, const char *text) {
  size_t n = strlen(text);
  return tok->type == JSMN_STRING && (size_t)(tok->end - tok->start) == n &&
         !memcmp(json + tok->start, text, n);
}

static int hex4(const char *p) {
  int value = 0;
  for (int i = 0; i < 4; i++) {
    char c = p[i];
    int digit;
    if (c >= '0' && c <= '9')
      digit = c - '0';
    else if (c >= 'a' && c <= 'f')
      digit = c - 'a' + 10;
    else if (c >= 'A' && c <= 'F')
      digit = c - 'A' + 10;
    else
      return -1;
    value = value * 16 + digit;
  }
  return value;
}

static void utf8_append(char *out, size_t *used, uint32_t cp) {
  if (cp <= 0x7f)
    out[(*used)++] = (char)cp;
  else if (cp <= 0x7ff) {
    out[(*used)++] = (char)(0xc0 | cp >> 6);
    out[(*used)++] = (char)(0x80 | (cp & 63));
  } else if (cp <= 0xffff) {
    out[(*used)++] = (char)(0xe0 | cp >> 12);
    out[(*used)++] = (char)(0x80 | ((cp >> 6) & 63));
    out[(*used)++] = (char)(0x80 | (cp & 63));
  } else {
    out[(*used)++] = (char)(0xf0 | cp >> 18);
    out[(*used)++] = (char)(0x80 | ((cp >> 12) & 63));
    out[(*used)++] = (char)(0x80 | ((cp >> 6) & 63));
    out[(*used)++] = (char)(0x80 | (cp & 63));
  }
}

static char *tok_string(const char *json, const jsmntok_t *tok) {
  if (tok->type != JSMN_STRING)
    return NULL;
  size_t n = (size_t)(tok->end - tok->start), used = 0;
  char *out = kual_xcalloc(n + 1, 1);
  for (size_t i = 0; i < n; i++) {
    char c = json[tok->start + (int)i];
    if (c != '\\' || i + 1 >= n) {
      out[used++] = c;
      continue;
    }
    c = json[tok->start + (int)++i];
    if (c == 'n')
      out[used++] = '\n';
    else if (c == 'r')
      out[used++] = '\r';
    else if (c == 't')
      out[used++] = '\t';
    else if (c == 'b')
      out[used++] = '\b';
    else if (c == 'f')
      out[used++] = '\f';
    else if (c != 'u')
      out[used++] = c;
    else if (i + 4 < n) {
      int cp = hex4(json + tok->start + (int)i + 1);
      i += 4;
      if (cp >= 0xd800 && cp <= 0xdbff && i + 6 < n &&
          json[tok->start + (int)i + 1] == '\\' &&
          json[tok->start + (int)i + 2] == 'u') {
        int low = hex4(json + tok->start + (int)i + 3);
        if (low >= 0xdc00 && low <= 0xdfff) {
          cp = 0x10000 + ((cp - 0xd800) << 10) + low - 0xdc00;
          i += 6;
        }
      }
      utf8_append(out, &used, (uint32_t)(cp < 0 ? '?' : cp));
    }
  }
  out[used] = '\0';
  return out;
}

static bool tok_bool(const char *json, const jsmntok_t *tok, bool fallback) {
  if (tok->type != JSMN_PRIMITIVE)
    return fallback;
  size_t n = (size_t)(tok->end - tok->start);
  if ((n == 4 && !memcmp(json + tok->start, "true", 4)) ||
      (n == 1 && json[tok->start] == '1'))
    return true;
  if ((n == 5 && !memcmp(json + tok->start, "false", 5)) ||
      (n == 1 && json[tok->start] == '0'))
    return false;
  return fallback;
}

static int tok_int(const char *json, const jsmntok_t *tok, int fallback) {
  if (tok->type != JSMN_PRIMITIVE)
    return fallback;
  char *s = slice(json + tok->start, json + tok->end), *end = NULL;
  long value = strtol(s, &end, 10);
  bool valid = end && !*end && value >= INT_MIN && value <= INT_MAX;
  free(s);
  return valid ? (int)value : fallback;
}

static int parse_item(KualMenu *menu, KualEntry *parent, const char *json,
                      const jsmntok_t *tokens, int count, int index, int depth,
                      const char *cwd, const char *id, const char *source,
                      KualErrors *errors);

static int parse_array(KualMenu *menu, KualEntry *parent, const char *json,
                       const jsmntok_t *tokens, int count, int index, int depth,
                       const char *cwd, const char *id, const char *source,
                       KualErrors *errors) {
  if (tokens[index].type != JSMN_ARRAY)
    return tok_skip(tokens, count, index);
  int cursor = index + 1;
  while (cursor < count && tokens[cursor].start < tokens[index].end) {
    if (tokens[cursor].type == JSMN_OBJECT)
      cursor = parse_item(menu, parent, json, tokens, count, cursor, depth, cwd,
                          id, source, errors);
    else
      cursor = tok_skip(tokens, count, cursor);
  }
  return cursor;
}

static int parse_item(KualMenu *menu, KualEntry *parent, const char *json,
                      const jsmntok_t *tokens, int count, int index, int depth,
                      const char *cwd, const char *id, const char *source,
                      KualErrors *errors) {
  int after = tok_skip(tokens, count, index);
  if (depth >= KUAL_MAX_DEPTH) {
    kual_errors_add(errors, source, "menu exceeds %d levels", KUAL_MAX_DEPTH);
    return after;
  }
  KualEntry parsed = {0};
  parsed.exit_menu = true;
  parsed.show_status = true;
  parsed.working_dir = kual_xstrdup(cwd);
  parsed.extension_id = kual_xstrdup(id);
  parsed.source = kual_xstrdup(source);
  parsed.order = menu->next_order++;
  int cursor = index + 1;
  const jsmntok_t *items = NULL;
  while (cursor + 1 < count && tokens[cursor].start < tokens[index].end) {
    const jsmntok_t *key = &tokens[cursor++], *value = &tokens[cursor];
    if (tok_is(json, key, "name"))
      parsed.name = tok_string(json, value);
    else if (tok_is(json, key, "action"))
      parsed.action = tok_string(json, value);
    else if (tok_is(json, key, "params"))
      parsed.params = tok_string(json, value);
    else if (tok_is(json, key, "if"))
      parsed.condition = tok_string(json, value);
    else if (tok_is(json, key, "internal"))
      parsed.internal = tok_string(json, value);
    else if (tok_is(json, key, "priority"))
      parsed.priority = tok_int(json, value, 0);
    else if (tok_is(json, key, "exitmenu"))
      parsed.exit_menu = tok_bool(json, value, true);
    else if (tok_is(json, key, "checked"))
      parsed.checked_after = tok_bool(json, value, false);
    else if (tok_is(json, key, "refresh"))
      parsed.refresh_after = tok_bool(json, value, false);
    else if (tok_is(json, key, "status"))
      parsed.show_status = tok_bool(json, value, true);
    else if (tok_is(json, key, "date"))
      parsed.show_date = tok_bool(json, value, false);
    else if (tok_is(json, key, "hidden"))
      parsed.hidden = tok_bool(json, value, false);
    else if (tok_is(json, key, "items"))
      items = value;
    cursor = tok_skip(tokens, count, cursor);
  }
  if (!parsed.name || (!parsed.action && !items)) {
    kual_errors_add(errors, source,
                    "menu entry is missing name or action/items");
    entry_free(&parsed);
    return after;
  }
  if (items)
    parse_array(menu, &parsed, json, tokens, count, (int)(items - tokens),
                depth + 1, cwd, id, source, errors);
  *add_child(parent) = parsed;
  return after;
}

static void parse_json_menu(KualMenu *menu, const char *path, const char *cwd,
                            const char *id, KualErrors *errors) {
  size_t size;
  char *json = kual_read_file(path, &size);
  if (!json) {
    kual_errors_add(errors, path, "cannot read JSON menu: %s", strerror(errno));
    return;
  }
  size_t cap = size / 4 + 32;
  if (cap < 64)
    cap = 64;
  jsmntok_t *tokens = NULL;
  int parsed;
  for (;;) {
    tokens = kual_xrealloc(tokens, cap * sizeof(*tokens));
    jsmn_parser parser;
    jsmn_init(&parser);
    parsed = jsmn_parse(&parser, json, size, tokens, (unsigned int)cap);
    if (parsed != JSMN_ERROR_NOMEM)
      break;
    cap *= 2;
    if (cap > 262144)
      break;
  }
  if (parsed < 1 || tokens[0].type != JSMN_OBJECT) {
    kual_errors_add(errors, path, "invalid JSON menu (%d)", parsed);
    free(tokens);
    free(json);
    return;
  }
  bool found = false;
  int cursor = 1;
  while (cursor + 1 < parsed && tokens[cursor].start < tokens[0].end) {
    int value = cursor + 1;
    if (tok_is(json, &tokens[cursor], "items") &&
        tokens[value].type == JSMN_ARRAY) {
      parse_array(menu, &menu->root, json, tokens, parsed, value, 0, cwd, id,
                  path, errors);
      found = true;
    }
    cursor = tok_skip(tokens, parsed, value);
  }
  if (!found)
    kual_errors_add(errors, path, "top-level items array is missing");
  free(tokens);
  free(json);
}

static void parse_extension(KualMenu *menu, const ExtensionFile *file,
                            KualErrors *errors) {
  char *xml = kual_read_file(file->path, NULL);
  if (!xml)
    return;
  char *cwd = kual_dirname(file->path);
  const char *cursor = xml;
  bool found = false;
  while ((cursor = strstr(cursor, "<menu"))) {
    if (cursor[5] != '>' && !isspace((unsigned char)cursor[5])) {
      cursor += 5;
      continue;
    }
    const char *gt = strchr(cursor, '>');
    if (!gt)
      break;
    const char *end = strstr(gt + 1, "</menu>");
    if (!end)
      break;
    if (xml_json_menu(cursor, gt)) {
      char *name = slice(gt + 1, end);
      char *start = name;
      while (isspace((unsigned char)*start))
        start++;
      char *tail = start + strlen(start);
      while (tail > start && isspace((unsigned char)tail[-1]))
        *--tail = '\0';
      if (*start) {
        char *path = kual_join_path(cwd, start);
        parse_json_menu(menu, path, cwd, file->id, errors);
        free(path);
        found = true;
      }
      free(name);
    }
    cursor = end + 7;
  }
  if (!found)
    kual_errors_add(errors, file->path, "no readable JSON menu declaration");
  free(cwd);
  free(xml);
}

static void prune_entries(KualEntry *parent, const KualMenu *menu,
                          KualErrors *errors) {
  size_t out = 0;
  for (size_t i = 0; i < parent->child_count; i++) {
    KualEntry *entry = &parent->children[i];
    char *condition_error = NULL;
    bool keep = !entry->hidden &&
                kual_condition_eval(entry->condition, entry->working_dir, menu,
                                    &condition_error);
    if (condition_error) {
      kual_errors_add(errors, entry->source, "condition for '%s': %s",
                      entry->name, condition_error);
      free(condition_error);
    }
    if (!keep) {
      entry_free(entry);
      continue;
    }
    prune_entries(entry, menu, errors);
    if (out != i) {
      parent->children[out] = *entry;
      memset(entry, 0, sizeof(*entry));
    }
    out++;
  }
  parent->child_count = out;
}

static int sort_mode;
static int entry_compare(const void *a, const void *b) {
  const KualEntry *x = a, *y = b;
  int result;
  if (sort_mode == 3)
    result = (x->priority > y->priority) - (x->priority < y->priority);
  else
    result = strcasecmp(x->name, y->name);
  if (!result)
    result = (x->order > y->order) - (x->order < y->order);
  return result;
}

static void sort_entries(KualEntry *parent, bool recursive) {
  if (parent->child_count > 1)
    qsort(parent->children, parent->child_count, sizeof(*parent->children),
          entry_compare);
  if (recursive)
    for (size_t i = 0; i < parent->child_count; i++)
      sort_entries(&parent->children[i], true);
}

static void collate_entries(KualEntry *parent) {
  for (size_t i = 0; i < parent->child_count; i++) {
    KualEntry *a = &parent->children[i];
    if (!a->child_count)
      continue;
    for (size_t j = i + 1; j < parent->child_count;) {
      KualEntry *b = &parent->children[j];
      if (b->child_count && !strcmp(a->name, b->name)) {
        for (size_t k = 0; k < b->child_count; k++) {
          *add_child(a) = b->children[k];
          memset(&b->children[k], 0, sizeof(b->children[k]));
        }
        entry_free(b);
        memmove(b, b + 1, (parent->child_count - j - 1) * sizeof(*b));
        parent->child_count--;
      } else
        j++;
    }
    collate_entries(a);
  }
}

int kual_menu_load(KualMenu *menu, KualErrors *errors) {
  char *config_path = kual_join_path(menu->extensions_dir, "KUAL.cfg");
  kual_config_load(&menu->config, config_path, errors);
  free(config_path);
  int max_depth = 2;
  const char *depth = kual_config_get(&menu->config, "search_depth");
  if (depth) {
    int parsed = atoi(depth);
    if (parsed >= 1 && parsed <= KUAL_MAX_DEPTH)
      max_depth = parsed;
  }
  bool follow = true;
  const char *nofollow = kual_config_get(&menu->config, "nofollow");
  if (nofollow && !strcasecmp(nofollow, "true"))
    follow = false;
  ExtensionFiles files = {0};
  VisitedDirs seen = {0};
  discover_dir(menu, menu->extensions_dir, 0, max_depth, follow,
               kual_config_get(&menu->config, "search_exclude_paths"), &files,
               &seen, errors);
  free(seen.items);
  for (size_t i = 0; i < files.len; i++)
    parse_extension(menu, &files.items[i], errors);
  for (size_t i = 0; i < files.len; i++) {
    free(files.items[i].path);
    free(files.items[i].id);
  }
  free(files.items);
  prune_entries(&menu->root, menu, errors);
  const char *collate = kual_config_get(&menu->config, "collate");
  if (!collate || strcasecmp(collate, "false"))
    collate_entries(&menu->root);
  const char *mode = kual_config_get(&menu->config, "sort_mode");
  if (!mode)
    mode = "ABC";
  if (!strcasecmp(mode, "123")) {
    sort_mode = 3;
    sort_entries(&menu->root, true);
  } else if (!strcasecmp(mode, "ABC!")) {
    sort_mode = 1;
    sort_entries(&menu->root, true);
  } else if (!strcasecmp(mode, "ABC")) {
    sort_mode = 1;
    sort_entries(&menu->root, false);
  }
  return menu->root.child_count ? 0 : -1;
}

void kual_menu_add_errors(KualMenu *menu, const KualErrors *errors) {
  if (!errors || !errors->len)
    return;
  KualEntry *group = add_child(&menu->root);
  group->name = kual_xstrdup("Errors");
  group->priority = INT_MIN;
  group->order = menu->next_order++;
  group->exit_menu = false;
  group->show_status = false;
  for (size_t i = 0; i < errors->len; i++) {
    KualEntry *entry = add_child(group);
    const char *base = strrchr(errors->items[i].source, '/');
    base = base ? base + 1 : errors->items[i].source;
    size_t needed = strlen(base) + strlen(errors->items[i].message) + 3;
    entry->name = kual_xcalloc(needed, 1);
    snprintf(entry->name, needed, "%s: %s", base, errors->items[i].message);
    entry->action = kual_xstrdup(":");
    entry->internal = kual_xstrdup(errors->items[i].message);
    entry->working_dir = kual_xstrdup("/var/tmp");
    entry->exit_menu = false;
    entry->show_status = false;
    entry->order = menu->next_order++;
  }
}

static void print_entry(const KualEntry *entry, FILE *out, int depth) {
  for (int i = 0; i < depth; i++)
    fputs("  ", out);
  fprintf(out, "%s%s", entry->child_count ? "> " : "- ", entry->name);
  if (entry->action)
    fprintf(out, " => %s%s%s", entry->action,
            entry->params && *entry->params ? " " : "",
            entry->params ? entry->params : "");
  fputc('\n', out);
  for (size_t i = 0; i < entry->child_count; i++)
    print_entry(&entry->children[i], out, depth + 1);
}

void kual_menu_print(const KualMenu *menu, FILE *out) {
  fprintf(out, "KUAL Next %s; model=%s; extensions=%zu; entries=%zu\n",
          KUAL_NEXT_VERSION, menu->model, menu->extension_id_count,
          menu->root.child_count);
  for (size_t i = 0; i < menu->root.child_count; i++)
    print_entry(&menu->root.children[i], out, 0);
}
