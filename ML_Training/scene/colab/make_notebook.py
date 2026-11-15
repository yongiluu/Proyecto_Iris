"""Genera iris_escenas_colab.ipynb: Retina (modelo de escenas de la placa) en Google Colab.

    python scene/colab/make_notebook.py

Editar este archivo, no el .ipynb (el notebook se regenera desde aqui).
"""
import json
from pathlib import Path

OUT = Path(__file__).with_name("iris_escenas_colab.ipynb")
cells = []


def md(text):
    cells.append({"cell_type": "markdown", "metadata": {}, "source": text.strip("\n").splitlines(keepends=True)})


def code(text):
    cells.append({"cell_type": "code", "metadata": {}, "execution_count": None, "outputs": [],
                  "source": text.strip("\n").splitlines(keepends=True)})


md(r"""
# Retina: el modelo de escenas de la placa de Iris (Google Colab)

**Iris ve, Retina entiende al instante (en la placa), Occipital piensa en profundidad (en la nube).**

1. Baja fotos a color de Open Images, con más peso a lo que importa al caminar (escaleras, conos, postes...).
2. (Opcional) Compara varios **profesores** con 300 fotos y se queda con el mejor.
3. El profesor mira cada foto y llena la ficha: objetos, dónde están, distancia, colores, personas, **peligros**.
4. Entrena al **alumno** (Retina), el modelo chico que corre en la placa XIAO.
5. Le pone un umbral propio a cada objeto (dice menos cosas, pero seguras) y lo exporta a int8.

**Antes de empezar:** *Entorno de ejecución → Cambiar tipo de entorno de ejecución* → **GPU A100** (o L4, más
lenta pero gasta menos unidades). La T4 **no sirve**.

**IMPORTANTE para dejarlo toda la noche (Colab Pro apaga la máquina si la pestaña se "duerme"):**
1. En Chrome: *Configuración → Rendimiento → Ahorro de memoria → Mantener siempre activos estos sitios →
   Agregar* `colab.research.google.com`. Sin esto, al cambiar de ventana Chrome congela la pestaña (se ve gris)
   y Google recupera la máquina.
2. Deja esta pestaña en **su propia ventana** de Chrome (puede quedar detrás de otras, pero no la cierres).
3. Windows: *Configuración → Sistema → Inicio/apagado → Suspender: Nunca* (enchufado).

**Si Colab se desconecta:** recarga la página y *Ejecutar todo*. Lo importante vive en tu Google Drive
(carpeta `Iris_escenas`) y cada paso salta lo que ya estaba hecho.

**Para revisar el avance:** abre la **Terminal** (abajo a la izquierda) y pega el comando de la celda 0.
""")

code(r"""
#@title 0. (Solo para mirar) Comando para ver el avance en la Terminal { display-mode: "form" }
print('Pega esto en la Terminal de Colab (abajo a la izquierda):')
print('  wc -l /content/drive/MyDrive/Iris_escenas/*.jsonl; nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv')
""")

code(r"""
#@title 1. Ajustes { display-mode: "form" }
FOTOS = 100000  #@param {type:"integer"}
CON_TRAIN = True  #@param {type:"boolean"}
# True: elige entre las 1,7 millones de fotos de Open Images (mas escaleras, conos, postes...). Baja ~5,6 GB de CSV.
PROFESOR = "Qwen/Qwen3-VL-8B-Instruct"  #@param ["Qwen/Qwen3-VL-8B-Instruct", "Qwen/Qwen2.5-VL-7B-Instruct", "Qwen/Qwen2.5-VL-32B-Instruct-AWQ"]
COMPARAR_PROFESORES = False  #@param {type:"boolean"}
# True: antes de etiquetar todo, prueba cada candidato con 300 fotos y usa el que mejor coincide con lo
# que marcaron personas en Open Images (reemplaza a PROFESOR).
CANDIDATOS = ["Qwen/Qwen3-VL-8B-Instruct", "Qwen/Qwen2.5-VL-7B-Instruct", "Qwen/Qwen2.5-VL-32B-Instruct-AWQ"]
ALPHA = 0.5  #@param [0.35, 0.5]
# 0.35: Retina 1 (1,1 MB). 0.5: mas capaz (~2 MB); necesita el firmware con la particion de modelos de 4 MB.
EPOCAS = 40  #@param {type:"integer"}
RAMA = "main"  #@param {type:"string"}
""")

code(r"""
#@title 2. Google Drive, código y GPU
import os, subprocess, pathlib, re, json, tarfile, time, urllib.request
from google.colab import drive
drive.mount('/content/drive')

DRIVE = pathlib.Path('/content/drive/MyDrive/Iris_escenas')
DRIVE.mkdir(parents=True, exist_ok=True)
(DRIVE / 'resultado').mkdir(exist_ok=True)

REPO = pathlib.Path('/content/Proyecto_Iris')
if not REPO.exists():
    subprocess.run(['git', 'clone', '--depth', '1', '-b', RAMA,
                    'https://github.com/yongiluu/Proyecto_Iris.git', str(REPO)], check=True)
else:
    subprocess.run(['git', '-C', str(REPO), 'pull', '--ff-only'], check=False)
ML = REPO / 'ML_Training'
DATA = ML / 'data' / 'scene'
DATA.mkdir(parents=True, exist_ok=True)
os.chdir(ML)

gpu = subprocess.run(['nvidia-smi', '--query-gpu=name,memory.total', '--format=csv,noheader'],
                     capture_output=True, text=True).stdout.strip()
print('GPU:', gpu or 'NINGUNA')
assert gpu, 'No hay GPU: cambia el tipo de entorno de ejecución a A100 o L4.'
assert 'T4' not in gpu, 'La T4 no alcanza para el profesor: usa A100 o L4.'
MEM_GB = int(gpu.split(',')[-1].strip().split()[0]) / 1024

def nombre_corto(modelo):
    return re.sub(r'[^a-z0-9.]+', '-', modelo.split('/')[-1].lower()).strip('-')
""")

code(r"""
#@title 3. Lo guardado en Drive vuelve a su lugar (si Colab se desconectó)
def enlazar(nombre):
    # El archivo vive en Drive; en el proyecto queda un acceso directo. Cada linea escrita queda a salvo.
    en_drive, local = DRIVE / nombre, DATA / nombre
    en_drive.touch()
    if local.is_symlink() or local.exists():
        local.unlink()
    local.symlink_to(en_drive)

ETIQ_AUTO = 'labels_auto.jsonl'
ETIQUETAS = [ETIQ_AUTO] + [f'labels_teacher_{nombre_corto(m)}.jsonl' for m in set(CANDIDATOS + [PROFESOR])]
for n in ETIQUETAS:
    enlazar(n)

FOTOS_TAR = DRIVE / 'fotos.tar'
if FOTOS_TAR.exists() and not (DATA / 'images' / 'openimages').exists():
    print('Recuperando las fotos desde Drive...')
    with tarfile.open(FOTOS_TAR) as tar:
        tar.extractall(DATA)

# Si se corto a mitad de la descarga, quita etiquetas de fotos que no alcanzaron a guardarse en Drive.
def limpiar(nombre):
    ruta = DRIVE / nombre
    filas = [l for l in ruta.read_text(encoding='utf-8').splitlines() if l.strip()]
    def foto_existe(linea):
        try:
            return (DATA / 'images' / json.loads(linea)['image']).exists()
        except (json.JSONDecodeError, KeyError):
            return False  # linea a medio escribir cuando se apago la maquina: se descarta
    buenas = [l for l in filas if foto_existe(l)]
    if len(buenas) != len(filas):
        ruta.write_text(''.join(l + '\n' for l in buenas), encoding='utf-8')
    return len(buenas), len(filas) - len(buenas)

for n in ETIQUETAS:
    ok, quitadas = limpiar(n)
    if ok or quitadas:
        print(f'{n}: {ok} filas' + (f' ({quitadas} sin foto, se rehacen)' if quitadas else ''))
""")

code(r"""
#@title 4. Fotos a color de Open Images
!pip -q install pandas pillow requests tqdm
extra = '--con-train' if CON_TRAIN else ''
!python scene/download_images.py --count {FOTOS} --workers 64 {extra}

print('Guardando las fotos en Drive (tarda unos minutos)...')
tmp = pathlib.Path('/content/fotos.tar')
with tarfile.open(tmp, 'w') as tar:
    tar.add(DATA / 'images', arcname='images')
subprocess.run(['cp', str(tmp), str(FOTOS_TAR)], check=True)
tmp.unlink()
print('Fotos listas:', sum(1 for _ in (DATA / 'images' / 'openimages').glob('*.jpg')))
""")

code(r"""
#@title 5. Servidor del profesor (vLLM): corre aparte del notebook y se reinicia solo si se cae
VENV = pathlib.Path('/content/venv_profesor')
if not (VENV / 'bin' / 'vllm').exists():
    !pip -q install uv
    !uv venv -q {VENV} --python 3.12
    !uv pip install -q --python {VENV}/bin/python vllm requests tqdm pillow
PY = VENV / 'bin' / 'python'

# El muestreador de FlashInfer necesita kernels que Colab no trae (sin nvcc): vLLM se caia al arrancar.
os.environ['VLLM_USE_FLASHINFER_SAMPLER'] = '0'
LARGO = 8192 if MEM_GB >= 40 else 4096

def servidor_vivo(modelo=None):
    try:
        datos = json.load(urllib.request.urlopen('http://localhost:8000/v1/models', timeout=5))
        return modelo is None or any(m['id'] == modelo for m in datos.get('data', []))
    except Exception:
        return False

def apagar_servidor():
    subprocess.run(['pkill', '-f', 'vllm serve'])
    time.sleep(10)

def arrancar_servidor(modelo):
    apagar_servidor()
    log = open('/content/vllm.log', 'a')
    proc = subprocess.Popen([str(VENV / 'bin' / 'vllm'), 'serve', modelo, '--port', '8000',
                             '--max-model-len', str(LARGO), '--gpu-memory-utilization', '0.92'],
                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    print(f'Cargando {modelo} (la primera vez lo baja, unos minutos)...')
    while not servidor_vivo(modelo):
        if proc.poll() is not None:
            lineas = open('/content/vllm.log').read().splitlines()
            errores = [l for l in lineas if 'Error' in l or 'ERROR' in l]
            print('\n'.join(errores[-25:] or lineas[-40:]))
            raise RuntimeError(f'vLLM no pudo cargar {modelo}: mira el log de arriba')
        time.sleep(10)
    print('Profesor listo:', modelo)

def etiquetar(modelo, limite=0):
    # Etiqueta (o retoma) con el modelo; si el servidor se cae, lo reinicia y sigue (hasta 8 veces).
    if not servidor_vivo(modelo):
        arrancar_servidor(modelo)
    extra = f'--limit {limite}' if limite else ''
    for intento in range(1, 9):
        get_ipython().system(f'{PY} scene/label_teacher.py --url http://localhost:8000/v1 --model {modelo} --workers 64 {extra}')
        if get_ipython().user_ns.get('_exit_code', 0) == 0:
            return
        print('El profesor se cayó; lo reinicio y sigo desde donde quedó.')
        arrancar_servidor(modelo)
    raise RuntimeError('El profesor se cayó 8 veces: revisa /content/vllm.log')
print('Listo.')
""")

code(r"""
#@title 6. (Opcional) Comparar profesores con 300 fotos y elegir el mejor
if COMPARAR_PROFESORES:
    for modelo in CANDIDATOS:
        try:
            etiquetar(modelo, limite=300)
        except Exception as e:
            print(f'⚠ {modelo} no funcionó aquí ({e}); queda fuera de la comparación.')
    apagar_servidor()
    !python scene/compare_teachers.py
    # Puntaje: encontrar lo que marcaron personas, sin inventar, acertando las personas.
    salida = subprocess.run(['python', 'scene/compare_teachers.py'], capture_output=True, text=True).stdout
    mejor, mejor_puntaje = PROFESOR, -1.0
    for modelo in CANDIDATOS:
        fila = [l for l in salida.splitlines() if l.startswith(nombre_corto(modelo) + ' ')]
        if not fila:
            continue
        numeros = [float(x.rstrip('%')) / 100 for x in fila[0].split()[2:6]]
        encuentra, inventa, personas, _ = numeros
        puntaje = encuentra - 0.5 * inventa + 0.3 * personas
        print(f'{modelo}: puntaje {puntaje:.3f}')
        if puntaje > mejor_puntaje:
            mejor, mejor_puntaje = modelo, puntaje
    PROFESOR = mejor
print('Profesor elegido:', PROFESOR)
""")

code(r"""
#@title 7. El profesor etiqueta todas las fotos (se puede cortar y retomar)
etiquetar(PROFESOR)
apagar_servidor()
print('Profesor terminado; la GPU queda libre para el alumno.')
""")

code(r"""
#@title 8. Retina (el alumno): entrenar con las etiquetas del profesor elegido
os.environ['IRIS_PROFESOR'] = nombre_corto(PROFESOR)
!pip -q install pandas pillow tqdm
!python scene/train.py --labels mix --epochs {EPOCAS} --batch-size 128 --alpha {ALPHA}
!cp models/scene_student.keras models/scene_report.txt "{DRIVE}/resultado/" 2>/dev/null; true
""")

code(r"""
#@title 9. Umbral por objeto + int8 para la placa + demo, y guardar todo en Drive
os.environ['IRIS_PROFESOR'] = nombre_corto(PROFESOR)
!python scene/export_model.py
!python scene/demo.py --int8 --n 120
!cp models/scene_student_int8.tflite models/scene_report_int8.txt models/scene_thresholds.json models/scene_student.keras models/scene_report.txt models/scene_student.json models/firmware_models.json "{DRIVE}/resultado/"
!cp data/scene/demo_alumno.html "{DRIVE}/resultado/" 2>/dev/null; true
ETIQ_PROFESOR = f'labels_teacher_{nombre_corto(PROFESOR)}.jsonl'
!cp "{DRIVE}/{ETIQ_PROFESOR}" "{DRIVE}/resultado/"
print(open('models/scene_report_int8.txt', encoding='utf-8').read()[:3000])
print()
print('LISTO. Baja de Mi unidad/Iris_escenas/resultado/ a tu PC:')
print('  scene_student_int8.tflite, scene_report_int8.txt, scene_thresholds.json, scene_student.keras,')
print('  scene_student.json, scene_report.txt  -> ML_Training/models/')
print(f'  {ETIQ_PROFESOR} -> ML_Training/data/scene/   (las etiquetas del profesor valen oro: guárdalas)')
print('  demo_alumno.html -> ábrelo en el navegador para ver qué dice Retina de cada foto')
print('Y desconecta el entorno (Entorno de ejecución -> Desconectar y borrar) para no gastar unidades.')
""")

nb = {"cells": cells, "metadata": {"accelerator": "GPU", "colab": {"provenance": [], "gpuType": "A100"},
                                   "kernelspec": {"display_name": "Python 3", "name": "python3"},
                                   "language_info": {"name": "python"}},
      "nbformat": 4, "nbformat_minor": 0}
with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    json.dump(nb, f, ensure_ascii=False, indent=1)
    f.write("\n")
print(f"ok: {OUT} ({len(cells)} celdas)")
