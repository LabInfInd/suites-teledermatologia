import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/config/app_config.dart';

void main() {
  runApp(SuitesApp(dependencies: AppDependencies.production(AppConfig.fromEnvironment())));
}
