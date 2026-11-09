import 'package:flutter_test/flutter_test.dart';
import 'package:iris_app/services/ai/occipital_agent_service.dart';

void main() {
  test('errores de conexion se reconocen (para usar la descripcion de la placa)', () {
    expect(OccipitalAgentService.isFailureReply(null), isTrue);
    expect(OccipitalAgentService.isFailureReply('La conexion tardo demasiado. Intentalo de nuevo.'), isTrue);
    expect(OccipitalAgentService.isFailureReply('Hubo un problema de conexion con el servidor de Iris. Intentalo de nuevo.'),
        isTrue);
    expect(OccipitalAgentService.isFailureReply('Adelante hay una puerta cafe.'), isFalse);
    // La camara que falla no es falta de internet: esa respuesta ya trae lo ultimo que vio la placa.
    expect(OccipitalAgentService.isFailureReply(OccipitalAgentService.cameraFailedMessage), isFalse);
  });

  test('solo las preguntas de vision usan la descripcion de la placa', () {
    expect(OccipitalAgentService.wantsVision('¿Qué hay adelante?'), isTrue);
    expect(OccipitalAgentService.wantsVision('Describe la vista actual.'), isTrue);
    expect(OccipitalAgentService.wantsVision('¿Qué tiempo hace?'), isFalse);
  });
}
