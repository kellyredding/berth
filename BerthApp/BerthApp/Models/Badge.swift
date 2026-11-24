import Foundation

/// The Dock badge from a page title: the first match of the site's
/// `badge.title` expression, whose first capture group is the badge. No match,
/// or an empty group, clears it.
struct BadgeRule {
    let pattern: String
    private let regex: NSRegularExpression

    /// Nil when the expression does not compile under ICU or has no group.
    init?(pattern: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              regex.numberOfCaptureGroups >= 1
        else { return nil }
        self.pattern = pattern
        self.regex = regex
    }

    func label(for title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let range = NSRange(title.startIndex..., in: title)
        guard let match = regex.firstMatch(in: title, range: range),
              let group = Range(match.range(at: 1), in: title)
        else { return nil }
        let label = title[group].trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }
}
