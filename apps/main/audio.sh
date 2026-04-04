#!/bin/bash
filename=$1
text=$2
cd src-tauri
curl --location 'https://rishi-worker.faridmato90.workers.dev/api/audio/speech' \
--header 'Content-Type: application/json' --output test_data/${filename}.mpg \
--data '{
        "model": "tts-1",
        "voice": "alloy",
        "input": "'"${text}"'",
        "response_format": "mp3",
        "speed": 1.0
}'
ffmpeg -i test_data/${filename}.mpg test_data/${filename}.wav -y
rm test_data/${filename}.mpg