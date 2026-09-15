using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

public partial class MainWindow
{
    private Guid? selectedFolder;
    private bool refreshingLibrary;
    private HashSet<Guid> expandedFolders = [];
    private Point dragOrigin;
    private object? dragItem;
    private const string FolderDragFormat = "AI-NoteTaker.Folder";
    private const string RecordingDragFormat = "AI-NoteTaker.Recording";
    private string FolderAppearancePath => Path.Combine(library.Root, "folder-appearance.json");

    private void LoadFolderAppearance()
    {
        try { expandedFolders = JsonDisk.Read<HashSet<Guid>>(FolderAppearancePath) ?? []; }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or UnauthorizedAccessException)
        { SetStatus("폴더 펼침 상태를 읽지 못했습니다. 녹음과 폴더는 유지됩니다.", true); }
    }
    private void SaveFolderExpansion(Guid id, bool expanded)
    {
        if (refreshingLibrary) return;
        if (expanded) expandedFolders.Add(id); else expandedFolders.Remove(id);
        try { JsonDisk.Write(FolderAppearancePath, expandedFolders); }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
    }
    private void ReloadFolders()
    {
        refreshingLibrary = true;
        try
        {
            if (selectedFolder is not null && !folderStore.IsActive(selectedFolder)) { selectedFolder = null; FilterBox.SelectedIndex = 0; }
            FolderTree.Items.Clear();
            UnfiledDropTarget.Visibility = folderStore.Active.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            foreach (var folder in folderStore.Active)
            {
                var members = recordings.Where(r => !r.IsRecording && r.DeletedAt is null && r.FolderId == folder.Id).ToArray();
                var header = new Grid();
                header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
                header.ColumnDefinitions.Add(new ColumnDefinition());
                header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                header.Children.Add(new AppleIcon { Kind = "folder", Width = 14, Height = 14, HorizontalAlignment = HorizontalAlignment.Left });
                var name = new TextBlock { Text = folder.Name, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(name, 1); header.Children.Add(name);
                var count = new TextBlock { Text = members.Length.ToString(), FontSize = 10, Opacity = .65, Margin = new Thickness(5, 0, 1, 0), VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(count, 2); header.Children.Add(count);
                var item = new TreeViewItem { Header = header, Tag = folder, IsExpanded = expandedFolders.Contains(folder.Id), IsSelected = selectedFolder == folder.Id, ToolTip = folder.Name };
                AutomationProperties.SetName(item, $"{folder.Name}, 녹음 {members.Length}개");
                item.Expanded += (_, e) => { if (e.OriginalSource == item) SaveFolderExpansion(folder.Id, true); };
                item.Collapsed += (_, e) => { if (e.OriginalSource == item) SaveFolderExpansion(folder.Id, false); };
                item.ContextMenu = FolderContextMenu(folder);
                foreach (var record in members)
                {
                    var panel = new StackPanel { Margin = new Thickness(0, 2, 0, 2) };
                    panel.Children.Add(new TextBlock { Text = record.DisplayTitle, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis });
                    panel.Children.Add(new TextBlock { Text = record.Subtitle, FontSize = 9, Opacity = .65, TextTrimming = TextTrimming.CharacterEllipsis });
                    var child = new TreeViewItem { Header = panel, Tag = record, ToolTip = record.Title };
                    AutomationProperties.SetName(child, record.Title);
                    var menu = new ContextMenu();
                    var move = new MenuItem { Header = "폴더로 이동" }; menu.Items.Add(move);
                    menu.Opened += (_, _) => PopulateMoveMenu(move);
                    child.ContextMenu = menu; item.Items.Add(child);
                }
                FolderTree.Items.Add(item);
            }
        }
        finally { refreshingLibrary = false; }
    }
    private ContextMenu FolderContextMenu(RecordingCollectionFolder folder)
    {
        var menu = new ContextMenu();
        var rename = new MenuItem { Header = "폴더 이름 변경…" };
        rename.Click += (_, _) =>
        {
            var dialog = new RenameWindow(folder.Name, "폴더 이름 변경", "폴더 이름", 120) { Owner = this };
            if (dialog.ShowDialog() == true) FolderAction(() => folderStore.Rename(folder.Id, dialog.Result));
        };
        var remove = new MenuItem { Header = "폴더 삭제 · 녹음 유지" };
        remove.Click += (_, _) => FolderAction(() => { folderStore.Delete(folder.Id); SetStatus("폴더를 삭제했습니다. 녹음은 모든 녹음 항목에서 계속 볼 수 있습니다."); });
        var up = new MenuItem { Header = "위로 이동" }; var down = new MenuItem { Header = "아래로 이동" };
        int index = folderStore.Active.ToList().FindIndex(x => x.Id == folder.Id);
        up.IsEnabled = index > 0; down.IsEnabled = index < folderStore.Active.Count - 1;
        up.Click += (_, _) => FolderAction(() => folderStore.Move(folder.Id, folderStore.Active[index - 1].Id));
        down.Click += (_, _) => FolderAction(() => folderStore.Move(folder.Id, index + 2 < folderStore.Active.Count ? folderStore.Active[index + 2].Id : null));
        menu.Items.Add(rename); menu.Items.Add(up); menu.Items.Add(down); menu.Items.Add(new Separator()); menu.Items.Add(remove);
        return menu;
    }
    private void FolderAction(Action action)
    {
        if (recorder is not null || transitioning || runningWork is not null) return;
        try { action(); ReloadLibrary(selected?.Id); }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
    }
    private void CreateFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new RenameWindow("", "새 폴더", "폴더 이름", 120) { Owner = this };
        if (dialog.ShowDialog() == true) CreateNamedFolder(dialog.Result);
    }
    internal void CreateNamedFolder(string name) => FolderAction(() => folderStore.Create(name));
    private void SelectFolderFilter(Guid? folderId)
    {
        selectedFolder = folderStore.IsActive(folderId) ? folderId : null;
        refreshingLibrary = true;
        try { FilterBox.SelectedIndex = selectedFolder is null ? 0 : -1; }
        finally { refreshingLibrary = false; }
    }
    private void ClearFolderSelection()
    {
        refreshingLibrary = true;
        try
        {
            foreach (TreeViewItem item in FolderTree.Items)
            {
                item.IsSelected = false;
                foreach (TreeViewItem child in item.Items) child.IsSelected = false;
            }
        }
        finally { refreshingLibrary = false; }
    }
    private void Folder_Selected(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if (!loaded || refreshingLibrary || e.NewValue is not TreeViewItem item) return;
        if (item.Tag is RecordingCollectionFolder folder) { SelectFolderFilter(folder.Id); FilterLibrary(selected?.Id); }
        else if (item.Tag is Recording record)
        {
            SelectFolderFilter(record.FolderId);
            refreshingLibrary = true;
            try { SearchBox.Clear(); }
            finally { refreshingLibrary = false; }
            FilterLibrary(record.Id);
        }
    }
    private void Folder_RightClick(object sender, MouseButtonEventArgs e)
    {
        if (Ancestor<TreeViewItem>(e.OriginalSource as DependencyObject) is { } item) item.IsSelected = true;
    }
    private void PopulateMoveMenu(MenuItem menu)
    {
        menu.Items.Clear(); menu.IsEnabled = selected is { DeletedAt: null } && recorder is null && runningWork is null && !transitioning && folderStore.LoadError is null;
        if (!menu.IsEnabled) return;
        void Add(string name, Guid? id)
        {
            var item = new MenuItem { Header = name, IsCheckable = true, IsChecked = (folderStore.IsActive(selected?.FolderId) ? selected?.FolderId : null) == id };
            item.Click += (_, _) => MoveSelectedToFolder(id); menu.Items.Add(item);
        }
        Add("폴더 밖으로 이동", null);
        foreach (var folder in folderStore.Active) Add(folder.Name, folder.Id);
    }
    internal void MoveSelectedToFolder(Guid? id)
    {
        if (selected is null) return;
        FolderAction(() =>
        {
            selected = folderStore.MoveRecording(library, selected, id);
            SelectFolderFilter(id); SetStatus(id is null ? "녹음을 폴더 밖으로 이동했습니다." : "녹음을 폴더로 이동했습니다.");
        });
    }
    private static T? Ancestor<T>(DependencyObject? source) where T : DependencyObject
    {
        while (source is not null)
        {
            if (source is T match) return match;
            source = source is System.Windows.Documents.Run run ? run.Parent : VisualTreeHelper.GetParent(source);
        }
        return null;
    }
    private void Library_DragStart(object sender, MouseButtonEventArgs e)
    {
        dragOrigin = e.GetPosition(this);
        dragItem = sender == FolderTree ? Ancestor<TreeViewItem>(e.OriginalSource as DependencyObject)?.Tag
            : Ancestor<ListBoxItem>(e.OriginalSource as DependencyObject)?.DataContext;
    }
    private void Library_DragMove(object sender, MouseEventArgs e)
    {
        if (dragItem is null || e.LeftButton != MouseButtonState.Pressed || recorder is not null || runningWork is not null || transitioning) return;
        var point = e.GetPosition(this);
        if (Math.Abs(point.X - dragOrigin.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(point.Y - dragOrigin.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        var source = dragItem; dragItem = null;
        if (source is Recording { DeletedAt: null } record) DragDrop.DoDragDrop((DependencyObject)sender, new DataObject(RecordingDragFormat, record.Id), DragDropEffects.Move);
        else if (source is RecordingCollectionFolder folder) DragDrop.DoDragDrop((DependencyObject)sender, new DataObject(FolderDragFormat, folder.Id), DragDropEffects.Move);
    }
    private void Library_DragOver(object sender, DragEventArgs e)
    {
        bool available = recorder is null && runningWork is null && !transitioning && folderStore.LoadError is null;
        bool all = sender == UnfiledDropTarget || sender == FilterBox && Ancestor<ListBoxItem>(e.OriginalSource as DependencyObject) is { } row && FilterBox.Items.IndexOf(row) == 0;
        var node = Ancestor<TreeViewItem>(e.OriginalSource as DependencyObject);
        bool folderTarget = sender == FolderTree && DropFolder(node) is not null;
        bool allowed = e.Data.GetDataPresent(RecordingDragFormat) && (all || folderTarget) || e.Data.GetDataPresent(FolderDragFormat) && sender == FolderTree && node?.Tag is not Recording;
        e.Effects = available && allowed ? DragDropEffects.Move : DragDropEffects.None; e.Handled = true;
    }
    private void Library_Drop(object sender, DragEventArgs e)
    {
        Library_DragOver(sender, e); if (e.Effects != DragDropEffects.Move) return;
        var target = DropFolder(Ancestor<TreeViewItem>(e.OriginalSource as DependencyObject));
        if (e.Data.GetData(FolderDragFormat) is Guid folderId) FolderAction(() => folderStore.Move(folderId, target?.Id));
        else if (e.Data.GetData(RecordingDragFormat) is Guid recordId && recordings.FirstOrDefault(r => r.Id == recordId && r.DeletedAt is null) is { } record)
        {
            FolderAction(() =>
            {
                folderStore.MoveRecording(library, record, target?.Id);
                // Keep any currently playing recording selected; a drop can target another row.
                if (selected?.Id == record.Id) selected = record with { FolderId = target?.Id };
                SelectFolderFilter(target?.Id);
            });
        }
    }
    private RecordingCollectionFolder? DropFolder(TreeViewItem? node) => node?.Tag switch
    {
        RecordingCollectionFolder folder => folder,
        Recording recording => folderStore.Active.FirstOrDefault(f => f.Id == recording.FolderId),
        _ => null
    };
}
