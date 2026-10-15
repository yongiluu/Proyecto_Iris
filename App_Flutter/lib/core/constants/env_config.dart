import 'package:flutter_dotenv/flutter_dotenv.dart';

class EnvConfig {
  EnvConfig._();

  static String _read(String key) => (dotenv.env[key] ?? '').trim();

  static String get azureFoundryEndpoint => _read('AZURE_FOUNDRY_ENDPOINT');
  static String get azureFoundryKey => _read('AZURE_FOUNDRY_KEY');
  static String get azureFoundryDeployment {
    final value = _read('AZURE_FOUNDRY_DEPLOYMENT');
    return value.isEmpty ? 'gpt-4.1-mini' : value;
  }

  static String get azureSearchEndpoint => _read('AZURE_SEARCH_ENDPOINT');
  static String get azureSearchKey => _read('AZURE_SEARCH_KEY');
  static String get azureSpeechKey => _read('AZURE_SPEECH_KEY');
  static String get azureSpeechRegion => _read('AZURE_SPEECH_REGION');
  static String get huggingFaceApiKey => _read('HUGGINGFACE_API_KEY');
  static String get locationIqKey => _read('LOCATIONIQ_KEY');
  static String get openWeatherKey => _read('OPENWEATHER_KEY');

  static Future<void> init() async {
    await dotenv.load(fileName: '.env');
  }
}
