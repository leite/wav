require "math"

class Wav
  alias LE = IO::ByteFormat::LittleEndian

  RIFF = "RIFF"
  WAVE = "WAVE"
  DATA = "data"
  FMT  = "fmt "

  getter rate : Float64, channels : Int32, bits : Int32, samples : Array(Float64)

  def initialize (@rate = 44_100.0, @channels = 1, @bits = 16, @samples = [] of Float64)
    raise "invalid params" unless @rate > 0 && @channels > 0 && (@bits == 8 || @bits == 16)
  end

  def self.read (path : String)
    raise "file does not exist" unless File.exists? path

    File.open(path, "rb") { |f| read f }
  end

  def self.read (io : IO)
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

  def write (path : String)
    File.open(path, "wb") { |f| write f }
  end

  def write (io : IO)
    write_header io
    write_data io
    self
  end

  def to_mono
    return self if @channels == 1
    mono = Array(Float64).new @samples.size // @channels
    @samples.each_slice(@channels) { |s| mono << s.sum / @channels }
    self.class.new @rate, 1, @bits, mono
  end

  def resample (new_rate : Float64)
    return self if @rate == new_rate
    ratio = @rate / new_rate
    size  = (@samples.size / ratio).ceil.to_i
    res   = Array(Float64).new size

    (0...size).each do |i|
      pos =   i * ratio
      idx =   pos.to_i
      s1  =   @samples[idx]? || 0.0
      s2  =   @samples[idx+1]? || s1
      res <<  s1 + (pos - idx) * (s2 - s1)
    end

    self.class.new new_rate, @channels, @bits, res
  end

  def normalize! (target = 0.95)
    max = @samples.max_of?(&.abs) || 0.0
    return self if max <= 0
    factor = target / max
    @samples.map! { |s| (s * factor).clamp -1.0, 1.0 }
    self
  end

  def mix! (other : self)
    raise "format mismatch" unless @rate == other.rate && @channels == other.channels
    {@samples.size, other.samples.size}.min.times do |i|
      @samples[i] = (@samples[i] + other.samples[i]).clamp -1.0, 1.0
    end
    self
  end

  def trim! (s : Float64, e : Float64)
    start     = (s * @rate * @channels).to_i.clamp 0, @samples.size
    finish    = (e * @rate * @channels).to_i.clamp start, @samples.size
    @samples  = @samples[start...finish]
    self
  end

  def fade! (dur : Float64, head = false, tail = false)
    head = true if !head && !tail
    len  = (dur * @rate * @channels).to_i.clamp 0, @samples.size

    len.times { |i| @samples[i] *= i.to_f / len } if head
    len.times { |i| @samples[@samples.size - len + i] *= 1.0 - (i.to_f / len) } if tail

    self
  end

  def delay! (time : Float64, feedback = 0.4)
    d = (time * @rate * @channels).to_i
    @samples.each_with_index do |s, i|
      @samples[i] = (s + @samples[i-d] * feedback).clamp(-1.0, 1.0) if i >= d
    end
    self
  end

  def low_pass! (cutoff : Float64)
    return self if @samples.empty?

    dt    = 1.0 / @rate
    rc    = 1.0 / (2 * Math::PI * cutoff)
    alpha = dt / (rc + dt)
    prev  = @samples.first

    @samples.map! { |s| prev += alpha * (s - prev) }

    self
  end

  def chorus! (depth = 0.002, rate = 1.5, mix = 0.5)
    delay = (depth * @rate).to_i
    buf   = Array(Float64).new delay * 2 + 1, 0.0
    w_idx = 0

    @samples.map! do |s|
      buf[w_idx % buf.size] =   s
      mod                   =   Math.sin(2 * Math::PI * rate * (w_idx / @rate)) * delay
      r_idx                 =   (w_idx - delay - mod.to_i) % buf.size
      val                   =   s * (1 - mix) + buf[r_idx] * mix
      w_idx                 +=  1

      val.clamp -1.0, 1.0
    end
    self
  end

  def generate! (dur : Float64, amp = 1.0, &)
    (dur * @rate).to_i.times do |i|
      val = (yield(i.to_f64 / @rate) * amp).clamp -1.0, 1.0
      @channels.times { @samples << val }
    end
    self
  end

  def sine! (f, d, a = 1.0)
    generate!(d, a) { |t| Math.sin(2 * Math::PI * f * t) }
  end

  def square! (f, d, a = 1.0)
    generate!(d, a) { |t| Math.sin(2 * Math::PI * f * t) >= 0 ? 1.0 : -1.0 }
  end

  def sawtooth! (f, d, a = 1.0)
    generate!(d, a) { |t| 2.0 * (t * f - (t * f).floor) - 1.0 }
  end

  def triangle! (f, d, a = 1.0)
    generate!(d, a) { |t| 2.0 * (2.0 * (t * f - (t * f + 0.5).floor)).abs - 1.0 }
  end

  def noise! (d, a = 1.0)
    generate!(d, a) { Random.rand * 2.0 - 1.0 }
  end

  def silence! (d)
    @samples.concat [0.0] * (d * @rate * @channels).to_i
    self
  end

  def self.build (rate = 44_100.0, channels = 1, bits = 16, &)
    inst = new rate, channels, bits
    yield inst
    inst
  end

  def to_s (io)
    io << "#<Wav r=#{@rate.to_i} ch=#{@channels} b=#{@bits} t=#{(@samples.size/@channels/@rate).round(2)}s>"
  end

  private def self.assert (io : IO, expected : String, skip = 0)
    id = io.read_string expected.bytesize
    raise "expected #{expected} got #{id}" unless id == expected
    io.skip skip
  end

  private def self.read (io : IO, type : T.class, skip = 0) forall T
    val = io.read_bytes type, LE
    io.skip skip
    val
  end

  private def self.parse_samples (io, sz, ch, bits)
    cnt = sz // (bits // 8)
    smp = Array(Float64).new cnt.to_i

    if bits == 16
      (cnt // ch).to_i.times do
        ch.times { smp << io.read_bytes(Int16, LE).to_f64 / 32768.0 }
      end
    else
      cnt.to_i.times do
        smp << (io.read_byte.not_nil!.to_f64 - 128.0) / 127.0
      end
    end
    smp
  end

  private def write_header (io)
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

  private def write_data (io)
    sc, off = @bits == 8 ? {127.0, 128.0} : {32767.0, 0.0}

    @samples.each do |s|
      v = (s.clamp(-1.0, 1.0) * sc + off).round
      @bits == 16 ? io.write_bytes(v.to_i16, LE) : io.write_byte(v.to_u8)
    end
  end
end

