#define _POSIX_C_SOURCE 200809L
#include "kual.h"

#include <ctype.h>
#include <errno.h>
#include <regex.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct { char *text; } Value;

static bool truth(const char *s) {
    return s && *s && strcmp(s, "0") != 0 && strcmp(s, "false") != 0;
}

static char *bool_string(bool value) { return kual_xstrdup(value ? "1" : "0"); }

static void set_error(char **out, const char *format, ...) {
    if (!out || *out || !format) return;
    va_list ap, copy;
    va_start(ap, format); va_copy(copy, ap);
    int n = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    *out = kual_xcalloc((size_t)(n < 0 ? 0 : n) + 1, 1);
    if (n >= 0) vsnprintf(*out, (size_t)n + 1, format, ap);
    va_end(ap);
}

static char *condition_path(const char *cwd, const char *value) {
    return value && value[0] == '/' ? kual_xstrdup(value) : kual_join_path(cwd, value);
}

static bool has_extension(const KualMenu *menu, const char *id) {
    for (size_t i = 0; i < menu->extension_id_count; i++)
        if (strcmp(menu->extension_ids[i], id) == 0) return true;
    return false;
}

static int grep_file(const char *pattern, const char *path, bool invert) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    regex_t regex;
    if (regcomp(&regex, pattern, REG_EXTENDED | REG_NOSUB) != 0) { fclose(f); return -2; }
    char *line = NULL;
    size_t cap = 0;
    bool found = false;
    while (getline(&line, &cap, f) >= 0) {
        if (regexec(&regex, line, 0, NULL, 0) == 0) { found = true; break; }
    }
    free(line); regfree(&regex); fclose(f);
    return invert ? !found : found;
}

static char *next_token(const char **cursor, char **error) {
    const char *p = *cursor;
    while (isspace((unsigned char)*p)) p++;
    if (!*p) { *cursor = p; return NULL; }

    /* KUAL's tokenizer recognizes operators without requiring whitespace.
     * This matters for common expressions such as `"KindleVoyage" -m!`,
     * which is tokenized as `-m` followed by `!`.  Keep grep's negated
     * operators atomic by checking the longest spellings first. */
    static const char *const operators[] = {
        "-ext", "-gg!", "-gg", "-g!", "-g", "-z!",
        "-e", "-f", "-m", "-o", "&&", "||", "!"
    };
    if (*p != '"') {
        for (size_t i = 0; i < sizeof(operators) / sizeof(operators[0]); i++) {
            size_t length = strlen(operators[i]);
            if (strncmp(p, operators[i], length) == 0) {
                char *operator = kual_xcalloc(length + 1, 1);
                memcpy(operator, p, length);
                *cursor = p + length;
                return operator;
            }
        }
    }

    size_t cap = 32, len = 0;
    char *out = kual_xcalloc(cap, 1);
    if (*p == '"') {
        p++;
        while (*p && *p != '"') {
            char c = *p++;
            if (c == '\\' && *p) {
                c = *p++;
                if (c == 'n') c = '\n'; else if (c == 'r') c = '\r'; else if (c == 't') c = '\t';
            }
            if (len + 2 > cap) { cap *= 2; out = kual_xrealloc(out, cap); }
            out[len++] = c;
        }
        if (*p != '"') { free(out); set_error(error, "unterminated quoted token"); return NULL; }
        p++;
    } else {
        while (*p && !isspace((unsigned char)*p)) {
            if (len + 2 > cap) { cap *= 2; out = kual_xrealloc(out, cap); }
            out[len++] = *p++;
        }
    }
    out[len] = '\0'; *cursor = p; return out;
}

static bool unary(const char *op) {
    return !strcmp(op, "!") || !strcmp(op, "-e") || !strcmp(op, "-f") ||
           !strcmp(op, "-z!") || !strcmp(op, "-ext") || !strcmp(op, "-m");
}

static bool binary(const char *op) {
    return !strcmp(op, "&&") || !strcmp(op, "||") || !strcmp(op, "-o") ||
           !strcmp(op, "-g") || !strcmp(op, "-g!") || !strcmp(op, "-gg") ||
           !strcmp(op, "-gg!");
}

bool kual_condition_eval(const char *expr, const char *working_dir,
                         const KualMenu *menu, char **error_out) {
    if (error_out) *error_out = NULL;
    if (!expr || !*expr) return true;
    Value stack[64] = {{0}};
    size_t sp = 0;
    const char *cursor = expr;
    char *tok;
    while ((tok = next_token(&cursor, error_out)) != NULL) {
        if (!unary(tok) && !binary(tok)) {
            if (sp == 64) { set_error(error_out, "condition stack overflow"); free(tok); goto fail; }
            stack[sp++].text = tok;
            continue;
        }
        if (unary(tok)) {
            if (sp < 1) { set_error(error_out, "stack underflow at %s", tok); free(tok); goto fail; }
            char *x = stack[--sp].text;
            bool result = false;
            if (!strcmp(tok, "!")) result = !truth(x);
            else if (!strcmp(tok, "-ext")) result = has_extension(menu, x);
            else if (!strcmp(tok, "-m")) result = strcmp(menu->model, x) == 0;
            else {
                char *path = condition_path(working_dir, x);
                struct stat st;
                bool exists = stat(path, &st) == 0;
                if (!strcmp(tok, "-e")) result = exists;
                else if (!strcmp(tok, "-f")) result = exists && S_ISREG(st.st_mode);
                else result = exists && S_ISREG(st.st_mode) && st.st_size > 0;
                free(path);
            }
            free(x); free(tok); stack[sp++].text = bool_string(result);
            continue;
        }
        if (sp < 2) { set_error(error_out, "stack underflow at %s", tok); free(tok); goto fail; }
        char *x = stack[--sp].text;
        char *y = stack[--sp].text;
        bool result = false;
        if (!strcmp(tok, "&&")) result = truth(y) && truth(x);
        else if (!strcmp(tok, "||")) result = truth(y) || truth(x);
        else if (!strcmp(tok, "-o")) {
            const char *configured = kual_config_get(&menu->config, y);
            result = configured && strcmp(configured, x) == 0;
        } else {
            char *path = condition_path(working_dir, y);
            bool invert = strchr(tok, '!') != NULL;
            int matched = grep_file(x, path, invert);
            if (matched == -2) set_error(error_out, "invalid regular expression: %s", x);
            else if (matched == -1 && tok[2] != 'g') set_error(error_out, "condition file not found: %s", path);
            else result = matched > 0;
            free(path);
        }
        free(x); free(y); free(tok);
        if (error_out && *error_out) goto fail;
        stack[sp++].text = bool_string(result);
    }
    if (error_out && *error_out) goto fail;
    if (sp != 1) { set_error(error_out, "condition leaves %zu values on stack", sp); goto fail; }
    bool result = truth(stack[0].text);
    free(stack[0].text);
    return result;
fail:
    for (size_t i = 0; i < sp; i++) free(stack[i].text);
    return true; /* KUAL reports malformed conditions but keeps the entry visible. */
}
