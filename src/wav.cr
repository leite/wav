require "math"

# a simple WAV file reader, writer and basic audio processor.
#
# ## usage
#
# ```
# require "wav"
#
# # Reading and writing
# wav = Wav.read("input.wav")
# wav.write("output.wav")
#
# # Building from scratch
# sine = Wav.build { |w| w.sine 440, 2.0 }
# square = Wav.build { |w| w.square 220, 1.0, 0.8 }
#
# # Mixing tracks
# mix = sine.mix square
#
# # Applying effects
# mix.delay(0.3, feedback: 0.5)
#    .chorus(depth: 0.003, lfo_rate: 2.0, mix: 0.3)
#    .low_pass(2_000)
#    .normalize(0.95)
#    .fade_in(0.1)
#    .fade_out(0.5)
#
# # Generating noise and silence
# Wav.build { |w| w.noise(2.0, 0.2).silence(0.5).saw 440, 1.0 }
#
# # Trimming and resampling
# wav.trim(1.0, 3.5).resample(22_050.0).to_mono
#
# # Multi‑channel composition with cursor and channel targeting
# track = Wav.build do |w|
#   w.left.sine 440, 1.0              # left channel, first second
#   w.at(1.0).right.square 880, 1.0   # right channel, second second
#   w.all.forward                     # move to end
#   w.triangle 220, 2.0, 0.5          # both channels
# end
# track.write "track.wav"
#
# # Custom waveform generation
# wav = Wav.build do |w|
#   w.generate(2.0, 0.8) { |t| Math.cos 2 * Math::PI * 330 * t }
# end
#
# # Information
# puts wav   # => #<Wav r=44100 ch=2 b=16 t=2.0s>
# ```
class Wav
  alias LE = IO::ByteFormat::LittleEndian

  RIFF = "RIFF"
  WAVE = "WAVE"
  DATA = "data"
  FMT  = "fmt "

  getter rate : Float64, channels : Int32, bits : Int32, samples : Array(Float64)

  # create a new Wav instance
  #
  # accepts *rate* or samples per second (default: 44_100.0), *channels* number of channels
  # (default: 1), *bits* bit depth, 8 or 16 (default: 16), other exceptional options are:
  # *samples* initial sample array (default: empty array of Float64), *cursor* internal cursor
  # position (default: 0) and *target* optional channel target for generation
  # (default: nil, meaning all channels)
  #
  # raises exception if parameters are invalid.
  def initialize (
    @rate     = 44_100.0,
    @channels = 1,
    @bits     = 16,
    @samples  = [] of Float64,
    @cursor   = 0,
    @target   = nil.as(Int32?)
  )
    raise "invalid params" unless @rate > 0 && @channels > 0 && (@bits == 8 || @bits == 16)
  end

  # reads a WAV file from the given *path*, raises exception on invalid WAV or non-existent file
  def self.read (path : String) : Wav
    raise "file does not exist" unless File.exists? path

    File.open(path, "rb") { |f| read f }
  end

  # reads a WAV file from any *io*, IO must be at start and it must be valid WAV, raises otherwise
  def self.read (io : IO) : Wav
    assert io, RIFF, skip: 4
    assert io, WAVE

    fmt, data = nil, nil
    until (fmt && data) || !(id = io.read_string(4))
      sz    = read io, UInt32
      fmt   = io.pos if id == FMT
      data  = {sz, io.pos} if id == DATA

      io.skip sz
    end

    raise "missing chunks" unless fmt && data

    io.pos = fmt
    raise "unsupported format" unless read(io, UInt16) == 1

    channels  = read(io, UInt16).to_i32
    rate      = read(io, UInt32, skip: 6).to_f64
    bits      = read(io, UInt16).to_i32
    io.pos    = data[1]

    new rate, channels, bits, parse_samples(io, data[0], channels, bits)
  end

  # writes the current audio data to a file at the given *path*
  def write (path : String) : self
    File.open(path, "wb") { |f| write f }
  end

  # writes the current audio data to any *io*
  def write (io : IO) : self
    write_header io
    write_data io

    self
  end

  # converts multi‑channel audio to mono by averaging the channels, returns a new Wav instance
  def to_mono : Wav
    return self if @channels == 1

    mono = Array(Float64).new @samples.size // @channels
    @samples.each_slice(@channels) { |s| mono << s.sum / @channels }
    self.class.new @rate, 1, @bits, mono
  end

  # resamples the audio using linear interpolation with *new_rate*, returns a new Wav instance
  def resample (new_rate : Float64) : Wav
    return self if @rate == new_rate

    ratio     = @rate / new_rate
    frames    = @samples.size // @channels
    n_frames  = 0...(frames / ratio).ceil.to_i
    res       = Array(Float64).new n_frames.size * @channels

    @channels.times do |ch|
      n_frames.each do |i|
        pos   =   i * ratio
        idx   =   pos.to_i
        off1  =   idx * @channels + ch
        off2  =   (idx + 1) * @channels + ch
        s1    =   @samples[off1]? || 0.0
        s2    =   @samples[off2]? || s1
        res   <<  s1 + (pos - idx) * (s2 - s1)
      end
    end

    self.class.new(
      new_rate,
      @channels,
      @bits,
      @channels == 1 ? res : n_frames.flat_map do |i|
        (0...@channels).map { |ch| res[ch * n_frames.size + i] }
      end
    )
  end

  # scales the audio to the peak absolute amplitude of *target*,
  # *target* should be between 0 and 1 (default: 0.95)
  def normalize (target = 0.95) : self
    max = @samples.max_of?(&.abs) || 0.0
    return self if max <= 0

    factor = target / max
    @samples.map! { |s| (s * factor).clamp -1.0, 1.0 }

    self
  end

  # mixes the samples of another `Wav`, *other* into the current one (additive),
  # the two must have identical sample rates and channel counts otherwise raises exception
  def mix (other : Wav) : self
    raise "format mismatch" unless @rate == other.rate && @channels == other.channels

    {@samples.size, other.samples.size}.min.times do |i|
      @samples[i] = (@samples[i] + other.samples[i]).clamp -1.0, 1.0
    end

    self
  end

  # keeps only the portion between *start* and *finish*, values are in seconds
  def trim (start : Float64, finish : Float64) : self
    starts    = ((start * @rate).to_i * @channels).clamp 0, @samples.size
    finishes  = ((finish * @rate).to_i * @channels).clamp starts, @samples.size
    @samples  = @samples[starts...finishes]

    self
  end

  # applies a linear fade of *duration* in seconds. if *head* is true, fades in at the start,
  # if *tail* is true fades out at the end. defaults to fade in
  def fade (duration : Float64, head = false, tail = false) : self
    head = true if !head && !tail
    len  = ((duration > 0 ? duration : 0) * @rate * @channels).to_i.clamp 0, @samples.size

    len.times { |i| @samples[i] *= i.to_f / len } if head
    len.times { |i| @samples[@samples.size - len + i] *= 1.0 - (i.to_f / len) } if tail

    self
  end

  # shorthand for `#fade` with head fade
  def fade_in (duration : Float64) : self
    fade duration
  end

  # shorthand for `#fade` with tail fade
  def fade_out (duration : Float64) : self
    fade duration, false, true
  end

  # adds an echo / delay effect. *time* is delay in seconds,
  # *feedback* controls the decay of repeats (default 0.4)
  def delay (time : Float64, feedback = 0.4) : self
    d = (time * @rate * @channels).to_i
    return self if d <= 0

    @samples.each_with_index do |s, i|
      @samples[i] = (s + @samples[i-d] * feedback).clamp(-1.0, 1.0) if i >= d
    end

    self
  end

  # applies a simple first-order low-pass filter with *cutoff* frequency in Hz
  def low_pass (cutoff : Float64) : self
    return self if @samples.empty?

    dt    = 1.0 / @rate
    rc    = 1.0 / (2 * Math::PI * cutoff)
    alpha = dt / (rc + dt)
    prev  = Array.new(@channels) { |ch| @samples[ch]? || 0.0 }

    @samples.map_with_index! do |s, i|
      ch = i % @channels
      prev[ch] += alpha * (s - prev[ch])
    end

    self
  end

  # applies a chorus effect, *depth* is modulation depth in seconds (default 0.002),
  # *lfo_rate* is modulation rate in Hz (default 1.5), *mix* is the wet/dry balance
  # (0 = dry only, 1 = wet only, default 0.5).
  def chorus (depth = 0.002, lfo_rate = 1.5, mix = 0.5) : self
    delay = (depth * @rate).to_i
    buf   = Array(Float64).new delay * 2 + 1, 0.0
    w_idx = 0

    @samples.map! do |s|
      buf[w_idx % buf.size] =   s
      mod                   =   Math.sin(2 * Math::PI * lfo_rate * (w_idx / @rate)) * delay
      r_idx                 =   ((w_idx - delay - mod.to_i) % buf.size + buf.size) % buf.size
      val                   =   s * (1 - mix) + buf[r_idx] * mix
      w_idx                 +=  1

      val.clamp -1.0, 1.0
    end

    self
  end

  # appends custom samples generated by block, given *duration* in seconds, scaled by *amplitude*,
  # block receives time in seconds and should return a sample value between -1.0 and 1.0
  def generate (duration : Float64, amplitude = 1.0, &) : self
    frames  = (duration * @rate).to_i
    missing = (@cursor + (frames * @channels)) - @samples.size

    @samples.concat [0.0] * missing if missing > 0

    frames.times do |i|
      val = yield(i.to_f64 / @rate) * amplitude

      @channels.times do |ch|
        if (@cursor += 1) && (@target || ch) == ch
          @samples[@cursor - 1] = (val + @samples[@cursor - 1]).clamp -1.0, 1.0
        end
      end
    end

    self
  end

  # appends a sine wave of *frequency* in Hz for *duration* in seconds, scaled by *amplitude*
  def sine (frequency, duration, amplitude = 1.0) : self
    generate(duration, amplitude) { |t| Math.sin(2 * Math::PI * frequency * t) }
  end

  # appends a square wave of *frequency* in Hz for *duration* in seconds, scaled by *amplitude*
  def square (frequency, duration, amplitude = 1.0) : self
    generate(duration, amplitude) { |t| Math.sin(2 * Math::PI * frequency * t) >= 0 ? 1.0 : -1.0 }
  end

  # appends a sawtooth wave of *frequency* in Hz for *duration* in seconds, scaled by *amplitude*
  def sawtooth (frequency, duration, amplitude = 1.0) : self
    generate(duration, amplitude) { |t| 2.0 * (t * frequency - (t * frequency).floor) - 1.0 }
  end

  # shorthand for `#sawtooth`
  def saw (frequency, duration, amplitude = 1.0) : self
    sawtooth frequency, duration, amplitude
  end

  # appends a triangle wave of *frequency* in Hz for *duration* in seconds, scaled by *amplitude*
  def triangle (frequency, duration, amplitude = 1.0) : self
    generate(duration, amplitude) do |t|
      2.0 * (2.0 * (t * frequency - (t * frequency + 0.5).floor)).abs - 1.0
    end
  end

  # appends white noise for *duration* in seconds, scaled by *amplitude*
  def noise (duration, amplitude = 1.0) : self
    generate(duration, amplitude) { Random.rand * 2.0 - 1.0 }
  end

  # adds silence for *duration* in seconds by appending zero samples
  def silence (duration) : self
    @samples.concat [0.0] * (duration * @rate * @channels).to_i

    self
  end

  # moves the internal cursor to the sample corresponding to *time* in seconds
  def at (time : Float64) : self
    cursor (time * @rate * @channels).to_i
  end

  # moves the internal cursor back to the start of the audio
  def rewind : self
    cursor 0
  end

  # moves the internal cursor forward by *time* in seconds, if *time* not set moves to the end
  def forward (time : Float64 = 0.0) : self
    cursor time == 0 ? @samples.size : @cursor + (time * @rate * @channels).to_i
  end

  # targets the left channel for generation when stereo, otherwise targets the only channel
  def left : self
    channel 0
  end

  # targets the right channel for generation when stereo
  def right : self
    channel 1
  end

  # resets the channel target to all channels
  def all : self
    channel
  end

  # sets channel target to a specific index (0 based)
  def channel (@target = nil) : self
    raise "invalid channel" unless (0...@channels) === (@target || 0)
    self
  end

  # creates a new Wav instance and yields it to the block for building.
  #
  # accepts *rate* or samples per second (default: 44_100.0), *channels* number of channels
  # (default: 1), *bits* bit depth, 8 or 16 (default: 16)
  def self.build (rate = 44_100.0, channels = 1, bits = 16, &) : Wav
    inst = new rate, channels, bits
    yield inst
    inst
  end

  # returns a human‑readable summary, e.g. `#<Wav r=44100 ch=2 b=16 t=1.5s>`
  def to_s (io : IO) : Nil
    io << "#<Wav r=#{@rate.to_i} ch=#{@channels} b=#{@bits} "
    io << "t=#{(@samples.size/@channels/@rate).round(2)}s>"
  end

  # sets the cursor to an absolute sample index
  private def cursor (@cursor = 0) : self
    self
  end

  # asserts that the next bytes in *io* are equal to *expected* and optionally *skip* some bytes
  private def self.assert (io : IO, expected : String, skip = 0)
    id = io.read_string expected.bytesize
    raise "expected #{expected} got #{id}" unless id == expected

    io.skip skip
  end

  # reads a value of *type* from *io* in little‑endian format, optionally *skip* some bytes
  private def self.read (io : IO, type : T.class, skip = 0) : T forall T
    val = io.read_bytes type, LE
    io.skip skip

    val
  end

  # parses sample data from *io* according to chunk size *sz*, channels *ch*, and *bits* depth
  private def self.parse_samples (io, sz, ch, bits) : Array(Float64)
    cnt = sz // (bits // 8)
    smp = Array(Float64).new cnt.to_i

    if bits == 16
      (cnt // ch).to_i.times do
        ch.times { smp << io.read_bytes(Int16, LE).to_f64 / 32_768.0 }
      end
    else
      cnt.to_i.times do
        smp << (io.read_byte.not_nil!.to_f64 - 128.0) / 127.0
      end
    end

    smp
  end

  # writes the WAV header to *io*
  private def write_header (io : IO) : Nil
    bps = @bits // 8
    sz  = @samples.size * bps

    io.write        RIFF.to_slice
    io.write_bytes  (36 + sz).to_u32, LE
    io.write        WAVE.to_slice

    io.write        FMT.to_slice
    io.write_bytes  16_u32, LE
    io.write_bytes  1_u16, LE
    io.write_bytes  @channels.to_u16, LE
    io.write_bytes  @rate.to_u32, LE
    io.write_bytes  (@rate * @channels * bps).to_u32, LE
    io.write_bytes  (@channels * bps).to_u16, LE
    io.write_bytes  @bits.to_u16, LE

    io.write        DATA.to_slice
    io.write_bytes  sz.to_u32, LE
  end

  # writes the sample data to *io*, converting Float64 to 8‑bit or 16‑bit integers
  private def write_data (io : IO) : Nil
    sc, off = @bits == 8 ? {127.0, 128.0} : {32_767.0, 0.0}

    @samples.each do |s|
      v = (s.clamp(-1.0, 1.0) * sc + off).round
      @bits == 16 ? io.write_bytes(v.to_i16, LE) : io.write_byte(v.to_u8)
    end
  end
end
