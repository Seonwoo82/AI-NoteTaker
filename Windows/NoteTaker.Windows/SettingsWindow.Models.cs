using System.Windows;
using System.Windows.Controls;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class SettingsWindow
{
    private AiModelCatalog? catalog;
    private bool changingCatalog;
    private CancellationTokenSource? catalogCancellation;
    internal Func<CancellationToken, Task<AiModelCatalog>>? CatalogLoader { get; set; }
    private void InitializeCatalog()
    {
        try { catalog = new AiModelCatalogStore(libraryRoot).Load(); }
        catch (Exception ex) { CatalogStatus.Text = "저장된 목록을 읽지 못했습니다. 모델 ID는 유지됩니다. " + ex.Message; }
        if (catalog is not null) CatalogStatus.Text = $"저장된 목록 · {catalog.FetchedAt.LocalDateTime:yyyy.MM.dd HH:mm} · {catalog.Models.Count}개";
        else if (CatalogStatus.Text.Length == 0) CatalogStatus.Text = "공개 목록에서 검색하거나 모델 ID를 직접 입력할 수 있습니다. API 키는 목록 조회에 전송하지 않습니다.";
        RefreshCatalogLists(); Closed += (_, _) => catalogCancellation?.Cancel();
    }
    private async void RefreshModels_Click(object sender, RoutedEventArgs e)
    {
        if (catalogCancellation is not null) return;
        catalogCancellation = new(); RefreshModelsButton.IsEnabled = false; CatalogStatus.Text = "모델 목록을 불러오는 중…";
        try
        {
            using var client = new AiModelCatalogClient();
            var fetched = CatalogLoader is null ? await client.FetchAsync(catalogCancellation.Token) : await CatalogLoader(catalogCancellation.Token);
            catalogCancellation.Token.ThrowIfCancellationRequested(); new AiModelCatalogStore(libraryRoot).Save(fetched); catalog = fetched;
            CatalogStatus.Text = $"{catalog.FetchedAt.LocalDateTime:yyyy.MM.dd HH:mm} 갱신 · 텍스트 {catalog.Models.Count(m => m.SupportsSummary)} / 전사 {catalog.Models.Count(m => m.SupportsTranscription)} · 가격은 조회 시점 기준";
            RefreshCatalogLists();
        }
        catch (OperationCanceledException) { CatalogStatus.Text = "목록 조회를 취소했습니다. 이전 선택은 유지됩니다."; }
        catch (Exception ex) { CatalogStatus.Text = "목록을 갱신하지 못했습니다. 이전 선택은 유지됩니다. " + ex.Message; }
        finally { catalogCancellation.Dispose(); catalogCancellation = null; RefreshModelsButton.IsEnabled = true; }
    }
    private void CatalogSearch_Changed(object sender, TextChangedEventArgs e) { if (initialized && !changingCatalog) RefreshCatalogLists(); }
    private void CatalogModelId_Changed(object sender, TextChangedEventArgs e) { if (initialized && !changingCatalog) UpdateModelDetails(); }
    private void RefreshCatalogLists()
    {
        changingCatalog = true;
        try
        {
            void Fill(ComboBox list, TextBox search, TextBox selection, bool speech)
            {
                string query = search.Text.Trim(); var filtered = (catalog?.Models ?? []).Where(m => speech ? m.SupportsTranscription : m.SupportsSummary)
                    .Where(m => query.Length == 0 || m.Id.Contains(query, StringComparison.OrdinalIgnoreCase) || m.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
                list.ItemsSource = filtered; list.SelectedItem = filtered.FirstOrDefault(m => m.Id == selection.Text.Trim());
            }
            Fill(SummaryModelList, SummarySearchBox, SummaryModelBox, false); Fill(EnhancementModelList, EnhancementSearchBox, EnhancementModelBox, false); Fill(TranscriptionModelList, TranscriptionSearchBox, TranscriptionModelBox, true);
        }
        finally { changingCatalog = false; }
        UpdateModelDetails();
    }
    private void CatalogSelection_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized || changingCatalog || sender is not ComboBox { SelectedItem: AiModel model } list) return;
        (list == SummaryModelList ? SummaryModelBox : list == EnhancementModelList ? EnhancementModelBox : TranscriptionModelBox).Text = model.Id;
    }
    private AiModel? ModelInfo(string id, AiModel? previous) => catalog?.Models.FirstOrDefault(m => m.Id == id) ?? (previous?.Id == id ? previous : null);
    private void UpdateModelDetails()
    {
        string summary = SummaryModelBox.Text.Trim(), enhancement = EnhancementModelBox.Text.Trim();
        SummaryModelDetail.Text = ModelInfo(summary, Result.SummaryModelInfo)?.Detail ?? "목록에 없는 ID도 유지됩니다. 한도를 모르면 작은 문맥으로 나누어 처리합니다.";
        EnhancementModelDetail.Text = enhancement.Length == 0 ? "현재 회의록 모델과 동일하게 처리합니다." : ModelInfo(enhancement, Result.EnhancementModelInfo)?.Detail ?? "목록에 없는 ID · 선택은 유지됩니다.";
    }
}
