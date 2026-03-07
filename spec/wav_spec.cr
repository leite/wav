#
# make: crystal spec
#

require "spec"
require "../src/wav"

def subject (rate = 10.0, channels = 1, bits = 16, dur = 1.0, amp = 1.0, &)
  Wav.build(rate, channels, bits) { |w| w.generate(dur, amp) { |t| yield t } }
end

def subject (rate = 10.0, channels = 1, bits = 16, dur = 1.0)
  Wav.build(rate, channels, bits) { |w| w.silence dur }
end

def roundtrip (wav)
  io = IO::Memory.new
  wav.write io
  io.rewind
  Wav.read io
end


describe Wav do
  describe "synthesis" do
    it "generates silent audio" do
      wav = subject dur: 1.0
      wav.samples.size.should eq(10)
      wav.samples.all? { |s| s == 0.0 }.should be_true
    end

    it "generates a sine wave" do
      wav = Wav.build(4.0, 1) { |w| w.sine 1.0, 1.0 }
      wav.samples[0].should eq(0.0)
      wav.samples[1].should be_close(1.0, 0.001)
      wav.samples[2].should be_close(0.0, 0.001)
    end

    it "generates a square wave" do
      wav = Wav.build(4.0, 1) { |w| w.square 1.0, 1.0 }
      wav.samples.should eq [1.0, 1.0, 1.0, -1.0]
    end

    it "generates a sawtooth wave" do
      wav = Wav.build(4.0, 1) { |w| w.sawtooth 1.0, 1.0 }
      wav.samples.should eq [-1.0, -0.5, 0.0, 0.5]
    end

    it "generates a sawtooth via saw alias" do
      wav = Wav.build(4.0, 1) { |w| w.saw 1.0, 1.0 }
      wav.samples.should eq [-1.0, -0.5, 0.0, 0.5]
    end

    it "generates a triangle wave" do
      wav = Wav.build(4.0, 1) { |w| w.triangle 1.0, 1.0 }
      wav.samples.should eq [-1.0, 0.0, 1.0, 0.0]
    end

    it "generates noise in range" do
      wav = Wav.build(100.0, 1) { |w| w.noise 1.0 }
      wav.samples.size.should eq(100)
      wav.samples.any? { |s| s != 0.0 }.should be_true
      wav.samples.all? { |s| s >= -1.0 && s <= 1.0 }.should be_true
    end

    it "clamps values at boundaries" do
      wav = subject(rate: 100.0, dur: 0.1, amp: 5.0) { 1.0 }
      wav.samples.max.should eq(1.0)
    end
  end

  describe "IO" do
    it "round-trips 16-bit mono via Memory" do
      original = Wav.build(44_100.0, 1) { |w| w.sawtooth 440.0, 0.1, 0.8 }
      loaded   = roundtrip original

      loaded.rate.should          eq(original.rate)
      loaded.channels.should      eq(original.channels)
      loaded.bits.should          eq(16)
      loaded.samples.size.should  eq(original.samples.size)
      loaded.samples.first.should be_close(original.samples.first, 0.001)
    end

    it "round-trips 8-bit mono via Memory" do
      original = Wav.build(44_100.0, 1, 8) { |w| w.sine 440.0, 0.1 }
      loaded   = roundtrip original

      loaded.bits.should          eq(8)
      loaded.samples.size.should  eq(original.samples.size)
      loaded.samples.first.should be_close(original.samples.first, 0.02)
    end

    it "round-trips 16-bit stereo via Memory" do
      original = Wav.build(44_100.0, 2) { |w| w.sine 440.0, 0.1 }
      loaded   = roundtrip original

      loaded.channels.should      eq(2)
      loaded.samples.size.should  eq(original.samples.size)
    end

    it "round-trips to file" do
      path     = "spec_test_roundtrip.wav"
      original = Wav.build(44_100.0, 1) { |w| w.sine 440.0, 0.1 }
      original.write path

      loaded = Wav.read path
      loaded.rate.should          eq(original.rate)
      loaded.samples.size.should  eq(original.samples.size)
    ensure
      File.delete(path) if path && File.exists? path
    end

    it "raises on empty io" do
      expect_raises(IO::EOFError) { Wav.read IO::Memory.new }
    end

    it "raises on non-existent file" do
      expect_raises(Exception, "file does not exist") do
        Wav.read "/tmp/does_not_exist_#{Random.rand(999_999)}.wav"
      end
    end
  end

  describe "DSP effects" do
    it "mixes two tracks" do
      t1, t2 = subject { 0.3 }, subject { 0.2 }

      t1.mix t2
      t1.samples.first.should be_close(0.5, 0.001)
    end

    it "clamps when mixing loud tracks" do
      t1, t2 = subject { 0.8 }, subject { 0.8 }

      t1.mix t2
      t1.samples.first.should eq(1.0)
    end

    it "mixes tracks of different lengths" do
      t1, t2 = subject(dur: 1.0) { 0.3 }, subject(dur: 0.5) { 0.2 }

      t1.mix t2
      t1.samples.size.should  eq(10)
      t1.samples.first.should be_close(0.5, 0.001)
      t1.samples.last.should  be_close(0.3, 0.001)
    end

    it "raises on rate mismatch when mixing" do
      t1, t2 = subject(rate: 10.0), subject(rate: 20.0)

      expect_raises(Exception, "format mismatch") { t1.mix t2 }
    end

    it "raises on channel mismatch when mixing" do
      t1, t2 = subject(channels: 1), subject(channels: 2)

      expect_raises(Exception, "format mismatch") { t1.mix t2 }
    end

    it "resamples mono" do
      original  = Wav.build(100.0, 1) { |w| w.sine 1.0, 1.0 }
      resampled = original.resample 50.0

      resampled.rate.should         eq(50.0)
      resampled.samples.size.should eq(50)
    end

    it "resamples stereo preserving channels" do
      stereo    = Wav.build(100.0, 2) { |w| w.sine 1.0, 1.0 }
      resampled = stereo.resample 50.0

      resampled.rate.should         eq(50.0)
      resampled.channels.should     eq(2)
      resampled.samples.size.should eq(100)
    end

    it "returns self when resampling to same rate" do
      wav = subject
      wav.resample(10.0).should be(wav)
    end

    it "trims audio" do
      wav = subject(rate: 10.0, dur: 10.0).trim 1.0, 3.0
      wav.samples.size.should eq(20)
    end

    it "converts stereo to mono" do
      stereo = subject channels: 2
      mono   = stereo.to_mono

      mono.channels.should      eq(1)
      mono.samples.size.should  eq(stereo.samples.size // 2)
    end

    it "returns self when already mono" do
      mono = subject channels: 1
      mono.to_mono.should be(mono)
    end

    it "averages channels when converting to mono" do
      stereo = Wav.build(10.0, 2) do |w|
        w.left.generate(1.0) { 0.8 }.right.rewind.generate(1.0) { 0.2 }.all
      end

      stereo.to_mono.samples.first.should be_close(0.5, 0.001)
    end

    it "fades in" do
      wav = subject { 1.0 }.fade 0.5, head: true

      wav.samples[0].should eq(0.0)
      wav.samples[2].should be_close(0.4, 0.1)
      wav.samples[5].should eq(1.0)
    end

    it "fades out" do
      wav = subject { 1.0 }.fade 0.5, tail: true

      wav.samples[0].should   eq(1.0)
      wav.samples.last.should be < 0.2
    end

    it "defaults to head fade when neither specified" do
      wav = subject { 1.0 }.fade 0.5

      wav.samples[0].should eq(0.0)
      wav.samples[5].should eq(1.0)
    end

    it "fade_in is shorthand for head fade" do
      wav = subject { 1.0 }.fade_in 0.5

      wav.samples[0].should eq(0.0)
      wav.samples[5].should eq(1.0)
    end

    it "fade_out is shorthand for tail fade" do
      wav = subject { 1.0 }.fade_out 0.5

      wav.samples[0].should   eq(1.0)
      wav.samples.last.should be < 0.2
    end

    it "delays audio with feedback" do
      wav = Wav.build(10.0, 1) do |w|
        w.generate(0.1) { 1.0 }.silence 0.9
      end

      wav.delay 0.5, 0.5

      wav.samples[0].should eq(1.0)
      wav.samples[5].should be_close(0.5, 0.001)
    end

    it "returns self when delay is zero" do
      wav      = subject { 0.5 }
      original = wav.samples.dup

      wav.delay 0.0
      wav.samples.should eq(original)
    end

    it "returns self when delay is negative" do
      wav      = subject { 0.5 }
      original = wav.samples.dup

      wav.delay -1.0
      wav.samples.should eq(original)
    end

    it "normalizes to default target" do
      wav = subject { 0.5 }.normalize

      wav.samples.max.should be_close(0.95, 0.001)
    end

    it "normalizes to custom target" do
      wav = subject { 0.5 }.normalize 0.8

      wav.samples.max.should be_close(0.8, 0.001)
    end

    it "normalize is noop on silence" do
      wav = subject.normalize

      wav.samples.all? { |s| s == 0.0 }.should be_true
    end

    it "applies low pass filter" do
      wav      = Wav.build(1000.0, 1) { |w| w.noise 0.5 }
      original = wav.samples.dup

      wav.low_pass 100.0

      wav.samples.size.should eq(original.size)
      wav.samples.should_not  eq(original)
    end

    it "low pass is noop on empty samples" do
      wav = Wav.new
      wav.low_pass(100.0).should be(wav)
    end

    it "applies chorus effect" do
      wav      = Wav.build 1000.0, 1 { |w| w.sine 10.0, 0.5 }
      original = wav.samples.dup

      wav.chorus depth: 0.002, lfo_rate: 1.5, mix: 0.5

      wav.samples.size.should eq(original.size)
      wav.samples.should_not  eq(original)
      wav.samples.all? { |s| s >= -1.0 && s <= 1.0 }.should be_true
    end
  end

  describe "cursor and channel selection" do
    it "positions cursor at specific time" do
      wav = subject channels: 2, dur: 1.0 { 0.0 }.at(0.5).generate(0.1) { 1.0 }

      wav.samples[10].should eq(1.0)
    end

    it "rewinds cursor to start" do
      wav = subject channels: 2 { 0.0 }.at(0.5).rewind.generate(0.1) { 0.3 }

      wav.samples[0].should eq(0.3)
    end

    it "moves cursor forward by time" do
      wav = subject channels: 2 { 0.0 }
      wav.rewind.forward(0.3).generate(0.1) { 0.4 }

      wav.samples[6].should eq(0.4)
    end

    it "forward with no args moves to end" do
      wav = subject { |t| t }.forward.generate(0.5) { 0.7 }

      wav.samples.size.should eq(15)
      wav.samples[10].should  eq(0.7)
    end

    it "writes to left channel only" do
      wav = Wav.build(10.0, 2) do |w|
        w.left.generate(1.0) { 0.9 }.all
      end

      wav.samples[0].should be_close(0.9, 0.001)
      wav.samples[1].should eq(0.0)
    end

    it "writes to right channel only" do
      wav = Wav.build(10.0, 2) do |w|
        w.right.generate(1.0) { 0.7 }.all
      end

      wav.samples[0].should eq(0.0)
      wav.samples[1].should be_close(0.7, 0.001)
    end

    it "writes to all channels after targeting" do
      wav = Wav.build(10.0, 2) do |w|
        w.left.all.generate(1.0) { 0.5 }
      end

      wav.samples[0].should be_close(0.5, 0.001)
      wav.samples[1].should be_close(0.5, 0.001)
    end
  end

  describe "validation" do
    it "raises on invalid rate" do
      expect_raises(Exception, "invalid params") { Wav.new rate: -1.0 }
      expect_raises(Exception, "invalid params") { Wav.new rate: 0.0 }
    end

    it "raises on invalid channels" do
      expect_raises(Exception, "invalid params") { Wav.new channels: 0 }
      expect_raises(Exception, "invalid params") { Wav.new channels: -1 }
    end

    it "raises on invalid bits" do
      expect_raises(Exception, "invalid params") { Wav.new bits: 24 }
      expect_raises(Exception, "invalid params") { Wav.new bits: 4 }
    end
  end

  describe "to_s" do
    it "formats mono output" do
      subject.to_s.should eq("#<Wav r=10 ch=1 b=16 t=1.0s>")
    end

    it "formats stereo output" do
      subject(rate: 44_100.0, channels: 2).to_s.should eq("#<Wav r=44100 ch=2 b=16 t=1.0s>")
    end
  end
end
