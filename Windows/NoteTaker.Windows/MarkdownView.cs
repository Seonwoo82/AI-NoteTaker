using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace NoteTaker.Windows;

// Text-only Markdown rendering: never fetch images, execute HTML or navigate links.
internal static class MarkdownView
{
    public static FlowDocument Render(string markdown)
    {
        var document = new FlowDocument { FontFamily = new FontFamily("Segoe UI Variable, Segoe UI, Malgun Gothic"), FontSize = 13, LineHeight = 23, PagePadding = new Thickness(24) };
        document.SetResourceReference(TextElement.ForegroundProperty, "Ink");
        foreach (var raw in markdown.Replace("\r\n", "\n").Split('\n'))
        {
            string text = raw.TrimEnd();
            if (string.IsNullOrWhiteSpace(text)) continue;
            var paragraph = new Paragraph { Margin = new Thickness(0, 0, 0, 10) };
            if (text.StartsWith("# ")) { text = text[2..]; paragraph.FontSize = 24; paragraph.FontWeight = FontWeights.Bold; paragraph.Margin = new Thickness(0, 0, 0, 18); }
            else if (text.StartsWith("## ")) { text = text[3..]; paragraph.FontSize = 18; paragraph.FontWeight = FontWeights.Bold; paragraph.Margin = new Thickness(0, 16, 0, 10); }
            else if (text.StartsWith("### ")) { text = text[4..]; paragraph.FontSize = 16; paragraph.FontWeight = FontWeights.SemiBold; }
            else if (text.StartsWith("- [ ] ")) text = "☐  " + text[6..];
            else if (text.StartsWith("- [x] ", StringComparison.OrdinalIgnoreCase)) text = "☑  " + text[6..];
            else if (text.StartsWith("- ") || text.StartsWith("* ")) text = "•  " + text[2..];
            var spans = text.Split("**", StringSplitOptions.None);
            for (int i = 0; i < spans.Length; i++)
            {
                var run = new Run(spans[i]);
                if (i % 2 == 1) run.FontWeight = FontWeights.Bold;
                paragraph.Inlines.Add(run);
            }
            document.Blocks.Add(paragraph);
        }
        return document;
    }
}
