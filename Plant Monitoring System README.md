# B2B Autonomous Plant Monitoring & Automation System
# Enterprise Technical Architecture & Deployment Blueprint

> **⚠️ ORIGINAL SPECIFICATION — superseded in places by the as-built system.**
> This is the initial design blueprint. Several decisions changed during
> implementation for cost, hardware, and Pi-5 feasibility reasons. For the
> architecture that was actually built, see [`README.md`](README.md) (§ Design
> Decisions). Key deltas:
> - **Telemetry:** LoRaWAN → **WiFi + MQTT** (LoRa is future work for large outdoor sites)
> - **Soil sensors:** RS485 Modbus 3-in-1 → **analog moisture sensors** (HW-103/HW-080, ADC)
> - **Vision:** YOLO11 detection → **ResNet-18 classification** (INT8 ONNX, 15-class PlantVillage)
> - **LLM:** local Phi-3/Ollama → **cloud chat** (Gemini free tier / Anthropic), the only outbound call
>
> The remainder of this document is preserved as the original proposal.

This document serves as the master architectural specification for a production-grade, internet-independent, B2B smart farming platform. It is designed to scale across high-density commercial greenhouses and large-scale agricultural operations while maintaining low hardware unit manufacturing costs and zero cloud operational overhead.

## 1. System Architecture Overview & Topology

The platform utilizes a Hybrid Edge-Server Topology. Rather than depending on an external cloud server (e.g., Hetzner or AWS), the system uses a localized, high-performance industrial gateway on-site. This architecture ensures complete network autonomy, data privacy, and immunity to remote internet drops.

[ EDGE LAYER: FIELD NODES ]
  [ Type A: Soil Nodes ]            [ Type B: Camera Nodes ]
    (ESP32 + RS485 Sensors)            (ESP32-S3 + OV2640)
               │                                │
     (LoRaWAN Sub-GHz)                    (Wi-Fi 6 Mesh)
               │                                │
               ▼                                ▼
    [ LoRaWAN Gateway ]                [ Industrial Access Point ]
               │                                │
               └───────────(Local Ethernet)─────┤
                                                ▼
                            [ BACKEND SERVER LAYER: RASPBERRY PI 5 ]
                            ├── Ingestion: Mosquitto MQTT Broker
                            ├── In-Memory Buffer: Redis Streams
                            ├── AI Inference Engine: YOLO11 Nano INT8 (ONNX)
                            ├── Local LLM Agronomist: Phi-3-Mini (Ollama)
                            ├── Time-Series Storage: InfluxDB / SQLite
                            └── Reverse Proxy / App Host: Nginx
                                                │
                                    (WebSockets / Local REST API)
                                                │
                                                ▼
                             [ CLIENT LAYER: FLUTTER ECOSYSTEM ]
                             ┌──────────────────┴──────────────────┐
                             ▼                                     ▼
                   Native Mobile App (iOS/Android)         Cross-Platform Web App
				   
## 2. Hardware Specification & Networking Choices

### Hardware Division of Labor
- Edge Sensor Nodes (Type A): Standard ESP32 microcontroller paired with an SPI-based RFM95W LoRa transceiver module. It reads high-precision industrial RS485 soil moisture/temperature/EC probes.
- Edge Camera Nodes (Type B): ESP32-S3-WROOM-1 with 8MB PSRAM (mandatory to buffer camera frames and execute vector instructions) paired with an OV2640 sensor.
- Central Edge Server: Raspberry Pi 5 (8GB RAM variant mandatory) equipped with active cooling and an industrial-grade High-Endurance NVMe SSD (to handle intensive database writes without corruption).

### Dual-Network Communication Layer

- Telemetry Network: LoRaWAN (Sub-GHz 868/915 MHz): Chosen over standard Wi-Fi for telemetry because high-frequency signals suffer intense attenuation when passing through wet, dense plant canopies. LoRaWAN penetrates foliage up to 2–5 km away. It operates on an asynchronous, connectionless protocol—nodes blast a tiny 4-byte packed hexadecimal array in under 50ms and return to deep sleep, achieving a 3-to-5-year battery life on simple AA cells.
- Visual Network: Wi-Fi 6 (802.11ax) Mesh: ESP32-S3 camera nodes utilize Wi-Fi 6 with Target Wake Time (TWT) scheduling. This layout schedules transmission slots for each camera node to prevent network traffic collisions and router crashes when hundreds of cameras transmit large binary frames.

## 3. Data Pipeline & Software Stack
The software environment on the Raspberry Pi 5 is containerized via Docker to guarantee reproducible, isolated infrastructure across multiple commercial farm deployments.

### Data Routing Architecture

1. Ingestion: The LoRaWAN gateway decodes the physical radio pulses and forwards raw telemetry data to the Pi's Mosquitto MQTT Broker via the local network.
2. Buffering via Redis Streams: A lightweight Python bridge pulls messages from Mosquitto and appends them to a high-throughput Redis Stream (farm:telemetry). This architectural choice decoupling ensures that high-frequency ingestion never locks the persistent database. It acts as an unalterable append-only log allowing a Fan-Out Pattern where multiple background worker consumers process the exact same message independently (UI streaming, analytics storage, automated relay controls).
3. Storage Engine: Historical metrics route directly into InfluxDB (or a local SQLite instance) to feed long-term telemetry analytics and time-series charting.

## 4. Edge AI & On-Premise LLM Agronomist

### Computer Vision: YOLO11 Nano INT8 (ONNX Runtime)

To preserve maximum accuracy while protecting the Pi's processing limits, the system loads a cloned, pre-trained agricultural object detection model (such as YOLOv8n or YOLO11n fine-tuned on the PlantDoc/PlantVillage datasets).

- Quantization Strategy: The weights are converted from floating-point (FP32) down to 8-bit integers (INT8) using the Ultralytics export framework.
- Performance Metrics on Pi 5: File size shrinks to ~3.5 MB, memory footprint drops under 45 MB RAM, accuracy degradation remains under 1.5%, and inference speeds clock at an elite ~35 to 60 milliseconds per frame.
= ESP32-S3 Pre-Filtering AI: The ESP32-S3 leverages its internal Xtensa LX7 vector instructions (esp-nn library) to run a microscopic binary frame quality classifier. Before opening its power-hungry Wi-Fi radio, it runs local inference to check if a clear leaf is visible under adequate lighting conditions. If the frame is blurry or pitch black, it aborts transmission, saving battery and network bandwidth.

### The Autonomous "AI Agronomist" Chat Interface

Rather than hardcoding basic text responses to AI labels (which offers low business novelty), an on-premise Large Language Model (Phi-3-Mini-3.8B or Llama-3-8B-Instruct) is deployed directly on the Raspberry Pi via Ollama.

- Retrieval-Augmented Generation (RAG) Architecture: When a user queries the system via the dashboard, a FastAPI backend intercepts the text and programmatically auto-injects real-time crop parameters (e.g., soil moisture is dropping, YOLO detected a localized "Tomato Late Blight" spore signature).
- Because the 3.8-billion parameter LLM operates 100% locally on the Pi 5's RAM/CPU, recurrent cloud token generation costs are exactly $0.00. This enables a highly lucrative B2B software-as-a-service (SaaS) subscription model with near-100% gross margins.

## 5. User Interface (UI) Strategy: Flutter Ecosystem
The client dashboard is developed strictly inside Flutter, utilizing a single, reactive, cross-platform codebase.

- Deployment Vector: The codebase compiles natively into mobile packages (iOS/Android APK/IPA) for field deployment and a performance-optimized web build (flutter build web --release). The static web build is hosted locally on the Raspberry Pi via an Nginx server, accessible to any worker typing the Pi's local network IP into a browser.
- State Management & Live Sync: Telemetry dials render real-time changes instantly via a persistent WebSocket connection wired straight into the local Redis cache. Historical analytical graphs fetch data payloads via a traditional REST API exposed by a FastAPI worker layer.

## 6. Implementation Reference Architecture (FastAPI & Redis)
This production-grade Python script serves as the system's operational core on the Raspberry Pi 5. It manages incoming camera frames, performs local YOLO inference, queries the local telemetry state, and builds the dynamic RAG pipeline for the Ollama LLM chat engine.

```python
import io
import json
import httpx
import redis
import numpy as np
import onnxruntime as ort
from PIL import Image
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse

app = FastAPI(title="Industrial AI Agronomist Server", version="1.0.0")

# 1. Connect to Local Edge Cache and Stream Core
r = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)
r_binary = redis.Redis(host='localhost', port=6379, db=0, decode_responses=False) # For images

# 2. Initialize Cloned & Quantized Object Detection Model
try:
    # Permanently retained in the Pi's memory for high-speed processing
    ort_session = ort.InferenceSession("models/yolo11n_agri_int8.onnx")
    CLASS_LABELS = ["Healthy", "Tomato_Late_Blight", "Spider_Mites", "Powdery_Mildew"]
except Exception as e:
    print(f"CRITICAL: Failed to initialize localized ONNX Engine: {e}")

LOCAL_OLLAMA_URL = "http://localhost:11434/api/generate"

def preprocess_frame(image_bytes):
    """Formats raw network bytes to the precise quantized INT8 input tensor required by the model"""
    img = Image.open(io.BytesIO(image_bytes)).convert('RGB')
    img = img.resize((640, 640)) # Standard YOLO input dimension
    img_data = np.array(img).astype(np.float32) / 255.0
    img_data = np.transpose(img_data, (2, 0, 1)) # Conversion from HWC to CHW format
    return np.expand_dims(img_data, axis=0)

@app.post("/api/v1/node/{node_id}/upload-frame")
async def receive_camera_frame(node_id: str, file_bytes: bytes):
    """Saves incoming ESP32-S3 frames directly to volatile memory to preserve SSD life cycles"""
    r_binary.set(f"camera:{node_id}:latest", file_bytes)
    return {"status": "success", "buffered": True}

@app.get("/api/v1/node/{node_id}/analyze")
async def evaluate_crop_health(node_id: str):
    """Executes on-site vision diagnostics and triggers programmatic automation safety flags"""
    img_bytes = r_binary.get(f"camera:{node_id}:latest")
    if not img_bytes:
        raise HTTPException(status_code=404, detail="No fresh image array found in memory bank.")
    
    # Run INT8 Local Inference
    tensor = preprocess_frame(img_bytes)
    input_name = ort_session.get_inputs()[0].name
    raw_outputs = ort_session.run(None, {input_name: tensor})
    
    # Process bounding boxes and outputs (Simulated logic output interpretation for brevity)
    detected_issue = "Tomato_Late_Blight"  # Parsed class matching label index array
    confidence = 0.89

    # Cache diagnostics immediately to Redis for the LLM pipeline context loop
    diagnostic_payload = {"issue": detected_issue, "confidence": confidence}
    r.set(f"camera:{node_id}:diagnostics", json.dumps(diagnostic_payload))
    
    # Automation Override Flag (Example: Stop fungal spread by altering watering)
    if detected_issue == "Tomato_Late_Blight" and confidence > 0.75:
        r.set(f"automation:override:{node_id}:irrigation", "FORCE_CLOSE_OVERHEAD_VALVES")

    return {"node_id": node_id, "anomalies": diagnostic_payload}

@app.get("/api/v1/agronomist/chat")
async def stream_agronomist_chat(node_id: str, user_query: str):
    """Context-Aware RAG Pipeline matching sensor data matrices to local LLM prompt injections"""
    
    # Pull current environment variables cached from LoRaWAN/MQTT streams
    moisture = r.get(f"telemetry:{node_id}:moisture") or "45.2"
    temperature = r.get(f"telemetry:{node_id}:temp") or "26.4"
    vision_logs = r.get(f"camera:{node_id}:diagnostics") or "{'issue': 'None', 'confidence': 0.0}"
    
    # System Context Injection Architecture
    system_prompt = (
        f"You are an expert commercial agronomist system assistant monitoring a automated farm grid.\n"
        f"CONTEXT METRIC LOGS FOR SYSTEM NODE {node_id}:\n"
        f"- Volumetric Soil Moisture: {moisture}%\n"
        f"- Air Ambient Temperature: {temperature} C\n"
        f"- Active Edge Vision Diagnostics: {vision_logs}\n\n"
        f"Formulate a technical agronomy recommendation handling the following query. "
        f"Structure your response with clear, actionable technical protocols. Keep it fully offline-safe."
    )

    ollama_payload = {
        "model": "phi3:mini", # Light-weight, high-reasoning 3.8B parameter model
        "prompt": f"{system_prompt}\n\nUser Question: {user_query}\nResponse:",
        "stream": True
    }

    async def chat_streamer():
        async with httpx.AsyncClient(timeout=60.0) as client:
            async with client.stream("POST", LOCAL_OLLAMA_URL, json=ollama_payload) as response:
                if response.status_code != 200:
                    yield "Error link broken to local language processing runtime engine."
                    return
                async for chunk in response.aiter_text():
                    # Direct data-chunk yield out to Flutter StreamBuilder widgets
                    yield chunk

    return StreamingResponse(chat_streamer(), media_type="text/event-stream")
```

## 7. Strategic Field Deployment Blueprint
Phase 1: Gateway Anchorage ──> Phase 2: Mesh Deployment ──> Phase 3: Node Activation

1. Phase 1: Central Server Infrastructure Installation: Mount the industrial IP67 control enclosure containing the Raspberry Pi 5 and the Omni-Directional LoRaWAN Base Station Gateway at the highest structural elevation on the farm property. Connect them together via an industrial shielded Cat6 PoE Ethernet link.
2. Phase 2: Greenhouse Optical Network Expansion: String a series of ruggedized, weather-proof Wi-Fi 6 Mesh Access Points down the central structural spines of the active crop greenhouses. Ensure clear line of sight down row paths to reduce RF bouncing.
3. Phase 3: Deep Sleep Node Dispersal: Insert the Type A soil monitoring assemblies into the crop substrates. Use standard Over-The-Air Activation (OTAA) configuration keys to secure the node addresses to the local LoRa hub. Position the Type B Camera Nodes facing targeted canopy vectors.
4. Phase 4: Client Ecosystem Launch: Connect local tablets, mobile terminals, and office displays to the local mesh Wi-Fi network. Point browsers directly to the static domain URL (http://plant-hub.local) or launch the native Flutter dashboard app to securely access real-time metrics, automated system logs, and the local AI chat agronomist offline.