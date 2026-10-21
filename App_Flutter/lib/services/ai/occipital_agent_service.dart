import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/env_config.dart';

class OccipitalAgentService {
  static final OccipitalAgentService _instance = OccipitalAgentService._internal();

  factory OccipitalAgentService() => _instance;

  OccipitalAgentService._internal();

  static const Duration _requestTimeout = Duration(seconds: 30);
  static const Duration _toolTimeout = Duration(seconds: 15);
  static const int _maxTokens = 300;

  static const String cameraFailedMessage = 'No pude ver con la camara, intenta de nuevo en unos segundos.';

  // Preguntas que piden mirar al frente: se pide la foto al tiro, sin esperar a que el LLM
  // decida llamar analyze_surroundings (eso costaba una vuelta completa al modelo).
  static final RegExp _visionRequest = RegExp(
    r'(que hay (en)?frente|que hay (a|de)?delante|describ|que ves|que estoy viendo|\bmira\b|\bmirame\b|'
    r'analiza(r)? (la )?vision|que tengo (al |en )?frente|que tengo (a|de)?delante|que hay al frente)',
  );

  // Texto de llamadas a herramientas, razonamiento o estado interno que a veces el modelo escribe
  // en vez de (o ademas de) usar tool_calls. Nunca se habla ni se muestra.
  static const Map<String, String> _toolNames = {
    'analyze_surroundings': 'analyze_surroundings',
    'analyze surroundings': 'analyze_surroundings',
    'analyse surroundings': 'analyze_surroundings',
    'analyse_surroundings': 'analyze_surroundings',
    'get_weather_and_location': 'get_weather_and_location',
    'weather and location': 'get_weather_and_location',
    'search_medical_database': 'search_medical_database',
    'medical database': 'search_medical_database',
  };
  static final RegExp _leakPattern = RegExp(
    r'(llamando a|llamare a|voy a llamar|invocando|ejecutando la herramienta|usando la herramienta|'
    r'usare la herramienta|calling|call(ing)? the (tool|function)|tool_call|function_call|<tool|</?function|'
    r'analy[sz]e[ _]surroundings|get_weather_and_location|search_medical_database|^\s*[\[{].*[\]}]\s*$)',
    caseSensitive: false,
  );

  /// Quita las frases que filtran herramientas o JSON. Devuelve el texto limpio (puede quedar vacio).
  static String cleanReply(String text) {
    final sentences = text.split(RegExp(r'(?<=[.!?\n])\s+'));
    final kept = sentences.where((s) => s.trim().isNotEmpty && !_leakPattern.hasMatch(s)).toList();
    return kept.join(' ').replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }

  /// Si el texto menciona una herramienta (sin haberla llamado de verdad), cual.
  static String? leakedTool(String text) {
    final lower = text.toLowerCase();
    for (final entry in _toolNames.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return null;
  }

  static const String _noClearAnswer = 'No pude obtener una respuesta clara. Intentalo de nuevo.';

  /// Respuesta final para hablar: sin texto de herramientas; si no queda nada, un mensaje corto.
  static String? _speakable(String? content) {
    if (content == null) return null;
    final clean = cleanReply(content);
    if (clean != content.trim()) debugPrint('Texto interno filtrado de la respuesta: $content');
    return clean.isEmpty ? _noClearAnswer : clean;
  }

  /// true si la pregunta pide describir lo que hay adelante (sin tildes ni mayusculas).
  static bool wantsVision(String prompt) => _visionRequest.hasMatch(_normalize(prompt));

  static String _normalize(String text) {
    const from = 'áéíóúüñ';
    const to = 'aeiouun';
    final lower = text.toLowerCase();
    final buffer = StringBuffer();
    for (final rune in lower.runes) {
      final char = String.fromCharCode(rune);
      final i = from.indexOf(char);
      buffer.write(i >= 0 ? to[i] : char);
    }
    return buffer.toString().replaceAll(RegExp(r'[¿?¡!.,;:]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static const String systemPrompt = '''
Eres Occipital, un asistente visual y de razonamiento avanzado y altamente confiable. ERES LOS OJOS DE UNA PERSONA CIEGA.
Tu directiva principal es la seguridad del usuario y la precision absoluta.
TIENES ACCESO A HERRAMIENTAS Y ES OBLIGATORIO USARLAS CUANDO EL USUARIO PREGUNTE POR SU ENTORNO.
REGLA DE ORO: Si el usuario dice "Que ves aqui?", "Describe esto", o cualquier cosa sobre su vision o entorno, DEBES LLAMAR INMEDIATAMENTE a `analyze_surroundings`. NO preguntes que quiere ver! Llama a la herramienta de inmediato!
1. Entorno/vision -> LLAMA A `analyze_surroundings`.
2. Ubicacion/Clima -> LLAMA A `get_weather_and_location`.
3. Salud/Medicinas -> LLAMA A `search_medical_database`.
4. Charla general -> RESPONDE DIRECTAMENTE.

SEGURIDAD: Si la imagen esta borrosa, oscura o no puedes distinguir algo con certeza, dilo en lugar de adivinar. En temas de salud no inventes dosis ni indicaciones: usa solo lo que entregue la base de datos y, si no hay informacion, recomienda consultar a un medico o farmaceutico.

RESPONDE SIEMPRE EN ESPANOL Y DE FORMA MUY BREVE, CORTA Y CONCISA. No des explicaciones largas.
''';

  static const List<Map<String, dynamic>> _tools = [
    {
      'type': 'function',
      'function': {
        'name': 'analyze_surroundings',
        'description': "Capture an image from the camera and analyze the user's surroundings.",
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'get_weather_and_location',
        'description': 'Get the current weather and GPS location of the user.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'search_medical_database',
        'description': 'Search the medical database for FDA guidelines or health info.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': 'The medical query'},
          },
          'required': ['query'],
        },
      },
    },
  ];

  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
  }

  /// Endpoint de chat completions a partir de AZURE_FOUNDRY_ENDPOINT (acepta la URL base o la completa).
  Uri? _chatCompletionsUri() {
    var base = EnvConfig.azureFoundryEndpoint;
    if (base.isEmpty) return null;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/chat/completions')) return Uri.parse(base);
    if (base.endsWith('/openai/v1')) return Uri.parse('$base/chat/completions');
    return Uri.parse('$base/openai/v1/chat/completions');
  }

  Future<http.Response> _postChat(Uri url, Map<String, dynamic> body) {
    return http
        .post(
          url,
          headers: {'Content-Type': 'application/json', 'api-key': EnvConfig.azureFoundryKey},
          body: jsonEncode(body),
        )
        .timeout(_requestTimeout);
  }

  /// Envia el prompt al agente, que decide si usar una herramienta o responder directo.
  Future<String?> processWithAgenticReasoning({
    required String userPrompt,
    required Future<Uint8List?> Function() captureImageCallback,
    Function(String status)? onStatusUpdate,
    String? sensorContext,
    void Function()? onVisionStart,
    String? Function()? visionFallback,
  }) async {
    debugPrint('🧠 OccipitalAgentService: Thinking about prompt: $userPrompt');
    onStatusUpdate?.call('Pensando...');

    final url = _chatCompletionsUri();
    if (url == null || EnvConfig.azureFoundryKey.isEmpty) {
      return 'Las claves de API para Azure OpenAI no estan configuradas.';
    }

    final deployment = EnvConfig.azureFoundryDeployment;

    if (wantsVision(userPrompt)) {
      return _describeNow(
        url,
        deployment,
        userPrompt: userPrompt,
        captureImageCallback: captureImageCallback,
        onStatusUpdate: onStatusUpdate,
        sensorContext: sensorContext,
        onVisionStart: onVisionStart,
        visionFallback: visionFallback,
      );
    }

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      // Lo que oyen y ven los modelos locales de la placa (ver SensorContext).
      if (sensorContext != null) {'role': 'system', 'content': sensorContext},
      {'role': 'user', 'content': userPrompt},
    ];

    try {
      // PRIMERA PASADA: el modelo decide si necesita herramientas
      final firstResponse = await _postChat(url, {
        'model': deployment,
        'messages': messages,
        'tools': _tools,
        'tool_choice': 'auto',
        'max_tokens': _maxTokens,
      });

      if (firstResponse.statusCode != 200) {
        debugPrint('Azure Error ${firstResponse.statusCode}: ${firstResponse.body}');
        return 'Error al contactar al cerebro de Iris.';
      }

      var message = jsonDecode(firstResponse.body)['choices'][0]['message'] as Map<String, dynamic>;
      var toolCalls = (message['tool_calls'] as List?) ?? const [];
      if (toolCalls.isEmpty) {
        final content = message['content']?.toString() ?? '';
        final leaked = leakedTool(content);
        if (leaked == null) return _speakable(content);
        // Escribio "llamando a analyze_surroundings..." sin llamarla: ejecutarla de verdad y
        // hablar solo la respuesta final.
        debugPrint('El modelo escribio la herramienta $leaked en vez de llamarla; se ejecuta.');
        if (leaked == 'analyze_surroundings') {
          return _describeNow(
            url,
            deployment,
            userPrompt: userPrompt,
            captureImageCallback: captureImageCallback,
            onStatusUpdate: onStatusUpdate,
            sensorContext: sensorContext,
            onVisionStart: onVisionStart,
            visionFallback: visionFallback,
          );
        }
        toolCalls = [
          {
            'id': 'call_iris_leak',
            'type': 'function',
            'function': {'name': leaked, 'arguments': jsonEncode({'query': userPrompt})},
          },
        ];
        message = {'role': 'assistant', 'content': null, 'tool_calls': toolCalls};
      }

      // Cada tool_call necesita su propio mensaje "tool"; si falta alguno la API responde 400.
      messages.add(message);
      Map<String, dynamic>? imageMessage;
      for (final call in toolCalls) {
        final result = await _runTool(
          call as Map<String, dynamic>,
          userPrompt: userPrompt,
          captureImageCallback: captureImageCallback,
          onStatusUpdate: onStatusUpdate,
        );
        // Si la camara fallo, responder al tiro en vez de hacer otra vuelta al modelo.
        if (result.cameraFailed) return _cameraFailed(visionFallback);
        messages.add({
          'role': 'tool',
          'tool_call_id': call['id'],
          'name': call['function']['name'],
          'content': result.text,
        });
        imageMessage ??= result.imageMessage;
      }
      // El mensaje con la imagen va despues de todos los mensajes "tool".
      if (imageMessage != null) messages.add(imageMessage);

      // SEGUNDA PASADA: respuesta final con los resultados
      final secondResponse = await _postChat(url, {
        'model': deployment,
        'messages': messages,
        'max_tokens': _maxTokens,
      });

      if (secondResponse.statusCode != 200) {
        debugPrint('Azure Error ${secondResponse.statusCode}: ${secondResponse.body}');
        return 'Error al analizar los resultados de las herramientas.';
      }
      return _speakable(jsonDecode(secondResponse.body)['choices'][0]['message']['content']?.toString());
    } on TimeoutException {
      return 'La conexion tardo demasiado. Intentalo de nuevo.';
    } catch (e) {
      debugPrint('Exception in OccipitalAgentService: $e');
      return 'Hubo un problema de conexion. Intentalo de nuevo.';
    }
  }

  /// Pregunta de "que hay adelante": foto de inmediato (en paralelo con el aviso "Dejame mirar")
  /// y una sola llamada al modelo con la imagen.
  Future<String?> _describeNow(
    Uri url,
    String deployment, {
    required String userPrompt,
    required Future<Uint8List?> Function() captureImageCallback,
    Function(String status)? onStatusUpdate,
    String? sensorContext,
    void Function()? onVisionStart,
    String? Function()? visionFallback,
  }) async {
    onStatusUpdate?.call('Mirando...');
    final photo = captureImageCallback();
    onVisionStart?.call();
    final imageBytes = await photo;
    if (imageBytes == null) return _cameraFailed(visionFallback);

    onStatusUpdate?.call('Analizando vision...');
    try {
      final response = await _postChat(url, {
        'model': deployment,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          if (sensorContext != null) {'role': 'system', 'content': sensorContext},
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': userPrompt},
              {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}'}},
            ],
          },
        ],
        'max_tokens': _maxTokens,
      });
      if (response.statusCode != 200) {
        debugPrint('Azure Error ${response.statusCode}: ${response.body}');
        return 'Error al analizar la imagen.';
      }
      return _speakable(jsonDecode(response.body)['choices'][0]['message']['content']?.toString());
    } on TimeoutException {
      return 'La conexion tardo demasiado. Intentalo de nuevo.';
    } catch (e) {
      debugPrint('Exception in OccipitalAgentService (vision): $e');
      return 'Hubo un problema de conexion. Intentalo de nuevo.';
    }
  }

  /// Respuesta rapida si la foto fallo, con lo ultimo que vio la vision local de respaldo.
  String _cameraFailed(String? Function()? visionFallback) {
    final seen = visionFallback?.call();
    return seen == null
        ? cameraFailedMessage
        : '$cameraFailedMessage Lo ultimo que detecto la placa fue $seen.';
  }

  Future<({String text, Map<String, dynamic>? imageMessage, bool cameraFailed})> _runTool(
    Map<String, dynamic> call, {
    required String userPrompt,
    required Future<Uint8List?> Function() captureImageCallback,
    Function(String status)? onStatusUpdate,
  }) async {
    final name = call['function']['name'];

    switch (name) {
      case 'analyze_surroundings':
        onStatusUpdate?.call('Analizando vision...');
        final imageBytes = await captureImageCallback();
        if (imageBytes == null) {
          return (text: 'Error: No se pudo capturar la imagen.', imageMessage: null, cameraFailed: true);
        }
        return (
          cameraFailed: false,
          text: 'Imagen capturada exitosamente.',
          imageMessage: {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Aqui tienes la imagen capturada para tu analisis:'},
              {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}'}},
            ],
          },
        );

      case 'get_weather_and_location':
        onStatusUpdate?.call('Obteniendo Clima y GPS...');
        return (text: await _fetchLocationAndWeather(), imageMessage: null, cameraFailed: false);

      case 'search_medical_database':
        onStatusUpdate?.call('Consultando Base de Datos Medica...');
        String query = userPrompt;
        try {
          final args = jsonDecode(call['function']['arguments'] ?? '{}');
          query = (args['query'] ?? userPrompt).toString();
        } catch (e) {
          debugPrint('Argumentos invalidos para search_medical_database: $e');
        }
        return (text: await _searchMedicalDB(query), imageMessage: null, cameraFailed: false);

      default:
        return (text: 'Herramienta desconocida: $name', imageMessage: null, cameraFailed: false);
    }
  }

  /// Posicion GPS actual, o null si no hay servicio/permiso (nunca se inventa una ubicacion).
  Future<Position?> _currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.whileInUse && permission != LocationPermission.always) {
        return null;
      }
      return await Geolocator.getCurrentPosition().timeout(_toolTimeout);
    } catch (e) {
      debugPrint('Error GPS: $e');
      return null;
    }
  }

  Future<String> _fetchLocationAndWeather() async {
    final position = await _currentPosition();
    if (position == null) {
      return 'No se pudo obtener la ubicacion GPS del usuario. Dile que active la ubicacion; no inventes una.';
    }
    final lat = position.latitude;
    final lon = position.longitude;

    String locationText = 'ubicacion desconocida';
    String weatherText = 'clima desconocido';

    try {
      if (EnvConfig.locationIqKey.isNotEmpty) {
        final response = await http
            .get(Uri.parse(
                'https://us1.locationiq.com/v1/reverse?key=${EnvConfig.locationIqKey}&lat=$lat&lon=$lon&format=json'))
            .timeout(_toolTimeout);
        if (response.statusCode == 200) {
          final address = jsonDecode(response.body)['address'] ?? {};
          final road = address['road'] ?? 'una calle desconocida';
          final city = address['city'] ?? address['town'] ?? address['village'] ?? '';
          locationText = '$road, $city';
        }
      }

      if (EnvConfig.openWeatherKey.isNotEmpty) {
        final response = await http
            .get(Uri.parse(
                'https://api.openweathermap.org/data/2.5/weather?lat=$lat&lon=$lon&appid=${EnvConfig.openWeatherKey}&units=metric&lang=es'))
            .timeout(_toolTimeout);
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final temperature = (data['main']['temp'] as num).round();
          weatherText = '$temperature°C y ${data['weather'][0]['description']}';
        }
      }
      return 'Ubicacion: $locationText. Clima: $weatherText.';
    } catch (e) {
      debugPrint('Error obteniendo clima/ubicacion: $e');
      return 'No se pudo obtener el clima o la ubicacion.';
    }
  }

  Future<String> _searchMedicalDB(String query) async {
    if (EnvConfig.azureSearchEndpoint.isEmpty || EnvConfig.azureSearchKey.isEmpty) {
      return 'Base de datos Medica no configurada.';
    }
    try {
      final response = await http
          .post(
            Uri.parse('${EnvConfig.azureSearchEndpoint}/indexes/insulina-fda-kb/docs/search?api-version=2023-11-01'),
            headers: {'Content-Type': 'application/json', 'api-key': EnvConfig.azureSearchKey},
            body: jsonEncode({'search': query, 'top': 3}),
          )
          .timeout(_toolTimeout);

      if (response.statusCode == 200) {
        final values = (jsonDecode(response.body)['value'] as List?) ?? const [];
        if (values.isNotEmpty) {
          return values.map((e) => e['content'] ?? '').join('\n');
        }
      }
      return 'No se encontraron resultados en la base de datos Medica para la consulta: $query.';
    } catch (e) {
      debugPrint('Error consultando base medica: $e');
      return 'Error al consultar la base de datos Medica.';
    }
  }

  Future<void> dispose() async {
    _isInitialized = false;
  }
}
