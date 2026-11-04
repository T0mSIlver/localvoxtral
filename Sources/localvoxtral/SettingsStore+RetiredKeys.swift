import Foundation

extension SettingsStore {
    /// Keys of settings the app no longer has. Every launch removes them, so a
    /// user's defaults never carry dead state that a later migration could
    /// mistake for a choice. A removed setting adds its keys here.
    static let retiredKeys: [String] = [
        // Commit interval (removed 2026-07).
        "settings.commit_interval_seconds",
        // The old mlx-audio backend (removed 2026-07).
        "settings.mlx_audio_endpoint_url",
        "settings.mlx_audio_model_name",
        "settings.mlx_audio_transcription_delay_ms",
        // Local Claude title fallback (removed 2026-09, #250).
        "settings.claude_local_title_marker_fallback_enabled",
        // speechd step interval: the helper sizes its steps itself (#639).
        "settings.speechd_step_cadence",
        // speechd memory limit (removed 2026-09, #832).
        "settings.speechd_cache_limit",
        // Dogfood capture (removed 2026-09, #797).
        "debug.dogfood_capture_enabled",
        // Realtime provider: one provider left (2026-11).
        "settings.realtime_provider",
        // Quick capture and voice memos (removed 2026-11).
        "settings.quick_capture_shortcut_key_code",
        "settings.quick_capture_shortcut_carbon_modifiers",
        "settings.quick_capture_shortcut_enabled",
        "settings.quick_capture_shortcut_chord",
        "settings.quick_capture_jev_enabled",
        "settings.quick_capture_router",
        "settings.quick_capture_project_lines",
        "settings.voice_memos_enabled",
        // Agent control (removed 2026-11).
        "settings.answer_agent_shortcut_key_code",
        "settings.answer_agent_shortcut_carbon_modifiers",
        "settings.answer_agent_shortcut_enabled",
        "settings.answer_agent_shortcut_chord",
        "settings.spoken_abort_phrases",
        "session_navigation.nicknames",
    ]
}
