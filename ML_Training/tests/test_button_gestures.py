"""Gestos del boton de la placa (Hardware_ESP32/src/button_gestures.cpp), probados en el PC.

    python tests/test_button_gestures.py

Compila el mismo codigo de la placa y le pasa apretones simulados (cada 5 ms, como la tarea del boton):

    mantener, hablar y soltar          -> TalkStart ... TalkStop
    un toque                           -> Tap1   (describe el modelo de la placa)
    toque + mantener, hablar y soltar  -> CloudTalkStart ... TalkStop   (pregunta a la nube)
    dos toques                         -> Tap2
    tres toques                        -> Tap3   (leer texto)

y el caso de la placa dormida: el toque que la despierta cuenta como el primero.
"""
import subprocess
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_DIR = TESTS_DIR.parents[1]
BUILD_DIR = TESTS_DIR / "build"
STEP_MS = 5
HOLD_MS = 350     # ButtonGestures::kHoldMs
GAP_MS = 400      # ButtonGestures::kTapGapMs


def build() -> Path:
    BUILD_DIR.mkdir(exist_ok=True)
    binary = BUILD_DIR / ("button_gestures_host.exe" if sys.platform == "win32" else "button_gestures_host")
    subprocess.run([sys.executable, "-m", "ziglang", "c++", "-O2", "-std=c++17",
                    f"-I{REPO_DIR / 'Hardware_ESP32' / 'include'}", str(TESTS_DIR / "button_gestures_host_main.cpp"),
                    str(REPO_DIR / "Hardware_ESP32" / "src" / "button_gestures.cpp"), "-o", str(binary)], check=True)
    return binary


def run(binary: Path, segments: list[tuple[int, int]], wake: tuple[int, int] | None = None,
        start_ms: int = 0) -> tuple[list[tuple[int, str]], bool]:
    """segments: [(duracion_ms, apretado)]. Devuelve [(ms, evento)] y si quedo un gesto a medias."""
    lines = []
    if wake is not None:
        lines.append(f"wake {wake[0]} {wake[1]}")
    now = start_ms
    for duration, pressed in segments:
        for _ in range(duration // STEP_MS):
            lines.append(f"{now} {pressed}")
            now += STEP_MS
    out = subprocess.run([str(binary)], input="\n".join(lines) + "\n", capture_output=True, text=True, check=True).stdout
    events, busy = [], False
    for line in out.splitlines():
        first, second = line.split()
        if first == "busy":
            busy = second == "1"
        else:
            events.append((int(first), second))
    return events, busy


def main() -> None:
    binary = build()
    failures = 0

    def expect(what: str, got: list[tuple[int, str]], names: list[str], busy: bool = False, got_busy: bool = False):
        nonlocal failures
        ok = [n for _, n in got] == names and busy == got_busy
        print(("  ok    " if ok else "  FALLA ") + f"{what}: {[n for _, n in got]}")
        failures += not ok

    quiet = (1000, 0)
    tap, gap = (120, 1), (150, 0)

    events, busy = run(binary, [quiet, (2000, 1), quiet])
    expect("mantener y soltar = pregunta", events, ["TalkStart", "TalkStop"], got_busy=busy)
    start = events[0][0] - 1000
    if not HOLD_MS <= start <= HOLD_MS + 2 * STEP_MS:
        print(f"  FALLA TalkStart llego a los {start} ms de apretar (se esperaban ~{HOLD_MS})")
        failures += 1

    events, busy = run(binary, [quiet, tap, quiet])
    expect("un toque = describir en la placa", events, ["Tap1"], got_busy=busy)
    delay = events[0][0] - 1120 if events else -1
    if not GAP_MS <= delay <= GAP_MS + 2 * STEP_MS:
        print(f"  FALLA Tap1 llego {delay} ms despues de soltar (se esperaban ~{GAP_MS})")
        failures += 1

    events, busy = run(binary, [quiet, tap, gap, (1500, 1), quiet])
    expect("toque + mantener = pregunta a la nube", events, ["CloudTalkStart", "TalkStop"], got_busy=busy)

    events, busy = run(binary, [quiet, tap, gap, tap, quiet])
    expect("dos toques", events, ["Tap2"], got_busy=busy)

    events, busy = run(binary, [quiet, tap, gap, tap, gap, tap, quiet])
    expect("tres toques = leer", events, ["Tap3"], got_busy=busy)

    events, busy = run(binary, [quiet, tap, gap, tap, gap, (1500, 1), quiet])
    expect("tercer toque mantenido tambien es leer (y soltar no hace nada)", events, ["Tap3"], got_busy=busy)

    events, busy = run(binary, [quiet, tap, gap, tap, gap, tap, quiet, tap, quiet])
    expect("despues de leer, un toque vuelve a ser describir", events, ["Tap3", "Tap1"], got_busy=busy)

    events, busy = run(binary, [quiet, tap, (GAP_MS + 100, 0), tap, quiet])
    expect("dos toques separados son dos descripciones", events, ["Tap1", "Tap1"], got_busy=busy)

    events, busy = run(binary, [quiet, (HOLD_MS - 50, 1), quiet])
    expect("un toque largo pero menor que 'mantener' sigue siendo un toque", events, ["Tap1"], got_busy=busy)

    events, busy = run(binary, [quiet, (2000, 1)])
    expect("boton todavia apretado: gesto a medias", events, ["TalkStart"], busy=True, got_busy=busy)

    events, busy = run(binary, [quiet, tap])
    expect("toque sin confirmar: gesto a medias", events, [], busy=True, got_busy=busy)

    # ─── La placa estaba dormida: el toque que la desperto es parte del gesto ───
    events, busy = run(binary, [quiet], wake=(0, 300), start_ms=300)
    expect("despertar con un toque (ya soltado al arrancar) = describir", events, ["Tap1"], got_busy=busy)

    events, busy = run(binary, [gap, tap, quiet], wake=(0, 300), start_ms=300)
    expect("despertar + otro toque = dos toques", events, ["Tap2"], got_busy=busy)

    events, busy = run(binary, [(150, 0), (1500, 1), quiet], wake=(0, 300), start_ms=300)
    expect("despertar con un toque + mantener = pregunta a la nube", events, ["CloudTalkStart", "TalkStop"],
           got_busy=busy)

    events, busy = run(binary, [(1500, 1), quiet], wake=(1, 300), start_ms=300)
    expect("despertar manteniendo apretado = pregunta", events, ["TalkStart", "TalkStop"], got_busy=busy)

    events, busy = run(binary, [(100, 1), quiet], wake=(1, 300), start_ms=300)
    expect("despertar y soltar enseguida = un toque", events, ["Tap1"], got_busy=busy)

    if failures:
        raise SystemExit(f"{failures} gestos fallaron")
    print("Gestos del boton: todos correctos")


if __name__ == "__main__":
    main()
