// Face: Graph Focus
// Maximizes graph area. Glucose overlaid on graph, minimal text.
// Designed for users who prioritize the trend visualization.

#include "face_graph_focus.h"
#include "../modules/config.h"
#include "../modules/graph.h"
#include "../modules/complications.h"

static TextLayer *s_glucose, *s_trend, *s_delta, *s_time;
static TextLayer *s_iob_cob;
static Layer *s_graph_layer, *s_comp_layer;
static char s_time_buf[8], s_glucose_buf[20], s_iob_cob_buf[32];

static void graph_proc(Layer *layer, GContext *ctx) {
    graph_draw(layer, ctx, config_get());
}

static void comp_proc(Layer *layer, GContext *ctx) {
    GRect bounds = layer_get_bounds(layer);
    complications_draw_bar(ctx, bounds, app_state_get(), config_get());
}

static TextLayer *make_text(Layer *root, GRect frame, const char *font_key, GTextAlignment align, GColor fg) {
    TextLayer *tl = text_layer_create(frame);
    text_layer_set_background_color(tl, GColorClear);
    text_layer_set_text_color(tl, fg);
    text_layer_set_font(tl, fonts_get_system_font(font_key));
    text_layer_set_text_alignment(tl, align);
    layer_add_child(root, text_layer_get_layer(tl));
    return tl;
}

void face_graph_focus_load(Window *window, Layer *root, GRect bounds) {
    (void)window;
    int w = bounds.size.w;
    int h = bounds.size.h;
    bool light = config_get()->color_scheme == COLOR_SCHEME_LIGHT;
    GColor fg = light ? GColorBlack : GColorWhite;
#ifdef PBL_COLOR
    GColor fg_muted = light ? GColorDarkGray : GColorLightGray;
#else
    GColor fg_muted = light ? GColorBlack : GColorWhite;
#endif
    int comp_h = 18;

    // Graph behind UI; reserve bottom row for complications (weather on Diorite, etc.)
    s_graph_layer = layer_create(GRect(0, 0, w, h - comp_h));
    layer_set_update_proc(s_graph_layer, graph_proc);
    layer_add_child(root, s_graph_layer);

    // Overlaid glucose - large, top-left
    s_glucose = make_text(root, GRect(4, -2, w / 2, 40), FONT_KEY_BITHAM_34_MEDIUM_NUMBERS, GTextAlignmentLeft, fg);
    text_layer_set_text(s_glucose, "--");

    // Trend arrow next to glucose
    s_trend = make_text(root, GRect(w / 2, 6, 40, 24), FONT_KEY_GOTHIC_24_BOLD, GTextAlignmentLeft, fg);

    // Delta below glucose
    s_delta = make_text(root, GRect(4, 34, w / 3, 16), FONT_KEY_GOTHIC_14, GTextAlignmentLeft, fg_muted);

    // Time - top right
    s_time = make_text(root, GRect(w - 52, 2, 48, 20), FONT_KEY_GOTHIC_18, GTextAlignmentRight, fg_muted);

    // IOB + COB — above complications strip
    s_iob_cob = make_text(root, GRect(4, h - comp_h - 18, w - 4, 16), FONT_KEY_GOTHIC_14, GTextAlignmentLeft, fg_muted);

    s_comp_layer = layer_create(GRect(0, h - comp_h, w, comp_h));
    layer_set_update_proc(s_comp_layer, comp_proc);
    layer_add_child(root, s_comp_layer);
}

void face_graph_focus_unload(void) {
    text_layer_destroy(s_glucose);
    text_layer_destroy(s_trend);
    text_layer_destroy(s_delta);
    text_layer_destroy(s_time);
    text_layer_destroy(s_iob_cob);
    layer_destroy(s_graph_layer);
    layer_destroy(s_comp_layer);
}

void face_graph_focus_update(AppState *state) {
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    strftime(s_time_buf, sizeof(s_time_buf), "%H:%M", t);
    text_layer_set_text(s_time, s_time_buf);

    text_layer_set_font(s_glucose, config_get()->is_mmol
                        ? FONT_KEY_GOTHIC_28_BOLD
                        : FONT_KEY_BITHAM_34_MEDIUM_NUMBERS);
    if (state->cgm.glucose > 0) {
        format_glucose_display_string(s_glucose_buf, sizeof(s_glucose_buf), state->cgm.glucose);
    } else {
        snprintf(s_glucose_buf, sizeof(s_glucose_buf), "--");
    }
    text_layer_set_text(s_glucose, s_glucose_buf);

#ifdef PBL_COLOR
    if (state->cgm.glucose > 0) {
        TrioConfig *cfg = &state->config;
        GColor gc;
        if (state->cgm.glucose <= cfg->low_threshold) gc = GColorRed;
        else if (state->cgm.glucose >= cfg->high_threshold) gc = GColorOrange;
        else gc = GColorGreen;
        text_layer_set_text_color(s_glucose, gc);
        text_layer_set_text_color(s_trend, gc);
    }
#endif

    text_layer_set_text(s_trend, state->cgm.trend_str);
    text_layer_set_text(s_delta, state->cgm.delta_str);

    snprintf(s_iob_cob_buf, sizeof(s_iob_cob_buf), "IOB:%s COB:%s", state->loop.iob, state->loop.cob);
    text_layer_set_text(s_iob_cob, s_iob_cob_buf);

    layer_mark_dirty(s_graph_layer);
    layer_mark_dirty(s_comp_layer);
}
