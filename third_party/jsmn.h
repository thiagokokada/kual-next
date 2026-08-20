/*
 * jsmn.h - Minimalistic JSON parser in C.
 * Copyright (c) 2010 Serge Zaitsev
 * SPDX-License-Identifier: MIT
 */
#ifndef JSMN_H
#define JSMN_H

#include <stddef.h>

typedef enum { JSMN_UNDEFINED = 0, JSMN_OBJECT = 1, JSMN_ARRAY = 2,
               JSMN_STRING = 3, JSMN_PRIMITIVE = 4 } jsmntype_t;

enum jsmnerr { JSMN_ERROR_NOMEM = -1, JSMN_ERROR_INVAL = -2,
               JSMN_ERROR_PART = -3 };

typedef struct {
    jsmntype_t type;
    int start;
    int end;
    int size;
    int parent;
} jsmntok_t;

typedef struct {
    unsigned int pos;
    unsigned int toknext;
    int toksuper;
} jsmn_parser;

static void jsmn_init(jsmn_parser *p) {
    p->pos = 0; p->toknext = 0; p->toksuper = -1;
}

static jsmntok_t *jsmn_alloc(jsmn_parser *p, jsmntok_t *t, size_t n) {
    if (p->toknext >= n) return NULL;
    jsmntok_t *tok = &t[p->toknext++];
    tok->start = tok->end = -1; tok->size = 0; tok->parent = -1;
    tok->type = JSMN_UNDEFINED;
    return tok;
}

static void jsmn_fill(jsmntok_t *t, jsmntype_t type, int start, int end) {
    t->type = type; t->start = start; t->end = end; t->size = 0;
}

static int jsmn_primitive(jsmn_parser *p, const char *js, size_t len,
                          jsmntok_t *tokens, size_t count) {
    unsigned int start = p->pos;
    for (; p->pos < len; p->pos++) {
        char c = js[p->pos];
        if (c == '\t' || c == '\r' || c == '\n' || c == ' ' || c == ',' ||
            c == ']' || c == '}') break;
        if ((unsigned char)c < 32 || c == ':' || c == '"') {
            p->pos = start; return JSMN_ERROR_INVAL;
        }
    }
    if (!tokens) { p->pos--; return 0; }
    jsmntok_t *tok = jsmn_alloc(p, tokens, count);
    if (!tok) { p->pos = start; return JSMN_ERROR_NOMEM; }
    jsmn_fill(tok, JSMN_PRIMITIVE, (int)start, (int)p->pos);
    tok->parent = p->toksuper;
    p->pos--;
    return 0;
}

static int jsmn_string(jsmn_parser *p, const char *js, size_t len,
                       jsmntok_t *tokens, size_t count) {
    unsigned int start = p->pos++;
    for (; p->pos < len; p->pos++) {
        char c = js[p->pos];
        if (c == '"') {
            if (!tokens) return 0;
            jsmntok_t *tok = jsmn_alloc(p, tokens, count);
            if (!tok) { p->pos = start; return JSMN_ERROR_NOMEM; }
            jsmn_fill(tok, JSMN_STRING, (int)start + 1, (int)p->pos);
            tok->parent = p->toksuper;
            return 0;
        }
        if (c == '\\') {
            p->pos++;
            if (p->pos >= len) { p->pos = start; return JSMN_ERROR_PART; }
            c = js[p->pos];
            if (c == '"' || c == '/' || c == '\\' || c == 'b' || c == 'f' ||
                c == 'r' || c == 'n' || c == 't') continue;
            if (c == 'u') {
                for (int i = 0; i < 4; i++) {
                    if (++p->pos >= len) { p->pos = start; return JSMN_ERROR_PART; }
                    c = js[p->pos];
                    if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') ||
                          (c >= 'a' && c <= 'f'))) {
                        p->pos = start; return JSMN_ERROR_INVAL;
                    }
                }
                continue;
            }
            p->pos = start; return JSMN_ERROR_INVAL;
        }
        if ((unsigned char)c < 32) { p->pos = start; return JSMN_ERROR_INVAL; }
    }
    p->pos = start;
    return JSMN_ERROR_PART;
}

static int jsmn_parse(jsmn_parser *p, const char *js, size_t len,
                      jsmntok_t *tokens, unsigned int count) {
    int r, i;
    for (; p->pos < len; p->pos++) {
        char c = js[p->pos];
        switch (c) {
        case '{': case '[': {
            jsmntok_t *tok = tokens ? jsmn_alloc(p, tokens, count) : NULL;
            if (tokens && !tok) return JSMN_ERROR_NOMEM;
            if (tokens) {
                if (p->toksuper != -1) tokens[p->toksuper].size++;
                tok->type = c == '{' ? JSMN_OBJECT : JSMN_ARRAY;
                tok->start = (int)p->pos; tok->parent = p->toksuper;
            }
            p->toksuper = tokens ? (int)p->toknext - 1 : p->toksuper;
            break;
        }
        case '}': case ']':
            if (!tokens) break;
            for (i = (int)p->toknext - 1; i >= 0; i--) {
                if (tokens[i].start != -1 && tokens[i].end == -1) {
                    if ((tokens[i].type == JSMN_OBJECT && c == '}') ||
                        (tokens[i].type == JSMN_ARRAY && c == ']')) {
                        tokens[i].end = (int)p->pos + 1;
                        p->toksuper = tokens[i].parent;
                        break;
                    }
                    return JSMN_ERROR_INVAL;
                }
            }
            if (i == -1) return JSMN_ERROR_INVAL;
            break;
        case '"':
            r = jsmn_string(p, js, len, tokens, count);
            if (r < 0) return r;
            if (tokens && p->toksuper != -1) tokens[p->toksuper].size++;
            break;
        case '\t': case '\r': case '\n': case ' ': case ':': case ',':
            break;
        default:
            r = jsmn_primitive(p, js, len, tokens, count);
            if (r < 0) return r;
            if (tokens && p->toksuper != -1) tokens[p->toksuper].size++;
            break;
        }
    }
    if (tokens) {
        for (i = (int)p->toknext - 1; i >= 0; i--)
            if (tokens[i].start != -1 && tokens[i].end == -1)
                return JSMN_ERROR_PART;
    }
    return (int)p->toknext;
}
#endif
