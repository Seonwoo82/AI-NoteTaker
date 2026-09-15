using System.Windows;
using Microsoft.Win32;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class TranscriptImportWindow : Window
{
    private ImportedTranscript? selectedFile;
    public ImportedTranscript? Result { get; private set; }
    public TranscriptImportWindow(string title) { InitializeComponent(); RecordingTitle.Text = title; }
    private void ChooseFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = "전사문|*.txt;*.srt;*.md", Title = "전사문 선택" };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            selectedFile = TranscriptImport.Read(dialog.FileName);
            PreviewBox.Text = selectedFile.Text; PreviewBox.IsReadOnly = true;
            SourceDescription.Text = selectedFile.FileName + (selectedFile.Format == "srt" ? $" · {selectedFile.Segments.Count}개 시간 구간" : " · 발언자·시간 표기는 원문대로 보관");
            ErrorText.Text = "";
        }
        catch (Exception ex) { ErrorText.Text = ex.Message; }
    }
    private void PasteMode_Click(object sender, RoutedEventArgs e)
    {
        selectedFile = null; PreviewBox.IsReadOnly = false; PreviewBox.Clear(); PreviewBox.Focus();
        SourceDescription.Text = "전사문을 붙여넣으세요. 여러 노트라면 시간 순서대로 합쳐 넣으세요.";
    }
    private void Import_Click(object sender, RoutedEventArgs e)
    {
        try { Result = selectedFile ?? TranscriptImport.Parse(PreviewBox.Text); DialogResult = true; }
        catch (Exception ex) { ErrorText.Text = ex.Message; }
    }
}
