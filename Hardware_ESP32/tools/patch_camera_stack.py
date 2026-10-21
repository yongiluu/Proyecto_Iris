# Script de PlatformIO (extra_scripts = pre:tools/patch_camera_stack.py).
# La tarea interna de esp32-camera ("cam_task") tiene solo 2 KB de pila (CONFIG_CAMERA_TASK_STACK_SIZE
# viene fijo en el sdkconfig precompilado de Arduino). Se cayo por stack canary al actualizar por WiFi y
# la Iris blanca se reiniciaba (panic) al sacar fotos. Se parchea la libreria descargada a 6 KB.
import os

Import("env")  # noqa: F821 (lo define PlatformIO)

path = os.path.join(env.subst("$PROJECT_LIBDEPS_DIR"), env.subst("$PIOENV"),  # noqa: F821
                    "esp32-camera", "driver", "cam_hal.c")
OLD = "#define CAM_TASK_STACK             CONFIG_CAMERA_TASK_STACK_SIZE"
NEW = "#define CAM_TASK_STACK             (6*1024)  /* IRIS: era CONFIG_CAMERA_TASK_STACK_SIZE (2 KB) */"
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if OLD in text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text.replace(OLD, NEW))
        print("[iris] cam_task: pila de 6 KB")
