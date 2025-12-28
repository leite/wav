# wav

[![wav](https://github.com/leite/wav/actions/workflows/crystal.yml/badge.svg)](https://github.com/leite/wav/actions/workflows/crystal.yml)

a tiny library for reading, writing and synthesizing WAV audio files.

## installation

add this to your `shard.yml`

```yaml
dependencies:
  wav:
    github: leite/wav
    version: ~> 0.1.0
```

## usage

### systhesis

create audio from scratch using `Wav.build` block.

```crystal
require "wav"

wav = Wav.build(44100.0, 2) do |w|
  w.sine! 440.0, 1.0             # a4 sine, 1 sec
  w.sawtooth! 110.0, 0.5         # a2 saw, .5 sec
  w.noise! 0.1, 0.5              # white noise
  w.generate!(1.0, 0.8) do |t|   # fm
    mod = Math.sin(2 * Math::PI * 6.0 * t) * 10.0
    Math.sin 2 * Math::PI * (440.0 + mod) * t
  end
end
```

### processing & dsp

chainable effects.

```crystal
lead = Wav.read "lead.wav"
beat = Wav.read "drums.wav"

lead.mix!(beat)
    .trim!(0.0, 5.0)
    .low_pass!(1200.0)
    .delay!(0.3, 0.4)
    .chorus!(depth: 0.003, rate: 1.2)
    .fade!(2.0, head: true, tail: true)
    .normalize!(0.98)
    .to_mono
```

### io

you can read/write to files, memory or sockets.

```crystal
mem = IO::Memory.new
wav.write mem

mem.rewind
loaded = Wav.read mem
```

## reference

### code
  - `Wav.read io : IO | String` parses WAV files.
  - `wav.write io: IO | String` exports valie 8-bit or 16 bit PCM WAV.

### generators
  - `sine! freq, dur, amp`
  - `square! freq, dur, amp`
  - `sawtooth! freq, dur, amp`
  - `triangle! freq, dur, amp`
  - `noise! dur, amp`
  - `silence! dur`

### modifiers
  - `mix! other_wav`
  - `fade! dur, head : Bool, tail : Bool`
  - `trim! start, end`
  - `resample new_rate`
  - `to_mono`
