// SimpleScripture About and acknowledgements.
// Extracted and redesigned from PocketSword's supporting views, 5 October 2026.
// Distributed under GNU GPL version 2; original notices are retained in Notices.

import SwiftUI
import UIKit

struct AboutInformation: Equatable {
    static let appName = "SimpleScripture"
    static let projectURL = URL(string: "https://github.com/timTam97/pocketsword")!

    let version: String
    let build: String
    let feedbackURL: URL

    static func current() -> AboutInformation {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? ""
        let device = UIDevice.current
        var components = URLComponents(
            url: projectURL.appendingPathComponent("issues/new"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "title", value: "\(appName) feedback"),
            URLQueryItem(
                name: "body",
                value: "\(appName) \(version) (\(build))\n"
                    + "\(device.systemName) \(device.systemVersion)\n\n"
            ),
        ]
        return AboutInformation(
            version: version,
            build: build,
            feedbackURL: components.url!
        )
    }
}

/// A notice is tied to the exact bundled component, not the latest upstream release.
struct AboutNotice: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let resource: String
    var version: String? = nil
    var subdirectory: String? = "Notices"

    func text(bundle: Bundle = .main) throws -> String {
        guard let url = bundle.url(
            forResource: resource, withExtension: "txt", subdirectory: subdirectory
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let application = AboutNotice(
        id: "application", title: "AboutUpstreamTitle",
        subtitle: "AboutUpstreamSubtitle", resource: "Application"
    )
    static let gpl = AboutNotice(
        id: "gpl", title: "AboutGPLTitle", subtitle: "AboutGPLSubtitle",
        resource: "LICENSE", subdirectory: nil
    )
    static let creativeCommons = AboutNotice(
        id: "cc-by-sa", title: "AboutCCTitle", subtitle: "AboutCCSubtitle",
        resource: "CC-BY-SA-3.0"
    )
    static let modules: [AboutNotice] = [
        AboutNotice(
            id: "KJV", title: "AboutKJVTitle", subtitle: "AboutKJVSubtitle",
            resource: "KJV", version: "2.9"
        ),
        AboutNotice(
            id: "MHCC", title: "AboutMHCCTitle", subtitle: "AboutPublicDomain",
            resource: "MHCC", version: "1.1"
        ),
        AboutNotice(
            id: "StrongsRealGreek", title: "AboutGreekTitle", subtitle: "AboutPublicDomain",
            resource: "StrongsRealGreek", version: "1.5-150704"
        ),
        AboutNotice(
            id: "StrongsRealHebrew", title: "AboutHebrewTitle", subtitle: "AboutPublicDomain",
            resource: "StrongsRealHebrew", version: "1.090107"
        ),
        AboutNotice(
            id: "Robinson", title: "AboutRobinsonTitle", subtitle: "AboutCCSubtitle",
            resource: "Robinson", version: "2.0"
        ),
    ]
    static let fonts: [AboutNotice] = [
        AboutNotice(
            id: "gentium", title: "AboutGentiumTitle", subtitle: "AboutOFLSubtitle",
            resource: "GentiumPlus", version: "1.510"
        ),
        AboutNotice(
            id: "ezra", title: "AboutEzraTitle", subtitle: "AboutEzraSubtitle",
            resource: "EzraSIL", version: "2.51"
        ),
    ]
    static let all = [application, gpl, creativeCommons] + modules + fonts
}

struct AboutView: View {
    let information: AboutInformation

    var body: some View {
        List {
            AboutHeader(version: information.version, build: information.build)
            AboutProjectSection(feedbackURL: information.feedbackURL)
            AboutHeritageSection()
        }
        .listStyle(.insetGrouped)
        .tint(Color("AboutAccent"))
    }
}

private struct AboutHeader: View {
    let version: String
    let build: String

    var body: some View {
        VStack(spacing: 12) {
            Image("SimpleScriptureAbout")
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
                .padding(.bottom, 8)
            Text(verbatim: AboutInformation.appName)
                .font(.largeTitle.weight(.semibold))
            Text("AboutTagline")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Version \(version) (\(build))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("about.header")
    }
}

private struct AboutProjectSection: View {
    let feedbackURL: URL

    var body: some View {
        Section {
            NavigationLink {
                AboutAcknowledgementsView()
            } label: {
                Label("AboutAcknowledgementsTitle", systemImage: "text.book.closed")
            }
            .accessibilityIdentifier("about.acknowledgements")
            Link(destination: AboutInformation.projectURL) {
                Label {
                    Text("AboutProjectSourceLink")
                        .foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
            }
            .accessibilityIdentifier("about.source")
            Link(destination: feedbackURL) {
                Label {
                    Text("AboutReportIssueLink")
                        .foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: "bubble.left")
                }
            }
            .accessibilityIdentifier("about.feedback")
        }
    }
}

private struct AboutHeritageSection: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("AboutHeritageTitle")
                    .font(.headline)
                Text("AboutHeritageText")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.vertical, 4)
        }
    }
}

private struct AboutAcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                AboutNoticeRow(notice: .application)
                AboutNoticeRow(notice: .gpl)
            } header: {
                Text("AboutApplicationSection")
            }
            AboutComponentSection(title: "AboutTextsSection", notices: AboutNotice.modules)
            AboutComponentSection(title: "AboutFontsSection", notices: AboutNotice.fonts)
            Section {
                AboutNoticeRow(notice: .creativeCommons)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AboutAcknowledgementsTitle")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color("AboutAccent"))
        .accessibilityIdentifier("about.notices")
    }
}

private struct AboutComponentSection: View {
    let title: LocalizedStringResource
    let notices: [AboutNotice]

    var body: some View {
        Section {
            ForEach(notices) { notice in
                AboutNoticeRow(notice: notice)
            }
        } header: {
            Text(title)
        }
    }
}

private struct AboutNoticeRow: View {
    let notice: AboutNotice

    var body: some View {
        NavigationLink {
            AboutNoticeView(notice: notice)
        } label: {
            Text(notice.title)
                .foregroundStyle(.primary)
                .padding(.vertical, 3)
        }
        .accessibilityIdentifier("about.notice.\(notice.id)")
    }
}

private struct AboutNoticeParagraph: Identifiable, Sendable {
    // Stable within an immutable document; paragraphs are never reordered or edited.
    let id: Int
    let text: String
}

private struct AboutNoticeView: View {
    let notice: AboutNotice
    @State private var paragraphs: [AboutNoticeParagraph] = []
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(notice.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let version = notice.version {
                    Text("About component version \(version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if failed {
                    ContentUnavailableView(
                        "AboutNoticeUnavailable",
                        systemImage: "doc.text",
                        description: Text("AboutNoticeUnavailableMessage")
                    )
                } else if paragraphs.isEmpty {
                    ProgressView()
                } else {
                    ForEach(paragraphs) { paragraph in
                        Text(paragraph.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if notice.id == "Robinson" {
                        NavigationLink {
                            AboutNoticeView(notice: .creativeCommons)
                        } label: {
                            Label("AboutReadCCLicense", systemImage: "doc.text")
                        }
                        .accessibilityIdentifier("about.robinson.license")
                    }
                }
            }
            .font(.body)
            .textSelection(.enabled)
            .lineSpacing(3)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(notice.title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color("AboutAccent"))
        .accessibilityIdentifier("about.document.\(notice.id)")
        .task(id: notice.id) {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try notice.text()
                }.value
                paragraphs = text.split(separator: "\n\n").map { paragraph in
                    // These plain-text licenses contain fixed-column line wraps.
                    // Reflow display whitespace to the available width; keep the
                    // bundled originals and every word of their notices intact.
                    let displayText = notice.id == "gpl" || notice.id == "cc-by-sa"
                        ? paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        : String(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
                    return AboutNoticeParagraph(
                        id: paragraph.startIndex.utf16Offset(in: text),
                        text: displayText
                    )
                }
            } catch {
                failed = true
            }
        }
    }
}
