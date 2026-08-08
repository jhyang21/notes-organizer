import Foundation

/// One definition of "a word" for the whole app: a whitespace-separated
/// token. Coarse on purpose — it feeds the over-summarization guard and the
/// diagnostics timings, neither of which needs linguistic accuracy, and both
/// of which would mislead if they counted differently from each other.
public enum WordCounter {
    public static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
