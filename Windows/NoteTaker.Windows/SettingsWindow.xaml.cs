using System.Windows;
using System.Windows.Controls;
using System.Windows.Shell;
using NoteTaker.Windows.Components;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class SettingsWindow : Window
{
    private readonly string libraryRoot;
    private CancellationTokenSource? preparation;
    private bool initialized, closeAfterPreparation;
    public AppSettings Result { get; private set; }
    public SettingsWindow(AppSettings settings, string? root = null)
    {
        libraryRoot = root ?? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AI-NoteTaker");
        Result = settings;
        InitializeComponent();
        SummaryModelBox.Text = settings.SummaryModel;
        EnhancementModelBox.Text = settings.EnhancementModel;
        TranscriptionModelBox.Text = settings.TranscriptionModel;
        LanguageBox.SelectedIndex = settings.Language == "en" ? 1 : settings.Language == "source" ? 2 : 0;
        KeyHint.Text = settings.ProtectedApiKey is null ? "키는 현재 Windows 계정으로 암호화해 저장합니다." : "저장된 키가 있습니다. 빈칸으로 두면 기존 키를 유지합니다.";
        KeyStatus.Text = settings.ProtectedApiKey is null ? "미설정" : "저장됨";
        SharingUrlBox.Text = settings.SharingServerUrl;
        SharingTokenHint.Text = settings.ProtectedSharingSyncToken is null ? "토큰은 현재 Windows 계정으로 암호화해 저장합니다." : "저장된 토큰이 있습니다. 빈칸으로 두면 기존 토큰을 유지합니다.";
        SharingTokenStatus.Text = settings.ProtectedSharingSyncToken is null ? "미설정" : "저장됨";
        TranscriptionProviderBox.SelectedIndex = settings.TranscriptionProvider == "openrouter" ? 1 : settings.TranscriptionProvider == "qwen" ? 2 : 0;
        QwenAsrModelBox.SelectedIndex = settings.QwenAsrModel == "0.6b" ? 1 : 0;
        SummaryProviderBox.SelectedIndex = settings.SummaryProvider == "openrouter" ? 1 : 0;
        SpeechLanguageBox.SelectedIndex = settings.SpeechLanguage == "auto" ? 1 : settings.SpeechLanguage == "en" ? 2 : 0;
        UseGpuBox.IsChecked = settings.UseGpu;
        AutoGenerateBox.IsChecked = settings.AutoGenerate;
        TranscriptCleanupBox.IsChecked = settings.TranscriptCleanupEnabled;
        KeepRunningBox.IsChecked = settings.KeepRunningInTray;
        GlobalShortcutsBox.IsChecked = settings.EnableGlobalShortcuts;
        LocalSummaryBox.SelectedIndex = settings.LocalSummaryModel == "qwen3.5:9b" ? 1 : 0;
        LocalEnhancementBox.SelectedIndex = settings.LocalEnhancementModel == "qwen3.5:9b" ? 2 : settings.LocalEnhancementModel == "qwen3.5:4b" ? 1 : 0;
        OllamaAddressBox.Text = settings.OllamaAddress;
        initialized = true; UpdateProviders(); InitializeCatalog();
        Closing += (_, e) => { if (preparation is not null) { closeAfterPreparation = true; preparation.Cancel(); e.Cancel = true; } };
    }
    private AppSettings ReadSelection() => Result with
    {
        TranscriptionProvider = TranscriptionProviderBox.SelectedIndex == 1 ? "openrouter" : TranscriptionProviderBox.SelectedIndex == 2 ? "qwen" : "whisper",
        QwenAsrModel = QwenAsrModelBox.SelectedIndex == 1 ? "0.6b" : "1.7b",
        SummaryProvider = SummaryProviderBox.SelectedIndex == 1 ? "openrouter" : "ollama",
        SpeechLanguage = SpeechLanguageBox.SelectedIndex == 1 ? "auto" : SpeechLanguageBox.SelectedIndex == 2 ? "en" : "ko",
        UseGpu = UseGpuBox.IsChecked == true,
        LocalSummaryModel = LocalSummaryBox.SelectedIndex == 1 ? "qwen3.5:9b" : "qwen3.5:4b",
        LocalEnhancementModel = LocalEnhancementBox.SelectedIndex == 2 ? "qwen3.5:9b" : LocalEnhancementBox.SelectedIndex == 1 ? "qwen3.5:4b" : "",
        TranscriptCleanupEnabled = TranscriptCleanupBox.IsChecked == true,
        OllamaAddress = OllamaAddressBox.Text.Trim(),
        AutoGenerate = AutoGenerateBox.IsChecked == true,
        KeepRunningInTray = KeepRunningBox.IsChecked == true,
        EnableGlobalShortcuts = GlobalShortcutsBox.IsChecked == true
    };
    private void Provider_Changed(object sender, SelectionChangedEventArgs e) { if (initialized) UpdateProviders(); }
    private void UpdateProviders()
    {
        bool cloudSpeech = TranscriptionProviderBox.SelectedIndex == 1, cloudSummary = SummaryProviderBox.SelectedIndex == 1;
        CloudKeyCard.Visibility = CloudModelCard.Visibility = cloudSpeech || cloudSummary ? Visibility.Visible : Visibility.Collapsed;
        LocalModelCard.Visibility = !cloudSpeech || !cloudSummary ? Visibility.Visible : Visibility.Collapsed;
        bool qwen = TranscriptionProviderBox.SelectedIndex == 2;
        if (qwen) SpeechLanguageBox.SelectedIndex = 1;
        SpeechLanguageBox.IsEnabled = !cloudSpeech && !qwen; UseGpuBox.IsEnabled = !cloudSpeech;
        QwenAsrModelBox.Visibility = qwen ? Visibility.Visible : Visibility.Collapsed;
        LocalSpeechDescription.Text = qwen ? "Qwen3-ASR · 언어 자동 감지 · 실행 환경 약 254 MB 별도" : "Whisper large-v3-turbo · 약 1.62 GB";
        LocalSummaryBox.IsEnabled = LocalEnhancementBox.IsEnabled = OllamaAddressBox.IsEnabled = !cloudSummary;
        TranscriptionModelBox.IsEnabled = cloudSpeech; SummaryModelBox.IsEnabled = cloudSummary;
        TranscriptionModelList.IsEnabled = TranscriptionSearchBox.IsEnabled = cloudSpeech;
        SummaryModelList.IsEnabled = SummarySearchBox.IsEnabled = EnhancementModelBox.IsEnabled = EnhancementModelList.IsEnabled = EnhancementSearchBox.IsEnabled = cloudSummary;
        ProcessingNotice.Text = cloudSpeech ? "전사할 때 오디오가 OpenRouter로 전송됩니다. 클라우드 요약을 선택하면 전사문도 전송되며 이용료가 발생할 수 있습니다." :
            cloudSummary ? "음성 전사는 이 PC에서 무료로 처리합니다. 회의록을 정리할 때 전사문이 OpenRouter로 전송되며 이용료가 발생할 수 있습니다." :
            "전사와 회의록을 이 PC에서 처리합니다. API 키와 분당 요금이 없고, 모델을 준비한 뒤에는 오프라인으로 사용할 수 있습니다.";
    }
    private async void PrepareLocal_Click(object sender, RoutedEventArgs e)
    {
        if (preparation is not null) return;
        var settings = ReadSelection();
        preparation = new(); PrepareLocalButton.IsEnabled = SaveSettingsButton.IsEnabled = false;
        TranscriptionProviderBox.IsEnabled = SummaryProviderBox.IsEnabled = false;
        QwenAsrModelBox.IsEnabled = SpeechLanguageBox.IsEnabled = UseGpuBox.IsEnabled = LocalSummaryBox.IsEnabled = LocalEnhancementBox.IsEnabled = OllamaAddressBox.IsEnabled = false;
        CancelPreparationButton.Visibility = Visibility.Visible;
        try
        {
            var progress = new Progress<string>(message => PreparationStatus.Text = message);
            if (settings.TranscriptionProvider == "whisper") await ModelDownload.EnsureAsync(libraryRoot, ModelDownload.WhisperTurbo, progress, preparation.Token);
            if (settings.SummaryProvider == "ollama") await LocalRuntime.PrepareOllamaAsync(libraryRoot, settings, progress, preparation.Token);
            if (settings.SummaryProvider == "ollama" && AiProviders.EnhancementSettings(settings).LocalSummaryModel != settings.LocalSummaryModel)
                await LocalRuntime.PrepareOllamaAsync(libraryRoot, AiProviders.EnhancementSettings(settings), progress, preparation.Token);
            if (settings.TranscriptionProvider == "qwen") await QwenModels.PrepareAsync(libraryRoot, settings.QwenAsrModel, progress, preparation.Token);
            if (settings.TranscriptionProvider == "whisper" && settings.UseGpu) await LocalRuntime.PrepareCudaAsync(libraryRoot, progress, preparation.Token);
            PreparationStatus.Text = "모델 준비 완료. 설정을 저장하고 전사·회의록을 실행하세요.";
        }
        catch (OperationCanceledException) { PreparationStatus.Text = "준비를 중단했습니다. 다음에 다시 누르면 다운로드를 이어받습니다."; }
        catch (Exception ex) { PreparationStatus.Text = ex.Message; }
        finally
        {
            preparation.Dispose(); preparation = null;
            PrepareLocalButton.IsEnabled = SaveSettingsButton.IsEnabled = TranscriptionProviderBox.IsEnabled = SummaryProviderBox.IsEnabled = true;
            CancelPreparationButton.Visibility = Visibility.Collapsed;
            QwenAsrModelBox.IsEnabled = true; UpdateProviders();
            if (closeAfterPreparation) Close();
        }
    }
    private void CancelPreparation_Click(object sender, RoutedEventArgs e) => preparation?.Cancel();
    private void Save_Click(object sender, RoutedEventArgs e)
    {
        string model = SummaryModelBox.Text.Trim(), transcription = TranscriptionModelBox.Text.Trim(), enhancement = EnhancementModelBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(model) || string.IsNullOrWhiteSpace(transcription) || model.Any(char.IsWhiteSpace) || transcription.Any(char.IsWhiteSpace) || enhancement.Any(char.IsWhiteSpace))
        { ErrorText.Text = "두 모델 ID를 공백 없이 입력해 주세요."; return; }
        try
        {
            var selected = ReadSelection();
            if (selected.SummaryProvider == "ollama") _ = OllamaSummarizer.LocalAddress(selected.OllamaAddress);
            string sharingUrl = SharingUrlBox.Text.Trim();
            if (sharingUrl.Length > 0 && (!Uri.TryCreate(sharingUrl, UriKind.Absolute, out var shareUri) || shareUri.Scheme != Uri.UriSchemeHttps ||
                !string.IsNullOrEmpty(shareUri.UserInfo) || !string.IsNullOrEmpty(shareUri.Query) || !string.IsNullOrEmpty(shareUri.Fragment)))
            { ErrorText.Text = "웹 공유 서버 주소는 https:// 호스트만 입력해 주세요."; return; }
            Result = selected with
            {
                SummaryModel = model, TranscriptionModel = transcription, EnhancementModel = enhancement,
                SummaryModelInfo = ModelInfo(model, Result.SummaryModelInfo), EnhancementModelInfo = ModelInfo(enhancement, Result.EnhancementModelInfo),
                Language = LanguageBox.SelectedIndex == 1 ? "en" : LanguageBox.SelectedIndex == 2 ? "source" : "ko",
                ProtectedApiKey = DeleteKeyBox.IsChecked == true ? null : string.IsNullOrWhiteSpace(ApiKeyBox.Password)
                    ? Result.ProtectedApiKey : SettingsStore.ProtectKey(ApiKeyBox.Password),
                SharingServerUrl = sharingUrl,
                ProtectedSharingSyncToken = DeleteSharingTokenBox.IsChecked == true ? null : string.IsNullOrWhiteSpace(SharingTokenBox.Password)
                    ? Result.ProtectedSharingSyncToken : SettingsStore.ProtectKey(SharingTokenBox.Password)
            };
            ApiKeyBox.Clear(); SharingTokenBox.Clear(); DialogResult = true;
        }
        catch (Exception ex) { ErrorText.Text = ex.Message; }
    }
}

internal sealed class RenameWindow : Window
{
    public string Result { get; private set; }
    public RenameWindow(string title, string windowTitle = "녹음 이름 변경", string fieldLabel = "녹음 이름", int maxLength = 160, bool allowEmpty = false)
    {
        Result = title;
        Title = windowTitle; Width = 440; Height = 218; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner; ShowInTaskbar = false;
        Style = (Style)FindResource(typeof(Window)); WindowStyle = WindowStyle.None;
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 44, ResizeBorderThickness = new Thickness(0), GlassFrameThickness = new Thickness(0), CornerRadius = new CornerRadius(10), UseAeroCaptionButtons = false });
        var root = new Grid(); root.SetResourceReference(BackgroundProperty, "WindowSurface");
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(44) }); root.RowDefinitions.Add(new RowDefinition());
        var header = new Grid(); header.SetResourceReference(BackgroundProperty, "ToolbarSurface");
        var windowControls = new WindowControls { HorizontalAlignment = HorizontalAlignment.Left };
        WindowChrome.SetIsHitTestVisibleInChrome(windowControls, true);
        header.Children.Add(windowControls); header.Children.Add(new TextBlock { Text = Title, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeights.SemiBold });
        root.Children.Add(header);
        var panel = new StackPanel { Margin = new Thickness(24) };
        var text = new TextBox { Text = title, MaxLength = maxLength };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        var cancel = new Button { Content = "취소", IsCancel = true };
        var save = new Button { Content = "저장", IsDefault = true, Style = (Style)FindResource("PrimaryButton"), Margin = new Thickness(8, 0, 0, 0) };
        save.Click += (_, _) => { if (allowEmpty || !string.IsNullOrWhiteSpace(text.Text)) { Result = text.Text.Trim(); DialogResult = true; } };
        buttons.Children.Add(cancel); buttons.Children.Add(save);
        panel.Children.Add(new TextBlock { Text = fieldLabel, FontSize = 11, Margin = new Thickness(0, 0, 0, 6) });
        panel.Children.Add(text); panel.Children.Add(buttons); Grid.SetRow(panel, 1); root.Children.Add(panel); Content = root;
        Loaded += (_, _) => { text.Focus(); text.SelectAll(); };
    }
}
