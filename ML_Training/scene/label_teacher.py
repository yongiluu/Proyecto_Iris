"""Etiqueta fotos con un modelo de vision-lenguaje grande (el profesor) servido con API compatible con OpenAI.

En Lambda (ver scene/README.md), con vLLM sirviendo Qwen2.5-VL:
    vllm serve Qwen/Qwen2.5-VL-7B-Instruct --max-model-len 8192 --limit-mm-per-prompt image=1
    python scene/label_teacher.py --url http://localhost:8000/v1 --model Qwen/Qwen2.5-VL-7B-Instruct

Fotos que etiqueta (por defecto, todas):
    - las de data/scene/labels_auto.jsonl (Open Images, ya bajadas por download_images.py)
    - las fotos reales de la placa en data/scene_board/
Escribe data/scene/labels_teacher_<modelo>.jsonl. Se puede cortar y retomar: salta lo ya etiquetado.
Con --limit 20 se prueba rapido y se imprimen las frases resultantes.
"""
import argparse
import base64
import json
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests
from tqdm import tqdm

import config
from describe import describe, scene_from_labels
from schema import clean, json_schema
from teacher_prompt import PROMPT_VERSION, build_prompt


def list_images(sources: list[str]) -> list[str]:
    images = []
    if "openimages" in sources and config.AUTO_LABELS.exists():
        with open(config.AUTO_LABELS, encoding="utf-8") as file:
            images += [json.loads(line)["image"] for line in file]
    if "board" in sources and config.BOARD_IMAGES_DIR.exists():
        images += [f"board/{p.name}" for p in sorted(config.BOARD_IMAGES_DIR.glob("*.png"))]
    return images


def image_path(name: str) -> Path:
    if name.startswith("board/"):
        return config.BOARD_IMAGES_DIR / name.split("/", 1)[1]
    return config.IMAGES_DIR / name


def ask_teacher(url: str, model: str, api_key: str, prompt: str, image_file: Path, guided: bool) -> dict:
    data = base64.b64encode(image_file.read_bytes()).decode()
    mime = "image/png" if image_file.suffix == ".png" else "image/jpeg"
    body = {
        "model": model,
        "temperature": 0,
        "max_tokens": 700,
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}},
            {"type": "text", "text": prompt},
        ]}],
    }
    if guided:  # vLLM (y otros) obligan a que la salida cumpla el esquema
        body["response_format"] = {"type": "json_schema",
                                   "json_schema": {"name": "escena", "schema": json_schema(), "strict": True}}
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    for attempt in range(4):
        try:
            response = requests.post(f"{url.rstrip('/')}/chat/completions", json=body, headers=headers, timeout=180)
            response.raise_for_status()
            text = response.json()["choices"][0]["message"]["content"]
            match = re.search(r"\{.*\}", text, re.S)
            return json.loads(match.group(0) if match else text)
        except (requests.RequestException, ValueError, KeyError):
            if attempt == 3:
                raise
            time.sleep(2 * (attempt + 1))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://localhost:8000/v1")
    parser.add_argument("--model", default="Qwen/Qwen2.5-VL-7B-Instruct")
    parser.add_argument("--api-key", default=os.environ.get("TEACHER_API_KEY", ""))
    parser.add_argument("--sources", default="openimages,board", help="openimages,board")
    parser.add_argument("--workers", type=int, default=16, help="pedidos en paralelo (vLLM los agrupa en la GPU)")
    parser.add_argument("--limit", type=int, default=0, help="solo N fotos (prueba)")
    parser.add_argument("--no-guided", action="store_true", help="si el servidor no soporta response_format json_schema")
    args = parser.parse_args()

    short_name = re.sub(r"[^a-z0-9.]+", "-", args.model.split("/")[-1].lower()).strip("-")
    out_file = config.DATA_DIR / f"labels_teacher_{short_name}.jsonl"
    done = set()
    if out_file.exists():
        with open(out_file, encoding="utf-8") as file:
            done = {json.loads(line)["image"] for line in file}

    images = [i for i in list_images(args.sources.split(",")) if i not in done]
    if args.limit:
        images = images[:args.limit]
    print(f"{len(images)} fotos por etiquetar con {args.model} ({len(done)} ya hechas) -> {out_file}")
    prompt = build_prompt()

    def work(name):
        raw = ask_teacher(args.url, args.model, args.api_key, prompt, image_path(name), not args.no_guided)
        labels, problems = clean(raw)
        return {"image": name, "source": short_name, "prompt": PROMPT_VERSION, "labels": labels,
                "problems": problems}

    errors, examples = 0, []
    with open(out_file, "a", encoding="utf-8") as out, ThreadPoolExecutor(args.workers) as pool:
        futures = {pool.submit(work, name): name for name in images}
        for future in tqdm(as_completed(futures), total=len(futures), desc="Profesor"):
            try:
                row = future.result()
            except Exception as e:
                errors += 1
                tqdm.write(f"  error con {futures[future]}: {e}")
                continue
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
            out.flush()
            if len(examples) < 10:
                examples.append(row)

    for row in examples if args.limit else []:
        print(f"\n{row['image']}\n  -> {describe(scene_from_labels(row['labels']))}"
              + (f"\n  detalle: {row['labels']['detalle']}" if row['labels'].get('detalle') else "")
              + (f"\n  problemas: {row['problems']}" if row['problems'] else ""))
    print(f"\n✔ Listo ({errors} errores). Siguiente: python scene/train.py")


if __name__ == "__main__":
    main()
