#!/usr/bin/env python3
"""Guitar part analysis: download -> trim -> separate -> key/tempo -> chords -> notes -> summary.

Usage:
  python analyze.py --url https://youtu.be/m8wBqPCqWjU --start 16:33 --end 19:30
  python analyze.py --input clip.wav            # skip download/trim
  python analyze.py --input stem.wav --no-separate   # input is already a guitar stem
"""
import argparse
import csv
import os
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

import numpy as np
import librosa
import soundfile as sf

NOTE_NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
SR = 44100


def ts(t):
    t = max(t, 0.0)
    return f"{int(t // 60)}:{t % 60:05.2f}"


def parse_time(s):
    parts = [float(p) for p in s.split(":")]
    out = 0.0
    for p in parts:
        out = out * 60 + p
    return out


def run(cmd):
    print("+", " ".join(map(str, cmd)), flush=True)
    subprocess.run(cmd, check=True)


# ---------------------------------------------------------------- 1-2. audio

def download_and_trim(url, start, end, out_dir, work):
    work.mkdir(parents=True, exist_ok=True)
    tmpl = str(work / "source.%(ext)s")
    run([sys.executable, "-m", "yt_dlp", "-f", "bestaudio", "-o", tmpl, "--no-playlist", url])
    src = next(p for p in work.glob("source.*") if p.suffix != ".part")
    clip = out_dir / "clip.wav"
    run(["ffmpeg", "-y", "-loglevel", "error", "-ss", str(start), "-to", str(end), "-i", str(src),
         "-ar", str(SR), "-ac", "2", "-c:a", "pcm_s16le", str(clip)])
    return clip


# ---------------------------------------------------------------- 3. separation

def rms_db(path):
    y, _ = librosa.load(path, sr=22050, mono=True)
    return 20 * np.log10(np.sqrt(np.mean(y ** 2)) + 1e-12)


def separate(clip, out_dir, work):
    run([sys.executable, "-m", "demucs", "-n", "htdemucs_6s", "-o", str(work / "demucs"), str(clip)])
    stems = work / "demucs" / "htdemucs_6s" / clip.stem
    levels = {s: rms_db(stems / f"{s}.wav") for s in ["guitar", "other", "piano", "vocals", "bass", "drums"]}
    # "Weak" guitar stem: very quiet in absolute terms, or far below the "other" stem.
    weak = levels["guitar"] < -40 or levels["guitar"] < levels["other"] - 6
    chosen = "other" if weak else "guitar"
    dst = out_dir / "guitar_stem.wav"
    shutil.copy(stems / f"{chosen}.wav", dst)
    return dst, chosen, levels


# ---------------------------------------------------------------- 4. key / tempo / meter

# Krumhansl-Kessler profiles
KK_MAJ = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
KK_MIN = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


def detect_key(y, sr):
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr).mean(axis=1)
    scores = []
    for i in range(12):
        scores.append((np.corrcoef(chroma, np.roll(KK_MAJ, i))[0, 1], f"{NOTE_NAMES[i]} major"))
        scores.append((np.corrcoef(chroma, np.roll(KK_MIN, i))[0, 1], f"{NOTE_NAMES[i]} minor"))
    scores.sort(reverse=True)
    return scores[0][1], scores[0][0], scores[1][1], scores[1][0]


def chord_key(chords):
    """Key from chord durations: diatonic fit picks the relative major/minor pair, then
    tonic weight (time on I vs vi, plus the final chord) picks between them."""
    dur = Counter()
    for s, e, lab in chords:
        if lab != "N":
            dur[lab] += e - s
    total = sum(dur.values())
    if not total:
        return None, 0.0, None, 0.0
    best = None
    for i in range(12):
        diat = {NOTE_NAMES[i], NOTE_NAMES[(i + 5) % 12], NOTE_NAMES[(i + 7) % 12],
                NOTE_NAMES[(i + 2) % 12] + "m", NOTE_NAMES[(i + 4) % 12] + "m", NOTE_NAMES[(i + 9) % 12] + "m",
                NOTE_NAMES[(i + 4) % 12]}  # III -> V of relative minor (harmonic minor)
        fit = sum(d for c, d in dur.items() if c in diat) / total
        if best is None or fit > best[0]:
            best = (fit, i)
    fit, i = best
    major, minor = NOTE_NAMES[i], NOTE_NAMES[(i + 9) % 12] + "m"
    last = next((lab for _, _, lab in reversed(chords) if lab != "N"), None)
    first = next((lab for _, _, lab in chords if lab != "N"), None)
    m_score = dur[major] + (0.25 * total if last == major else 0) + (0.1 * total if first == major else 0)
    n_score = dur[minor] + (0.25 * total if last == minor else 0) + (0.1 * total if first == minor else 0)
    key = f"{major} major" if m_score >= n_score else f"{minor[:-1]} minor"
    return key, fit, f"{major} major / {minor[:-1]} minor", abs(m_score - n_score) / total


def detect_tempo_meter(path):
    y, sr = librosa.load(path, sr=22050, mono=True)
    tempo, beats = librosa.beat.beat_track(y=y, sr=sr)
    tempo = float(np.atleast_1d(tempo)[0])
    beat_times = librosa.frames_to_time(beats, sr=sr)
    ibi_cv = float(np.std(np.diff(beat_times)) / np.mean(np.diff(beat_times))) if len(beat_times) > 2 else 1.0

    downbeats, meter = None, None
    try:
        from madmom.features.downbeats import RNNDownBeatProcessor, DBNDownBeatTrackingProcessor
        act = RNNDownBeatProcessor()(str(path))
        db = DBNDownBeatTrackingProcessor(beats_per_bar=[3, 4], fps=100)(act)
        counts = db[:, 1].astype(int)
        meter = int(counts.max())
        downbeats = db[counts == 1, 0]
        madmom_tempo = 60.0 / np.median(np.diff(db[:, 0]))
    except Exception as e:  # pragma: no cover
        print("madmom downbeat tracking failed:", e)
        madmom_tempo = None
    return tempo, madmom_tempo, ibi_cv, meter, downbeats


# ---------------------------------------------------------------- 5. chords

def recognize_chords(path):
    from madmom.audio.chroma import DeepChromaProcessor
    from madmom.features.chords import DeepChromaChordRecognitionProcessor
    chroma = DeepChromaProcessor()(str(path))
    segs = DeepChromaChordRecognitionProcessor()(chroma)
    merged = []
    for start, end, label in segs:
        label = pretty_chord(label)
        if merged and merged[-1][2] == label:
            merged[-1][1] = end
        else:
            merged.append([float(start), float(end), label])
    return merged


def pretty_chord(label):
    if label == "N":
        return "N"
    root, qual = label.split(":")
    root = {"Db": "C#", "D#": "Eb", "Gb": "F#", "G#": "Ab", "A#": "Bb"}.get(root, root)
    return root + ("m" if qual == "min" else "")


def chords_per_bar(chords, downbeats, total):
    if downbeats is None or len(downbeats) < 2:
        return []
    edges = list(downbeats) + [total]
    bars = []
    for b0, b1 in zip(edges[:-1], edges[1:]):
        dur = Counter()
        for s, e, lab in chords:
            ov = min(e, b1) - max(s, b0)
            if ov > 0:
                dur[lab] += ov
        if not dur:
            bars.append((b0, "N"))
            continue
        (top, d1), *rest = dur.most_common()
        # Two chords sharing a bar roughly half and half -> show both.
        if rest and rest[0][1] > 0.35 * (b1 - b0):
            first = min((c for c in (top, rest[0][0])),
                        key=lambda c: min(s for s, e, l in chords if l == c and e > b0))
            second = rest[0][0] if first == top else top
            bars.append((b0, f"{first} {second}"))
        else:
            bars.append((b0, top))
    return bars


def group_sections(bars, phrase=4):
    """Cut bars into phrases, label identical phrases A/B/C..., collapse repeats."""
    phrases = [tuple(c for _, c in bars[i:i + phrase]) for i in range(0, len(bars), phrase)]
    starts = [bars[i][0] for i in range(0, len(bars), phrase)]
    tail = None
    if phrases and len(phrases[-1]) < phrase:
        tail = phrases.pop()
        starts.pop()
    labels, names = {}, []
    for p in phrases:
        if p not in labels:
            labels[p] = chr(ord("A") + len(labels))
        names.append(labels[p])
    runs = []
    for name, p, t in zip(names, phrases, starts):
        if runs and runs[-1][0] == name:
            runs[-1][2] += 1
        else:
            runs.append([name, p, 1, t])
    if tail:
        runs.append(["tail", tail, 1, bars[-len(tail)][0]])
    return labels, runs


# ---------------------------------------------------------------- 6. notes

def transcribe(stem, out_dir, min_dur=0.08, min_amp=0.3):
    from basic_pitch.inference import predict
    from basic_pitch import ICASSP_2022_MODEL_PATH
    import pretty_midi

    _, _, events = predict(str(stem), ICASSP_2022_MODEL_PATH,
                           onset_threshold=0.5, frame_threshold=0.3,
                           minimum_note_length=min_dur * 1000,
                           minimum_frequency=70, maximum_frequency=1400,
                           multiple_pitch_bends=False, melodia_trick=True)
    kept, dropped = [], 0
    for start, end, pitch, amp, bends in events:
        if end - start < min_dur or amp < min_amp:
            dropped += 1
            continue
        # bends are in 1/3-semitone bins; a note counts as bent when most of its frames sit >= 2/3 st away
        bend = float(np.mean(np.abs(bends) >= 2)) if bends else 0.0
        kept.append((float(start), float(end), int(pitch), float(amp), bend))
    kept.sort()

    pm = pretty_midi.PrettyMIDI()
    inst = pretty_midi.Instrument(program=25, name="Guitar")
    for s, e, p, a, _ in kept:
        inst.notes.append(pretty_midi.Note(velocity=int(40 + 87 * min(a, 1)), pitch=p, start=s, end=e))
    pm.instruments.append(inst)
    pm.write(str(out_dir / "guitar.mid"))

    with open(out_dir / "notes.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["time", "time_s", "pitch", "midi", "duration_s", "confidence", "bend_flag"])
        for s, e, p, a, b in kept:
            w.writerow([ts(s), f"{s:.3f}", midi_name(p), p, f"{e - s:.3f}", f"{a:.2f}",
                        "bend" if b >= 0.5 and e - s >= 0.15 else ""])
    return kept, dropped, len(events)


def midi_name(p):
    return f"{NOTE_NAMES[p % 12]}{p // 12 - 1}"


# ---------------------------------------------------------------- 7. tuning / capo / shapes

def infer_tuning(notes, cents_offset):
    # Short, quiet low notes are usually subharmonic errors or bass bleed; count only sustained, confident ones.
    pitches = np.array([p for s, e, p, a, _ in notes if e - s >= 0.3 and a >= 0.45])
    if len(pitches) == 0:
        return "unknown (no sustained notes)", None, []
    low = int(np.percentile(pitches, 1))
    lowest = int(pitches.min())
    n_below_e2 = int((pitches < 40).sum())
    if n_below_e2 < max(5, 0.02 * len(pitches)):
        n_below_e2 = min(n_below_e2, 4)  # too few to call: falls through to the flag below
    flags = []
    if abs(cents_offset) > 25:
        flags.append(f"global pitch is {cents_offset:+.0f} cents off A440: possible non-standard reference "
                     "or a sped-up/slowed-down upload; semitone names may be one step off")
    if n_below_e2 >= 5 and low <= 38:
        guess = "Drop D (D A D G B E) or D standard; several notes at or below D2"
    elif n_below_e2 >= 5 and low == 39:
        guess = "Half step down (Eb Ab Db Gb Bb Eb) or Drop Eb; repeated notes at Eb2"
    elif n_below_e2 >= 5:
        guess = f"Lower than standard: notes down to {midi_name(low)}"
    else:
        guess = "Standard (E A D G B E): no sustained notes below E2"
    if 0 < n_below_e2 < 5:
        flags.append(f"{n_below_e2} note(s) below E2 (lowest {midi_name(lowest)}); too few to call a lower "
                     "tuning, likely bass bleed or a pitch-tracking octave error")
    return guess, low, flags


OPEN_SHAPES = {  # string 6 -> 1, x = muted
    "C": "x32010", "D": "xx0232", "E": "022100", "G": "320003", "A": "x02220",
    "Am": "x02210", "Dm": "xx0231", "Em": "022000",
}
FRIENDLY = set(OPEN_SHAPES) | {"F", "Bm"}


def transpose(chord, n):
    if chord == "N":
        return chord
    minor = chord.endswith("m")
    root = chord[:-1] if minor else chord
    i = NOTE_NAMES.index(root)
    return NOTE_NAMES[(i + n) % 12] + ("m" if minor else "")


def best_capo(chord_names):
    names = [c for c in chord_names if c != "N"]
    if not names:
        return 0, {}
    best = None
    for capo in range(0, 8):
        shapes = {c: transpose(c, -capo) for c in names}
        score = sum(1 for c in names if shapes[c] in OPEN_SHAPES) * 2 + sum(1 for c in names if shapes[c] in FRIENDLY)
        score -= capo * 0.5  # prefer lower capo on ties
        if best is None or score > best[0]:
            best = (score, capo, shapes)
    return best[1], best[2]


def barre_shape(chord):
    minor = chord.endswith("m")
    root = NOTE_NAMES.index(chord[:-1] if minor else chord)
    e_fret = (root - 4) % 12 or 12   # root on low E
    a_fret = (root - 9) % 12 or 12   # root on A string
    if e_fret <= 9:
        f = e_fret
        pat = [f, f + 2, f + 2, f + (0 if minor else 1), f, f]
        pos = f"E-shape barre, fret {f}"
    else:
        f = a_fret
        pat = ["x", f, f + 2, f + 2, f + (1 if minor else 2), f]
        pos = f"A-shape barre, fret {f}"
    return "-".join(str(x) for x in pat), pos


def voicing(chord):
    if chord in OPEN_SHAPES:
        return "-".join(OPEN_SHAPES[chord]), "open"
    return barre_shape(chord)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url")
    ap.add_argument("--start", default="0")
    ap.add_argument("--end")
    ap.add_argument("--input", help="local audio (skips download/trim)")
    ap.add_argument("--no-separate", action="store_true", help="input is already the guitar stem")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent))
    ap.add_argument("--work", default=None, help="scratch dir for downloads and demucs output")
    a = ap.parse_args()

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    work = Path(a.work or out / ".work")
    start = parse_time(a.start)

    if a.input:
        clip = out / "clip.wav"
        run(["ffmpeg", "-y", "-loglevel", "error", "-i", a.input, "-ar", str(SR), "-ac", "2", str(clip)])
    else:
        clip = download_and_trim(a.url, start, parse_time(a.end), out, work)

    flags = []
    if a.no_separate:
        stem, chosen, levels = out / "guitar_stem.wav", "input", {}
        shutil.copy(clip, stem)
    else:
        stem, chosen, levels = separate(clip, out, work)
        if chosen == "other":
            flags.append(f"guitar stem was weak (guitar {levels['guitar']:.1f} dB vs other "
                         f"{levels['other']:.1f} dB); used 'other' stem, which may include keys/synths")
        elif levels["guitar"] < levels["other"] + 3:
            flags.append(f"guitar and 'other' stems have similar energy ({levels['guitar']:.1f} / "
                         f"{levels['other']:.1f} dB): busy mix, expect bleed in both directions")

    # 4. key/tempo: key from the stem (harmony), tempo/meter from the full mix (drums help)
    y_stem, sr = librosa.load(stem, sr=22050, mono=True)
    key, kconf, key2, kconf2 = detect_key(y_stem, sr)
    cents = float(librosa.estimate_tuning(y=y_stem, sr=sr) * 100)
    tempo, mm_tempo, ibi_cv, meter, downbeats = detect_tempo_meter(clip)
    total = librosa.get_duration(path=str(clip))
    if kconf - kconf2 < 0.05:
        flags.append(f"key is ambiguous: {key} (r={kconf:.2f}) vs {key2} (r={kconf2:.2f}); "
                     "relative major/minor confusions are common")
    if ibi_cv > 0.1:
        flags.append(f"beat spacing varies (CV {ibi_cv:.2f}): tempo changes, rubato, or unreliable beat tracking")
    if mm_tempo and abs(mm_tempo - tempo) > 5 and abs(mm_tempo - 2 * tempo) > 5 and abs(2 * mm_tempo - tempo) > 5:
        flags.append(f"tempo estimators disagree: librosa {tempo:.0f} BPM vs madmom {mm_tempo:.0f} BPM")

    # 5. chords
    chords = recognize_chords(stem)
    ckey, cfit, cpair, cmargin = chord_key(chords)
    key_chroma = (key, kconf)
    if ckey:
        if cfit < 0.8:
            flags.append(f"only {cfit:.0%} of chord time fits one diatonic key: modal mixture, borrowed chords, "
                         "or recognizer errors")
        if ckey != key:
            flags.append(f"chroma profile says {key}, chord content says {ckey}; the summary uses the chord-based key")
        if cmargin < 0.1:
            flags.append(f"tonic is ambiguous between {cpair}: same chords, the center depends on phrasing")
        key = ckey
    with open(out / "chords.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["time", "start_s", "end_s", "source_time", "chord"])
        for s, e, lab in chords:
            w.writerow([ts(s), f"{s:.2f}", f"{e:.2f}", ts(start + s), lab])
    short = sum(1 for s, e, l in chords if e - s < 0.5)
    none_frac = sum(e - s for s, e, l in chords if l == "N") / max(total, 1e-9)
    if chords and short / len(chords) > 0.3:
        flags.append(f"{short}/{len(chords)} chord segments are shorter than 0.5 s: fast changes, "
                     "passing tones, or recognizer jitter")
    if none_frac > 0.15:
        flags.append(f"{none_frac:.0%} of the clip has no chord detected (single-note lines, silence, or heavy effects)")
    flags.append("chord vocabulary is major/minor triads only: 7ths, sus, add9, power chords "
                 "and slash chords are reported as the nearest triad")

    bars = chords_per_bar(chords, downbeats, total)
    labels, runs = group_sections(bars, phrase=4) if bars else ({}, [])

    # 6. notes
    notes, dropped, raw = transcribe(stem, out)
    bends = sum(1 for s, e, _, _, b in notes if b >= 0.5 and e - s >= 0.15)
    if notes and bends / len(notes) > 0.05:
        flags.append(f"{bends} notes ({bends / len(notes):.0%}) carry pitch bends/vibrato; "
                     "bent notes may be named at the start or target pitch")
    if notes:
        dur = sum(e - s for s, e, *_ in notes)
        if dur / total > 3.0:
            flags.append(f"dense polyphony ({dur / total:.1f} sounding notes on average): strummed chords, "
                         "the note list is better read as voicings than a melody")

    # 7. tuning / capo / shapes
    tuning, low, tflags = infer_tuning(notes, cents)
    flags += tflags
    weight = Counter()
    for s, e, lab in chords:
        if lab != "N":
            weight[lab] += e - s
    main_chords = [c for c, d in weight.most_common(8) if d > 0.03 * total]
    capo, shapes = best_capo(main_chords)

    write_summary(out, a, start, total, key, key_chroma, cents, tempo, mm_tempo, meter,
                  chords, bars, labels, runs, notes, dropped, raw, tuning, low, capo, shapes,
                  main_chords, weight, chosen, levels, flags)
    print("\nDone. Outputs in", out)


def write_summary(out, a, start, total, key, key_chroma, cents, tempo, mm_tempo, meter,
                  chords, bars, labels, runs, notes, dropped, raw, tuning, low, capo, shapes,
                  main_chords, weight, chosen, levels, flags):
    L = []
    src = a.url or a.input
    L += ["# Guitar analysis", "",
          f"Source: {src}  ", f"Clip: {ts(start)} to {ts(start + total)} ({total:.1f} s). "
          "All times below are relative to the clip start.", ""]

    L += ["## Overview", "",
          "| | |", "|---|---|",
          f"| Key | **{key}** (from chord content; chroma profile: {key_chroma[0]}, r={key_chroma[1]:.2f}) |",
          f"| Tempo | **{tempo:.0f} BPM** (librosa)" + (f", {mm_tempo:.0f} BPM (madmom)" if mm_tempo else "") + " |",
          f"| Time signature | {f'{meter}/4' if meter else 'unknown'} (madmom downbeat tracker, choosing between 3 and 4) |",
          f"| Tuning reference | {cents:+.0f} cents from A440 |",
          f"| Stem used | {chosen}" + (f" (guitar {levels['guitar']:.1f} dB, other {levels['other']:.1f} dB)" if levels else "") + " |",
          ""]

    L += ["## Chord progression", ""]
    if runs:
        L += ["Bars come from detected downbeats; each bar shows its dominant chord "
              "(two names = chord change mid-bar). Phrases are 4 bars.", "", "Sections:", "", "```"]
        for p, name in labels.items():
            L.append(f"{name}: | " + " | ".join(p) + " |")
        L += ["```", "", "Form (order as played):", "", "```"]
        L.append("  ".join(f"{n}" + (f" x{c}" if c > 1 else "") + f" @{ts(t)}" for n, _, c, t in runs))
        if runs[-1][0] == "tail":
            L.append("tail: | " + " | ".join(runs[-1][1]) + " |  (incomplete last phrase)")
        L += ["```", ""]
    else:
        L += ["No downbeats detected; see the raw timeline below.", ""]
    L += ["Main chords by total time: " + ", ".join(f"{c} ({weight[c]:.0f}s)" for c in main_chords), "",
          "Raw timeline (merged): see `chords.csv`.", ""]

    L += ["## Tuning and capo", "",
          f"- Tuning: {tuning}.",
          f"- Lowest stable note (1st percentile): {midi_name(low) if low is not None else 'n/a'}.",
          f"- Capo: {'none needed' if capo == 0 else f'capo {capo}'} — this is a playability suggestion "
          "(fewest barre chords), not something audio can detect. A capo and a full-neck voicing sound almost the same.",
          ""]

    L += ["## Fretboard positions", "",
          "Strings low E to high E; x = muted, 0 = open."
          + (f" Shapes are relative to capo {capo}." if capo else ""), "",
          "| Chord (sounding) | Shape | Frets | Position |", "|---|---|---|---|"]
    for c in main_chords:
        sh = shapes.get(c, c)
        frets, pos = voicing(sh)
        L.append(f"| {c} | {sh} | `{frets}` | {pos} |")
    L += ["", "Alternative without capo: " + ", ".join(f"{c} `{voicing(c)[0]}` ({voicing(c)[1]})" for c in main_chords)
          if capo else "", ""]

    L += ["## Notes (basic-pitch)", "",
          f"- {len(notes)} notes kept out of {raw} detected; {dropped} dropped (shorter than 80 ms or confidence < 0.30).",
          "- `guitar.mid` and `notes.csv` hold the kept notes. `bend_flag` marks notes held at least 2/3 semitone off pitch for most of their length.",
          ""]
    if notes:
        pc = Counter(NOTE_NAMES[p % 12] for _, _, p, _, _ in notes)
        L.append("Most frequent pitch classes: " + ", ".join(f"{n} ({c})" for n, c in pc.most_common(7)))
        L.append("")

    L += ["## Low-confidence flags", ""] + [f"- {f}" for f in flags] + [""]
    L += ["## Files", "",
          "- `clip.wav` — trimmed audio, 44.1 kHz WAV",
          "- `guitar_stem.wav` — demucs htdemucs_6s stem",
          "- `guitar.mid` — basic-pitch transcription",
          "- `chords.csv` — merged chord timeline",
          "- `notes.csv` — filtered note list", ""]
    (out / "summary.md").write_text("\n".join(L))


if __name__ == "__main__":
    main()
