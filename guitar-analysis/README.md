# guitar-analysis

Pipeline for the guitar part of https://youtu.be/m8wBqPCqWjU, 16:33–19:30.

```sh
uv venv -p 3.11 .venv && . .venv/bin/activate
uv pip install -r requirements.txt     # also needs ffmpeg on PATH
python analyze.py --url https://youtu.be/m8wBqPCqWjU --start 16:33 --end 19:30
```

Writes `clip.wav`, `guitar_stem.wav`, `guitar.mid`, `chords.csv`, `notes.csv`, `summary.md` here.
Scratch files (full download, all demucs stems) go to `.work/`.

Other entry points: `--input file.wav` skips the download, `--no-separate` treats the input as an already isolated stem.

Tools: demucs `htdemucs_6s` (falls back to the `other` stem if `guitar` is weak), librosa (tempo, tuning offset, chroma key),
madmom (deep-chroma chord recognition, downbeats/meter), basic-pitch (notes, MIDI). Chordino was not used: its plugin host
was unreachable from the build environment, and madmom covers the same major/minor vocabulary.
