#
# make: crystal spec
#

require "spec"
require "../src/wav"

describe Wav do
  describe "synthesis" do
    it "generates silent audio" do
      wav = Wav.build(44100.0, 1) { |w| w.silence! 1.0 }
      wav.samples.size.should eq(44100)
      wav.samples.all? { |s| s == 0.0 }.should be_true
    end

    it "generates a sine wave" do
      wav = Wav.build(4.0, 1) { |w| w.sine! 1.0, 1.0 }
      wav.samples[0].should eq(0.0)
      wav.samples[1].should be_close(1.0, 0.001)
      wav.samples[2].should be_close(0.0, 0.001)
    end

    it "clamps values strictly between -1.0 and 1.0" do
      wav = Wav.build(100.0, 1) { |w| w.generate!(0.1, 5.0) { 1.0 } }
      wav.samples.max.should eq(1.0)
    end
  end

  describe "IO" do
    it "writes and reads back perfectly from Memory" do
      original = Wav.build(44100.0, 2) do |w|
        w.sawtooth! 440.0, 0.1, 0.8
      end

      io = IO::Memory.new
      original.write io

      io.rewind
      loaded = Wav.read io

      loaded.rate.should eq(original.rate)
      loaded.channels.should eq(original.channels)
      loaded.samples.size.should eq(original.samples.size)

      loaded.samples.first.should be_close(original.samples.first, 0.001)
    end

    it "handles empty io gracefully" do
      empty_io = IO::Memory.new
      expect_raises(IO::EOFError) do
        Wav.read empty_io
      end
    end
  end

  describe "DSP effects" do
    it "mixes two tracks correctly" do
      t1 = Wav.build(10.0, 1) { |w| w.generate!(1.0) { 0.3 } }
      t2 = Wav.build(10.0, 1) { |w| w.generate!(1.0) { 0.2 } }

      t1.mix! t2
      t1.samples.first.should be_close(0.5, 0.001)
    end

    it "resamples audio" do
      original = Wav.build(100.0, 1) { |w| w.sine! 1.0, 1.0 }

      resampled = original.resample 50.0

      resampled.rate.should eq(50.0)
      resampled.samples.size.should eq(50)
    end

    it "trims audio" do
      wav = Wav.build(10.0, 1) { |w| w.silence! 10.0 }
      wav.trim! 1.0, 3.0

      wav.samples.size.should eq(20)
    end

    it "converts to mono" do
      stereo = Wav.build(44100.0, 2) { |w| w.silence! 1.0 }
      stereo.samples.size.should eq(88200)

      mono = stereo.to_mono
      mono.channels.should eq(1)
      mono.samples.size.should eq(44100)
    end

    it "fades in" do
      wav = Wav.build(10.0, 1) { |w| w.generate!(1.0) { 1.0 } }
      wav.fade! 0.5, head: true

      wav.samples[0].should eq(0.0)
      wav.samples[2].should be_close(0.4, 0.1)
      wav.samples[5].should eq(1.0)
    end

    it "fades out" do
      wav = Wav.build(10.0, 1) { |w| w.generate!(1.0) { 1.0 } }
      wav.fade! 0.5, tail: true

      wav.samples[0].should eq(1.0)
      wav.samples.last.should be < 0.2
    end

    it "delays audio" do
      wav = Wav.build(10.0, 1) do |w|
        w.generate!(0.1) { 1.0 }
        w.silence! 0.9
      end

      wav.delay! 0.5, 0.5

      wav.samples[0].should eq(1.0)
      wav.samples[5].should be_close(0.5, 0.001)
    end

    it "normalizes audio" do
      wav = Wav.build(10.0, 1) { |w| w.generate!(1.0) { 0.5 } }
      wav.normalize! 1.0

      wav.samples.max.should eq(1.0)
    end
  end
end
