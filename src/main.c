#define _POSIX_C_SOURCE 200809L
#include "kual.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(FILE *out) {
    fprintf(out,
        "Usage: kual-next [--extensions PATH] [--model NAME] [--validate] [--version]\n"
        "  --validate  parse menus and print the resulting tree without opening FBInk\n");
}

int main(int argc, char **argv) {
    const char *extensions = KUAL_DEFAULT_EXTENSIONS;
    const char *model_arg = NULL;
    bool validate = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--extensions") && i + 1 < argc) extensions = argv[++i];
        else if (!strcmp(argv[i], "--model") && i + 1 < argc) model_arg = argv[++i];
        else if (!strcmp(argv[i], "--validate")) validate = true;
        else if (!strcmp(argv[i], "--version")) { puts("kual-next " KUAL_NEXT_VERSION); return 0; }
        else if (!strcmp(argv[i], "--help")) { usage(stdout); return 0; }
        else { usage(stderr); return 2; }
    }
    char *probed = NULL;
#ifndef KUAL_HOST
    if (!model_arg) probed = kual_device_model_probe();
#endif
    const char *environment_model = getenv("KUAL_MODEL");
    const char *model = model_arg ? model_arg :
        (environment_model && *environment_model ? environment_model : (probed ? probed : "Unknown"));
    KualMenu menu; KualErrors errors = {0};
    kual_menu_init(&menu, extensions, model);
    int load_result = kual_menu_load(&menu, &errors);
    if (validate) {
        kual_menu_print(&menu, stdout);
        for (size_t i = 0; i < errors.len; i++)
            fprintf(stderr, "%s: %s\n", errors.items[i].source, errors.items[i].message);
        int result = errors.len || load_result ? 1 : 0;
        kual_menu_free(&menu); kual_errors_free(&errors); free(probed); return result;
    }
#ifdef KUAL_HOST
    fputs("kual-next: this host build only supports --validate\n", stderr);
    kual_menu_free(&menu); kual_errors_free(&errors); free(probed); return 2;
#else
    kual_menu_add_errors(&menu, &errors);
    int result = kual_ui_run(&menu, &errors);
    kual_menu_free(&menu); kual_errors_free(&errors); free(probed); return result;
#endif
}
