// C interface to the Cursor Pilot Rust core (core/src/lib.rs).
// All strings are UTF-8 JSON. Strings returned as `char *` must be released
// with cp_string_free.
#ifndef CURSOR_PILOT_CORE_H
#define CURSOR_PILOT_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct CPCore CPCore;
typedef void (*CPEventCallback)(void *ctx, const char *event_json);

CPCore *cp_core_new(const char *config_json);
void cp_core_free(CPCore *core);
bool cp_core_configure(CPCore *core, const char *settings_json);

uint64_t cp_core_send(CPCore *core, const char *request_json, CPEventCallback callback, void *ctx);
void cp_core_cancel(CPCore *core, uint64_t request_id);

void cp_core_new_conversation(CPCore *core);
char *cp_core_current_conversation(CPCore *core);
char *cp_core_list_conversations(CPCore *core);
char *cp_core_load_conversation(CPCore *core, const char *conversation_id);
void cp_core_delete_conversation(CPCore *core, const char *conversation_id);
bool cp_core_resume_conversation(CPCore *core, const char *conversation_id);

/* The agent host: called from a background thread with a JSON request, it
 * returns a JSON reply allocated with malloc (the core frees it), and may
 * block while an action runs. Pass NULL to remove it. */
typedef char *(*CPHostCallback)(void *ctx, const char *request_json);
void cp_core_set_host(CPCore *core, CPHostCallback host, void *ctx);
void cp_core_rename_conversation(CPCore *core, const char *conversation_id, const char *title);

char *cp_core_save_drawing(CPCore *core, const uint8_t *png, size_t len, const char *title);
char *cp_core_list_drawings(CPCore *core);
void cp_core_delete_drawing(CPCore *core, const char *drawing_id);

void cp_string_free(char *s);
const char *cp_core_version(void);

#endif
