#!/usr/bin/env bash
# Pipeline completo de descripcion de escenas en una instancia de Lambda (Ubuntu + GPU NVIDIA).
#
#   git clone https://github.com/yongiluu/Proyecto_Iris.git && cd Proyecto_Iris/ML_Training
#   bash scene/lambda/run_all.sh                          # todo: fotos, profesor, entrenamiento, export
#   COUNT=20000 bash scene/lambda/run_all.sh              # menos fotos (prueba mas barata)
#   MODEL=Qwen/Qwen2.5-VL-32B-Instruct bash scene/lambda/run_all.sh   # profesor mas grande (A100 80 GB / H100)
#   STEP=teacher bash scene/lambda/run_all.sh             # retomar desde un paso: images|teacher|train
#
# Usa dos entornos de Python separados porque vLLM (profesor) y TensorFlow (alumno) suelen chocar.
# Al final, copia a tu PC data/scene/labels_teacher_*.jsonl (las etiquetas valen oro) y models/scene_*.
set -euo pipefail

MODEL=${MODEL:-Qwen/Qwen2.5-VL-7B-Instruct}
COUNT=${COUNT:-60000}
EPOCHS=${EPOCHS:-40}
STEP=${STEP:-images}
PORT=8000
cd "$(dirname "$0")/../.."   # ML_Training
mkdir -p logs

STEPS=(images teacher train)
step_index() { for i in "${!STEPS[@]}"; do [[ "${STEPS[$i]}" == "$1" ]] && echo "$i"; done; }
[ -n "$(step_index "$STEP")" ] || { echo "STEP debe ser uno de: ${STEPS[*]}"; exit 1; }
step_reached() { [ "$(step_index "$1")" -ge "$(step_index "$STEP")" ]; }  # pasos desde STEP en adelante

if [ ! -d ~/venv_train ]; then
  python3 -m venv ~/venv_train
  ~/venv_train/bin/pip install -q --upgrade pip
  ~/venv_train/bin/pip install -q "tensorflow[and-cuda]" -r requirements.txt
fi
if [ ! -d ~/venv_teacher ]; then
  python3 -m venv ~/venv_teacher
  ~/venv_teacher/bin/pip install -q --upgrade pip
  ~/venv_teacher/bin/pip install -q vllm requests tqdm
fi

if step_reached images; then
  echo "== 1/4 Fotos a color de Open Images ($COUNT) =="
  ~/venv_train/bin/python scene/download_images.py --count "$COUNT" --workers 64
fi

if step_reached teacher; then
  echo "== 2/4 Profesor: $MODEL con vLLM =="
  ~/venv_teacher/bin/vllm serve "$MODEL" --port $PORT --max-model-len 8192 > logs/vllm.log 2>&1 &
  VLLM_PID=$!
  trap 'kill $VLLM_PID 2>/dev/null || true' EXIT
  echo "Cargando el modelo (puede tardar varios minutos la primera vez)..."
  until curl -sf "http://localhost:$PORT/v1/models" > /dev/null; do
    kill -0 $VLLM_PID 2>/dev/null || { echo "vLLM se cayo, ver logs/vllm.log"; tail -30 logs/vllm.log; exit 1; }
    sleep 10
  done
  echo "-- Prueba con 10 fotos (revisa que las frases tengan sentido) --"
  ~/venv_teacher/bin/python scene/label_teacher.py --url "http://localhost:$PORT/v1" --model "$MODEL" --limit 10
  echo "-- Todas las fotos --"
  ~/venv_teacher/bin/python scene/label_teacher.py --url "http://localhost:$PORT/v1" --model "$MODEL" --workers 64
  kill $VLLM_PID; trap - EXIT
fi

if step_reached train; then
  echo "== 3/4 Alumno (GPU) =="
  ~/venv_train/bin/python scene/train.py --labels mix --epochs "$EPOCHS" --batch-size 128
  echo "== 4/4 int8 + demo =="
  ~/venv_train/bin/python scene/export_model.py
  ~/venv_train/bin/python scene/demo.py --int8 --n 120
fi

echo
echo "Listo. Trae a tu PC (desde tu PC):"
echo "  scp ubuntu@<ip>:~/Proyecto_Iris/ML_Training/data/scene/labels_teacher_*.jsonl ML_Training/data/scene/"
echo "  scp ubuntu@<ip>:~/Proyecto_Iris/ML_Training/models/scene_* ML_Training/models/"
echo "  scp ubuntu@<ip>:~/Proyecto_Iris/ML_Training/data/scene/demo_alumno.html ."
echo "Y APAGA LA INSTANCIA en el panel de Lambda (se cobra por hora)."
