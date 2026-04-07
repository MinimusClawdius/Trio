#pragma once
#include "../trio_types.h"
#include <stddef.h>

void config_init(void);
void config_save(void);
void config_load(void);
void config_apply_message(DictionaryIterator *iter);
TrioConfig *config_get(void);

/** Format `glucose_mgdl` for UI; uses `config_get()->is_mmol` (one decimal mmol vs integer mg/dL). */
void format_glucose_display_string(char *buf, size_t buf_size, int16_t glucose_mgdl);
