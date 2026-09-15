using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Text.RegularExpressions;

namespace NoteTaker.Windows;

// Text-only Markdown rendering: never fetch images, execute HTML or navigate links.
internal static class MarkdownView
{
    internal sealed record Heading(string Label, int Level, Paragraph Paragraph);
    public static FlowDocument Render(string markdown) => Render(markdown, out _);
    public static FlowDocument Render(string markdown, out List<Heading> headings)
    {
        headings = [];
        var document = new FlowDocument { FontFamily = new FontFamily("Segoe UI Variable, Segoe UI, Malgun Gothic"), FontSize = 13, LineHeight = 23, PagePadding = new Thickness(24) };
        document.SetResourceReference(TextElement.ForegroundProperty, "Ink");
        char fence = '\0'; int fenceLength = 0;
        foreach (var raw in markdown.Replace("\r\n", "\n").Split('\n'))
        {
            string text = raw.TrimEnd();
            var marker = Regex.Match(text, @"^ {0,3}(`{3,}|~{3,})(.*)$");
            if (marker.Success && (fence == '\0' || marker.Groups[1].Value[0] == fence && marker.Groups[1].Length >= fenceLength && string.IsNullOrWhiteSpace(marker.Groups[2].Value)))
            {
                if (fence == '\0') { fence = marker.Groups[1].Value[0]; fenceLength = marker.Groups[1].Length; }
                else fence = '\0';
                continue;
            }
            if (string.IsNullOrWhiteSpace(text)) continue;
            var paragraph = new Paragraph { Margin = new Thickness(0, 0, 0, 10) };
            if (fence != '\0') { paragraph.FontFamily = new FontFamily("Consolas"); paragraph.Inlines.Add(new Run(text)); document.Blocks.Add(paragraph); continue; }
            var heading = Regex.Match(text, @"^ {0,3}(#{1,6})\s+(.+)$");
            if (heading.Success)
            {
                int level = heading.Groups[1].Length; text = Regex.Replace(heading.Groups[2].Value, @"\s+#+\s*$", "");
                paragraph.FontSize = level == 1 ? 24 : level == 2 ? 18 : 16;
                paragraph.FontWeight = FontWeights.SemiBold; paragraph.Margin = new Thickness(0, level == 1 ? 0 : 16, 0, 10);
                headings.Add(new(new string('　', level - 1) + text.Replace("**", ""), level, paragraph));
            }
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
