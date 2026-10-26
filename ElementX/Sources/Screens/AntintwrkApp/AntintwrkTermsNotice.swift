// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct AntintwrkTermsNotice: View {
    let format: String
    let rules: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var fontSize: CGFloat = 13
    @State private var availableWidth: CGFloat = 0
    
    var body: some View {
        Button(action: action) {
            Text(Self.text(format: format, rules: rules, font: .systemFont(ofSize: fontSize), width: availableWidth))
                .font(.system(size: fontSize))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .accessibilityLabel(String(format: format, rules))
    }
    
    static func text(format: String, rules: String, font: UIFont, width: CGFloat) -> AttributedString {
        let fits = (rules as NSString).size(withAttributes: [.font: font]).width <= max(0, width - 2)
        let displayedRules = fits ? rules.replacingOccurrences(of: " ", with: "\u{00A0}").map(String.init).joined(separator: "\u{2060}") : rules
        let notice = String(format: format, displayedRules)
        let value = NSMutableAttributedString(string: notice)
        let range = (notice as NSString).range(of: displayedRules)
        if range.location != NSNotFound {
            value.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .foregroundColor: UIColor(red: 0.94, green: 0.42, blue: 0.33, alpha: 1)], range: range)
        }
        return AttributedString(value)
    }
}

struct AntintwrkTermsNotice_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 24) {
            AntintwrkTermsNotice(format: "By signing in, you agree to the %1$@.", rules: "Terms of ANTINTWRK") { }
            AntintwrkTermsNotice(format: "Входя в аккаунт, вы соглашаетесь с %1$@.", rules: "Правилами ANTINTWRK") { }
        }
        .frame(width: 300).padding().preferredColorScheme(.dark)
        .previewLayout(.sizeThatFits)
    }
}
