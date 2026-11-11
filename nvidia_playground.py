#!/usr/bin/env python3
"""NVIDIA NIM interactive playground with task-specific payload presets.

Loads models from nvidia_inventory.json, supports chat/completions/embeddings
plus dedicated vision, ranking, document, and genai-style payloads.
"""

import base64
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from getpass import getpass

INVENTORY = "nvidia_inventory.json"
HISTORY = "nvidia_playground_history.jsonl"
BASE_URL = "https://integrate.api.nvidia.com/v1"
AI_API = "https://ai.api.nvidia.com/v1"

API_KEY = ""
BASE = BASE_URL
TIMEOUT = 180
MODELS = []


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def load_models():
    if not os.path.exists(INVENTORY):
        print(f"\nMissing {INVENTORY}")
        sys.exit(1)

    with open(INVENTORY, encoding="utf-8") as f:
        data = json.load(f)

    raw = data.get("models", []) if isinstance(data, dict) else data
    models = []
    seen = set()

    for item in raw:
        if isinstance(item, str):
            mid = item
        elif isinstance(item, dict):
            mid = item.get("id") or item.get("model") or ""
        else:
            continue

        mid = str(mid).strip()
        if mid and mid not in seen:
            seen.add(mid)
            models.append(mid)

    return sorted(models, key=str.lower)


def save_history(record):
    with open(HISTORY, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def pause():
    input("\nPress Enter to continue...")


def header(title):
    os.system("clear" if os.name != "nt" else "cls")
    print("=" * 66)
    print("              NVIDIA NIM MODEL PLAYGROUND")
    print("=" * 66)
    print(title)
    print("-" * 66)


def choose_model():
    while True:
        header("MODEL SELECTION")
        print(f"Available models: {len(MODELS)}")
        print("\nSearch by model name, or enter a model number.")
        print("Enter q to return.\n")

        term = input("Search / selection: ").strip()

        if term.lower() == "q":
            return None

        if term.isdigit():
            index = int(term) - 1
            if 0 <= index < len(MODELS):
                return MODELS[index]

        matches = [m for m in MODELS if term.lower() in m.lower()]

        if not matches:
            print("\nNo matching models.")
            pause()
            continue

        print()
        for i, model in enumerate(matches, 1):
            print(f"{i:>3}. {model}")

        selection = input(
            "\nSelect result number, or Enter to search again: "
        ).strip()

        if selection.isdigit():
            index = int(selection) - 1
            if 0 <= index < len(matches):
                return matches[index]


def list_models():
    while True:
        header("MODEL CATALOG")
        for i, model in enumerate(MODELS, 1):
            print(f"{i:>3}. {model}")

        print("\nEnter a model number to select it.")
        print("Enter s to search, q to return.")

        choice = input("\nSelection: ").strip().lower()

        if choice == "q":
            return None

        if choice == "s":
            model = choose_model()
            if model:
                return model

        if choice.isdigit():
            index = int(choice) - 1
            if 0 <= index < len(MODELS):
                return MODELS[index]


def classify_hint(model):
    m = model.lower()

    if any(x in m for x in ("rerank", "reranker")):
        return "Hint: ranking / rerank payload"
    if any(x in m for x in ("embed", "nvclip")):
        return "Hint: embeddings (optionally with input_type)"
    if any(x in m for x in (
        "parakeet", "magpie", "canary", "riva",
        "chatterbox", "speech", "tts", "asr"
    )):
        return "Hint: speech → use gRPC / NVCF (not this REST playground)"
    if any(x in m for x in ("parse", "docling", "document", "ocr")):
        return "Hint: document / OCR style payload"
    if any(x in m for x in (
        "flux", "stable-diffusion", "sdxl", "imagen", "image-gen"
    )):
        return "Hint: image generation (genai path)"
    if any(x in m for x in ("cosmos", "video")):
        return "Hint: video / cosmos style payload"
    if any(x in m for x in (
        "vlm", "vision", "vila", "neva", "phi-3-vision", "phi-3.5-vision",
        "llama-3.2-11b-vision", "llama-3.2-90b-vision", "qwen2-vl", "qwen2.5-vl"
    )):
        return "Hint: vision → use Vision Chat preset"
    return "Hint: language / chat model"


def endpoint_menu():
    """Return (operation_name, path_or_url, payload_kind)."""
    options = [
        ("Chat Completions", "/chat/completions", "chat"),
        ("Vision Chat (image + text)", "/chat/completions", "vision"),
        ("Text Completions", "/completions", "completions"),
        ("Responses API", "/responses", "responses"),
        ("Embeddings", "/embeddings", "embeddings"),
        ("Embeddings + input_type", "/embeddings", "embeddings_typed"),
        ("Ranking (integrate /v1/ranking)", "/ranking", "ranking"),
        ("Rerank (ai.api retrieval path)", None, "rerank"),
        ("Image generation (genai)", None, "image_gen"),
        ("Custom endpoint + JSON", None, "custom"),
    ]

    print("\nAPI OPERATION / PAYLOAD PRESET")
    for i, (name, path, _) in enumerate(options, 1):
        suffix = path if path else "(model-specific URL)"
        print(f"  {i:>2}. {name:<34} {suffix or ''}")

    while True:
        choice = input("\nChoose operation: ").strip()
        if choice.isdigit():
            idx = int(choice) - 1
            if 0 <= idx < len(options):
                return options[idx]
        print("Invalid selection.")


def resolve_image_ref(ref):
    """Turn a path or URL into an image_url value (URL or data: URL)."""
    ref = ref.strip()
    if not ref:
        return None
    if ref.startswith(("http://", "https://", "data:")):
        return ref
    if os.path.isfile(ref):
        mime = mimetypes.guess_type(ref)[0] or "image/jpeg"
        with open(ref, "rb") as f:
            b64 = base64.b64encode(f.read()).decode("ascii")
        return f"data:{mime};base64,{b64}"
    print(f"Not a readable file or URL: {ref}")
    return None


def build_payload(kind, model, **kwargs):
    prompt = kwargs.get("prompt", "")
    system_prompt = kwargs.get("system_prompt", "You are a helpful assistant.")
    max_tokens = kwargs.get("max_tokens", 512)
    temperature = kwargs.get("temperature", 0.7)
    image_url = kwargs.get("image_url")
    query = kwargs.get("query", prompt)
    passages = kwargs.get("passages") or []

    if kind == "chat":
        return {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": prompt},
            ],
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": False,
        }

    if kind == "vision":
        if not image_url:
            raise ValueError("Vision payload requires an image URL or local path")
        content = [
            {"type": "text", "text": prompt or "Describe this image."},
            {"type": "image_url", "image_url": {"url": image_url}},
        ]
        return {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": content},
            ],
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": False,
        }

    if kind == "completions":
        full = (system_prompt + "\n\n" + prompt) if system_prompt else prompt
        return {
            "model": model,
            "prompt": full,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": False,
        }

    if kind == "responses":
        return {
            "model": model,
            "instructions": system_prompt,
            "input": prompt,
            "max_output_tokens": max_tokens,
            "temperature": temperature,
        }

    if kind == "embeddings":
        return {
            "model": model,
            "input": [prompt or "NVIDIA endpoint connectivity test"],
            "encoding_format": "float",
        }

    if kind == "embeddings_typed":
        return {
            "model": model,
            "input": [prompt or "NVIDIA endpoint connectivity test"],
            "input_type": kwargs.get("input_type", "query"),
            "encoding_format": "float",
        }

    if kind == "ranking":
        if not passages:
            passages = [
                "H100 has approximately 3.35 TB/s memory bandwidth.",
                "A100 has lower memory bandwidth than H100.",
            ]
        return {
            "model": model,
            "query": {"text": query or "What is the memory bandwidth of H100?"},
            "passages": [{"text": p} for p in passages],
        }

    if kind == "rerank":
        if not passages:
            passages = [
                "H100 has approximately 3.35 TB/s memory bandwidth.",
                "A100 has lower memory bandwidth than H100.",
            ]
        return {
            "model": model,
            "query": {"text": query or "What is the memory bandwidth of H100?"},
            "passages": [{"text": p} for p in passages],
        }

    if kind == "image_gen":
        return {
            "prompt": prompt or "a red cube on a white table, studio lighting",
            "cfg_scale": float(kwargs.get("cfg_scale", 3.5)),
            "steps": int(kwargs.get("steps", 20)),
        }

    return None


def default_path_for(kind, model):
    mid = model.strip("/")
    if "/" in mid:
        publisher, name = mid.split("/", 1)
    else:
        publisher, name = "nvidia", mid

    if kind in ("chat", "vision", "completions", "responses",
                "embeddings", "embeddings_typed", "ranking"):
        path_map = {
            "chat": "/chat/completions",
            "vision": "/chat/completions",
            "completions": "/completions",
            "responses": "/responses",
            "embeddings": "/embeddings",
            "embeddings_typed": "/embeddings",
            "ranking": "/ranking",
        }
        return BASE.rstrip("/") + path_map[kind]

    if kind == "rerank":
        return f"{AI_API}/retrieval/nvidia/reranking"

    if kind == "image_gen":
        return f"{AI_API}/genai/{publisher}/{name}"

    return None


def endpoint_url(path):
    if path is None:
        return None
    if path.startswith("http://") or path.startswith("https://"):
        return path
    return BASE.rstrip("/") + "/" + path.lstrip("/")


def request_api(url, payload):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            raw = response.read().decode("utf-8", errors="replace")
            code = response.status
    except urllib.error.HTTPError as e:
        code = e.code
        raw = e.read().decode("utf-8", errors="replace")
    except Exception as e:
        return {
            "http_code": None,
            "latency": round(time.monotonic() - start, 3),
            "body": None,
            "raw": str(e),
        }

    elapsed = round(time.monotonic() - start, 3)
    try:
        parsed = json.loads(raw)
    except Exception:
        parsed = None

    return {
        "http_code": code,
        "latency": elapsed,
        "body": parsed,
        "raw": raw,
    }


def extract_text(kind, body):
    if not isinstance(body, dict):
        return None

    if kind in ("chat", "vision"):
        try:
            message = body["choices"][0]["message"]
            return (
                message.get("content")
                or message.get("reasoning_content")
                or str(message)
            )
        except Exception:
            return None

    if kind == "completions":
        try:
            return body["choices"][0].get("text")
        except Exception:
            return None

    if kind == "responses":
        if body.get("output_text"):
            return body["output_text"]
        try:
            parts = []
            for item in body.get("output", []):
                for content in item.get("content", []):
                    if content.get("text"):
                        parts.append(content["text"])
            return "\n".join(parts) or None
        except Exception:
            return None

    if kind in ("embeddings", "embeddings_typed"):
        try:
            vector = body["data"][0]["embedding"]
            return f"Embedding returned: {len(vector)} dimensions"
        except Exception:
            return None

    if kind in ("ranking", "rerank"):
        for key in ("rankings", "results", "data"):
            if key in body:
                return json.dumps(body[key], indent=2)[:4000]
        return json.dumps(body, indent=2)[:4000]

    if kind == "image_gen":
        # Some genai endpoints return base64 or a URL; surface whatever we get.
        return json.dumps(body, indent=2)[:4000]

    return None


def print_response(result, kind):
    print("\n" + "=" * 66)
    print("                    API RESPONSE")
    print("=" * 66)

    code = result["http_code"]
    print(f"HTTP status: {code if code is not None else 'NO RESPONSE'}")
    print(f"Latency:     {result['latency']} seconds")

    body = result["body"]
    text = extract_text(kind, body)

    if 200 <= (code or 0) < 300:
        if text:
            print("\nMODEL OUTPUT:\n")
            print(text)
        else:
            print("\nRequest succeeded, but no standard text output was found.")
            print("\nRAW RESPONSE:\n")
            print(result["raw"][:10000])
    else:
        print("\nREQUEST ERROR:\n")
        print(result["raw"][:10000])

    print("\n" + "=" * 66)


def run_test(model, operation, url, payload, kind):
    print("\nMODEL:    ", model)
    print("OPERATION:", operation)
    print("ENDPOINT: ", url)
    print("\nSending request...")

    result = request_api(url, payload)
    print_response(result, kind)

    save_history({
        "timestamp": timestamp(),
        "model": model,
        "operation": operation,
        "kind": kind,
        "endpoint": url,
        "payload": payload,
        "http_code": result["http_code"],
        "latency_seconds": result["latency"],
        "response": result["body"],
        "raw_response": result["raw"][:12000],
    })
    return result


def collect_common_params():
    system_prompt = input(
        "\nSystem prompt (Enter for default): "
    ).strip() or "You are a helpful assistant."

    try:
        max_tokens = int(input("Maximum output tokens [512]: ").strip() or "512")
        temperature = float(input("Temperature [0.7]: ").strip() or "0.7")
    except ValueError:
        print("Invalid parameter.")
        return None

    if not (1 <= max_tokens <= 32768):
        print("Token limit must be between 1 and 32768.")
        return None

    return system_prompt, max_tokens, temperature


def interactive_model_test(model):
    header("SINGLE MODEL TEST")
    print("Selected:", model)
    print(classify_hint(model))

    operation, path, kind = endpoint_menu()

    # Resolve endpoint
    if kind == "custom":
        custom_path = input(
            "Enter full URL or path (e.g. /chat/completions or https://...): "
        ).strip()
        if not custom_path:
            return
        url = endpoint_url(custom_path)
        payload = custom_payload(model)
        if payload is None:
            return
        run_test(model, operation, url, payload, kind)
        pause()
        return

    if kind in ("rerank", "image_gen"):
        url = default_path_for(kind, model)
        # allow override
        override = input(f"Endpoint [{url}]: ").strip()
        if override:
            url = endpoint_url(override)
    else:
        url = endpoint_url(path) if path else default_path_for(kind, model)

    # Build payload by kind
    if kind == "vision":
        params = collect_common_params()
        if not params:
            pause()
            return
        system_prompt, max_tokens, temperature = params
        print("\nImage source: public URL or local file path")
        img_ref = input("Image: ").strip()
        image_url = resolve_image_ref(img_ref)
        if not image_url:
            print("No valid image provided.")
            pause()
            return
        prompt = input("Prompt [Describe this image.]: ").strip() or "Describe this image."
        try:
            payload = build_payload(
                kind, model,
                prompt=prompt,
                system_prompt=system_prompt,
                max_tokens=max_tokens,
                temperature=temperature,
                image_url=image_url,
            )
        except ValueError as e:
            print(e)
            pause()
            return
        run_test(model, operation, url, payload, kind)
        pause()
        return

    if kind in ("ranking", "rerank"):
        query = input("\nQuery text: ").strip() or "What is the memory bandwidth of H100?"
        print("Passages (one per line, empty line to finish; Enter twice for defaults):")
        passages = []
        while True:
            line = input()
            if not line.strip():
                break
            passages.append(line.strip())
        payload = build_payload(kind, model, query=query, passages=passages)
        run_test(model, operation, url, payload, kind)
        pause()
        return

    if kind == "image_gen":
        prompt = input("\nImage prompt: ").strip() or "a red cube on a white table, studio lighting"
        try:
            cfg = float(input("cfg_scale [3.5]: ").strip() or "3.5")
            steps = int(input("steps [20]: ").strip() or "20")
        except ValueError:
            print("Invalid cfg/steps.")
            pause()
            return
        payload = build_payload(kind, model, prompt=prompt, cfg_scale=cfg, steps=steps)
        # many genai models want the model id in the path only; still include if present
        if "model" not in payload:
            payload = dict(payload)
        run_test(model, operation, url, payload, kind)
        pause()
        return

    if kind in ("embeddings", "embeddings_typed"):
        text = input("\nText to embed: ").strip() or "NVIDIA endpoint connectivity test"
        input_type = "query"
        if kind == "embeddings_typed":
            input_type = input("input_type [query]: ").strip() or "query"
        payload = build_payload(
            kind, model, prompt=text, input_type=input_type
        )
        run_test(model, operation, url, payload, kind)
        pause()
        return

    # chat / completions / responses — conversational loop for chat
    params = collect_common_params()
    if not params:
        pause()
        return
    system_prompt, max_tokens, temperature = params

    if kind != "chat":
        prompt = input("\nPrompt: ").strip()
        if not prompt:
            return
        payload = build_payload(
            kind, model,
            prompt=prompt,
            system_prompt=system_prompt,
            max_tokens=max_tokens,
            temperature=temperature,
        )
        run_test(model, operation, url, payload, kind)
        pause()
        return

    # multi-turn chat
    print("\nEnter your prompt.")
    print("Enter /exit to return, /system to change system prompt, /clear to reset.\n")
    messages = []

    while True:
        prompt = input("YOU > ").strip()
        if not prompt:
            continue
        if prompt == "/exit":
            break
        if prompt == "/system":
            new_system = input("New system prompt: ").strip()
            if new_system:
                system_prompt = new_system
                print("System prompt updated.")
            continue
        if prompt == "/clear":
            messages = []
            print("Conversation cleared.")
            continue

        messages.append({"role": "user", "content": prompt})
        payload = {
            "model": model,
            "messages": [{"role": "system", "content": system_prompt}] + messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": False,
        }
        result = run_test(model, operation, url, payload, kind)
        answer = extract_text(kind, result["body"])
        if answer:
            messages.append({"role": "assistant", "content": answer})


def custom_payload(model):
    print("\nCUSTOM JSON PAYLOAD")
    print("Use $MODEL as a placeholder for the selected model ID.")
    print("Paste one JSON object (single line or multi-line ending with a blank line).")
    print('Example: {"model":"$MODEL","messages":[{"role":"user","content":"hi"}]}')
    print()

    lines = []
    while True:
        line = input()
        if not line.strip() and lines:
            break
        if line.strip():
            lines.append(line)
        elif not lines:
            continue

    raw = "\n".join(lines).replace("$MODEL", model)
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"Invalid JSON: {e}")
        return None

    if not isinstance(payload, dict):
        print("Payload must be a JSON object.")
        return None

    if "model" not in payload:
        payload["model"] = model
    return payload


def compare_models():
    header("COMPARE MULTIPLE MODELS")
    print("Enter model IDs or numbers, comma-separated.\n")
    for i, model in enumerate(MODELS, 1):
        print(f"{i:>3}. {model}")

    raw = input("\nModels: ").strip()
    if not raw:
        return

    selected = []
    for item in raw.split(","):
        item = item.strip()
        if item.isdigit():
            index = int(item) - 1
            if 0 <= index < len(MODELS):
                selected.append(MODELS[index])
        else:
            match = next((m for m in MODELS if m.lower() == item.lower()), None)
            if match:
                selected.append(match)

    selected = list(dict.fromkeys(selected))
    if not selected:
        print("No valid models selected.")
        pause()
        return

    operation, path, kind = endpoint_menu()
    if kind in ("custom", "vision", "ranking", "rerank", "image_gen"):
        print("This compare mode only supports simple chat/completions/embeddings presets.")
        pause()
        return

    prompt = input("\nShared prompt: ").strip()
    if not prompt:
        return

    system_prompt = input(
        "System prompt [You are a helpful assistant]: "
    ).strip() or "You are a helpful assistant."

    try:
        max_tokens = int(input("Maximum output tokens [512]: ").strip() or "512")
        temperature = float(input("Temperature [0.7]: ").strip() or "0.7")
    except ValueError:
        print("Invalid parameters.")
        pause()
        return

    for model in selected:
        print("\n\n" + "#" * 66)
        print("MODEL:", model)
        print("#" * 66)
        url = endpoint_url(path) if path else default_path_for(kind, model)
        payload = build_payload(
            kind, model,
            prompt=prompt,
            system_prompt=system_prompt,
            max_tokens=max_tokens,
            temperature=temperature,
        )
        run_test(model, operation, url, payload, kind)

    pause()


def custom_request():
    model = choose_model()
    if not model:
        return
    header("CUSTOM REQUEST")
    print("Model:", model)
    path = input("Full URL or path: ").strip()
    if not path:
        return
    url = endpoint_url(path)
    payload = custom_payload(model)
    if payload is None:
        pause()
        return
    run_test(model, "Custom", url, payload, "custom")
    pause()


def show_history():
    header("RECENT TEST HISTORY")
    if not os.path.exists(HISTORY):
        print("No test history yet.")
        pause()
        return

    records = []
    with open(HISTORY, encoding="utf-8") as f:
        for line in f:
            try:
                records.append(json.loads(line))
            except Exception:
                pass

    for record in records[-30:]:
        print("-" * 66)
        print("Time:     ", record.get("timestamp"))
        print("Model:    ", record.get("model"))
        print("Operation:", record.get("operation"))
        print("Endpoint: ", record.get("endpoint"))
        print("HTTP:     ", record.get("http_code"))
        print("Latency:  ", record.get("latency_seconds"))
    pause()


def settings():
    global BASE, TIMEOUT
    while True:
        header("SETTINGS")
        print("Current API base:", BASE)
        print("Timeout:", TIMEOUT, "seconds")
        print("\n1. Change API base URL")
        print("2. Change timeout")
        print("3. Return")

        choice = input("\nSelection: ").strip()
        if choice == "1":
            value = input("New base URL: ").strip()
            if value.startswith(("https://", "http://")):
                BASE = value.rstrip("/")
                print("Updated.")
                pause()
        elif choice == "2":
            try:
                value = int(input("Timeout seconds: "))
                if 5 <= value <= 600:
                    TIMEOUT = value
            except ValueError:
                pass
        elif choice == "3":
            return


def main():
    global API_KEY, MODELS

    MODELS = load_models()
    if not MODELS:
        sys.exit("No models found in inventory.")

    header("INITIALIZATION")
    print(f"Loaded {len(MODELS)} models from {INVENTORY}.")
    print("\nNVIDIA API key is requested for this session.")
    API_KEY = getpass("\nPaste NVIDIA API key: ").strip()
    if not API_KEY:
        sys.exit("No API key supplied.")

    while True:
        header("MAIN MENU")
        print(f"Models loaded: {len(MODELS)}")
        print(f"API base: {BASE}")
        print()
        print("  1. Browse model catalog")
        print("  2. Search and select a model")
        print("  3. Test a specific model")
        print("  4. Compare multiple models")
        print("  5. Custom endpoint / JSON request")
        print("  6. View recent test history")
        print("  7. Settings")
        print("  0. Exit")

        choice = input("\nChoose: ").strip()

        if choice == "1":
            model = list_models()
            if model:
                interactive_model_test(model)
        elif choice == "2":
            model = choose_model()
            if model:
                interactive_model_test(model)
        elif choice == "3":
            model = choose_model()
            if model:
                interactive_model_test(model)
        elif choice == "4":
            compare_models()
        elif choice == "5":
            custom_request()
        elif choice == "6":
            show_history()
        elif choice == "7":
            settings()
        elif choice == "0":
            print("\nExiting NVIDIA playground.")
            break


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nExited.")
        sys.exit(0)
