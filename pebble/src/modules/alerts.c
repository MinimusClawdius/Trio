#include "alerts.h"

#define ALERT_REPEAT_MIN_SEC 60
#define URGENT_REPEAT_MIN_SEC 120
#define HIGH_CLEAR_HYSTERESIS_MGDL 8
#define LOW_CLEAR_HYSTERESIS_MGDL 8

// Vibration patterns
static const uint32_t VIBE_LOW[] = {300, 200, 300, 200, 600};
static const uint32_t VIBE_HIGH[] = {200, 100, 200};
static const uint32_t VIBE_URGENT[] = {400, 100, 400, 100, 400, 100, 800};

void alerts_init(void) {
    // Nothing to initialize; state is in AppState
}

static bool is_snoozed(AppState *state) {
    return time(NULL) < state->alerts.snooze_until;
}

void alerts_snooze(AppState *state) {
    state->alerts.snooze_until = time(NULL) + (state->config.alert_snooze_min * 60);
    state->alerts.high_active = false;
    state->alerts.low_active = false;
    state->alerts.urgent_low_active = false;
}

void alerts_check(AppState *state) {
    if (is_snoozed(state)) return;

    int16_t glucose = state->cgm.glucose;
    if (glucose <= 0 || state->cgm.is_stale) return;

    time_t now = time(NULL);
    TrioConfig *cfg = &state->config;

    // Urgent low — separate 120s cooldown so 30s HTTP polls do not re-vibrate.
    if (glucose <= cfg->urgent_low && glucose > 0) {
        if (now - state->alerts.last_urgent_alert_time >= URGENT_REPEAT_MIN_SEC) {
            state->alerts.urgent_low_active = true;
            state->alerts.last_urgent_alert_time = now;
            state->alerts.last_alert_time = now;
            VibePattern pat = { .durations = VIBE_URGENT, .num_segments = ARRAY_LENGTH(VIBE_URGENT) };
            vibes_enact_custom_pattern(pat);
        }
        return;
    }
    state->alerts.urgent_low_active = false;

    if (now - state->alerts.last_alert_time < ALERT_REPEAT_MIN_SEC) return;

    // Low — latch until clearly above threshold (reduces bounce at boundary)
    if (cfg->alert_low_enabled && glucose <= cfg->low_threshold) {
        if (!state->alerts.low_active) {
            state->alerts.low_active = true;
            state->alerts.last_alert_time = now;
            VibePattern pat = { .durations = VIBE_LOW, .num_segments = ARRAY_LENGTH(VIBE_LOW) };
            vibes_enact_custom_pattern(pat);
        }
        return;
    }
    if (glucose > cfg->low_threshold + LOW_CLEAR_HYSTERESIS_MGDL) {
        state->alerts.low_active = false;
    }

    // High — latch until clearly below threshold
    if (cfg->alert_high_enabled && glucose >= cfg->high_threshold) {
        if (!state->alerts.high_active) {
            state->alerts.high_active = true;
            state->alerts.last_alert_time = now;
            VibePattern pat = { .durations = VIBE_HIGH, .num_segments = ARRAY_LENGTH(VIBE_HIGH) };
            vibes_enact_custom_pattern(pat);
        }
        return;
    }
    if (glucose < cfg->high_threshold - HIGH_CLEAR_HYSTERESIS_MGDL) {
        state->alerts.high_active = false;
    }
}

bool alerts_is_active(AppState *state) {
    return state->alerts.high_active || state->alerts.low_active || state->alerts.urgent_low_active;
}
