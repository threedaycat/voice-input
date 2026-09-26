#!/usr/bin/env bash
# 可选：装本机语音识别（Qwen3-ASR-1.7B，4-bit MLX 版），云端都连不上时的最后一道备用。
# 只支持 Apple Silicon。约占 1.7 GB 磁盘；平时不加载，调用时峰值内存约 2.5 GB。
# 国内网络慢的话：PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple HF_ENDPOINT=https://hf-mirror.com ./setup.sh
set -euo pipefail
VENV="$HOME/.local/share/voice-input/asr-venv"
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q mlx-qwen3-asr
"$VENV/bin/python" -c "from huggingface_hub import snapshot_download; print(snapshot_download('moona3k/mlx-qwen3-asr-1.7b-4bit'))"
echo "装好了。在面板 → 设置 → 模型里勾上 local-qwen3-asr-1.7b（默认已排在最后）。"
