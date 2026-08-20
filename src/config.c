#define _POSIX_C_SOURCE 200809L
#include "kual.h"

#include <ctype.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

void kual_config_init(KualConfig *config) { memset(config, 0, sizeof(*config)); }

void kual_config_free(KualConfig *config) {
    for (size_t i = 0; i < config->len; i++) {
        free(config->items[i].key); free(config->items[i].value);
    }
    free(config->items); memset(config, 0, sizeof(*config));
}

const char *kual_config_get(const KualConfig *config, const char *key) {
    for (size_t i = config->len; i > 0; i--)
        if (strcmp(config->items[i - 1].key, key) == 0) return config->items[i - 1].value;
    return NULL;
}

void kual_config_set(KualConfig *config, const char *key, const char *value) {
    for (size_t i = 0; i < config->len; i++) {
        if (strcmp(config->items[i].key, key) == 0) {
            free(config->items[i].value);
            config->items[i].value = kual_xstrdup(value);
            return;
        }
    }
    if (config->len == config->cap) {
        config->cap = config->cap ? config->cap * 2 : 16;
        config->items = kual_xrealloc(config->items, config->cap * sizeof(*config->items));
    }
    config->items[config->len++] = (KualOption){kual_xstrdup(key), kual_xstrdup(value)};
}

static char *trim(char *s) {
    while (isspace((unsigned char)*s)) s++;
    char *end = s + strlen(s);
    while (end > s && isspace((unsigned char)end[-1])) *--end = '\0';
    return s;
}

int kual_config_load(KualConfig *config, const char *path, KualErrors *errors) {
    FILE *f = fopen(path, "r");
    if (!f) return errno == ENOENT ? 0 : -1;
    char *line = NULL;
    size_t cap = 0;
    unsigned long lineno = 0;
    while (getline(&line, &cap, f) >= 0) {
        lineno++;
        char *p = trim(line);
        if (!*p || *p == '#') continue;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        *eq++ = '\0';
        char *key = trim(p), *value = trim(eq);
        if (strncmp(key, "KUAL_", 5) != 0 || !key[5]) continue;
        key += 5;
        size_t n = strlen(value);
        if (n >= 2 && ((value[0] == '"' && value[n - 1] == '"') ||
                       (value[0] == '\'' && value[n - 1] == '\''))) {
            value[n - 1] = '\0'; value++;
        }
        kual_config_set(config, key, value);
    }
    if (ferror(f)) kual_errors_add(errors, path, "failed reading configuration near line %lu", lineno);
    free(line); fclose(f);
    return 0;
}
