#pragma once

#include <pebble.h>

#define MAX_GRAPH_POINTS 36

void glucose_graph_init(void);
void glucose_graph_deinit(void);
void glucose_graph_set_data(const uint16_t *values, int count);
void glucose_graph_update_proc(Layer *layer, GContext *ctx);
