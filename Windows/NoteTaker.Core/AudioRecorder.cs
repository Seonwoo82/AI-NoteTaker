using System.Diagnostics;
using System.Buffers.Binary;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace NoteTaker.Core;

// One session owns all capture devices, buffers and the writer. A wall clock keeps
// system-audio silence on the timeline even when WASAPI emits no callbacks.
public sealed class AudioRecorder : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly List<WasapiCapture> captures = [];
    private readonly List<MMDevice> devices = [];
    private readonly List<BufferedWaveProvider> buffers = [];
    private readonly Stopwatch clock = new();
    private readonly CancellationTokenSource cancellation = new();
    private WaveFileWriter? writer;
    private Task? pump;
    private bool paused, stopping, started;
    private long writtenFrames;
    private double lastFlush;
    private float microphoneLevel, systemLevel;
    private long lastMicrophoneSample, lastSystemSample;
    public string? Failure { get; private set; }
    public double DurationSeconds { get { lock (gate) return clock.Elapsed.TotalSeconds; } }
    public bool IsPaused { get { lock (gate) return paused; } }
    public float MicrophoneLevel => Stopwatch.GetElapsedTime(Volatile.Read(ref lastMicrophoneSample)).TotalMilliseconds < 300 ? Volatile.Read(ref microphoneLevel) : 0;
    public float SystemLevel => Stopwatch.GetElapsedTime(Volatile.Read(ref lastSystemSample)).TotalMilliseconds < 300 ? Volatile.Read(ref systemLevel) : 0;

    public static IReadOnlyList<AudioDevice> GetDevices(DataFlow flow)
    {
        using var enumerator = new MMDeviceEnumerator();
        var result = new List<AudioDevice>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(flow, DeviceState.Active))
        {
            using (device) result.Add(new AudioDevice(device.ID, device.FriendlyName));
        }
        return result;
    }

    public async Task StartAsync(string path, RecordingMode mode, string? microphoneId, string? outputId)
    {
        if (started) throw new InvalidOperationException("이미 사용한 녹음 세션입니다.");
        started = true;
        if (mode == RecordingMode.Imported) throw new ArgumentException("녹음 모드를 선택해 주세요.");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        try
        {
            // Construct off the UI thread so WASAPI completion cannot wait on its dispatcher.
            await Task.Run(() =>
            {
                using var enumerator = new MMDeviceEnumerator();
                if (mode is RecordingMode.Microphone or RecordingMode.Mixed)
                    AddSource(microphoneId is null ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console) : enumerator.GetDevice(microphoneId), false);
                if (mode is RecordingMode.SystemAudio or RecordingMode.Mixed)
                    AddSource(outputId is null ? enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia) : enumerator.GetDevice(outputId), true);
                writer = new WaveFileWriter(path, AudioFiles.RecordingFormat);
                foreach (var capture in captures) capture.StartRecording();
                lock (gate) clock.Start();
            });
            pump = Task.Run(PumpAsync);
        }
        catch
        {
            await StopAsync();
            throw;
        }
    }

    private void AddSource(MMDevice device, bool loopback)
    {
        devices.Add(device);
        WasapiCapture capture = loopback ? new WasapiLoopbackCapture(device) : new WasapiCapture(device);
        captures.Add(capture);
        capture.WaveFormat = AudioFiles.RecordingFormat;
        var buffer = new BufferedWaveProvider(capture.WaveFormat)
        {
            BufferDuration = TimeSpan.FromSeconds(5), ReadFully = true, DiscardOnBufferOverflow = false
        };
        buffers.Add(buffer);
        capture.DataAvailable += (_, args) =>
        {
            lock (gate)
            {
                if (paused || stopping || Failure is not null) return;
                try
                {
                    buffer.AddSamples(args.Buffer, 0, args.BytesRecorded);
                    var peak = PcmMixer.Peak(args.Buffer.AsSpan(0, args.BytesRecorded));
                    if (loopback) { systemLevel = peak; Volatile.Write(ref lastSystemSample, Stopwatch.GetTimestamp()); }
                    else { microphoneLevel = peak; Volatile.Write(ref lastMicrophoneSample, Stopwatch.GetTimestamp()); }
                }
                catch (Exception) { Failure = "오디오 처리가 지연되어 녹음을 중단했습니다. 저장된 부분을 확인해 주세요."; }
            }
        };
        capture.RecordingStopped += (_, args) =>
        {
            lock (gate)
                if (!stopping) Failure = args.Exception is null ? "오디오 장치가 녹음을 중단했습니다." : "오디오 장치 연결 또는 권한에 문제가 생겼습니다. 장치를 확인해 주세요.";
        };
    }

    public void TogglePause()
    {
        lock (gate)
        {
            if (stopping || writer is null || Failure is not null) return;
            if (!paused) { clock.Stop(); WriteUntil(clock.Elapsed.TotalSeconds); }
            foreach (var buffer in buffers) buffer.ClearBuffer();
            paused = !paused;
            microphoneLevel = systemLevel = 0;
            if (!paused) clock.Start();
        }
    }

    private async Task PumpAsync()
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(20));
            while (await timer.WaitForNextTickAsync(cancellation.Token))
            {
                lock (gate)
                {
                    if (paused || stopping || Failure is not null) continue;
                    // Leave a 200 ms queue for the independent capture callbacks.
                    WriteUntil(Math.Max(0, clock.Elapsed.TotalSeconds - .2));
                    if (clock.Elapsed.TotalSeconds - lastFlush >= 1)
                    {
                        writer!.Flush(); // commits a readable WAV header for crash recovery
                        lastFlush = clock.Elapsed.TotalSeconds;
                        if (new DriveInfo(Path.GetPathRoot(writer.Filename)!).AvailableFreeSpace < 100 * 1024 * 1024)
                            Failure = "저장 공간이 부족하여 녹음을 중단했습니다.";
                    }
                    if (clock.Elapsed.TotalHours >= 4) Failure = "WAV 파일 크기를 보호하기 위해 4시간 녹음을 저장했습니다. 새 녹음을 시작해 주세요.";
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception) { lock (gate) Failure = "오디오 파일 저장에 실패했습니다. 저장 공간과 폴더 권한을 확인해 주세요."; }
    }

    private void WriteUntil(double seconds)
    {
        if (writer is null || buffers.Count == 0) return;
        long targetFrames = (long)(seconds * AudioFiles.SampleRate);
        var source = buffers.Select(_ => new byte[960 * 4]).ToArray();
        var mixed = new byte[960 * 4];
        while (writtenFrames < targetFrames)
        {
            int count = (int)Math.Min(960, targetFrames - writtenFrames) * 4;
            foreach (var (buffer, index) in buffers.Select((buffer, index) => (buffer, index)))
                buffer.Read(source[index], 0, count);
            PcmMixer.Mix(source, mixed, count);
            writer.Write(mixed, 0, count);
            writtenFrames += count / 4;
        }
    }

    public async Task<double> StopAsync()
    {
        lock (gate)
        {
            if (stopping) return (double)writtenFrames / AudioFiles.SampleRate;
            clock.Stop();
            stopping = true;
        }
        await cancellation.CancelAsync();
        if (pump is not null) await pump;
        await Task.Run(() =>
        {
            foreach (var capture in captures)
            {
                try { capture.Dispose(); }
                catch (Exception) { Failure ??= "오디오 장치를 종료하는 중 오류가 발생했습니다."; }
            }
        });
        lock (gate)
        {
            try { WriteUntil(clock.Elapsed.TotalSeconds); }
            catch (Exception) { Failure ??= "녹음의 마지막 부분을 저장하지 못했습니다. 저장된 오디오를 확인해 주세요."; }
            finally
            {
                try { writer?.Dispose(); }
                finally
                {
                    writer = null;
                    foreach (var device in devices) device.Dispose();
                    captures.Clear(); devices.Clear(); buffers.Clear();
                }
            }
            return (double)writtenFrames / AudioFiles.SampleRate;
        }
    }

    public async ValueTask DisposeAsync() { await StopAsync(); cancellation.Dispose(); }
}

public static class PcmMixer
{
    public static void Mix(IReadOnlyList<byte[]> sources, byte[] output, int count)
    {
        if (sources.Count == 0 || count < 0 || count % 2 != 0 || count > output.Length || sources.Any(x => x.Length < count))
            throw new ArgumentException("PCM 믹서 버퍼 크기가 올바르지 않습니다.");
        for (int offset = 0; offset < count; offset += 2)
        {
            int sum = 0;
            foreach (var source in sources) sum += BinaryPrimitives.ReadInt16LittleEndian(source.AsSpan(offset, 2));
            BinaryPrimitives.WriteInt16LittleEndian(output.AsSpan(offset, 2), (short)(sum / sources.Count));
        }
    }
    public static float Peak(ReadOnlySpan<byte> buffer)
    {
        int peak = 0;
        for (int i = 0; i + 1 < buffer.Length; i += 2)
            peak = Math.Max(peak, Math.Abs((int)BinaryPrimitives.ReadInt16LittleEndian(buffer.Slice(i, 2))));
        return peak / 32768f;
    }
}
