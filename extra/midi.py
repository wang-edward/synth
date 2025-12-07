def note_to_midi(s: str) -> int:
    s = s.lower().strip()
    letter = s[0]
    octave = int(s[-1])
    acc = s[1:-1]

    base = {'c':0,'d':2,'e':4,'f':5,'g':7,'a':9,'b':11}[letter]
    flat = acc.count('b') + acc.count('f')
    sharp = acc.count('#')

    semitone = (base - flat + sharp) % 12
    return (octave + 1) * 12 + semitone

notes = [
"bf3",
"ef2",
"bf4",
"ef3",
"df3",
"bf3",
"ef2",
"df4",
"ef3",
"bf3",
"df4",
"bf4",
"bf4",
"ef3",
"ef3",
"bf3",

"cf3",
"ef3",
"cf4",
"cf3",
"gf3",
"cf4",
"cf3",
"gf4",
"cf4",
"cf4",
"gf4",
"cf4",
"cf4",
"cf3",
"ef3",
"cf3",

"cf3",
"ef3",
"cf4",
"cf3",
"ef3",
"cf3",
"af3",
"ef4",
"cf4",
"cf3",
"ef4",
"cf4",
"cf4",
"af3",
"df3",
"cf3",

"bf3",
"df3",
"bf4",
"bf3",
"df3",
"bf3",
"bf3",
"df4",
"df3",
"bf3",
"df4",
"bf4",
"bf4",
"bf3",
"gf3",
"bf3",
]

print("const pat = [_]seq.Step{")

for x in notes:
    print(f"\t.{{ .Note = {note_to_midi(x)} }}, // {x}")

print("};")

    # // const pat = [_]seq.Step{
    # //     // .Rest,
    # //     .{ .Note = 60 }, // C4
    # //     .{ .Note = 64 }, //
    # //     .{ .Note = 67 }, // E4
    # //     .{ .Note = 71 }, //
    # //     .{ .Note = 72 }, // C5
    # //     .{ .Note = 71 }, //
    # //     .{ .Note = 67 }, // E4
    # //     .{ .Note = 64 }, //
    # // };

