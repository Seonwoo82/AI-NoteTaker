using System.Windows;
using System.Windows.Controls;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class MainWindow
{
    private readonly CapturePreferencesStore capturePreferencesStore;
    private CapturePreferences capturePreferences = new();
    private bool refreshingDevices;
    private void LoadCapturePreferences()
    {
        capturePreferences = capturePreferencesStore.Load();
        ModeBox.SelectedIndex = capturePreferences.Mode switch { RecordingMode.Microphone => 1, RecordingMode.SystemAudio => 2, _ => 0 };
        MicrophoneGainSlider.Value = capturePreferences.MicrophoneGain;
        SystemGainSlider.Value = capturePreferences.SystemGain;
    }
    private void CaptureDevice_Changed(object sender, SelectionChangedEventArgs e) => SaveCapturePreferences();
    private void CaptureGain_Changed(object sender, RoutedPropertyChangedEventArgs<double> e) => SaveCapturePreferences();
    private void SaveCapturePreferences()
    {
        if (!loaded || refreshingDevices || recorder is not null || transitioning || runningWork is not null || ModalOperationOpen) return;
        try
        {
            var changed = capturePreferences with { Mode = Mode,
                MicrophoneId = (MicrophoneBox.SelectedItem as AudioDevice)?.Id ?? capturePreferences.MicrophoneId,
                OutputId = (OutputBox.SelectedItem as AudioDevice)?.Id ?? capturePreferences.OutputId,
                MicrophoneGain = (float)MicrophoneGainSlider.Value, SystemGain = (float)SystemGainSlider.Value };
            capturePreferencesStore.Save(changed); capturePreferences = changed;
        }
        catch (Exception ex) { SetStatus("녹음 설정을 저장하지 못했습니다. " + FriendlyError(ex), true); }
    }
}
