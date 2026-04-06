/*
 * Trio CGM Monitor - Pebble Watch App
 *
 * Displays blood glucose with trend graph, IOB, COB, delta,
 * and loop status. Supports bolus/carb entry with iPhone confirmation.
 */

#include <pebble.h>
#include "glucose_graph.h"

// ==================== AppMessage Keys ====================

#define KEY_GLUCOSE          0
#define KEY_TREND            1
#define KEY_IOB              2
#define KEY_IS_CLOSED_LOOP   3
#define KEY_COB              4
#define KEY_DELTA            5
#define KEY_REQUEST_DATA     6
#define KEY_BOLUS_REQUEST    7
#define KEY_CARB_REQUEST     8
#define KEY_ABSORPTION_HOURS 9
#define KEY_COMMAND_STATUS   10
#define KEY_COMMAND_MSG      11
#define KEY_GRAPH_COUNT      12
#define KEY_GRAPH_VALUES     13
#define KEY_EVENTUAL_BG      14
#define KEY_LAST_LOOP_MINS   15

// ==================== Alert Thresholds ====================

#define LOW_THRESHOLD  70
#define HIGH_THRESHOLD 180

// ==================== Bolus / Carb Limits ====================

#define BOLUS_MIN  0.05
#define BOLUS_MAX  10.0
#define BOLUS_STEP 0.05
#define CARBS_MIN  5
#define CARBS_MAX  200
#define CARBS_STEP 5

// ==================== UI Elements ====================

static Window *s_main_window;
static TextLayer *s_time_layer;
static TextLayer *s_glucose_layer;
static TextLayer *s_trend_layer;
static TextLayer *s_iob_layer;
static TextLayer *s_cob_layer;
static TextLayer *s_delta_layer;
static TextLayer *s_status_layer;
static TextLayer *s_hint_layer;
static Layer *s_graph_layer;

static Window *s_menu_window;
static SimpleMenuLayer *s_menu_layer;
static SimpleMenuItem s_menu_items[2];
static SimpleMenuSection s_menu_section;

static Window *s_bolus_window;
static TextLayer *s_bolus_title_layer;
static TextLayer *s_bolus_amount_layer;
static TextLayer *s_bolus_hint_layer;

static Window *s_carbs_window;
static TextLayer *s_carbs_title_layer;
static TextLayer *s_carbs_amount_layer;
static TextLayer *s_carbs_hint_layer;

static Window *s_confirm_window;
static TextLayer *s_confirm_title_layer;
static TextLayer *s_confirm_msg_layer;

// ==================== Data Buffers ====================

static char s_glucose_buf[16];
static char s_trend_buf[8];
static char s_iob_buf[24];
static char s_cob_buf[24];
static char s_delta_buf[16];
static char s_status_buf[32];
static char s_time_buf[8];
static char s_amount_buf[16];

static double s_bolus_amount = 0.5;
static int s_carbs_amount = 10;

// ==================== Helpers ====================

static void request_data(void) {
    DictionaryIterator *iter;
    if (app_message_outbox_begin(&iter) == APP_MSG_OK) {
        dict_write_uint8(iter, KEY_REQUEST_DATA, 1);
        app_message_outbox_send();
    }
}

static void request_bolus(double units) {
    DictionaryIterator *iter;
    if (app_message_outbox_begin(&iter) == APP_MSG_OK) {
        dict_write_int32(iter, KEY_BOLUS_REQUEST, (int)(units * 20));
        app_message_outbox_send();
    }
}

static void request_carbs(int grams) {
    DictionaryIterator *iter;
    if (app_message_outbox_begin(&iter) == APP_MSG_OK) {
        dict_write_int32(iter, KEY_CARB_REQUEST, grams);
        dict_write_int32(iter, KEY_ABSORPTION_HOURS, 3);
        app_message_outbox_send();
    }
}

static void update_time(void) {
    time_t temp = time(NULL);
    struct tm *tick_time = localtime(&temp);
    strftime(s_time_buf, sizeof(s_time_buf), "%H:%M", tick_time);
    text_layer_set_text(s_time_layer, s_time_buf);
}

static void check_alerts(int glucose) {
    static time_t last_alert = 0;
    time_t now = time(NULL);
    if (now - last_alert < 15 * 60) return;

    if (glucose > 0 && glucose < LOW_THRESHOLD) {
        vibes_double_pulse();
        last_alert = now;
    } else if (glucose > HIGH_THRESHOLD) {
        vibes_short_pulse();
        last_alert = now;
    }
}

// ==================== Confirmation Window ====================

static void confirm_window_load(Window *window) {
    Layer *root = window_get_root_layer(window);
    GRect bounds = layer_get_bounds(root);

    s_confirm_title_layer = text_layer_create(GRect(0, 20, bounds.size.w, 30));
    text_layer_set_font(s_confirm_title_layer, fonts_get_system_font(FONT_KEY_GOTHIC_24_BOLD));
    text_layer_set_text_alignment(s_confirm_title_layer, GTextAlignmentCenter);
    text_layer_set_text(s_confirm_title_layer, "Request Sent!");
    text_layer_set_background_color(s_confirm_title_layer, GColorClear);
#ifdef PBL_COLOR
    text_layer_set_text_color(s_confirm_title_layer, GColorGreen);
#endif
    layer_add_child(root, text_layer_get_layer(s_confirm_title_layer));

    s_confirm_msg_layer = text_layer_create(GRect(10, 60, bounds.size.w - 20, 80));
    text_layer_set_font(s_confirm_msg_layer, fonts_get_system_font(FONT_KEY_GOTHIC_18));
    text_layer_set_text_alignment(s_confirm_msg_layer, GTextAlignmentCenter);
    text_layer_set_text(s_confirm_msg_layer, "Check your iPhone to confirm.");
    text_layer_set_background_color(s_confirm_msg_layer, GColorClear);
    layer_add_child(root, text_layer_get_layer(s_confirm_msg_layer));
}

static void confirm_window_unload(Window *window) {
    text_layer_destroy(s_confirm_title_layer);
    text_layer_destroy(s_confirm_msg_layer);
}

static void confirm_timer_callback(void *data) {
    window_stack_pop(true);
}

static void show_confirmation(const char *message) {
    s_confirm_window = window_create();
    window_set_background_color(s_confirm_window, GColorBlack);
    window_set_window_handlers(s_confirm_window, (WindowHandlers) {
        .load = confirm_window_load,
        .unload = confirm_window_unload
    });
    window_stack_push(s_confirm_window, true);

    if (message) {
        text_layer_set_text(s_confirm_msg_layer, message);
    }
    app_timer_register(3000, confirm_timer_callback, NULL);
}

// ==================== Bolus Entry ====================

static void update_bolus_display(void) {
    snprintf(s_amount_buf, sizeof(s_amount_buf), "%.2f U", s_bolus_amount);
    text_layer_set_text(s_bolus_amount_layer, s_amount_buf);
}

static void bolus_select_click(ClickRecognizerRef recognizer, void *context) {
    request_bolus(s_bolus_amount);
    window_stack_pop(false);
    show_confirmation("Confirm bolus on iPhone");
}

static void bolus_up_click(ClickRecognizerRef recognizer, void *context) {
    if (s_bolus_amount + BOLUS_STEP <= BOLUS_MAX) {
        s_bolus_amount += BOLUS_STEP;
        update_bolus_display();
        vibes_short_pulse();
    }
}

static void bolus_down_click(ClickRecognizerRef recognizer, void *context) {
    if (s_bolus_amount - BOLUS_STEP >= BOLUS_MIN) {
        s_bolus_amount -= BOLUS_STEP;
        update_bolus_display();
        vibes_short_pulse();
    }
}

static void bolus_click_config(void *context) {
    window_single_click_subscribe(BUTTON_ID_SELECT, bolus_select_click);
    window_single_click_subscribe(BUTTON_ID_UP, bolus_up_click);
    window_single_click_subscribe(BUTTON_ID_DOWN, bolus_down_click);
}

static void bolus_window_load(Window *window) {
    Layer *root = window_get_root_layer(window);
    GRect bounds = layer_get_bounds(root);

    s_bolus_title_layer = text_layer_create(GRect(0, 10, bounds.size.w, 30));
    text_layer_set_font(s_bolus_title_layer, fonts_get_system_font(FONT_KEY_GOTHIC_24_BOLD));
    text_layer_set_text_alignment(s_bolus_title_layer, GTextAlignmentCenter);
    text_layer_set_text(s_bolus_title_layer, "Request Bolus");
    text_layer_set_background_color(s_bolus_title_layer, GColorClear);
    layer_add_child(root, text_layer_get_layer(s_bolus_title_layer));

    s_bolus_amount_layer = text_layer_create(GRect(0, 50, bounds.size.w, 40));
    text_layer_set_font(s_bolus_amount_layer, fonts_get_system_font(FONT_KEY_BITHAM_30_BLACK));
    text_layer_set_text_alignment(s_bolus_amount_layer, GTextAlignmentCenter);
    text_layer_set_background_color(s_bolus_amount_layer, GColorClear);
#ifdef PBL_COLOR
    text_layer_set_text_color(s_bolus_amount_layer, GColorCyan);
#endif
    layer_add_child(root, text_layer_get_layer(s_bolus_amount_layer));

    s_bolus_hint_layer = text_layer_create(GRect(10, 100, bounds.size.w - 20, 60));
    text_layer_set_font(s_bolus_hint_layer, fonts_get_system_font(FONT_KEY_GOTHIC_14));
    text_layer_set_text_alignment(s_bolus_hint_layer, GTextAlignmentCenter);
    text_layer_set_text(s_bolus_hint_layer, "UP/DOWN adjust\nSELECT to send\nRequires iPhone confirm");
    text_layer_set_background_color(s_bolus_hint_layer, GColorClear);
    layer_add_child(root, text_layer_get_layer(s_bolus_hint_layer));

    update_bolus_display();
}

static void bolus_window_unload(Window *window) {
    text_layer_destroy(s_bolus_title_layer);
    text_layer_destroy(s_bolus_amount_layer);
    text_layer_destroy(s_bolus_hint_layer);
}

// ==================== Carb Entry ====================

static void update_carbs_display(void) {
    snprintf(s_amount_buf, sizeof(s_amount_buf), "%d g", s_carbs_amount);
    text_layer_set_text(s_carbs_amount_layer, s_amount_buf);
}

static void carbs_select_click(ClickRecognizerRef recognizer, void *context) {
    request_carbs(s_carbs_amount);
    window_stack_pop(false);
    show_confirmation("Confirm carbs on iPhone");
}

static void carbs_up_click(ClickRecognizerRef recognizer, void *context) {
    if (s_carbs_amount + CARBS_STEP <= CARBS_MAX) {
        s_carbs_amount += CARBS_STEP;
        update_carbs_display();
        vibes_short_pulse();
    }
}

static void carbs_down_click(ClickRecognizerRef recognizer, void *context) {
    if (s_carbs_amount - CARBS_STEP >= CARBS_MIN) {
        s_carbs_amount -= CARBS_STEP;
        update_carbs_display();
        vibes_short_pulse();
    }
}

static void carbs_click_config(void *context) {
    window_single_click_subscribe(BUTTON_ID_SELECT, carbs_select_click);
    window_single_click_subscribe(BUTTON_ID_UP, carbs_up_click);
    window_single_click_subscribe(BUTTON_ID_DOWN, carbs_down_click);
}

static void carbs_window_load(Window *window) {
    Layer *root = window_get_root_layer(window);
    GRect bounds = layer_get_bounds(root);

    s_carbs_title_layer = text_layer_create(GRect(0, 10, bounds.size.w, 30));
    text_layer_set_font(s_carbs_title_layer, fonts_get_system_font(FONT_KEY_GOTHIC_24_BOLD));
    text_layer_set_text_alignment(s_carbs_title_layer, GTextAlignmentCenter);
    text_layer_set_text(s_carbs_title_layer, "Log Carbs");
    text_layer_set_background_color(s_carbs_title_layer, GColorClear);
    layer_add_child(root, text_layer_get_layer(s_carbs_title_layer));

    s_carbs_amount_layer = text_layer_create(GRect(0, 50, bounds.size.w, 40));
    text_layer_set_font(s_carbs_amount_layer, fonts_get_system_font(FONT_KEY_BITHAM_30_BLACK));
    text_layer_set_text_alignment(s_carbs_amount_layer, GTextAlignmentCenter);
    text_layer_set_background_color(s_carbs_amount_layer, GColorClear);
#ifdef PBL_COLOR
    text_layer_set_text_color(s_carbs_amount_layer, GColorOrange);
#endif
    layer_add_child(root, text_layer_get_layer(s_carbs_amount_layer));

    s_carbs_hint_layer = text_layer_create(GRect(10, 100, bounds.size.w - 20, 60));
    text_layer_set_font(s_carbs_hint_layer, fonts_get_system_font(FONT_KEY_GOTHIC_14));
    text_layer_set_text_alignment(s_carbs_hint_layer, GTextAlignmentCenter);
    text_layer_set_text(s_carbs_hint_layer, "UP/DOWN adjust\nSELECT to send\nRequires iPhone confirm");
    text_layer_set_background_color(s_carbs_hint_layer, GColorClear);
    layer_add_child(root, text_layer_get_layer(s_carbs_hint_layer));

    update_carbs_display();
}

static void carbs_window_unload(Window *window) {
    text_layer_destroy(s_carbs_title_layer);
    text_layer_destroy(s_carbs_amount_layer);
    text_layer_destroy(s_carbs_hint_layer);
}

// ==================== Command Menu ====================

static void menu_bolus_callback(int index, void *ctx) {
    s_bolus_amount = 0.5;
    s_bolus_window = window_create();
    window_set_background_color(s_bolus_window, GColorBlack);
    window_set_click_config_provider(s_bolus_window, bolus_click_config);
    window_set_window_handlers(s_bolus_window, (WindowHandlers) {
        .load = bolus_window_load,
        .unload = bolus_window_unload
    });
    window_stack_push(s_bolus_window, true);
}

static void menu_carbs_callback(int index, void *ctx) {
    s_carbs_amount = 10;
    s_carbs_window = window_create();
    window_set_background_color(s_carbs_window, GColorBlack);
    window_set_click_config_provider(s_carbs_window, carbs_click_config);
    window_set_window_handlers(s_carbs_window, (WindowHandlers) {
        .load = carbs_window_load,
        .unload = carbs_window_unload
    });
    window_stack_push(s_carbs_window, true);
}

static void menu_window_load(Window *window) {
    Layer *root = window_get_root_layer(window);
    GRect bounds = layer_get_bounds(root);

    s_menu_items[0] = (SimpleMenuItem) {
        .title = "Request Bolus",
        .callback = menu_bolus_callback,
    };
    s_menu_items[1] = (SimpleMenuItem) {
        .title = "Log Carbs",
        .callback = menu_carbs_callback,
    };

    s_menu_section = (SimpleMenuSection) {
        .items = s_menu_items,
        .num_items = 2,
    };

    s_menu_layer = simple_menu_layer_create(bounds, window, &s_menu_section, 1, NULL);
    layer_add_child(root, simple_menu_layer_get_layer(s_menu_layer));
}

static void menu_window_unload(Window *window) {
    simple_menu_layer_destroy(s_menu_layer);
}

// ==================== AppMessage Callbacks ====================

static void inbox_received_callback(DictionaryIterator *iterator, void *context) {
    // Command status feedback
    Tuple *status_tuple = dict_find(iterator, KEY_COMMAND_STATUS);
    if (status_tuple) {
        Tuple *msg_tuple = dict_find(iterator, KEY_COMMAND_MSG);
        const char *msg = msg_tuple ? msg_tuple->value->cstring : NULL;
        int status = (int)status_tuple->value->int32;
        if (status == 1) {
            show_confirmation(msg ? msg : "Check iPhone to confirm");
        } else if (status == -1) {
            show_confirmation(msg ? msg : "Request failed");
        }
        return;
    }

    // Glucose
    Tuple *glucose_tuple = dict_find(iterator, KEY_GLUCOSE);
    if (glucose_tuple) {
        int glucose = (int)glucose_tuple->value->int32;
        snprintf(s_glucose_buf, sizeof(s_glucose_buf), "%d", glucose);
        text_layer_set_text(s_glucose_layer, s_glucose_buf);
        check_alerts(glucose);

#ifdef PBL_COLOR
        if (glucose < LOW_THRESHOLD) {
            text_layer_set_text_color(s_glucose_layer, GColorRed);
        } else if (glucose > HIGH_THRESHOLD) {
            text_layer_set_text_color(s_glucose_layer, GColorOrange);
        } else {
            text_layer_set_text_color(s_glucose_layer, GColorGreen);
        }
#endif
    }

    // Trend
    Tuple *trend_tuple = dict_find(iterator, KEY_TREND);
    if (trend_tuple) {
        snprintf(s_trend_buf, sizeof(s_trend_buf), "%s", trend_tuple->value->cstring);
        text_layer_set_text(s_trend_layer, s_trend_buf);
    }

    // IOB
    Tuple *iob_tuple = dict_find(iterator, KEY_IOB);
    if (iob_tuple) {
        int iob = (int)iob_tuple->value->int32;
        snprintf(s_iob_buf, sizeof(s_iob_buf), "IOB:%d.%dU", iob / 10, abs(iob % 10));
        text_layer_set_text(s_iob_layer, s_iob_buf);
    }

    // COB
    Tuple *cob_tuple = dict_find(iterator, KEY_COB);
    if (cob_tuple) {
        int cob = (int)cob_tuple->value->int32;
        snprintf(s_cob_buf, sizeof(s_cob_buf), "COB:%dg", cob);
        text_layer_set_text(s_cob_layer, s_cob_buf);
    }

    // Delta
    Tuple *delta_tuple = dict_find(iterator, KEY_DELTA);
    if (delta_tuple) {
        int delta = (int)delta_tuple->value->int32;
        int whole = delta / 10;
        int frac = abs(delta % 10);
        if (delta >= 0) {
            snprintf(s_delta_buf, sizeof(s_delta_buf), "+%d.%d", whole, frac);
        } else {
            snprintf(s_delta_buf, sizeof(s_delta_buf), "%d.%d", whole, frac);
        }
        text_layer_set_text(s_delta_layer, s_delta_buf);
    }

    // Loop status
    Tuple *loop_tuple = dict_find(iterator, KEY_IS_CLOSED_LOOP);
    if (loop_tuple) {
        bool is_closed = loop_tuple->value->int32 > 0;

        Tuple *mins_tuple = dict_find(iterator, KEY_LAST_LOOP_MINS);
        if (mins_tuple) {
            int mins = (int)mins_tuple->value->int32;
            snprintf(s_status_buf, sizeof(s_status_buf), "%s %dm",
                     is_closed ? "Loop:ON" : "Loop:OFF", mins);
        } else {
            snprintf(s_status_buf, sizeof(s_status_buf), "%s",
                     is_closed ? "Loop: ON" : "Loop: OFF");
        }
        text_layer_set_text(s_status_layer, s_status_buf);

#ifdef PBL_COLOR
        text_layer_set_text_color(s_status_layer, is_closed ? GColorGreen : GColorRed);
#endif
    }

    // Graph data
    Tuple *graph_count_tuple = dict_find(iterator, KEY_GRAPH_COUNT);
    Tuple *graph_values_tuple = dict_find(iterator, KEY_GRAPH_VALUES);
    if (graph_count_tuple && graph_values_tuple) {
        int count = (int)graph_count_tuple->value->int32;
        uint8_t *raw = graph_values_tuple->value->data;
        int len = graph_values_tuple->length;

        if (count > 0 && len >= count * 2) {
            uint16_t values[MAX_GRAPH_POINTS];
            int n = count < MAX_GRAPH_POINTS ? count : MAX_GRAPH_POINTS;
            for (int i = 0; i < n; i++) {
                values[i] = (uint16_t)(raw[i * 2] | (raw[i * 2 + 1] << 8));
            }
            glucose_graph_set_data(values, n);
            layer_mark_dirty(s_graph_layer);
        }
    }

    update_time();
}

static void inbox_dropped_callback(AppMessageResult reason, void *context) {
    APP_LOG(APP_LOG_LEVEL_ERROR, "Message dropped: %d", reason);
}

static void outbox_failed_callback(DictionaryIterator *iterator, AppMessageResult reason, void *context) {
    APP_LOG(APP_LOG_LEVEL_ERROR, "Outbox send failed: %d", reason);
}

static void outbox_sent_callback(DictionaryIterator *iterator, void *context) {
    APP_LOG(APP_LOG_LEVEL_DEBUG, "Outbox send success");
}

// ==================== Main Window ====================

static void main_select_click(ClickRecognizerRef recognizer, void *context) {
    s_menu_window = window_create();
    window_set_window_handlers(s_menu_window, (WindowHandlers) {
        .load = menu_window_load,
        .unload = menu_window_unload
    });
    window_stack_push(s_menu_window, true);
}

static void main_click_config(void *context) {
    window_single_click_subscribe(BUTTON_ID_SELECT, main_select_click);
}

static void tick_handler(struct tm *tick_time, TimeUnits units_changed) {
    update_time();
    if (tick_time->tm_min % 5 == 0) {
        request_data();
    }
}

static void main_window_load(Window *window) {
    Layer *root = window_get_root_layer(window);
    GRect bounds = layer_get_bounds(root);
    int w = bounds.size.w;

    // Time (Y 0-20)
    s_time_layer = text_layer_create(GRect(0, 0, w, 20));
    text_layer_set_font(s_time_layer, fonts_get_system_font(FONT_KEY_GOTHIC_18_BOLD));
    text_layer_set_text_alignment(s_time_layer, GTextAlignmentCenter);
    text_layer_set_background_color(s_time_layer, GColorClear);
    layer_add_child(root, text_layer_get_layer(s_time_layer));

    // Glucose (Y 20-56) - large
    s_glucose_layer = text_layer_create(GRect(0, 20, w - 30, 36));
    text_layer_set_font(s_glucose_layer, fonts_get_system_font(FONT_KEY_BITHAM_30_BLACK));
    text_layer_set_text_alignment(s_glucose_layer, GTextAlignmentCenter);
    text_layer_set_background_color(s_glucose_layer, GColorClear);
    text_layer_set_text(s_glucose_layer, "---");
    layer_add_child(root, text_layer_get_layer(s_glucose_layer));

    // Trend arrow (right of glucose)
    s_trend_layer = text_layer_create(GRect(w - 30, 24, 30, 30));
    text_layer_set_font(s_trend_layer, fonts_get_system_font(FONT_KEY_GOTHIC_24_BOLD));
    text_layer_set_text_alignment(s_trend_layer, GTextAlignmentCenter);
    text_layer_set_background_color(s_trend_layer, GColorClear);
    layer_add_child(root, text_layer_get_layer(s_trend_layer));

    // Delta (Y 56-72)
    s_delta_layer = text_layer_create(GRect(0, 56, w, 16));
    text_layer_set_font(s_delta_layer, fonts_get_system_font(FONT_KEY_GOTHIC_14));
    text_layer_set_text_alignment(s_delta_layer, GTextAlignmentCenter);
    text_layer_set_background_color(s_delta_layer, GColorClear);
    layer_add_child(root, text_layer_get_layer(s_delta_layer));

    // IOB (Y 72-88, left half)
    s_iob_layer = text_layer_create(GRect(0, 72, w / 2, 16));
    text_layer_set_font(s_iob_layer, fonts_get_system_font(FONT_KEY_GOTHIC_14));
    text_layer_set_text_alignment(s_iob_layer, GTextAlignmentCenter);
    text_layer_set_background_color(s_iob_layer, GColorClear);
    text_layer_set_text(s_iob_layer, "IOB:--");
    layer_add_child(root, text_layer_get_layer(s_iob_layer));

    // COB (Y 72-88, right half)
    s_cob_layer = text_layer_create(GRect(w / 2, 72, w / 2, 16));
    text_layer_set_font(s_cob_layer, fonts_get_system_font(FONT_KEY_GOTHIC_14));
    text_layer_set_text_alignment(s_cob_layer, GTextAlignmentCenter);
    text_layer_set_background_color(s_cob_layer, GColorClear);
    text_layer_set_text(s_cob_layer, "COB:--");
    layer_add_child(root, text_layer_get_layer(s_cob_layer));

    // Loop status (Y 88-102)
    s_status_layer = text_layer_create(GRect(0, 88, w, 14));
    text_layer_set_font(s_status_layer, fonts_get_system_font(FONT_KEY_GOTHIC_14_BOLD));
    text_layer_set_text_alignment(s_status_layer, GTextAlignmentCenter);
    text_layer_set_background_color(s_status_layer, GColorClear);
    text_layer_set_text(s_status_layer, "Loop: --");
    layer_add_child(root, text_layer_get_layer(s_status_layer));

    // Glucose graph (Y 102-156, 54px tall)
    int graph_y = 102;
    int graph_h = bounds.size.h - graph_y - 14;
    if (graph_h < 30) graph_h = 30;
    s_graph_layer = layer_create(GRect(0, graph_y, w, graph_h));
    layer_set_update_proc(s_graph_layer, glucose_graph_update_proc);
    layer_add_child(root, s_graph_layer);

    // Hint (bottom)
    s_hint_layer = text_layer_create(GRect(0, bounds.size.h - 14, w, 14));
    text_layer_set_font(s_hint_layer, fonts_get_system_font(FONT_KEY_GOTHIC_14));
    text_layer_set_text_alignment(s_hint_layer, GTextAlignmentCenter);
    text_layer_set_background_color(s_hint_layer, GColorClear);
    text_layer_set_text(s_hint_layer, "SELECT for actions");
    layer_add_child(root, text_layer_get_layer(s_hint_layer));
}

static void main_window_unload(Window *window) {
    text_layer_destroy(s_time_layer);
    text_layer_destroy(s_glucose_layer);
    text_layer_destroy(s_trend_layer);
    text_layer_destroy(s_delta_layer);
    text_layer_destroy(s_iob_layer);
    text_layer_destroy(s_cob_layer);
    text_layer_destroy(s_status_layer);
    text_layer_destroy(s_hint_layer);
    layer_destroy(s_graph_layer);
}

// ==================== Init / Deinit ====================

static void init(void) {
    glucose_graph_init();

    app_message_register_inbox_received(inbox_received_callback);
    app_message_register_inbox_dropped(inbox_dropped_callback);
    app_message_register_outbox_failed(outbox_failed_callback);
    app_message_register_outbox_sent(outbox_sent_callback);
    app_message_open(app_message_inbox_size_maximum(), 256);

    s_main_window = window_create();
    window_set_background_color(s_main_window, GColorBlack);
    window_set_click_config_provider(s_main_window, main_click_config);
    window_set_window_handlers(s_main_window, (WindowHandlers) {
        .load = main_window_load,
        .unload = main_window_unload
    });
    window_stack_push(s_main_window, true);

    tick_timer_service_subscribe(MINUTE_UNIT, tick_handler);

    request_data();
    update_time();
}

static void deinit(void) {
    window_destroy(s_main_window);
    glucose_graph_deinit();
}

int main(void) {
    init();
    app_event_loop();
    deinit();
}
