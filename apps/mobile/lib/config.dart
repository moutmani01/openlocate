/// Build-time configuration. Never hard-code a production backend; pass it with
/// `--dart-define=BACKEND_URL=https://...` or set it in the app's settings.
class AppConfig {
  static const backendUrl = String.fromEnvironment('BACKEND_URL');
  static const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

  /// Raster tiles. OpenStreetMap's own servers are fine for testing only; self-hosters and
  /// production builds should point this at their own or a commercial tile service.
  static const tileUrl = String.fromEnvironment('MAP_TILE_URL', defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');

  /// Unsent fixes kept while offline (oldest dropped first).
  static const maxQueue = 10000;
  static const maxHistoryPerMember = 5000;
}
