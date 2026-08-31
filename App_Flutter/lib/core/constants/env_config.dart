import 'package:flutter_dotenv/flutter_dotenv.dart';

class EnvConfig {
  static String get azureFoundryEndpoint => dotenv.env['AZURE_FOUNDRY_ENDPOINT'] ?? '';
  static String get azureFoundryKey => dotenv.env['AZURE_FOUNDRY_KEY'] ?? '';
  static String get azureSearchEndpoint => dotenv.env['AZURE_SEARCH_ENDPOINT'] ?? '';
  static String get azureSearchKey => dotenv.env['AZURE_SEARCH_KEY'] ?? '';
  static String get locationIqKey => dotenv.env['LOCATIONIQ_KEY'] ?? '';
  static String get openWeatherKey => dotenv.env['OPENWEATHER_KEY'] ?? '';
  static String get azureOpenAiEndpoint => dotenv.env['AZURE_OPENAI_ENDPOINT'] ?? '';
  static String get azureOpenAiKey => dotenv.env['AZURE_OPENAI_API_KEY'] ?? '';
  static String get azureSpeechKey => dotenv.env['AZURE_SPEECH_KEY'] ?? '';
  static String get azureSpeechRegion => dotenv.env['AZURE_SPEECH_REGION'] ?? '';
  static String get huggingFaceApiKey => dotenv.env['HUGGINGFACE_API_KEY'] ?? '';
  
  static Future<void> init() async {
    await dotenv.load(fileName: ".env");
  }
}
