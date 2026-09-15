using NAudio.MediaFoundation;
using NAudio.Wave;
using System.Runtime.InteropServices;

namespace NoteTaker.Core;

public static class SyncAudio
{
    public static Task EncodeAsync(string wav, string destination, CancellationToken token) => Task.Run(() =>
    {
        token.ThrowIfCancellationRequested(); RequireDifferent(wav, destination); MediaFoundationApi.Startup();
        string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".m4a";
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destination))!);
        try
        {
            using (var reader = new WaveFileReader(wav))
            {
                if (reader.WaveFormat.Encoding != WaveFormatEncoding.Pcm || reader.WaveFormat.BitsPerSample != 16 || reader.WaveFormat.Channels is < 1 or > 2) throw new InvalidDataException("동기화할 PCM 오디오 형식이 올바르지 않습니다.");
                // Media Foundation's URL sink fails on long Windows paths; .NET streams support them.
                using var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
                MediaFoundationEncoder.EncodeToAac(new CancellableWave(reader, token), output, 128000);
            }
            token.ThrowIfCancellationRequested();
            if (new FileInfo(temporary).Length > SyncJson.AudioLimit) throw new InvalidDataException("변환한 오디오가 95 MiB 동기화 제한을 초과했습니다. 원본은 이 PC에 보존됩니다.");
            File.Move(temporary, destination, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }, token);
    public static Task<double> DecodeAsync(string m4a, string destination, CancellationToken token) => Task.Run(() =>
    {
        token.ThrowIfCancellationRequested(); RequireDifferent(m4a, destination);
        string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".wav";
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destination))!);
        try
        {
            using var input = File.OpenRead(m4a);
            using var reader = new SyncM4aReader(input);
            double duration = AudioFiles.ConvertToWave(reader, temporary, token); token.ThrowIfCancellationRequested(); File.Move(temporary, destination, true); return duration;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }, token);
    private static void RequireDifferent(string source, string destination)
    {
        if (string.Equals(Path.GetFullPath(source), Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("변환 결과는 원본과 다른 파일에 저장해야 합니다.");
    }
    private sealed class CancellableWave(IWaveProvider source, CancellationToken token) : IWaveProvider
    {
        public WaveFormat WaveFormat => source.WaveFormat;
        public int Read(byte[] buffer, int offset, int count) { token.ThrowIfCancellationRequested(); return source.Read(buffer, offset, count); }
    }
    // The NAudio stream reader omits the native channel/rate constraint present in its URL reader.
    // Without it low-rate mono AAC can change format on first Read and be decoded at the wrong speed.
    private sealed class SyncM4aReader(Stream input) : StreamMediaFoundationReader(input, new() { SingleReaderObject = true })
    {
        protected override IMFSourceReader CreateReader(MediaFoundationReaderSettings settings)
        {
            var reader = base.CreateReader(settings);
            IMFMediaType? native = null; MediaType? pcm = null;
            try
            {
                reader.GetNativeMediaType(MediaFoundationInterop.MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, out native);
                var original = new MediaType(native);
                pcm = new MediaType { MajorType = MediaTypes.MFMediaType_Audio, SubType = AudioSubtypes.MFAudioFormat_PCM,
                    SampleRate = original.SampleRate, ChannelCount = original.ChannelCount };
                try { reader.SetCurrentMediaType(MediaFoundationInterop.MF_SOURCE_READER_FIRST_AUDIO_STREAM, IntPtr.Zero, pcm.MediaFoundationObject); }
                catch (COMException ex) when (ex.HResult == MediaFoundationErrors.MF_E_INVALIDMEDIATYPE && original.SubType == AudioSubtypes.MFAudioFormat_AAC && original.ChannelCount == 1)
                {
                    pcm.SampleRate *= 2; pcm.ChannelCount *= 2;
                    reader.SetCurrentMediaType(MediaFoundationInterop.MF_SOURCE_READER_FIRST_AUDIO_STREAM, IntPtr.Zero, pcm.MediaFoundationObject);
                }
                return reader;
            }
            catch { Marshal.ReleaseComObject(reader); throw; }
            finally { if (native is not null) Marshal.ReleaseComObject(native); if (pcm is not null) Marshal.ReleaseComObject(pcm.MediaFoundationObject); }
        }
    }
}
