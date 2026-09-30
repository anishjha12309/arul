/// The app's UI language, registered on every event — same name as the person property `identify`
/// sets at sign-in, so a breakdown reads one column whichever scope it picks.
const kAppLanguageProperty = 'app_language';

/// Which rung decided that language: `pick`, `link`, `geo`, `phone` or `default`.
const kLanguageSourceProperty = 'language_source';

/// The device quality rung this phone resolved to: `low`, `mid` or `high` ([DeviceTier]).
/// Registered, not evented: it costs no new event and lets any later metric split by how much
/// phone the person is holding — the split the sign-in and apply funnels keep asking for.
const kDeviceTierProperty = 'device_tier';

/// The region `GET /geo` reported for this install, raw, or `none` -> how often the region default is right.
const kGeoRegionProperty = 'geo_region';

/// Diagnostics only PostHog reads (`JourneyStamps`, the Worker's login analytics). GA4 caps an event
/// at 25 parameters and a project at 25 user properties, and shows neither until registered -> the
/// GA4 sink drops these on events AND on `register`, so they never crowd out what its reports use.
/// Keys GA4 already reports on (`upi_apps`, `paywall_source`, `low_ram`, `install_*`) stay off it.
const kPostHogOnlyProperties = <String>{
  'attempt_n',
  'ms_since_launch',
  'prev_outcome',
  's_since_prev_outcome',
  'left_since_prev',
  'cancels_n',
  'fails_n',
  's_since_first_attempt',
  's_since_install',
  'app_paused_n',
  'ms_since_resume',
  'ms_credential',
  'ms_exchange',
  'net_kbps',
  'net_up_kbps',
  'net_validated',
  'net_vpn',
  'net_metered',
  'new_user',
  'sub_status',
  'trial_used',
  'account_age_d',
  'internal',
  'paid_before',
  'referred',
  'checkout_n',
  'paywall_n',
  'gate_kind',
  'gate_category',
  'gate_item',
  'cards_n',
  'previews_n',
  's_since_login',
  's_on_paywall',
  's_tap_to_trial',
  'click_to_install_s',
  'install_to_open_s',
  'launch_n',
  'install_age_d',
  'text_scale',
  'sys_dark',
  'first_frame_ms',
  'ram_gb',
  'soc',
  'gms_version',
  'gms_status',
  'play_store_version',
  'power_saver',
  'boot_age_min',
  'avail_mem_mb',
  'low_mem_now',
  'free_storage_mb',
  'battery_pct',
  'charging',
  'abi',
  'slow_frames',
  'worst_frame_ms',
  'wall_clip',
  'wall_reason',
  'geo_outcome',
  'geo_ms',
  'region_wait',
  'warm_ms',
  'thermal',
  'ms_before_main',
  'launch_source',
  'data_saver',
  'isp',
  'rtt_ms',
  'colo',
  'region_code',
  'asn',
  'http',
  'tls',
  'picker_opens',
  'picked_app',
};

/// Single interface for all analytics events.
/// `analyticsServiceProvider` assembles PostHog, GA4 and Meta behind it -> call sites never change.
abstract interface class AnalyticsService {
  void track(String event, {Map<String, Object?>? properties});
  void identify(String userId, {Map<String, Object?>? userProperties});
  void screen(String name, {Map<String, Object?>? properties});
  void reset();

  /// A property stamped on EVERY later event, not just on the person.
  /// Survives [reset]: each sink re-applies what was registered, so a sign-out never strips it.
  void register(String key, Object value);
}

/// No-op fallback when no backend is configured -> `flutter test`, CI and key-less builds send nothing.
class NoOpAnalyticsService implements AnalyticsService {
  const NoOpAnalyticsService();

  @override
  void track(String event, {Map<String, Object?>? properties}) {}

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}

  @override
  void register(String key, Object value) {}
}
