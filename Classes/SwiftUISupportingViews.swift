import SwiftUI
import UIKit
import Observation

struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            // Match LaunchScreen.storyboard so the system-to-app handoff keeps
            // the artwork and name in the same place.
            VStack(spacing: 24) {
                Image("LaunchIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)
                Text(verbatim: AboutInformation.appName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(22.0 / 28.0)
                    .frame(height: 34)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .accessibilityIdentifier("launch.brand")
        }
        .overlay(alignment: .bottom) {
            ProgressView()
                .tint(Color("AboutAccent"))
                .padding(.bottom, 32)
                .accessibilityLabel(Text("LaunchProgressLabel"))
                .accessibilityIdentifier("launch.progress")
        }
    }
}

#Preview("Launch — Light") {
    LaunchView()
        .preferredColorScheme(.light)
}

#Preview("Launch — Dark") {
    LaunchView()
        .preferredColorScheme(.dark)
}

#Preview("System Launch Screen") {
    UIStoryboard(name: "LaunchScreen", bundle: .main)
        .instantiateInitialViewController()!
}

struct ReferencePickerBook: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let shortName: String
    let verseCounts: [Int]

    init(
        id: String,
        name: String,
        shortName: String,
        verseCounts: [Int]
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.verseCounts = verseCounts
    }

    init(_ book: PSVersificationBook) {
        self.init(
            id: book.osisName,
            name: book.name,
            shortName: book.shortName,
            verseCounts: book.verseMax
        )
    }

    var chapterCount: Int {
        verseCounts.count
    }

    func verseCount(chapter: Int) -> Int {
        guard verseCounts.indices.contains(chapter - 1) else { return 0 }
        return verseCounts[chapter - 1]
    }
}

struct ReferencePickerSelection: Equatable {
    let bookName: String
    let chapter: Int
    let verse: Int
}

struct ReferencePickerIndexEntry: Identifiable, Equatable {
    var id: String { shortName }

    let shortName: String
    let bookID: String
}

enum ReferencePickerDestination: Hashable {
    case chapters(bookID: String)
    case verses(bookID: String, chapter: Int)
}

@MainActor
@Observable
final class ReferencePickerModel {
    var books: [ReferencePickerBook]
    var indexEntries: [ReferencePickerIndexEntry]
    var currentBookID: String?
    var currentChapter: Int?
    var path: [ReferencePickerDestination] = []
    var showsCancel: Bool

    @ObservationIgnored var onSelection: ((ReferencePickerSelection) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    init(
        books: [ReferencePickerBook] = [],
        currentReference: String? = nil,
        showsCancel: Bool = false
    ) {
        self.books = books
        self.indexEntries = Self.makeIndexEntries(books: books)
        self.showsCancel = showsCancel
        updateCurrentReference(currentReference)
    }

    func updateCurrentReference(_ reference: String?) {
        guard let chapterReference = reference?
            .components(separatedBy: ":")
            .first,
              let separator = chapterReference.range(
                of: " ",
                options: .backwards
              ),
              let chapter = Int(chapterReference[separator.upperBound...]) else {
            currentBookID = nil
            currentChapter = nil
            return
        }

        let bookName = String(chapterReference[..<separator.lowerBound])
        currentBookID = books.first { $0.name == bookName }?.id
        currentChapter = currentBookID == nil ? nil : chapter
    }

    func book(id: String) -> ReferencePickerBook? {
        books.first { $0.id == id }
    }

    func openChapters(for bookID: String) {
        guard book(id: bookID) != nil else { return }
        path.append(.chapters(bookID: bookID))
    }

    func openVerses(for bookID: String, chapter: Int) {
        // `(1...n).contains(x)` is a TRAP when `n` is 0: the `...` operator
        // precondition-fails ("Can't form Range with upperBound < lowerBound")
        // while FORMING the range, before `contains` is ever called — and both
        // `chapterCount` and `verseCount(chapter:)` return 0 for a book/chapter
        // the versification does not have. The bounds are therefore compared
        // directly here and in `select`, which is identical for every non-empty
        // book.
        guard let book = book(id: bookID),
              chapter >= 1,
              chapter <= book.chapterCount else {
            return
        }
        path.append(.verses(bookID: bookID, chapter: chapter))
    }

    func select(bookID: String, chapter: Int, verse: Int) {
        guard let book = book(id: bookID),
              chapter >= 1,
              chapter <= book.chapterCount,
              verse >= 1,
              verse <= book.verseCount(chapter: chapter) else {
            return
        }
        onSelection?(
            ReferencePickerSelection(
                bookName: book.name,
                chapter: chapter,
                verse: verse
            )
        )
    }

    func cancel() {
        onCancel?()
    }

    private static func makeIndexEntries(
        books: [ReferencePickerBook]
    ) -> [ReferencePickerIndexEntry] {
        var seen: Set<String> = []
        return books.compactMap { book in
            guard seen.insert(book.shortName).inserted else { return nil }
            return ReferencePickerIndexEntry(
                shortName: book.shortName,
                bookID: book.id
            )
        }
    }
}

struct ReferencePickerView: View {
    @State private var model: ReferencePickerModel

    init(model: ReferencePickerModel) {
        // Keep the navigation path when the presentation is rebuilt on rotation.
        self.model = model
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack(path: $model.path) {
            ReferenceBookList(model: model)
                .navigationDestination(
                    for: ReferencePickerDestination.self
                ) { destination in
                    switch destination {
                    case .chapters(let bookID):
                        if let book = model.book(id: bookID) {
                            ReferenceChapterList(model: model, book: book)
                        }
                    case .verses(let bookID, let chapter):
                        if let book = model.book(id: bookID) {
                            ReferenceVerseList(
                                model: model,
                                book: book,
                                chapter: chapter
                            )
                        }
                    }
                }
        }
    }
}

private struct ReferenceBookList: View {
    let model: ReferencePickerModel

    var body: some View {
        ScrollViewReader { proxy in
            List(model.books) { book in
                ReferenceBookRow(
                    id: book.id,
                    name: book.name,
                    isCurrent: model.currentBookID == book.id,
                    open: { model.openChapters(for: book.id) },
                    jumpToStart: {
                        model.select(bookID: book.id, chapter: 1, verse: 1)
                    }
                )
                .id(book.id)
            }
            .task(id: model.currentBookID) {
                await Task.yield()
                if let currentBookID = model.currentBookID {
                    proxy.scrollTo(currentBookID, anchor: .center)
                }
            }
            .contentMargins(.trailing, 32, for: .scrollContent)
            .overlay(alignment: .trailing) {
                ReferenceBookIndex(entries: model.indexEntries) { bookID in
                    proxy.scrollTo(bookID, anchor: .center)
                }
            }
        }
        .navigationTitle("RefSelectorBookTitle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.showsCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        model.cancel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Cancel"))
                    .help("Cancel")
                }
            }
        }
    }
}

private struct ReferenceBookIndex: View {
    let entries: [ReferencePickerIndexEntry]
    let scrollTo: (String) -> Void

    @State private var lastBookID: String?

    var body: some View {
        GeometryReader { geometry in
            let rowHeight = max(
                geometry.size.height / CGFloat(max(entries.count, 1)),
                0.1
            )

            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    Text(entry.shortName)
                        .font(.caption2)
                        .minimumScaleFactor(0.45)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: rowHeight)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = min(
                            max(Int(value.location.y / rowHeight), 0),
                            entries.count - 1
                        )
                        guard entries.indices.contains(index) else { return }
                        let bookID = entries[index].bookID
                        guard bookID != lastBookID else { return }
                        lastBookID = bookID
                        scrollTo(bookID)
                    }
                    .onEnded { _ in
                        lastBookID = nil
                    }
            )
        }
        .frame(width: 32)
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}

private struct ReferenceBookRow: View {
    let id: String
    let name: String
    let isCurrent: Bool
    let open: () -> Void
    let jumpToStart: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Text(name)
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    Spacer()
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reference.book.\(id)")

            Button(action: jumpToStart) {
                Text(verbatim: "1:1")
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("\(name) 1:1"))
            .accessibilityIdentifier("reference.book-start.\(id)")
        }
    }
}

private struct ReferenceChapterList: View {
    let model: ReferencePickerModel
    let book: ReferencePickerBook

    var body: some View {
        ReferenceNumberList(
            count: book.chapterCount,
            indexLabel: "RefSelectorChapterIndexLabel",
            indexIdentifier: "reference.chapter-index"
        ) { chapter in
            ReferenceChapterRow(
                bookID: book.id,
                chapter: chapter,
                title: ReferencePickerText.chapter(chapter),
                isCurrent: model.currentBookID == book.id
                    && model.currentChapter == chapter,
                open: {
                    model.openVerses(
                        for: book.id,
                        chapter: chapter
                    )
                },
                jumpToStart: {
                    model.select(
                        bookID: book.id,
                        chapter: chapter,
                        verse: 1
                    )
                }
            )
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReferenceChapterRow: View {
    let bookID: String
    let chapter: Int
    let title: String
    let isCurrent: Bool
    let open: () -> Void
    let jumpToStart: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Text(title)
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    Spacer()
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reference.chapter.\(chapter)")

            Button(action: jumpToStart) {
                Text(verbatim: "\(chapter):1")
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("\(title), verse 1"))
            .accessibilityIdentifier(
                "reference.chapter-start.\(bookID).\(chapter)"
            )
        }
    }
}

private struct ReferenceVerseList: View {
    let model: ReferencePickerModel
    let book: ReferencePickerBook
    let chapter: Int

    var body: some View {
        ReferenceNumberList(
            count: book.verseCount(chapter: chapter),
            indexLabel: "RefSelectorVerseIndexLabel",
            indexIdentifier: "reference.verse-index"
        ) { verse in
            Button {
                model.select(
                    bookID: book.id,
                    chapter: chapter,
                    verse: verse
                )
            } label: {
                Text(ReferencePickerText.verse(verse))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reference.verse.\(verse)")
        }
        .navigationTitle("\(book.name) \(chapter)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReferenceNumberList<Row: View>: View {
    let count: Int
    let indexLabel: LocalizedStringKey
    let indexIdentifier: String
    @ViewBuilder let row: (Int) -> Row

    @State private var showsIndex = false

    var body: some View {
        ScrollViewReader { proxy in
            // Half-open so an empty versification produces an empty list.
            List(1..<(max(count, 0) + 1), id: \.self) { number in
                row(number)
                    .id(number)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleHeight = geometry.containerSize.height
                    - geometry.contentInsets.top
                    - geometry.contentInsets.bottom
                return visibleHeight > 0
                    && geometry.contentSize.height > visibleHeight + 1
            } action: { _, overflows in
                showsIndex = overflows
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if showsIndex && count > 1 {
                    ReferenceNumberIndex(
                        count: count,
                        label: indexLabel,
                        identifier: indexIdentifier
                    ) { number in
                        proxy.scrollTo(number, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct ReferenceNumberIndex: View {
    let count: Int
    let label: LocalizedStringKey
    let identifier: String
    let scrollTo: (Int) -> Void

    @ScaledMetric(relativeTo: .caption2) private var minimumLabelHeight = 16
    @State private var lastDraggedNumber: Int?
    @State private var selectedNumber = 1

    var body: some View {
        GeometryReader { geometry in
            let labelCount = min(
                count,
                max(Int(geometry.size.height / minimumLabelHeight), 2)
            )
            let labelHeight = geometry.size.height / CGFloat(labelCount)
            let travelHeight = max(geometry.size.height - labelHeight, 1)
            let labels = (0..<labelCount).map { index in
                1 + Int(
                    (Double(index) * Double(count - 1)
                        / Double(labelCount - 1)).rounded()
                )
            }

            VStack(spacing: 0) {
                ForEach(labels, id: \.self) { number in
                    Text(number, format: .number.grouping(.never))
                        .font(.caption2)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: labelHeight)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Label centers and drag positions use the same scale.
                        // Even when labels are sampled, every number is reachable.
                        let fraction = min(
                            max((value.location.y - labelHeight / 2) / travelHeight, 0),
                            1
                        )
                        let number = 1 + Int(
                            (fraction * CGFloat(count - 1)).rounded()
                        )
                        guard number != lastDraggedNumber else { return }
                        lastDraggedNumber = number
                        selectedNumber = number
                        scrollTo(number)
                    }
                    .onEnded { _ in
                        lastDraggedNumber = nil
                    }
            )
        }
        .frame(width: 32)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(selectedNumber, format: .number))
        .accessibilityIdentifier(identifier)
        .accessibilityAdjustableAction { direction in
            let number: Int
            switch direction {
            case .increment:
                number = min(selectedNumber + 1, count)
            case .decrement:
                number = max(selectedNumber - 1, 1)
            @unknown default:
                return
            }
            selectedNumber = number
            scrollTo(number)
        }
    }
}

private enum ReferencePickerText {
    static func chapter(_ chapter: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "RefSelectorChapterTitle"),
            chapter
        )
    }

    static func verse(_ verse: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "RefSelectorVerseTitle"),
            verse
        )
    }
}

enum StudyFonts {
    static let all = [
        "American Typewriter",
        "Arial",
        "Courier",
        "Helvetica Neue",
        "HelveticaNeue-Light",
        "Times New Roman",
        "Gentium Plus",
        "Ezra SIL",
        "AppleGothic",
        "Arial Hebrew",
        "Arial Rounded MT Bold",
        "Arial Unicode MS",
        "Bangla Sangam MN",
        "Bodoni 72",
        "Cochin",
        "Courier New",
        "Damascus",
        "Devanagari Sangam MN",
        "Geeza Pro",
        "Georgia",
        "Gill Sans",
        "Gurmukhi MN",
        "Gujarati Sangam MN",
        "Heiti J",
        "Heiti K",
        "Heiti SC",
        "Heiti TC",
        "Helvetica",
        "Hiragino Kaku Gothic ProN",
        "Hoefler Text",
        "Kailasa",
        "Kannada Sangam MN",
        "Malayalam Sangam MN",
        "Marion",
        "Menlo",
        "Optima",
        "Oriya Sangam MN",
        "Sinhala Sangam MN",
        "Tamil Sangam MN",
        "Telugu Sangam MN",
        "Thonburi",
        "Trebuchet MS",
        "Verdana",
    ]
}

struct SettingsView: View {
    let settings: SettingsModel
    let maximumFontSize: Double

    @State private var showingFontPicker = false
    @State private var currentOrientation = RotationLock.portrait

    var body: some View {
        List {
            ReadingSettingsSection(
                settings: settings,
                maximumFontSize: maximumFontSize,
                showFontPicker: { showingFontPicker = true }
            )
            DeviceSettingsSection(
                settings: settings,
                currentOrientation: currentOrientation
            )
        }
        .background {
            SceneOrientationReader { interfaceOrientation in
                let orientation = RotationLock(
                    interfaceOrientation: interfaceOrientation
                )
                guard orientation != currentOrientation else { return }
                currentOrientation = orientation
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showingFontPicker) {
            NavigationStack {
                FontPickerView(settings: settings)
            }
        }
    }
}

private struct SceneOrientationReader: UIViewRepresentable {
    let onChange: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> SceneOrientationView {
        let view = SceneOrientationView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: SceneOrientationView, context: Context) {
        uiView.onChange = onChange
        uiView.reportOrientation()
    }
}

private final class SceneOrientationView: UIView {
    var onChange: ((UIInterfaceOrientation) -> Void)?

    private var lastOrientation: UIInterfaceOrientation?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportOrientation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportOrientation()
    }

    func reportOrientation() {
        guard let orientation = window?.windowScene?
            .effectiveGeometry.interfaceOrientation,
              orientation != .unknown,
              orientation != lastOrientation else {
            return
        }
        lastOrientation = orientation
        onChange?(orientation)
    }
}

private struct ReadingSettingsSection: View {
    let settings: SettingsModel
    let maximumFontSize: Double
    let showFontPicker: () -> Void

    var body: some View {
        Section("PreferencesDisplayPreferencesTitle") {
            ReadingPreviewRow(settings: settings)
            FontSizeControl(
                settings: settings,
                maximumFontSize: maximumFontSize
            )
            FontSelectionButton(
                fontName: settings.fontName,
                action: showFontPicker
            )
        }
    }
}

private struct ReadingPreviewRow: View {
    let settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SettingsReadingPreview")
                .font(
                    .custom(
                        settings.fontName,
                        size: CGFloat(settings.fontSize),
                        relativeTo: .body
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
            Text("SettingsReadingPreviewReference")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct FontSizeControl: View {
    let settings: SettingsModel
    let maximumFontSize: Double

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SettingsIconLabel(
                    title: "PreferencesFontSizeTitle",
                    systemImage: "textformat.size",
                    tint: .blue
                )
                Spacer()
                Text(settings.fontSize, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 12) {
                Text("A")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(
                    value: $settings.fontSizeValue,
                    in: 10...maximumFontSize,
                    step: 1
                )
                .accessibilityIdentifier("settings.font-size")
                .accessibilityLabel(Text("PreferencesFontSizeTitle"))
                .accessibilityValue(Text(settings.fontSize, format: .number))
                Text("A")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FontSelectionButton: View {
    let fontName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsIconLabel(
                    title: "PreferencesFontTitle",
                    systemImage: "character.cursor.ibeam",
                    tint: .purple
                )
                Spacer()
                Text(fontName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.font")
    }
}

private struct DeviceSettingsSection: View {
    let settings: SettingsModel
    let currentOrientation: RotationLock

    var body: some View {
        @Bindable var settings = settings

        Section {
            Toggle(
                isOn: $settings.keepScreenAwake,
                label: {
                    SettingsIconLabel(
                        title: "PreferencesDisableAutoLockTitle",
                        systemImage: "sun.max.fill",
                        tint: .orange
                    )
                }
            )
            .accessibilityIdentifier("settings.keep-awake")
            Toggle(
                isOn: $settings[
                    rotationLockedFor: currentOrientation
                ],
                label: {
                    SettingsIconLabel(
                        title: "PreferencesRotationLock",
                        systemImage: "lock.rotation",
                        tint: .teal
                    )
                }
            )
            .accessibilityIdentifier("settings.rotation-lock")
        } header: {
            Text("PreferencesDevicePreferencesTitle")
        }
    }
}

private struct SettingsIconLabel: View {
    let title: LocalizedStringResource
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 24)
        }
    }
}

struct FontPickerView: View {
    let settings: SettingsModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(StudyFonts.all, id: \.self) { fontName in
            FontPickerRow(
                fontName: fontName,
                isSelected: fontName == settings.fontName,
                select: {
                    settings.fontName = fontName
                    dismiss()
                }
            )
        }
        .navigationTitle("FontPreferenceTitle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(Text("CloseButtonTitle"))
                .help("CloseButtonTitle")
            }
        }
    }
}

private struct FontPickerRow: View {
    let fontName: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                Text(fontName)
                    .font(.custom(fontName, size: 17, relativeTo: .body))
                    .foregroundStyle(.primary)
                Spacer()
                ZStack {
                    Color.clear
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(fontName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
