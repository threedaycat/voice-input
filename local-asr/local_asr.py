# 本地语音识别：Qwen3-ASR-1.7B（阿里开源，4-bit MLX 版），voice-input 的最后一道备用。
# 云端（阿里云百炼、Gemini）都连不上时才调用；平时不加载，不占内存。
#
# 用法：python local_asr.py <音频文件> [上下文文字]   结果文字打到 stdout
# 实测（M4 16GB，10 段共 235 秒录音）：每段约 1.7 秒，另加载模型 1~2 秒；
# 峰值内存约 2.5 GB，CPU 占用不到半个核心（主要跑在 GPU 上）。
# 准确度比云端 qwen3-asr-flash 差一截（10 段里约 5 处明显听错），所以只当备用。
#
# 环境：~/.local/share/voice-input/asr-venv（pip install mlx-qwen3-asr）
# 模型：~/.cache/huggingface/hub/models--moona3k--mlx-qwen3-asr-1.7b-4bit
import glob
import os
import sys

MODEL_GLOB = os.path.expanduser(
    "~/.cache/huggingface/hub/models--moona3k--mlx-qwen3-asr-1.7b-4bit/snapshots/*")


def main():
    audio = sys.argv[1]
    context = sys.argv[2] if len(sys.argv) > 2 else ""
    paths = glob.glob(MODEL_GLOB)
    if not paths:
        sys.exit("本地模型没下载")
    from mlx_qwen3_asr import transcribe
    # 传本地路径而不是仓库名：传仓库名时就算已经下载过，它也会先联网检查
    print(transcribe(audio, model=paths[0], context=context).text, end="")


if __name__ == "__main__":
    main()
