/*
 * Glucose Graph Layer
 *
 * Draws a glucose trend line on the Pebble screen with:
 * - Color-coded segments (green=in-range, orange=high, red=low)
 * - Target range band (70-180 mg/dL)
 * - Dots at each data point
 * - B&W fallback for aplite/diorite
 */

#include "glucose_graph.h"

#define GRAPH_LOW_THRESHOLD   70
#define GRAPH_HIGH_THRESHOLD  180
#define GRAPH_MIN_MGDL        40
#define GRAPH_MAX_MGDL        350
#define GRAPH_MARGIN_LEFT      2
#define GRAPH_MARGIN_RIGHT     2
#define GRAPH_MARGIN_TOP       2
#define GRAPH_MARGIN_BOTTOM    2

static uint16_t s_values[MAX_GRAPH_POINTS];
static int s_count = 0;

void glucose_graph_init(void) {
    s_count = 0;
}

void glucose_graph_deinit(void) {
    s_count = 0;
}

void glucose_graph_set_data(const uint16_t *values, int count) {
    if (count > MAX_GRAPH_POINTS) count = MAX_GRAPH_POINTS;
    for (int i = 0; i < count; i++) {
        s_values[i] = values[i];
    }
    s_count = count;
}

static int glucose_to_y(int mg_dl, int graph_height) {
    int clamped = mg_dl;
    if (clamped < GRAPH_MIN_MGDL) clamped = GRAPH_MIN_MGDL;
    if (clamped > GRAPH_MAX_MGDL) clamped = GRAPH_MAX_MGDL;
    return (graph_height - 1) -
           ((clamped - GRAPH_MIN_MGDL) * (graph_height - 1)) / (GRAPH_MAX_MGDL - GRAPH_MIN_MGDL);
}

#ifdef PBL_COLOR
static GColor color_for_glucose(int mg_dl) {
    if (mg_dl < GRAPH_LOW_THRESHOLD) return GColorRed;
    if (mg_dl > GRAPH_HIGH_THRESHOLD) return GColorOrange;
    return GColorGreen;
}
#endif

void glucose_graph_update_proc(Layer *layer, GContext *ctx) {
    GRect bounds = layer_get_bounds(layer);
    int w = bounds.size.w - GRAPH_MARGIN_LEFT - GRAPH_MARGIN_RIGHT;
    int h = bounds.size.h - GRAPH_MARGIN_TOP - GRAPH_MARGIN_BOTTOM;

    if (w < 10 || h < 10) return;

    // Background
    graphics_context_set_fill_color(ctx, GColorBlack);
    graphics_fill_rect(ctx, bounds, 0, GCornersAll);

    // Target range band
    int y_high = GRAPH_MARGIN_TOP + glucose_to_y(GRAPH_HIGH_THRESHOLD, h);
    int y_low  = GRAPH_MARGIN_TOP + glucose_to_y(GRAPH_LOW_THRESHOLD, h);
    int band_height = y_low - y_high;
    if (band_height > 0) {
#ifdef PBL_COLOR
        graphics_context_set_fill_color(ctx, GColorDarkGreen);
#else
        graphics_context_set_fill_color(ctx, GColorLightGray);
#endif
        graphics_fill_rect(ctx,
            GRect(GRAPH_MARGIN_LEFT, y_high, w, band_height),
            0, GCornersAll);
    }

    if (s_count < 2) {
        // Not enough data - draw a "no data" indicator
        graphics_context_set_stroke_color(ctx, GColorWhite);
        int mid_y = GRAPH_MARGIN_TOP + h / 2;
        graphics_draw_line(ctx,
            GPoint(GRAPH_MARGIN_LEFT, mid_y),
            GPoint(GRAPH_MARGIN_LEFT + w, mid_y));
        return;
    }

    // Draw glucose trend line
    int x_step_num = w;
    int x_step_den = s_count - 1;

    for (int i = 1; i < s_count; i++) {
        int x0 = GRAPH_MARGIN_LEFT + ((i - 1) * x_step_num) / x_step_den;
        int y0 = GRAPH_MARGIN_TOP + glucose_to_y(s_values[i - 1], h);
        int x1 = GRAPH_MARGIN_LEFT + (i * x_step_num) / x_step_den;
        int y1 = GRAPH_MARGIN_TOP + glucose_to_y(s_values[i], h);

#ifdef PBL_COLOR
        int avg = ((int)s_values[i - 1] + (int)s_values[i]) / 2;
        graphics_context_set_stroke_color(ctx, color_for_glucose(avg));
#else
        graphics_context_set_stroke_color(ctx, GColorWhite);
#endif
        graphics_context_set_stroke_width(ctx, 2);
        graphics_draw_line(ctx, GPoint(x0, y0), GPoint(x1, y1));
    }

    // Draw dots at each data point
#ifdef PBL_COLOR
    for (int i = 0; i < s_count; i++) {
        int x = GRAPH_MARGIN_LEFT + (i * x_step_num) / x_step_den;
        int y = GRAPH_MARGIN_TOP + glucose_to_y(s_values[i], h);
        graphics_context_set_fill_color(ctx, color_for_glucose(s_values[i]));
        graphics_fill_circle(ctx, GPoint(x, y), 2);
    }
#else
    graphics_context_set_fill_color(ctx, GColorWhite);
    for (int i = 0; i < s_count; i++) {
        int x = GRAPH_MARGIN_LEFT + (i * x_step_num) / x_step_den;
        int y = GRAPH_MARGIN_TOP + glucose_to_y(s_values[i], h);
        graphics_fill_circle(ctx, GPoint(x, y), 2);
    }
#endif

    // Draw thin horizontal reference lines at thresholds
    graphics_context_set_stroke_width(ctx, 1);
#ifdef PBL_COLOR
    graphics_context_set_stroke_color(ctx, GColorDarkGray);
#else
    graphics_context_set_stroke_color(ctx, GColorLightGray);
#endif
    int ref_y_low = GRAPH_MARGIN_TOP + glucose_to_y(GRAPH_LOW_THRESHOLD, h);
    int ref_y_high = GRAPH_MARGIN_TOP + glucose_to_y(GRAPH_HIGH_THRESHOLD, h);
    for (int x = GRAPH_MARGIN_LEFT; x < GRAPH_MARGIN_LEFT + w; x += 4) {
        graphics_draw_pixel(ctx, GPoint(x, ref_y_low));
        graphics_draw_pixel(ctx, GPoint(x, ref_y_high));
    }
}
