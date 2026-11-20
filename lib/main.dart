import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'features/subscriptions/data/subscription_background_runner.dart';

export 'app/app.dart' show TunnelForgeApp;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  installGlobalErrorHooks();
  runApp(const TunnelForgeApp());
}

@pragma('vm:entry-point')
Future<void> subscriptionBackgroundMain() => runSubscriptionBackgroundMain();
