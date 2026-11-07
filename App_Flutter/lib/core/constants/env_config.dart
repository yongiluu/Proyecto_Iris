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
  static String get groqApiKey => _read('GROQ_API_KEY');
  static String get locationIqKey => _read('LOCATIONIQ_KEY');
  static String get openWeatherKey => _read('OPENWEATHER_KEY');

  // Backend (Supabase). Son valores PUBLICOS (la anon key solo permite lo que dejan las reglas RLS).
  // Si SUPABASE_URL esta vacio, la app funciona como antes: sin cuentas y con las llaves de arriba.
  static String get supabaseUrl => _read('SUPABASE_URL');
  static String get supabaseAnonKey => _read('SUPABASE_ANON_KEY');
  static String get googleWebClientId => _read('GOOGLE_WEB_CLIENT_ID');
  static bool get backendConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static Future<void> init() async {
    await dotenv.load(fileName: '.env');
  }
}
