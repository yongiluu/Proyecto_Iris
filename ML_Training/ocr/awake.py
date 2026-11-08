"""Evita que Windows suspenda el PC mientras entrena (la pantalla si puede apagarse).

Sin esto, un entrenamiento de noche se congela cuando el PC se duerme y amanece en la misma epoca.
En Linux/Mac (Lambda) no hace nada.
"""
import sys

_ES_CONTINUOUS = 0x80000000
_ES_SYSTEM_REQUIRED = 0x00000001


def keep_awake() -> None:
    if sys.platform != "win32":
        return
    try:
        import ctypes
        ctypes.windll.kernel32.SetThreadExecutionState(_ES_CONTINUOUS | _ES_SYSTEM_REQUIRED)
        print("PC despierto mientras entrena (se libera solo al terminar).")
    except Exception as error:  # nunca impedir el entrenamiento por esto
        print(f"No se pudo evitar la suspension: {error}")
