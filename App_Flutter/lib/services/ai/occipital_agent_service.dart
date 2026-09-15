import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import '../../core/constants/env_config.dart';

class OccipitalAgentService {
  static final OccipitalAgentService _instance = OccipitalAgentService._internal();

  factory OccipitalAgentService() => _instance;

  OccipitalAgentService._internal();

  static const String systemPrompt = '''
Eres Occipital, un asistente visual y de razonamiento avanzado y altamente confiable. ERES LOS OJOS DE UNA PERSONA CIEGA.
Tu directiva principal es la seguridad del usuario y la precision absoluta. 
TIENES ACCESO A HERRAMIENTAS Y ES OBLIGATORIO USARLAS CUANDO EL USUARIO PREGUNTE POR SU ENTORNO.
REGLA DE ORO: Si el usuario dice "Que ves aqui­?", "Describe esto", o cualquier cosa sobre su vision o entorno, DEBES LLAMAR INMEDIATAMENTE a `analyze_surroundings`. NO preguntes que quiere ver! Llama a la herramienta de inmediato!
1. Entorno/vision -> LLAMA A `analyze_surroundings`.
2. Ubicacion/Clima -> LLAMA A `get_weather_and_location`.
3. Salud/Medicinas -> LLAMA A `search_medical_database`.
4. Charla general -> RESPONDE DIRECTAMENTE.

RESPONDE SIEMPRE EN ESPANOL Y DE FORMA MUY BREVE, CORTA Y CONCISA. No des explicaciones largas.
''';

  bool _isInitialized = false;

  final double mockLat = -36.8282;
  final double mockLon = -73.0366;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
  }

  /// Sends the prompt to the reasoning agent which decides whether to use a tool or answer directly.
  Future<String?> processWithAgenticReasoning({
    required String userPrompt,
    required Future<Uint8List?> Function() captureImageCallback,
    Function(String status)? onStatusUpdate,
  }) async {
    debugPrint('ðŸ§  OccipitalAgentService: Thinking about prompt: $userPrompt');
    onStatusUpdate?.call('Pensando...');

    final endpoint = EnvConfig.azureFoundryEndpoint;
    final key = EnvConfig.azureFoundryKey;
    final deploymentName = 'gpt-4.1-mini';

    if (endpoint.isEmpty || key.isEmpty) {
      return "Las claves de API para Azure OpenAI no estan configuradas.";
    }

    final url = Uri.parse('https://occipital-east-resource.services.ai.azure.com/openai/v1/chat/completions');

    List<Map<String, dynamic>> messages = [
      {"role": "system", "content": systemPrompt},
      {"role": "user", "content": userPrompt}
    ];

    final tools = [
      {
        "type": "function",
        "function": {
          "name": "analyze_surroundings",
          "description": "Capture an image from the camera and analyze the user's surroundings.",
          "parameters": {"type": "object", "properties": {}}
        }
      },
      {
        "type": "function",
        "function": {
          "name": "get_weather_and_location",
          "description": "Get the current weather and GPS location of the user.",
          "parameters": {"type": "object", "properties": {}}
        }
      },
      {
        "type": "function",
        "function": {
          "name": "search_medical_database",
          "description": "Search the medical database for FDA guidelines or health info.",
          "parameters": {
            "type": "object",
            "properties": {
              "query": {"type": "string", "description": "The medical query"}
            },
            "required": ["query"]
          }
        }
      }
    ];

    try {
      // FIRST PASS: Let the model decide if it needs tools
      final response1 = await http.post(
        url,
        headers: {'Content-Type': 'application/json', 'api-key': key},
        body: jsonEncode({
          "model": deploymentName,
          "messages": messages,
          "tools": tools,
          "tool_choice": "auto",
          "max_tokens": 300,
        }),
      );

      if (response1.statusCode != 200) {
        debugPrint('Azure Error: ${response1.body}');
        return "Error al contactar al cerebro de Iris.";
      }

      final data1 = jsonDecode(response1.body);
      final choice = data1['choices'][0];
      final message = choice['message'];
      
      // If the model decides not to use tools, return its response
      if (message['tool_calls'] == null || (message['tool_calls'] as List).isEmpty) {
        return message['content'];
      }

      // Model wants to use a tool
      final toolCall = message['tool_calls'][0];
      final functionName = toolCall['function']['name'];
      final toolCallId = toolCall['id'];

      messages.add(message); // Add assistant's tool call to history

      String toolResult = "";

      if (functionName == 'analyze_surroundings') {
        onStatusUpdate?.call('Analizando vision...');
        final imageBytes = await captureImageCallback();
        if (imageBytes != null) {
          final base64Image = base64Encode(imageBytes);
          // For vision, we inject the image into the tool response
          messages.add({
            "role": "tool",
            "tool_call_id": toolCallId,
            "name": functionName,
            "content": "Imagen capturada exitosamente."
          });
          // We must append the image to the user message or as a new user message
          messages.add({
            "role": "user",
            "content": [
              {"type": "text", "text": "aqui­ tienes la imagen capturada para tu analisis:"},
              {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,$base64Image"}}
            ]
          });
        } else {
          messages.add({
             "role": "tool",
             "tool_call_id": toolCallId,
             "name": functionName,
             "content": "Error: No se pudo capturar la imagen."
          });
        }
      } else if (functionName == 'get_weather_and_location') {
        onStatusUpdate?.call('Obteniendo Clima y GPS...');
        toolResult = await _fetchLocationAndWeather();
        messages.add({
           "role": "tool",
           "tool_call_id": toolCallId,
           "name": functionName,
           "content": toolResult
        });
      } else if (functionName == 'search_medical_database') {
        onStatusUpdate?.call('Consultando Base de Datos Medica...');
        final args = jsonDecode(toolCall['function']['arguments']);
        toolResult = await _searchMedicalDB(args['query'] ?? userPrompt);
        messages.add({
           "role": "tool",
           "tool_call_id": toolCallId,
           "name": functionName,
           "content": toolResult
        });
      }

      // SECOND PASS: Send the tool result back to the model for final answer
      final response2 = await http.post(
        url,
        headers: {'Content-Type': 'application/json', 'api-key': key},
        body: jsonEncode({
          "model": deploymentName,
          "messages": messages,
          "max_tokens": 300,
        }),
      );

      if (response2.statusCode == 200) {
        final data2 = jsonDecode(response2.body);
        return data2['choices'][0]['message']['content'];
      } else {
        return "Error al analizar los resultados de las herramientas.";
      }

    } catch (e) {
      debugPrint('Exception in OccipitalAgentService: $e');
      return "Hubo un problema de conexion. Intentalo de nuevo.";
    }
  }

  Future<String> _fetchLocationAndWeather() async {
    String locationText = 'Unknown location';
    String weatherText = 'Unknown weather';
    double lat = mockLat;
    double lon = mockLon;

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (serviceEnabled) {
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
          Position position = await Geolocator.getCurrentPosition();
          lat = position.latitude;
          lon = position.longitude;
        }
      }
    } catch (e) { debugPrint('Error GPS: $e'); }

    try {
      if (EnvConfig.locationIqKey.isNotEmpty) {
        final locUrl = Uri.parse('https://us1.locationiq.com/v1/reverse?key=${EnvConfig.locationIqKey}&lat=$lat&lon=$lon&format=json');
        final locRes = await http.get(locUrl);
        if (locRes.statusCode == 200) {
          final data = jsonDecode(locRes.body);
          final address = data['address'];
          final road = address['road'] ?? 'una calle desconocida';
          final city = address['city'] ?? address['town'] ?? address['village'] ?? '';
          locationText = '$road, $city';
        }
      }

      if (EnvConfig.openWeatherKey.isNotEmpty) {
        final weatherUrl = Uri.parse('https://api.openweathermap.org/data/2.5/weather?lat=$lat&lon=$lon&appid=${EnvConfig.openWeatherKey}&units=metric&lang=es');
        final weatherRes = await http.get(weatherUrl);
        if (weatherRes.statusCode == 200) {
          final data = jsonDecode(weatherRes.body);
          final temp = data['main']['temp'];
          final tempRounded = (temp as num).round();
          final description = data['weather'][0]['description'];
          weatherText = '$tempRoundedÂ°C y $description';
        }
      }
      return "Ubicacion: $locationText. Clima: $weatherText.";
    } catch (e) {
      return "No se pudo obtener el clima o Ubicacion.";
    }
  }

  Future<String> _searchMedicalDB(String query) async {
    if (EnvConfig.azureSearchEndpoint.isEmpty || EnvConfig.azureSearchKey.isEmpty) {
      return "Base de datos Medica no configurada.";
    }
    try {
      final searchUrl = Uri.parse('${EnvConfig.azureSearchEndpoint}/indexes/insulina-fda-kb/docs/search?api-version=2023-11-01');
      final searchRes = await http.post(
        searchUrl,
        headers: {'Content-Type': 'application/json', 'api-key': EnvConfig.azureSearchKey},
        body: jsonEncode({"search": query, "top": 3}),
      );
      if (searchRes.statusCode == 200) {
        final data = jsonDecode(searchRes.body);
        final values = data['value'] as List;
        if (values.isNotEmpty) {
          return values.map((e) => e['content'] ?? '').join('\n');
        }
      }
      return "No se encontraron resultados en la base de datos Medica para la consulta: $query.";
    } catch (e) {
      return "Error al consultar la base de datos Medica.";
    }
  }

  Future<void> dispose() async {
    _isInitialized = false;
  }
}
