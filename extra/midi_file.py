# python3 midi_file.py fur_elise.mid > fur_elise.zig
import mido
import argparse

parser = argparse.ArgumentParser(description='Convert MIDI file to Zig note format')
parser.add_argument('midi_file', help='Input MIDI file')
args = parser.parse_args()

mid = mido.MidiFile(args.midi_file)
tempo = 120.0
ticks_per_beat = mid.ticks_per_beat
notes = []
active = {}

for track in mid.tracks:
    tick = 0
    for msg in track:
        tick += msg.time
        if msg.type == 'set_tempo':
            tempo = 60_000_000 / msg.tempo
        elif msg.type == 'note_on' and msg.velocity > 0:
            active[msg.note] = tick
        elif msg.type in ('note_off', 'note_on'):
            if msg.note in active:
                notes.append((active.pop(msg.note) / ticks_per_beat, tick / ticks_per_beat, msg.note))

print(f"const tempo: f32 = {tempo};\n\nconst notes = [_]midi.Note{{")
for start, end, note in sorted(notes):
    print(f"    .{{ .start = midi.beatsToSamples({start:.4f}, tempo, &context), .end = midi.beatsToSamples({end:.4f}, tempo, &context), .note = {note} }},")
print("};")
