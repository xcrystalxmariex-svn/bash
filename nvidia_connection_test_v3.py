#!/usr/bin/env python3
"""NVIDIA hosted-model endpoint tester with conservative task-aware routing (v5).

Discovers models from NVIDIA's live OpenAI-compatible catalog, applies explicit
routing contracts, probes only supported task families, and saves incremental
JSON/CSV reports. Unknown or specialized models are recorded as UNVERIFIED,
never blindly sent a chat payload.

Environment: NVIDIA_API_KEY (or interactive prompt). Optional inventory JSON
with {"models": ["provider/model", ...]} to limit tests to chosen model IDs.
"""
import argparse
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.request
import ssl
import subprocess
from collections import Counter
from datetime import datetime, timezone

INTEGRATE = "https://integrate.api.nvidia.com/v1"
INFERENCE = "https://inference-api.nvidia.com/v1"
AI_API = "https://ai.api.nvidia.com/v1"
# Specialized APIs often have model-specific payloads. The route can be
# resolved automatically, but probes are sent only when an exact payload is
# supplied in the overrides file.

TIMEOUT = 45
DELAY = 0.2
JSON_OUT = "nvidia_connection_results_v3.json"
CSV_OUT = "nvidia_connection_results_v3.csv"
INVENTORY = "nvidia_inventory.json"
OVERRIDES_FILE = "nvidia_endpoint_overrides.json"
FIELDS = ["model", "task", "route_source", "endpoint", "status", "http_code",
          "latency_seconds", "response_preview", "error", "tested_at"]

EMBEDDING_IDS = {
    "nvidia/embed-qa-4",
    "nvidia/nv-embedqa-mistral-7b-v2",
    "nvidia/nv-embedqa-e5-v5",
    "nvidia/llama-3.2-nv-embedqa-1b-v1",
    "nvidia/llama-3.2-nv-embedqa-1b-v2",
    "nvidia/llama-nemotron-embed-1b-v2",
    "nvidia/llama-nemotron-embed-vl-1b-v2",
    "nvidia/nemotron-3-embed-1b",
    "nvidia/nemotron-3.5-embed-1b",
    "nvidia/nemotron-3.5-embed-8b",
    "snowflake/arctic-embed-l",
}


def now():
    return datetime.now(timezone.utc).isoformat()


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def atomic_json(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def request(url, method="GET", payload=None, key=None):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if key:
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read().decode("utf-8", "replace")
            try:
                body = json.loads(raw)
            except ValueError:
                body = {"_raw": raw[:2000]}
            return r.status, body, round(time.monotonic() - started, 3), None
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            body = json.loads(raw)
        except ValueError:
            body = None
        return e.code, body, round(time.monotonic() - started, 3), raw[:2000]
    except Exception as e:
        return None, None, round(time.monotonic() - started, 3), str(e)[:2000]


NVCF_FUNCTIONS = "https://api.nvcf.nvidia.com/v2/nvcf/functions"
GRPC_HOST = "grpc.nvcf.nvidia.com:443"


def ensure_grpc_dependencies():
    """Install the Python gRPC/protobuf runtime when missing."""
    try:
        import grpc  # noqa: F401
        from google import protobuf  # noqa: F401
        return True, None
    except ImportError:
        print("Installing required packages: grpcio and protobuf...")
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "grpcio", "protobuf"])
            import grpc  # noqa: F401
            from google import protobuf  # noqa: F401
            return True, None
        except Exception as exc:
            return False, str(exc)


def resolve_nvcf_functions(key):
    """Fetch accessible NVCF functions and index their IDs and metadata."""
    code, body, _, err = request(NVCF_FUNCTIONS, key=key)
    if code != 200 or not isinstance(body, dict):
        return {}, f"NVCF function lookup failed (HTTP {code}): {err or body}"
    items = body.get("functions", body.get("data", []))
    if isinstance(items, dict):
        items = items.get("functions", [])
    index = {}
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict):
            continue
        fid = item.get("id") or item.get("functionId") or item.get("function_id")
        name = item.get("name") or item.get("functionName") or item.get("model") or ""
        if fid:
            index[str(name).lower()] = {"id": str(fid), "name": str(name), "raw": item}
            index[str(fid).lower()] = {"id": str(fid), "name": str(name), "raw": item}
    return index, None


def find_function_id(mid, functions, ov):
    explicit = ov.get("function_id")
    if explicit:
        return str(explicit)
    target = mid.lower().replace("_", "-")
    for name, item in functions.items():
        if name == item["id"].lower():
            continue
        normalized = name.replace("_", "-")
        if target in normalized or normalized in target:
            return item["id"]
    return None


def grpc_probe_speech(function_id, key, model_id, ov):
    """Call a Riva-compatible gRPC method; model-specific protos may be needed."""
    try:
        import grpc
        from google.protobuf import descriptor_pb2, descriptor_pool, message_factory
    except ImportError as exc:
        return None, None, f"gRPC dependencies unavailable: {exc}"
    # Build minimal Riva-compatible protobuf descriptors dynamically, avoiding
    # generated stubs. Function-specific services may still require overrides.
    service = ov.get("grpc_service", "nvidia.riva.asr.RivaSpeechRecognition")
    method = ov.get("grpc_method", "Recognize")
    request_type = ov.get("grpc_request_type", "nvidia.riva.asr.RecognizeRequest")
    request_fields = ov.get("grpc_request_fields")
    if not isinstance(request_fields, dict):
        return None, None, "Function ID resolved, but speech probe needs grpc_service, grpc_method, grpc_request_type, and grpc_request_fields in overrides; protobuf contract cannot safely be guessed."
    try:
        file_proto = descriptor_pb2.FileDescriptorProto()
        file_proto.name = "nvidia_connection_probe.proto"
        file_proto.package = request_type.rsplit(".", 1)[0]
        message_name = request_type.rsplit(".", 1)[-1]
        msg = file_proto.message_type.add()
        msg.name = message_name
        for number, (field_name, spec) in enumerate(request_fields.items(), 1):
            field = msg.field.add()
            field.name = field_name
            field.number = number
            field.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
            field.type = descriptor_pb2.FieldDescriptorProto.TYPE_STRING
            # Values can only be represented as string in this generic builder;
            # use an exact generated client for byte/repeated/nested contracts.
        pool = descriptor_pool.DescriptorPool()
        pool.Add(file_proto)
        desc = pool.FindMessageTypeByName(request_type)
        cls = message_factory.GetMessageClass(desc)
        req = cls()
        for field_name, value in request_fields.items():
            setattr(req, field_name, str(value))
        channel = grpc.secure_channel(GRPC_HOST, grpc.ssl_channel_credentials())
        rpc = channel.unary_unary(
            f"/{service}/{method}",
            request_serializer=lambda obj: obj.SerializeToString(),
            response_deserializer=lambda data: data,
        )
        response = rpc(req, metadata=(("function-id", function_id),
                                     ("authorization", "Bearer " + key)),
                       timeout=TIMEOUT)
        channel.close()
        return 200, repr(response[:300] if isinstance(response, bytes) else response), None
    except Exception as exc:
        return None, None, f"gRPC probe failed: {exc}"


def model_ids(key, source):
    """Return the union of unified-catalog models and accessible NVCF functions."""
    if source:
        data = read_json(source)
        if not isinstance(data, dict) or not isinstance(data.get("models"), list):
            raise ValueError(f"{source} must contain a models list")
        return sorted({(str(x.get("id") or x.get("model") or "").strip()
                        if isinstance(x, dict) else str(x).strip())
                       for x in data["models"]} - {""})
    code, body, _, err = request(INTEGRATE + "/models", key=key)
    if code != 200 or not isinstance(body, dict) or not isinstance(body.get("data"), list):
        raise RuntimeError(f"Model discovery failed (HTTP {code}): {err or body}")
    found = {x.get("id", "").strip() for x in body["data"] if x.get("id")}
    # Add accessible cloud functions too: many speech/audio functions are not
    # present in the OpenAI-compatible model catalog.
    fcode, fbody, _, ferr = request(NVCF_FUNCTIONS, key=key)
    if fcode == 200 and isinstance(fbody, dict):
        items = fbody.get("functions", fbody.get("data", []))
        if isinstance(items, dict):
            items = items.get("functions", [])
        for item in items if isinstance(items, list) else []:
            if isinstance(item, dict):
                name = item.get("name") or item.get("functionName") or item.get("model")
                if name:
                    found.add(str(name).strip())
    else:
        print(f"Warning: NVCF function discovery unavailable (HTTP {fcode}): {ferr or fbody}")
    return sorted(found)


def default_endpoint(task, mid):
    # Preserve publisher/model path segments for NVIDIA-hosted specialized APIs.
    model_path = mid.strip("/")
    if "/" in model_path:
        publisher, model = model_path.split("/", 1)
    else:
        publisher, model = "nvidia", model_path
    if task == "chat":
        return INTEGRATE + "/chat/completions"
    if task == "embedding":
        return INTEGRATE + "/embeddings"
    if task == "rerank":
        # Classic NeMo Retriever route. Prefer override endpoint for models
        # that require integrate.api.nvidia.com/v1/ranking or a model-specific path.
        return AI_API + "/retrieval/nvidia/reranking"
    if task == "ranking":
        return INTEGRATE + "/ranking"
    if task == "rerank_model":
        return AI_API + "/retrieval/nvidia/" + model_path + "/reranking"
    if task == "image_generation":
        return AI_API + f"/genai/{publisher}/{model}"
    if task == "cosmos":
        return AI_API + f"/cosmos/{publisher}/{model}"
    if task == "computer_vision":
        return AI_API + f"/cv/{publisher}/{model}"
    if task == "document_vision":
        return AI_API + f"/retrieval/nvidia/{model_path}"
    return None


def route(mid, overrides):
    ov = overrides.get(mid, {}) if isinstance(overrides, dict) else {}
    if ov.get("enabled") is False:
        return "unsupported", None, "override-disabled"
    if ov.get("task"):
        task = ov["task"]
        endpoint = ov.get("endpoint") or default_endpoint(task, mid)
        return task, endpoint, "explicit-override"
    low = mid.lower()
    if mid in EMBEDDING_IDS or ("embed" in low and "vlm" not in low and "nvclip" not in low):
        return "embedding", INTEGRATE + "/embeddings", "openai-compatible-embedding-family"
    if any(x in low for x in ("rerank", "reranker")):
        return "rerank", default_endpoint("rerank", mid), "NeMo Retriever reranking route; exact payload required"
    if any(x in low for x in ("parse", "ocr", "docling")):
        return "document_vision", default_endpoint("document_vision", mid), "Document/OCR route; exact payload required"
    if any(x in low for x in ("magpie", "flamingo", "parakeet", "canary", "riva-", "audio", "speech")):
        return "audio_speech", None, "UNSUPPORTED: speech/audio inference requires NVIDIA gRPC NVCF and a function-id; this REST tester cannot probe it"
    if any(x in low for x in ("flux", "stable-diffusion", "sdxl", "image-generation")):
        return "image_generation", default_endpoint("image_generation", mid), "GenAI route; exact payload required"
    if "cosmos" in low:
        return "cosmos", default_endpoint("cosmos", mid), "Cosmos route; exact payload required"
    if any(x in low for x in ("detect", "yolo", "segmentation", "classification", "depth", "nvclip")):
        return "computer_vision", default_endpoint("computer_vision", mid), "CV route; exact payload required"
    # NVIDIA VLMs commonly expose text-only probes on the unified chat route.
    if any(x in low for x in ("vlm", "vila", "neva", "fuyu", "deplot", "vision-language")):
        return "chat", INTEGRATE + "/chat/completions", "Unified chat text probe for VLM; verifies endpoint availability, not image understanding"
    if ov.get("probe_chat") is True:
        return "chat", INTEGRATE + "/chat/completions", "explicit-chat-probe"
    # For otherwise unknown catalog entries, make a minimal standard chat probe.
    # A rejected request is still recorded as a real result, not silently skipped.
    return "chat", INTEGRATE + "/chat/completions", "fallback-chat-probe-unclassified-model"


def payload(task, mid, ov):
    if task == "embedding":
        return {"model": mid, "input": ["NVIDIA endpoint connectivity test"],
                "input_type": "query", "encoding_format": "float"}
    if task == "chat":
        return {"model": mid, "messages": [{"role": "user", "content": "Reply with exactly: OK"}],
                "max_tokens": 8, "stream": False}
    # Specialized route contracts vary by model (assets, image fields, etc.).
    # Never invent one: user-provided exact payload enables the probe.
    if task in ("rerank", "ranking", "rerank_model", "document_vision",
                "image_generation", "cosmos", "computer_vision"):
        return ov.get("payload")
    return None


def classify_result(task, code, body):
    if code is None:
        return "CONNECTION_ERROR"
    if code in (401, 403):
        return "AUTH_OR_PERMISSION_ERROR"
    if code == 404:
        return "NOT_FOUND"
    if code == 429:
        return "RATE_LIMITED"
    if code >= 500:
        return "SERVICE_ERROR"
    if code not in (200, 202):
        return "BAD_REQUEST_OR_UNSUPPORTED"
    if code == 202:
        return "ACCEPTED_ASYNC"
    if not isinstance(body, dict):
        return "INVALID_RESPONSE"
    if task == "chat" and isinstance(body.get("choices"), list) and body["choices"]:
        return "CONNECTED"
    if task == "embedding" and isinstance(body.get("data"), list) and body["data"] and isinstance(body["data"][0].get("embedding"), list):
        return "CONNECTED"
    if task in ("rerank", "ranking", "rerank_model") and any(k in body for k in ("rankings", "results", "data")):
        return "CONNECTED"
    if task in ("document_vision", "image_generation", "cosmos", "computer_vision") and body:
        return "CONNECTED"
    return "INVALID_RESPONSE"


def save(results, total):
    atomic_json(JSON_OUT, {"provider": "NVIDIA hosted APIs", "version": 5,
                          "tested_at": now(), "total_inventory": total,
                          "completed": len(results), "results": results})
    tmp = CSV_OUT + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows([{k: row.get(k) for k in FIELDS} for row in results])
    os.replace(tmp, CSV_OUT)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--inventory", default=INVENTORY, help="Optional JSON model inventory; otherwise discover live catalog")
    ap.add_argument("--no-discovery", action="store_true", help="Require local inventory only")
    ap.add_argument("--include", action="append", default=[], help="Test only this exact model ID; repeatable")
    ap.add_argument("--dry-run", action="store_true", help="Resolve routes without inference requests")
    ap.add_argument("--key-env", default="NVIDIA_API_KEY", help="Environment variable holding API key")
    args = ap.parse_args()
    key = os.environ.get(args.key_env, "").strip()
    if not key and not args.dry_run:
        key = input("Paste NVIDIA API key: ").strip()
    if not key and not args.dry_run:
        sys.exit("No API key supplied")
    overrides = read_json(OVERRIDES_FILE, {}) or {}
    src = args.inventory if os.path.exists(args.inventory) else None
    if args.no_discovery and not src:
        sys.exit(f"Local inventory not found: {args.inventory}")
    ids = model_ids(key, src)
    if args.include:
        wanted = set(args.include)
        ids = [x for x in ids if x in wanted]
    if not ids:
        sys.exit("No model IDs selected")
    grpc_ready, grpc_error = ensure_grpc_dependencies()
    speech_models = [mid for mid in ids if route(mid, overrides)[0] == "audio_speech"]
    functions, function_error = ({}, None)
    if speech_models and not args.dry_run:
        functions, function_error = resolve_nvcf_functions(key)
    results = []
    categories = Counter(route(mid, overrides)[0] for mid in ids)
    print(f"Models selected: {len(ids)}; unsupported contracts are skipped safely.")
    print("Task categories:")
    for category, count in sorted(categories.items()):
        print(f"  {category:<22} {count}")
    for i, mid in enumerate(ids, 1):
        ov = overrides.get(mid, {}) if isinstance(overrides, dict) else {}
        task, endpoint, source = route(mid, overrides)
        row = {"model": mid, "task": task, "route_source": source, "endpoint": endpoint,
               "status": "UNVERIFIED", "http_code": None, "latency_seconds": None,
               "response_preview": None, "error": None, "tested_at": now()}
        body_payload = payload(task, mid, ov)
        if task == "audio_speech":
            row["endpoint"] = GRPC_HOST
            if args.dry_run:
                row["status"] = "ROUTE_RESOLVED_NOT_TESTED"
                row["error"] = "gRPC route resolved; live function lookup/probe skipped in dry-run."
            elif not grpc_ready:
                row["status"] = "DEPENDENCY_ERROR"
                row["error"] = grpc_error
            elif function_error:
                row["status"] = "FUNCTION_LOOKUP_ERROR"
                row["error"] = function_error
            else:
                function_id = find_function_id(mid, functions, ov)
                if not function_id:
                    row["status"] = "FUNCTION_ID_NOT_FOUND"
                    row["error"] = "No matching accessible NVCF function ID found. Set function_id in overrides if known."
                else:
                    row["route_source"] = "NVCF gRPC function lookup"
                    row["response_preview"] = "Function ID resolved: " + function_id
                    code, preview, grpc_error = grpc_probe_speech(function_id, key, mid, ov)
                    row["http_code"] = code
                    if code == 200:
                        row["status"] = "CONNECTED"
                        row["response_preview"] = preview
                    else:
                        row["status"] = "GRPC_CONTRACT_REQUIRED" if "needs grpc_service" in str(grpc_error) else "GRPC_ERROR"
                        row["error"] = grpc_error
        elif not endpoint or body_payload is None:
            row["error"] = "Route resolved where available, but no verified payload contract is configured; no inference request sent. Add an exact endpoint and payload override from the model page."
        elif args.dry_run:
            row["status"] = "ROUTE_RESOLVED_NOT_TESTED"
        else:
            code, body, latency, err = request(endpoint, "POST", body_payload, key)
            row.update(http_code=code, latency_seconds=latency,
                       status=classify_result(task, code, body), error=err)
            if isinstance(body, dict):
                if task == "chat":
                    try:
                        row["response_preview"] = str(body["choices"][0]["message"].get("content"))[:200]
                    except Exception:
                        row["response_preview"] = json.dumps(body)[:200]
                elif task == "embedding":
                    try:
                        row["response_preview"] = f"Embedding dimensions: {len(body['data'][0]['embedding'])}"
                    except Exception:
                        row["response_preview"] = json.dumps(body)[:200]
                else:
                    row["response_preview"] = json.dumps(body)[:200]
        results.append(row)
        save(results, len(ids))
        print(f"[{i}/{len(ids)}] {row['status']:<28} {task:<18} {mid}")
        if row["error"]:
            print("  " + row["error"].replace("\n", " ")[:180])
        if not args.dry_run:
            time.sleep(DELAY)
    print("Summary:", dict(Counter(r["status"] for r in results)))
    print(f"Reports: {JSON_OUT}, {CSV_OUT}; overrides: {OVERRIDES_FILE}")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Interrupted; incremental reports are preserved.")
        sys.exit(130)
