import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris_app/services/ai/known_faces_service.dart';
import 'package:iris_app/services/ai/phone_text_reader.dart';
import 'package:iris_app/services/ai/voice_intents.dart';
import 'package:iris_app/services/hardware/phone_light_meter.dart';

void main() {
  group('VoiceIntents', () {
    void expectIntent(String said, IrisIntentType type, [String? name]) {
      final intent = VoiceIntents.parse(said);
      expect(intent.type, type, reason: '"$said" -> $intent');
      if (name != null) expect(intent.name, name, reason: said);
    }

    test('leer texto', () {
      for (final said in [
        '¿Qué dice aquí?',
        'que dice el letrero',
        'Léeme esto',
        'lee lo que hay al frente',
        '¿qué está escrito en la caja?',
        'que pone en la etiqueta',
      ]) {
        expectIntent(said, IrisIntentType.readText);
      }
    });

    test('luz', () {
      expectIntent('busca la luz', IrisIntentType.lightOn);
      expectIntent('¿Dónde hay luz?', IrisIntentType.lightOn);
      expectIntent('activa el detector de luz', IrisIntentType.lightOn);
      expectIntent('¿Está prendida la luz?', IrisIntentType.lightOn);
      expectIntent('apaga el detector de luz', IrisIntentType.lightOff);
      expectIntent('deja de buscar la luz', IrisIntentType.lightOff);
    });

    test('personas', () {
      expectIntent('¿Quién está aquí?', IrisIntentType.whoIsHere);
      expectIntent('¿hay alguien conocido?', IrisIntentType.whoIsHere);
      expectIntent('Recuerda a Raúl', IrisIntentType.rememberPerson, 'Raul');
      expectIntent('recuerda la cara de maria jose', IrisIntentType.rememberPerson, 'Maria Jose');
      expectIntent('Esta es Ana', IrisIntentType.rememberPerson, 'Ana');
      expectIntent('olvida a Raúl', IrisIntentType.forgetPerson, 'Raul');
    });

    test('comandos rapidos', () {
      expectIntent('Repite', IrisIntentType.repeat);
      expectIntent('¿Qué dijiste?', IrisIntentType.repeat);
      expectIntent('no te entendí', IrisIntentType.repeat);
      expectIntent('¿me lo puedes repetir por favor?', IrisIntentType.repeat);
      expectIntent('¿Qué puedes hacer?', IrisIntentType.help);
      expectIntent('ayuda', IrisIntentType.help);
      expectIntent('¿Qué hora es?', IrisIntentType.time);
      expectIntent('¿qué día es hoy?', IrisIntentType.time);
      expectIntent('habla más lento', IrisIntentType.slower);
      expectIntent('más despacio por favor', IrisIntentType.slower);
      expectIntent('habla más rápido', IrisIntentType.faster);
      expectIntent('Cállate', IrisIntentType.stop);
      expectIntent('silencio por favor', IrisIntentType.stop);
    });

    test('lo demas va al agente', () {
      for (final said in [
        '¿Qué hay adelante?',
        'describe lo que ves',
        '¿Qué tiempo hace?',
        'esta es la puerta de mi casa',
        'recuerda que mañana tengo médico',
        'buenos días Iris',
        'describe otra vez',
        'estoy caminando lento',
        'para donde queda el metro',
        '¿qué hora abre la farmacia?',
        '',
      ]) {
        expectIntent(said, IrisIntentType.none);
      }
    });
  });

  group('PhoneLightMeter', () {
    test('nivel y tono en los extremos', () {
      expect(PhoneLightMeter.levelFromGray(Uint8List(32 * 32), 32), 0);
      expect(PhoneLightMeter.levelFromGray(Uint8List(32 * 32)..fillRange(0, 32 * 32, 255), 32), 100);
      expect(PhoneLightMeter.frequencyFor(0), 150);
      expect(PhoneLightMeter.frequencyFor(100), 2400);
      expect(PhoneLightMeter.frequencyFor(50), 600); // exponencial: la mitad suena a la media geometrica
    });

    test('solo cuenta el centro', () {
      final pixels = Uint8List(32 * 32)..fillRange(0, 32 * 32, 255);
      for (var y = 8; y < 24; y++) {
        pixels.fillRange(y * 32 + 8, y * 32 + 24, 0);
      }
      expect(PhoneLightMeter.levelFromGray(pixels, 32), 0);
    });
  });

  test('PhoneTextReader ordena los bloques como se lee', () {
    final text = PhoneTextReader.joinBlocks([
      (top: 200, left: 10, text: 'Lunes a viernes'),
      (top: 50, left: 300, text: 'ABIERTO'),
      (top: 45, left: 10, text: 'FARMACIA'),
      (top: 400, left: 10, text: '|'),
    ]);
    expect(text, 'FARMACIA. ABIERTO. Lunes a viernes');
  });

  test('Nombres: con o sin tildes es la misma persona', () {
    expect(KnownFacesService.nameKey('Raúl'), 'Raul');
    expect(KnownFacesService.nameKey('  maría   josé '), 'Maria Jose');
    expect(KnownFacesService.nameKey(VoiceIntents.parse('olvida a Raúl').name!), 'Raul');
  });

  test('Hora en palabras', () {
    expect(LocalAnswers.time(DateTime(2026, 11, 8, 15, 25)), 'Son las 3 y 25 de la tarde. Hoy es domingo 8 de noviembre.');
    expect(LocalAnswers.time(DateTime(2026, 11, 9, 13, 0)), 'Es la 1 en punto de la tarde. Hoy es lunes 9 de noviembre.');
    expect(LocalAnswers.time(DateTime(2026, 11, 9, 0, 30)), 'Son las 12 y media de la madrugada. Hoy es lunes 9 de noviembre.');
  });
}
