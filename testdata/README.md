Drop reference voice clips here. This directory is bind-mounted into every
engine container at `/testdata`, so a clip saved as `testdata/ref.wav` is
reachable from inside as `/testdata/ref.wav`:

    docker compose --profile chatterbox exec chatterbox \
      python tools/speak.py "Hello there." \
        --server http://localhost:7500 \
        --ref-audio /testdata/ref.wav \
        --output-file /testdata/out.wav

Generated audio written back here shows up on the host immediately.

Most engines want a clean 3-10 s clip of speech (not music). Chatterbox uses
only the first 10 s, IndexTTS only the first 15 s.
