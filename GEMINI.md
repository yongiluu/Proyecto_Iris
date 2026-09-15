# Reglas de Calidad y Arquitectura (Proyecto Iris)

Este archivo define las reglas estrictas de desarrollo para el Proyecto Iris, incorporando los principios de "Anti-Slop", "Arquitectura de Código Mejorada", y "Revisión de Calidad Termonuclear".

## 1. Anti-Slop (Concisión y Precisión)
- Escribe código directo y al grano. Evita la verbosidad innecesaria.
- No agregues comentarios redundantes que solo repitan lo que el código hace de forma obvia (ej. `// suma 1 a i`). Comenta el **por qué**, no el **qué**.
- Elimina cualquier código muerto, importaciones no utilizadas y funciones obsoletas de inmediato. No dejes código comentado.
- Respeta los principios DRY (Don't Repeat Yourself) y YAGNI (You Aren't Gonna Need It).

## 2. Improved Codebase Architecture (Arquitectura Limpia)
- **Separación de Responsabilidades:** Mantén la lógica de negocio, la interfaz de usuario (Flutter) y la comunicación de hardware (ESP32/BLE) estrictamente separadas en diferentes archivos y clases.
- **Inyección de Dependencias:** Evita los singletons globales ocultos. Pasa las dependencias explícitamente.
- **Manejo de Estado:** En Flutter, utiliza una arquitectura clara (Provider, Riverpod, BLoC) para el manejo de estado en lugar de `setState` masivos.
- **Modularidad en C++ (ESP32):** Divide el código en drivers lógicos (`audio_player`, `camera_driver`, `ble_manager`) en lugar de tener un `main.cpp` monolítico.

## 3. Thermonuclear Code Quality Review
- **Manejo de Errores Exhaustivo:** No asumas que las operaciones de red, Bluetooth o hardware serán exitosas. Siempre incluye bloques `try/catch` y maneja las desconexiones limpiamente con reconexiones automáticas.
- **Seguridad de Memoria (ESP32):** Presta especial atención a las fugas de memoria (`memory leaks`). Asegúrate de liberar cualquier `malloc` y manejar los buffers de audio (I2S/BLE) de forma estricta.
- **Nombres Semánticos:** Usa nombres de variables y funciones que revelen intención. `bool is_transmitting` es mejor que `bool t`.
- **Validación Estricta:** Valida todas las entradas y retornos. En Flutter, usa `null safety` agresivamente. En C++, revisa siempre si los punteros son nulos antes de usarlos.
