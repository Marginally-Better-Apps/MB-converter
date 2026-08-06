import MapKit
import SwiftUI
import UIKit

struct InputMetadataEditor: View {
    @Bindable var viewModel: OutputConfigViewModel
    let isMenuInteractionDisabled: Bool
    @State private var expandedGroups: Set<MetadataFieldGroup.Kind> = []
    @FocusState private var focusedMetadataRowID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Text("Metadata")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Spacer()
                CheckboxControl(
                    title: "Remove all",
                    isChecked: $viewModel.removeAllMetadata,
                    font: .subheadline.weight(.medium)
                )
            }
            .onChange(of: viewModel.removeAllMetadata) { _, isRemovingAll in
                if !isRemovingAll, viewModel.metadataFieldRows.isEmpty, !viewModel.discoveredMetadataTags.isEmpty {
                    viewModel.resetMetadataRowsFromDiscovery()
                }
                if isRemovingAll {
                    viewModel.isMetadataSectionExpanded = false
                    focusedMetadataRowID = nil
                    dismissKeyboard()
                }
            }

            DisclosureGroup(isExpanded: $viewModel.isMetadataSectionExpanded) {
                metadataBody
            } label: {
                HStack(spacing: 8) {
                    Text("Fields")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                    Text(fieldCountText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.background.opacity(0.5))
                        .clipShape(Capsule())
                }
            }
            .tint(Theme.primary)
        }
        .onChange(of: viewModel.isMetadataSectionExpanded) { _, isExpanded in
            if !isExpanded {
                expandedGroups.removeAll()
                focusedMetadataRowID = nil
            }
            dismissKeyboard()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.accent, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var metadataBody: some View {
        if viewModel.isLoadingDiscoveredMetadata {
            HStack {
                ProgressView()
                Text("Reading metadata…")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groupedRows) { group in
                    MetadataSectionDisclosure(
                        group: group,
                        isExpanded: groupExpansionBinding(for: group.kind),
                        isRemoved: !group.indices.isEmpty && group.indices.allSatisfy { viewModel.metadataFieldRows[$0].isRemoved },
                        onSetSectionRemoved: { shouldRemove in
                            setSection(group, removed: shouldRemove)
                        }
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            if group.kind == .location, let coordinate = locationCoordinateBinding() {
                                MetadataLocationCard(coordinate: coordinate)
                            }

                            if group.indices.isEmpty {
                                Text("No fields in this section yet.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textMuted)
                            } else {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 230), spacing: 10, alignment: .top)],
                                    alignment: .leading,
                                    spacing: 10
                                ) {
                                    ForEach(group.indices, id: \.self) { index in
                                        MetadataFieldCard(
                                            row: $viewModel.metadataFieldRows[index],
                                            focusedRowID: $focusedMetadataRowID,
                                            onUserEdit: userEditedField
                                        )
                                    }
                                }
                            }

                            AddMetadataFieldMenu(
                                items: missingTemplates(for: group.kind),
                                isInteractionDisabled: isMenuInteractionDisabled,
                                onAdd: addMetadataField
                            )
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var groupedRows: [MetadataFieldGroup] {
        let groups = Dictionary(grouping: viewModel.metadataFieldRows.indices) { index in
            MetadataFieldGroup.Kind(row: viewModel.metadataFieldRows[index])
        }

        let displayOrder: [MetadataFieldGroup.Kind] = viewModel.input.category == .image
            ? [.location, .camera, .capture, .file, .other]
            : MetadataFieldGroup.Kind.displayOrder
        return displayOrder.map { kind in
            let indices = groups[kind] ?? []
            return MetadataFieldGroup(
                kind: kind,
                indices: indices.sorted { lhs, rhs in
                    viewModel.metadataFieldRows[lhs].tag.label.localizedCaseInsensitiveCompare(
                        viewModel.metadataFieldRows[rhs].tag.label
                    ) == .orderedAscending
                }
            )
        }
    }

    private var fieldCountText: String {
        return "\(viewModel.metadataFieldRows.count)"
    }

    private func missingTemplates(for kind: MetadataFieldGroup.Kind) -> [AddableMetadataField] {
        switch viewModel.input.category {
        case .image:
            let existing = Set(viewModel.metadataFieldRows.map(StandardImageMetadataCatalog.matchID(for:)))
            return StandardImageMetadataCatalog.templates(for: kind)
                .filter { !existing.contains($0.matchID) }
                .map { .image($0) }
        case .video, .audio, .animatedImage:
            return missingFfprobeFieldTemplates(for: kind)
        default:
            return []
        }
    }

    private func missingFfprobeFieldTemplates(for kind: MetadataFieldGroup.Kind) -> [AddableMetadataField] {
        StandardVideoMetadataCatalog.templates(for: kind).compactMap { template in
            if videoFieldAlreadyExists(template) { return nil }
            return .video(template)
        }
    }

    private func videoFieldAlreadyExists(_ template: VideoMetadataFieldTemplate) -> Bool {
        viewModel.metadataFieldRows.contains { videoTemplate($0, matches: template) }
    }

    private func videoTemplate(_ row: MetadataFieldRowModel, matches template: VideoMetadataFieldTemplate) -> Bool {
        let keyMatches = row.tag.tagKey.compare(template.tagKey, options: .caseInsensitive) == .orderedSame
        if !keyMatches { return false }
        switch template.target {
        case .format:
            return row.tag.kind == .ffprobeFormat
        case .firstStream(let mediaType):
            guard case .ffprobeStream = row.tag.kind else { return false }
            return row.tag.ffprobeStreamType == mediaType
        }
    }

    private func firstFfprobeStreamIndex(matching mediaType: String) -> Int? {
        for tag in viewModel.discoveredMetadataTags {
            guard tag.ffprobeStreamType == mediaType, case .ffprobeStream(let index) = tag.kind else { continue }
            return index
        }
        for row in viewModel.metadataFieldRows {
            guard row.tag.ffprobeStreamType == mediaType, case .ffprobeStream(let index) = row.tag.kind else { continue }
            return index
        }
        return nil
    }

    private func addMetadataField(_ item: AddableMetadataField) {
        userEditedField()
        switch item {
        case .image(let template):
            if !expandedGroups.contains(template.group) {
                expandedGroups.insert(template.group)
            }
            let row = MetadataFieldRowModel(tag: template.makeTag())
            viewModel.metadataFieldRows.append(row)
            DispatchQueue.main.async {
                focusedMetadataRowID = row.id
            }
        case .video(let template):
            if !expandedGroups.contains(template.group) {
                expandedGroups.insert(template.group)
            }
            let tag = template.makeTag { self.firstFfprobeStreamIndex(matching: $0) }
            let row = MetadataFieldRowModel(tag: tag)
            viewModel.metadataFieldRows.append(row)
            DispatchQueue.main.async {
                focusedMetadataRowID = row.id
            }
        }
    }

    private func userEditedField() {
        if viewModel.removeAllMetadata {
            viewModel.removeAllMetadata = false
        }
    }

    private func groupExpansionBinding(for kind: MetadataFieldGroup.Kind) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(kind) },
            set: { isExpanded in
                if isExpanded {
                    expandedGroups.insert(kind)
                } else {
                    expandedGroups.remove(kind)
                }
                focusedMetadataRowID = nil
                dismissKeyboard()
            }
        )
    }

    private func setSection(_ group: MetadataFieldGroup, removed: Bool) {
        userEditedField()
        for index in group.indices {
            viewModel.metadataFieldRows[index].isRemoved = removed
        }
    }

    private func locationCoordinateBinding() -> Binding<CLLocationCoordinate2D>? {
        guard let fallback = MetadataLocationResolver.coordinate(from: viewModel.metadataFieldRows) else {
            return nil
        }
        return Binding(
            get: {
                MetadataLocationResolver.coordinate(from: viewModel.metadataFieldRows) ?? fallback
            },
            set: { newValue in
                updateLocationRows(to: newValue)
            }
        )
    }

    private func updateLocationRows(to coordinate: CLLocationCoordinate2D) {
        userEditedField()
        let isoValue = MetadataLocationResolver.iso6709String(for: coordinate)
        if let index = viewModel.metadataFieldRows.firstIndex(where: MetadataLocationResolver.isISO6709Row) {
            viewModel.metadataFieldRows[index].value = isoValue
            viewModel.metadataFieldRows[index].isRemoved = false
            return
        }

        for index in viewModel.metadataFieldRows.indices {
            if MetadataLocationResolver.isLatitudeRow(viewModel.metadataFieldRows[index]) {
                viewModel.metadataFieldRows[index].value = String(format: "%.6f", abs(coordinate.latitude))
                viewModel.metadataFieldRows[index].isRemoved = false
            } else if MetadataLocationResolver.isLongitudeRow(viewModel.metadataFieldRows[index]) {
                viewModel.metadataFieldRows[index].value = String(format: "%.6f", abs(coordinate.longitude))
                viewModel.metadataFieldRows[index].isRemoved = false
            } else if MetadataLocationResolver.isLatitudeRefRow(viewModel.metadataFieldRows[index]) {
                viewModel.metadataFieldRows[index].value = coordinate.latitude < 0 ? "S" : "N"
                viewModel.metadataFieldRows[index].isRemoved = false
            } else if MetadataLocationResolver.isLongitudeRefRow(viewModel.metadataFieldRows[index]) {
                viewModel.metadataFieldRows[index].value = coordinate.longitude < 0 ? "W" : "E"
                viewModel.metadataFieldRows[index].isRemoved = false
            }
        }
    }
}

private struct MetadataFieldGroup: Identifiable {
    let kind: Kind
    let indices: [Int]

    var id: Kind { kind }
    var title: String { kind.title }
    var systemImage: String { kind.systemImage }

    enum Kind: CaseIterable, Hashable {
        case location
        case camera
        case capture
        case file
        case stream
        case other

        static let displayOrder: [Kind] = [.location, .camera, .capture, .file, .stream, .other]

        init(row: MetadataFieldRowModel) {
            let key = (row.tag.tagKey + " " + row.tag.label).lowercased()
            if key.contains("gps") || key.contains("location") || key.contains("latitude") || key.contains("longitude") {
                self = .location
            } else if key.contains("make") || key.contains("model") || key.contains("lens") || key.contains("camera") {
                self = .camera
            } else if key.contains("date") || key.contains("time") || key.contains("iso") || key.contains("exposure")
                        || key.contains("fnumber") || key.contains("aperture") || key.contains("focal") {
                self = .capture
            } else if key.contains("filename") || key.contains("format") || key.contains("software") || key.contains("title")
                        || key.contains("artist") || key.contains("copyright") || key.contains("description") {
                self = .file
            } else if case .ffprobeStream = row.tag.kind {
                self = .stream
            } else {
                self = .other
            }
        }

        var title: String {
            switch self {
            case .location: "Location"
            case .camera: "Camera"
            case .capture: "Capture"
            case .file: "File"
            case .stream: "Streams"
            case .other: "Other"
            }
        }

        var systemImage: String {
            switch self {
            case .location: "map"
            case .camera: "camera"
            case .capture: "camera.aperture"
            case .file: "doc.text"
            case .stream: "waveform"
            case .other: "tag"
            }
        }
    }
}

private struct MetadataSectionDisclosure<Content: View>: View {
    let group: MetadataFieldGroup
    @Binding var isExpanded: Bool
    let isRemoved: Bool
    let onSetSectionRemoved: (Bool) -> Void
    let content: Content

    init(
        group: MetadataFieldGroup,
        isExpanded: Binding<Bool>,
        isRemoved: Bool,
        onSetSectionRemoved: @escaping (Bool) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.group = group
        self._isExpanded = isExpanded
        self.isRemoved = isRemoved
        self.onSetSectionRemoved = onSetSectionRemoved
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textMuted)
                        Label(group.title, systemImage: group.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        Text("\(group.indices.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                CheckboxControl(
                    title: "Remove section",
                    isChecked: Binding(
                        get: { isRemoved },
                        set: { onSetSectionRemoved($0) }
                    ),
                    font: .caption.weight(.semibold)
                )
            }

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private enum AddableMetadataField: Identifiable, Hashable {
    case image(StandardMetadataFieldTemplate)
    case video(VideoMetadataFieldTemplate)

    var id: String {
        switch self {
        case .image(let t): return "img:\(t.matchID)"
        case .video(let t): return "vid:\(t.templateID)"
        }
    }

    var title: String {
        switch self {
        case .image(let t): return t.title
        case .video(let t): return t.title
        }
    }

    var systemImage: String {
        switch self {
        case .image(let t): return t.systemImage
        case .video(let t): return t.systemImage
        }
    }
}

/// FFmpeg can write these as container format tags or per-stream tags (`-metadata` / `-metadata:s:n:`).
/// See `FFmpegMetadataOptions` and `VideoConverter` / `AudioConverter` encode paths.
private struct VideoMetadataFieldTemplate: Identifiable, Hashable {
    enum Target: Hashable {
        case format
        case firstStream(matchingType: String)
    }

    let title: String
    let group: MetadataFieldGroup.Kind
    let tagKey: String
    let defaultValue: String
    let systemImage: String
    let target: Target

    var id: String { templateID }

    var templateID: String {
        switch target {
        case .format:
            "fmt|\(tagKey.lowercased())"
        case .firstStream(let mediaType):
            "stm|\(mediaType)|\(tagKey.lowercased())"
        }
    }

    func makeTag(firstStreamIndex: (String) -> Int?) -> DiscoveredMetadataTag {
        switch target {
        case .format:
            return DiscoveredMetadataTag(
                id: "add:fmt:\(tagKey)",
                label: tagKey,
                value: defaultValue,
                tagKey: tagKey,
                kind: .ffprobeFormat
            )
        case .firstStream(let mediaType):
            let index = firstStreamIndex(mediaType) ?? (mediaType == "video" ? 0 : 1)
            return DiscoveredMetadataTag(
                id: "add:stm:\(index):\(tagKey)",
                label: "\(mediaType.uppercased()) stream \(index) · \(tagKey)",
                value: defaultValue,
                tagKey: tagKey,
                kind: .ffprobeStream(index: index),
                ffprobeStreamType: mediaType
            )
        }
    }
}

private enum StandardVideoMetadataCatalog {
    /// Curated names commonly accepted by Matroska / MP4 / MOV muxers in FFmpeg. Unknown keys are often ignored.
    static let templates: [VideoMetadataFieldTemplate] = [
        // Location (container)
        .init(title: "Location (ISO6709)", group: .location, tagKey: "com.apple.quicktime.location.ISO6709", defaultValue: "", systemImage: "mappin", target: .format),
        .init(title: "Location", group: .location, tagKey: "location", defaultValue: "", systemImage: "mappin", target: .format),

        // Camera hints sometimes stored in QuickTime/phone exports
        .init(title: "Device Make (container)", group: .camera, tagKey: "com.apple.quicktime.make", defaultValue: "", systemImage: "camera", target: .format),
        .init(title: "Device Model (container)", group: .camera, tagKey: "com.apple.quicktime.model", defaultValue: "", systemImage: "camera", target: .format),
        .init(title: "Lens Model (container)", group: .camera, tagKey: "com.apple.quicktime.lensModel", defaultValue: "", systemImage: "camera.aperture", target: .format),

        // Capture / time (container)
        .init(title: "Creation Time", group: .capture, tagKey: "creation_time", defaultValue: "", systemImage: "clock", target: .format),
        .init(title: "Date", group: .capture, tagKey: "date", defaultValue: "", systemImage: "calendar", target: .format),
        .init(title: "Year", group: .capture, tagKey: "year", defaultValue: "", systemImage: "calendar", target: .format),

        // File / identity (container)
        .init(title: "Title", group: .file, tagKey: "title", defaultValue: "", systemImage: "textformat", target: .format),
        .init(title: "Artist", group: .file, tagKey: "artist", defaultValue: "", systemImage: "person", target: .format),
        .init(title: "Album", group: .file, tagKey: "album", defaultValue: "", systemImage: "opticaldisc", target: .format),
        .init(title: "Album Artist", group: .file, tagKey: "album_artist", defaultValue: "", systemImage: "person.2", target: .format),
        .init(title: "Copyright", group: .file, tagKey: "copyright", defaultValue: "", systemImage: "c.circle", target: .format),
        .init(title: "Description", group: .file, tagKey: "description", defaultValue: "", systemImage: "text.alignleft", target: .format),
        .init(title: "Comment", group: .file, tagKey: "comment", defaultValue: "", systemImage: "text.bubble", target: .format),
        .init(title: "Genre", group: .file, tagKey: "genre", defaultValue: "", systemImage: "theatermasks", target: .format),
        .init(title: "Language (container)", group: .file, tagKey: "language", defaultValue: "", systemImage: "globe", target: .format),
        .init(title: "Encoder", group: .file, tagKey: "encoder", defaultValue: "", systemImage: "wrench", target: .format),
        .init(title: "Handler Name (container)", group: .file, tagKey: "handler_name", defaultValue: "", systemImage: "gearshape", target: .format),
        .init(title: "Major Brand", group: .file, tagKey: "major_brand", defaultValue: "", systemImage: "doc.richtext", target: .format),
        .init(title: "Compatible Brands", group: .file, tagKey: "compatible_brands", defaultValue: "", systemImage: "doc.on.doc", target: .format),
        .init(title: "Minor Version", group: .file, tagKey: "minor_version", defaultValue: "", systemImage: "number", target: .format),
        .init(title: "Encoder Software", group: .file, tagKey: "software", defaultValue: "", systemImage: "app", target: .format),

        // TV / series (container)
        .init(title: "Show", group: .file, tagKey: "show", defaultValue: "", systemImage: "tv", target: .format),
        .init(title: "Network", group: .file, tagKey: "network", defaultValue: "", systemImage: "antenna.radiowaves.left.and.right", target: .format),
        .init(title: "Episode ID", group: .file, tagKey: "episode_id", defaultValue: "", systemImage: "list.number", target: .format),
        .init(title: "Media Type", group: .file, tagKey: "media_type", defaultValue: "", systemImage: "film", target: .format),

        // Other (container)
        .init(title: "Synopsis", group: .other, tagKey: "synopsis", defaultValue: "", systemImage: "text.justify", target: .format),
        .init(title: "Keywords", group: .other, tagKey: "keywords", defaultValue: "", systemImage: "tag", target: .format),
        .init(title: "Sort Title", group: .other, tagKey: "sort_name", defaultValue: "", systemImage: "arrow.up.arrow.down", target: .format),
        .init(title: "Sort Artist", group: .other, tagKey: "sort_artist", defaultValue: "", systemImage: "arrow.up.arrow.down", target: .format),
        .init(title: "Sort Album", group: .other, tagKey: "sort_album", defaultValue: "", systemImage: "arrow.up.arrow.down", target: .format),
        .init(title: "Grouping", group: .other, tagKey: "grouping", defaultValue: "", systemImage: "folder", target: .format),
        .init(title: "Purchase Date", group: .other, tagKey: "purchase_date", defaultValue: "", systemImage: "cart", target: .format),
        .init(title: "Encoded By", group: .other, tagKey: "encoded_by", defaultValue: "", systemImage: "person.crop.circle", target: .format),
        .init(title: "Publisher", group: .other, tagKey: "publisher", defaultValue: "", systemImage: "building.2", target: .format),

        // Per-stream (first video / first audio stream as reported by ffprobe, else index 0 / 1)
        .init(title: "Stream Language (video)", group: .stream, tagKey: "language", defaultValue: "", systemImage: "character.book.closed", target: .firstStream(matchingType: "video")),
        .init(title: "Stream Title (video)", group: .stream, tagKey: "title", defaultValue: "", systemImage: "text.quote", target: .firstStream(matchingType: "video")),
        .init(title: "Handler Name (video)", group: .stream, tagKey: "handler_name", defaultValue: "", systemImage: "gearshape", target: .firstStream(matchingType: "video")),

        .init(title: "Stream Language (audio)", group: .stream, tagKey: "language", defaultValue: "", systemImage: "character.book.closed", target: .firstStream(matchingType: "audio")),
        .init(title: "Stream Title (audio)", group: .stream, tagKey: "title", defaultValue: "", systemImage: "text.quote", target: .firstStream(matchingType: "audio")),
        .init(title: "Handler Name (audio)", group: .stream, tagKey: "handler_name", defaultValue: "", systemImage: "gearshape", target: .firstStream(matchingType: "audio"))
    ]

    static func templates(for group: MetadataFieldGroup.Kind) -> [VideoMetadataFieldTemplate] {
        templates.filter { $0.group == group }
    }
}

private struct AddMetadataFieldMenu: View {
    let items: [AddableMetadataField]
    let isInteractionDisabled: Bool
    let onAdd: (AddableMetadataField) -> Void

    var body: some View {
        Menu {
            if items.isEmpty {
                Text("All standard fields already exist")
            } else {
                ForEach(items) { item in
                    Button {
                        onAdd(item)
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Text("Add field")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.background.opacity(0.6))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .foregroundStyle(items.isEmpty ? Theme.textMuted : Theme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.accent.opacity(0.65), lineWidth: 1)
            )
        }
        .disabled(items.isEmpty || isInteractionDisabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StandardMetadataFieldTemplate: Identifiable, Hashable {
    let title: String
    let group: MetadataFieldGroup.Kind
    let scope: ImageMetadataScope
    let key: String
    let defaultValue: String
    let systemImage: String

    var id: String { matchID }
    var matchID: String { "\(scope.rawValue)|\(key.lowercased())" }

    func makeTag() -> DiscoveredMetadataTag {
        let entry = ImageMetadataEntry(
            scope: scope,
            dictionaryKey: key,
            value: defaultValue,
            imagePropertyKey: matchID
        )
        return DiscoveredMetadataTag(
            id: "add:\(matchID)",
            label: "\(scope.displayName) · \(key)",
            value: defaultValue,
            tagKey: key,
            kind: .image(entry)
        )
    }
}

private enum StandardImageMetadataCatalog {
    /// Common still-image metadata users expect from phone/camera photos:
    /// TIFF identity, EXIF capture settings, GPS, and authoring fields.
    static let templates: [StandardMetadataFieldTemplate] = [
        // Location (8)
        .init(title: "GPS Latitude", group: .location, scope: .gps, key: "Latitude", defaultValue: "", systemImage: "mappin"),
        .init(title: "GPS Latitude Ref", group: .location, scope: .gps, key: "LatitudeRef", defaultValue: "N", systemImage: "mappin"),
        .init(title: "GPS Longitude", group: .location, scope: .gps, key: "Longitude", defaultValue: "", systemImage: "mappin"),
        .init(title: "GPS Longitude Ref", group: .location, scope: .gps, key: "LongitudeRef", defaultValue: "W", systemImage: "mappin"),
        .init(title: "GPS Altitude", group: .location, scope: .gps, key: "Altitude", defaultValue: "", systemImage: "mountain.2"),
        .init(title: "GPS Altitude Ref", group: .location, scope: .gps, key: "AltitudeRef", defaultValue: "0", systemImage: "mountain.2"),
        .init(title: "GPS Date Stamp", group: .location, scope: .gps, key: "DateStamp", defaultValue: "", systemImage: "calendar"),
        .init(title: "GPS Time Stamp", group: .location, scope: .gps, key: "TimeStamp", defaultValue: "", systemImage: "clock"),

        // Camera (6)
        .init(title: "Camera Make", group: .camera, scope: .tiff, key: "Make", defaultValue: "", systemImage: "camera"),
        .init(title: "Camera Model", group: .camera, scope: .tiff, key: "Model", defaultValue: "", systemImage: "camera"),
        .init(title: "Lens Model", group: .camera, scope: .exif, key: "LensModel", defaultValue: "", systemImage: "camera.aperture"),
        .init(title: "Lens Make", group: .camera, scope: .exif, key: "LensMake", defaultValue: "", systemImage: "camera.aperture"),
        .init(title: "Camera Serial Number", group: .camera, scope: .exif, key: "BodySerialNumber", defaultValue: "", systemImage: "number"),
        .init(title: "Lens Serial Number", group: .camera, scope: .exif, key: "LensSerialNumber", defaultValue: "", systemImage: "number"),

        // Capture (17)
        .init(title: "Date Taken", group: .capture, scope: .exif, key: "DateTimeOriginal", defaultValue: "", systemImage: "calendar"),
        .init(title: "Date Digitized", group: .capture, scope: .exif, key: "DateTimeDigitized", defaultValue: "", systemImage: "calendar"),
        .init(title: "Exposure Time", group: .capture, scope: .exif, key: "ExposureTime", defaultValue: "", systemImage: "timer"),
        .init(title: "F Number", group: .capture, scope: .exif, key: "FNumber", defaultValue: "", systemImage: "camera.aperture"),
        .init(title: "ISO Speed", group: .capture, scope: .exif, key: "ISOSpeedRatings", defaultValue: "", systemImage: "dial.low"),
        .init(title: "Focal Length", group: .capture, scope: .exif, key: "FocalLength", defaultValue: "", systemImage: "camera.metering.center.weighted"),
        .init(title: "Exposure Bias", group: .capture, scope: .exif, key: "ExposureBiasValue", defaultValue: "", systemImage: "plusminus"),
        .init(title: "Exposure Program", group: .capture, scope: .exif, key: "ExposureProgram", defaultValue: "", systemImage: "slider.horizontal.3"),
        .init(title: "Metering Mode", group: .capture, scope: .exif, key: "MeteringMode", defaultValue: "", systemImage: "scope"),
        .init(title: "Flash", group: .capture, scope: .exif, key: "Flash", defaultValue: "", systemImage: "bolt"),
        .init(title: "White Balance", group: .capture, scope: .exif, key: "WhiteBalance", defaultValue: "", systemImage: "circle.lefthalf.filled"),
        .init(title: "Digital Zoom Ratio", group: .capture, scope: .exif, key: "DigitalZoomRatio", defaultValue: "", systemImage: "plus.magnifyingglass"),
        .init(title: "Shutter Speed", group: .capture, scope: .exif, key: "ShutterSpeedValue", defaultValue: "", systemImage: "timer"),
        .init(title: "Aperture Value", group: .capture, scope: .exif, key: "ApertureValue", defaultValue: "", systemImage: "camera.aperture"),
        .init(title: "Brightness Value", group: .capture, scope: .exif, key: "BrightnessValue", defaultValue: "", systemImage: "sun.max"),
        .init(title: "Scene Type", group: .capture, scope: .exif, key: "SceneType", defaultValue: "", systemImage: "photo"),
        .init(title: "Subsecond Original Time", group: .capture, scope: .exif, key: "SubsecTimeOriginal", defaultValue: "", systemImage: "clock"),

        // File / authorship (7)
        .init(title: "Image Description", group: .file, scope: .tiff, key: "ImageDescription", defaultValue: "", systemImage: "doc.text"),
        .init(title: "Artist", group: .file, scope: .tiff, key: "Artist", defaultValue: "", systemImage: "person"),
        .init(title: "Copyright", group: .file, scope: .tiff, key: "Copyright", defaultValue: "", systemImage: "c.circle"),
        .init(title: "Software", group: .file, scope: .tiff, key: "Software", defaultValue: "", systemImage: "app"),
        .init(title: "Modified Date", group: .file, scope: .tiff, key: "DateTime", defaultValue: "", systemImage: "calendar"),
        .init(title: "Orientation", group: .file, scope: .tiff, key: "Orientation", defaultValue: "", systemImage: "rotate.right"),
        .init(title: "User Comment", group: .file, scope: .exif, key: "UserComment", defaultValue: "", systemImage: "text.bubble"),

        // IPTC / misc (4)
        .init(title: "Headline", group: .other, scope: .iptc, key: "Headline", defaultValue: "", systemImage: "textformat.size"),
        .init(title: "Caption", group: .other, scope: .iptc, key: "Caption/Abstract", defaultValue: "", systemImage: "captions.bubble"),
        .init(title: "Keywords", group: .other, scope: .iptc, key: "Keywords", defaultValue: "", systemImage: "tag"),
        .init(title: "Credit", group: .other, scope: .iptc, key: "Credit", defaultValue: "", systemImage: "person.text.rectangle"),

        // Advanced / low-level removable image fields
        .init(title: "EXIF Byte Order", group: .file, scope: .exif, key: "ExifByteOrder", defaultValue: "", systemImage: "number"),
        .init(title: "X Resolution", group: .file, scope: .tiff, key: "XResolution", defaultValue: "72", systemImage: "ruler"),
        .init(title: "Y Resolution", group: .file, scope: .tiff, key: "YResolution", defaultValue: "72", systemImage: "ruler"),
        .init(title: "Resolution Unit", group: .file, scope: .tiff, key: "ResolutionUnit", defaultValue: "2", systemImage: "ruler"),
        .init(title: "YCbCr Positioning", group: .file, scope: .tiff, key: "YCbCrPositioning", defaultValue: "", systemImage: "slider.horizontal.3"),
        .init(title: "EXIF Version", group: .file, scope: .exif, key: "ExifVersion", defaultValue: "0221", systemImage: "number"),
        .init(title: "Components Configuration", group: .file, scope: .exif, key: "ComponentsConfiguration", defaultValue: "", systemImage: "square.grid.3x3"),
        .init(title: "Flashpix Version", group: .file, scope: .exif, key: "FlashpixVersion", defaultValue: "0100", systemImage: "number"),
        .init(title: "Color Space", group: .file, scope: .exif, key: "ColorSpace", defaultValue: "1", systemImage: "paintpalette"),
        .init(title: "EXIF Image Width", group: .file, scope: .exif, key: "PixelXDimension", defaultValue: "", systemImage: "arrow.left.and.right"),
        .init(title: "EXIF Image Height", group: .file, scope: .exif, key: "PixelYDimension", defaultValue: "", systemImage: "arrow.up.and.down"),
        .init(title: "Scene Capture Type", group: .capture, scope: .exif, key: "SceneCaptureType", defaultValue: "0", systemImage: "photo"),
        .init(title: "Compression", group: .file, scope: .tiff, key: "Compression", defaultValue: "", systemImage: "archivebox"),
        .init(title: "Thumbnail Offset", group: .file, scope: .exif, key: "ThumbnailOffset", defaultValue: "", systemImage: "photo.on.rectangle"),
        .init(title: "Thumbnail Length", group: .file, scope: .exif, key: "ThumbnailLength", defaultValue: "", systemImage: "photo.on.rectangle"),
        .init(title: "Thumbnail Image", group: .file, scope: .exif, key: "ThumbnailImage", defaultValue: "", systemImage: "photo.on.rectangle"),
        .init(title: "XMP Toolkit", group: .other, scope: .xmp, key: "XMPToolkit", defaultValue: "", systemImage: "curlybraces")
    ]

    static var standardImageFieldCount: Int { templates.count }

    static func templates(for group: MetadataFieldGroup.Kind) -> [StandardMetadataFieldTemplate] {
        templates.filter { $0.group == group }
    }

    static func matchID(for row: MetadataFieldRowModel) -> String {
        if case .image(let entry) = row.tag.kind {
            return "\(entry.scope.rawValue)|\(entry.dictionaryKey.lowercased())"
        }
        return "\(row.tag.tagKey.lowercased())|\(row.tag.label.lowercased())"
    }
}

private extension ImageMetadataScope {
    var displayName: String {
        switch self {
        case .exif: "EXIF"
        case .gps: "GPS"
        case .iptc: "IPTC"
        case .tiff: "TIFF"
        case .png: "PNG"
        case .xmp: "XMP"
        }
    }
}

private struct MetadataFieldCard: View {
    @Binding var row: MetadataFieldRowModel
    let focusedRowID: FocusState<String?>.Binding
    let onUserEdit: () -> Void
    @State private var isDatePickerPresented = false
    @State private var pickerDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(row.tag.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                CheckboxControl(
                    title: "Remove",
                    isChecked: removeBinding,
                    font: .caption
                )
            }

            if row.isRemoved {
                Text("Will be removed")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 8) {
                    TextField("Value", text: valueBinding, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1...3)
                        .focused(focusedRowID, equals: row.id)

                    if isCalendarEligibleDateField {
                        Button {
                            focusedRowID.wrappedValue = nil
                            dismissKeyboard()
                            pickerDate = DateMetadataValueCodec.parse(row.value) ?? Date()
                            isDatePickerPresented = true
                        } label: {
                            Image(systemName: "calendar")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.primary)
                                .padding(6)
                                .background(Theme.background.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose date")
                    }
                }
                .padding(10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.accent.opacity(0.65), lineWidth: 1)
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: $isDatePickerPresented) {
            DateTimePickerSheet(
                date: $pickerDate,
                onCancel: { isDatePickerPresented = false },
                onApply: {
                    valueBinding.wrappedValue = DateMetadataValueCodec.encode(pickerDate, previousRaw: row.value)
                    isDatePickerPresented = false
                }
            )
        }
        .onChange(of: isDatePickerPresented) { _, isPresented in
            if isPresented {
                dismissKeyboard()
            }
        }
    }

    private var removeBinding: Binding<Bool> {
        Binding(
            get: { row.isRemoved },
            set: { newValue in
                onUserEdit()
                row.isRemoved = newValue
            }
        )
    }

    private var valueBinding: Binding<String> {
        Binding(
            get: { row.value },
            set: { newValue in
                onUserEdit()
                row.value = newValue
            }
        )
    }

    private var isCalendarEligibleDateField: Bool {
        let key = (row.tag.tagKey + " " + row.tag.label).lowercased()
        return key.contains("date")
            || key.contains("datetime")
            || key.contains("timestamp")
            || key.contains("created")
            || key.contains("modified")
    }
}

private struct DateTimePickerSheet: View {
    @Binding var date: Date
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker(
                    "Date & Time",
                    selection: $date,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Theme.primary)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Set Date & Time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: onApply)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private enum DateMetadataValueCodec {
    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static let userVisibleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let date = isoWithFractional.date(from: value) { return date }
        if let date = isoNoFractional.date(from: value) { return date }
        if let date = exifFormatter.date(from: value) { return date }
        if let date = userVisibleFormatter.date(from: value) { return date }
        return nil
    }

    static func encode(_ date: Date, previousRaw: String) -> String {
        let previous = previousRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if previous.contains("T") {
            return isoNoFractional.string(from: date)
        }
        if previous.contains(":") && previous.count >= 19 && !previous.contains("-") {
            return exifFormatter.string(from: date)
        }
        return userVisibleFormatter.string(from: date)
    }
}

private struct MetadataLocationCard: View {
    @Binding var coordinate: CLLocationCoordinate2D
    @State private var isEditorPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Map Preview", systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Edit") {
                    dismissKeyboard()
                    isEditorPresented = true
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.primary)
            }

            LocationPreviewMap(coordinate: coordinate)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture {
                dismissKeyboard()
                isEditorPresented = true
            }

            Text("\(coordinate.latitude, specifier: "%.5f"), \(coordinate.longitude, specifier: "%.5f")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textMuted)
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.accent.opacity(0.65), lineWidth: 1)
        )
        .sheet(isPresented: $isEditorPresented) {
            LocationEditorSheet(coordinate: $coordinate)
        }
        .onChange(of: isEditorPresented) { _, isPresented in
            if isPresented {
                dismissKeyboard()
            }
        }
    }
}

private struct LocationPreviewMap: View {
    let coordinate: CLLocationCoordinate2D
    @State private var position: MapCameraPosition

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        self._position = State(initialValue: .region(region))
    }

    var body: some View {
        Map(position: $position) {
            Marker("Media location", coordinate: coordinate)
        }
        .allowsHitTesting(false)
        .onAppear {
            position = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                )
            )
        }
        .onChange(of: coordinate.latitude) { _, _ in
            recenterPreview()
        }
        .onChange(of: coordinate.longitude) { _, _ in
            recenterPreview()
        }
    }

    private func recenterPreview() {
        position = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        )
    }
}

private struct LocationEditorSheet: View {
    @Binding var coordinate: CLLocationCoordinate2D
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = LocationSearchModel()
    @State private var draftCoordinate: CLLocationCoordinate2D

    init(coordinate: Binding<CLLocationCoordinate2D>) {
        self._coordinate = coordinate
        self._draftCoordinate = State(initialValue: coordinate.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Search for a place or address", text: $search.query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Theme.background.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal)

                if !search.results.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(search.results, id: \.self) { completion in
                                Button {
                                    search.resolve(completion) { coordinate in
                                        guard let coordinate else { return }
                                        draftCoordinate = coordinate
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(completion.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Theme.text)
                                            .lineLimit(1)
                                        if !completion.subtitle.isEmpty {
                                            Text(completion.subtitle)
                                                .font(.caption2)
                                                .foregroundStyle(Theme.textMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(width: 220, alignment: .leading)
                                    .background(Theme.background.opacity(0.55))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 62)
                }

                EditableLocationMap(coordinate: $draftCoordinate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal)

                Text("Search, pan the map, then tap or long-press to place the pin.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationTitle("Edit Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        coordinate = draftCoordinate
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct EditableLocationMap: UIViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .includingAll
        map.showsCompass = true
        map.showsScale = true
        map.isRotateEnabled = false

        let annotation = MKPointAnnotation()
        annotation.title = "Media location"
        annotation.coordinate = coordinate
        context.coordinator.annotation = annotation
        map.addAnnotation(annotation)
        map.setRegion(region(centeredAt: coordinate), animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMapLongPress(_:))
        )
        longPress.minimumPressDuration = 0.35
        longPress.cancelsTouchesInView = false
        map.addGestureRecognizer(longPress)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        if let annotation = context.coordinator.annotation,
           !context.coordinator.isDragging,
           !coordinatesAreClose(annotation.coordinate, coordinate) {
            annotation.coordinate = coordinate
            map.setRegion(region(centeredAt: coordinate), animated: true)
        }
        if let annotation = context.coordinator.annotation,
           let view = map.view(for: annotation) {
            view.isDraggable = true
        }
    }

    private func region(centeredAt coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
    }

    private func coordinatesAreClose(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.000001 && abs(lhs.longitude - rhs.longitude) < 0.000001
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: EditableLocationMap
        var annotation: MKPointAnnotation?
        var isDragging = false

        init(_ parent: EditableLocationMap) {
            self.parent = parent
        }

        @objc
        func handleMapTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            updatePin(to: coordinate)
        }

        @objc
        func handleMapLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            updatePin(to: coordinate)
        }

        private func updatePin(to coordinate: CLLocationCoordinate2D) {
            guard CLLocationCoordinate2DIsValid(coordinate),
                  abs(coordinate.latitude) <= 90,
                  abs(coordinate.longitude) <= 180 else {
                return
            }
            annotation?.coordinate = coordinate
            parent.coordinate = coordinate
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is MKPointAnnotation else { return nil }
            let reuseID = "metadata-location-pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
            view.annotation = annotation
            view.canShowCallout = true
            view.isDraggable = false
            view.markerTintColor = UIColor(Theme.primary)
            return view
        }

        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            didChange newState: MKAnnotationView.DragState,
            fromOldState oldState: MKAnnotationView.DragState
        ) {
            // Keep for compatibility if the system ever emits drag updates.
            switch newState {
            case .starting, .dragging:
                isDragging = true
            case .ending, .canceling:
                isDragging = false
                if let coordinate = view.annotation?.coordinate {
                    parent.coordinate = coordinate
                }
                view.dragState = .none
            default:
                break
            }
        }
    }
}

private final class LocationSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet {
            completer.queryFragment = query
        }
    }
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = Array(completer.results.prefix(8))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    func resolve(_ completion: MKLocalSearchCompletion, completionHandler: @escaping (CLLocationCoordinate2D?) -> Void) {
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                completionHandler(response?.mapItems.first?.placemark.coordinate)
            }
        }
    }
}

private enum MetadataLocationResolver {
    static func coordinate(from rows: [MetadataFieldRowModel]) -> CLLocationCoordinate2D? {
        if let iso = coordinateFromISO6709Fields(rows) {
            return iso
        }

        var latitude: Double?
        var longitude: Double?
        var latitudeRef: String?
        var longitudeRef: String?

        for row in rows {
            let key = (row.tag.tagKey + " " + row.tag.label).lowercased()
            if key.contains("latitude") && !key.contains("ref") {
                latitude = parseNumber(row.value)
            } else if key.contains("longitude") && !key.contains("ref") {
                longitude = parseNumber(row.value)
            } else if key.contains("latituderef") || key.contains("latitude ref") {
                latitudeRef = row.value
            } else if key.contains("longituderef") || key.contains("longitude ref") {
                longitudeRef = row.value
            }
        }

        guard var lat = latitude, var lon = longitude else { return nil }
        if latitudeRef?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("S") == true {
            lat = -abs(lat)
        }
        if longitudeRef?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("W") == true {
            lon = -abs(lon)
        }
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func isISO6709Row(_ row: MetadataFieldRowModel) -> Bool {
        let key = row.tag.tagKey.lowercased()
        return key.contains("iso6709")
            || key == "com.apple.quicktime.location.iso6709"
            || key == "location-iso6709"
    }

    static func isLatitudeRow(_ row: MetadataFieldRowModel) -> Bool {
        let key = normalizedLocationKey(row)
        return key.contains("latitude") && !key.contains("ref")
    }

    static func isLongitudeRow(_ row: MetadataFieldRowModel) -> Bool {
        let key = normalizedLocationKey(row)
        return key.contains("longitude") && !key.contains("ref")
    }

    static func isLatitudeRefRow(_ row: MetadataFieldRowModel) -> Bool {
        let key = normalizedLocationKey(row)
        return key.contains("latituderef") || key.contains("latitude ref")
    }

    static func isLongitudeRefRow(_ row: MetadataFieldRowModel) -> Bool {
        let key = normalizedLocationKey(row)
        return key.contains("longituderef") || key.contains("longitude ref")
    }

    static func iso6709String(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%+.6f%+.6f/", coordinate.latitude, coordinate.longitude)
    }

    private static func coordinateFromISO6709Fields(_ rows: [MetadataFieldRowModel]) -> CLLocationCoordinate2D? {
        // Most reliable source: explicit ISO6709 keys from QuickTime/FFmpeg.
        let prioritized = rows.filter(isISO6709Row)
        if let exact = prioritized.compactMap({ iso6709Coordinate(from: $0.value) }).first {
            return exact
        }

        // Fallback: location-labeled rows only (not arbitrary metadata values).
        let locationRows = rows.filter { row in
            let key = (row.tag.tagKey + " " + row.tag.label).lowercased()
            return key.contains("location") || key.contains("gps")
        }
        return locationRows.compactMap { iso6709Coordinate(from: $0.value) }.first
    }

    private static func normalizedLocationKey(_ row: MetadataFieldRowModel) -> String {
        (row.tag.tagKey + " " + row.tag.label).lowercased()
    }

    private static func parseNumber(_ value: String) -> Double? {
        if let direct = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return direct
        }
        let pattern = #"[-+]?\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else {
            return nil
        }
        return Double(value[range])
    }

    /// QuickTime and FFmpeg commonly expose GPS as ISO 6709, e.g. "+30.1234-096.1234/".
    private static func iso6709Coordinate(from value: String) -> CLLocationCoordinate2D? {
        let pattern = #"([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges >= 3,
              let latRange = Range(match.range(at: 1), in: value),
              let lonRange = Range(match.range(at: 2), in: value),
              let lat = Double(value[latRange]),
              let lon = Double(value[lonRange]),
              abs(lat) <= 90,
              abs(lon) <= 180 else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

private struct CheckboxControl: View {
    let title: String
    @Binding var isChecked: Bool
    var font: Font = .body

    var body: some View {
        Button {
            isChecked.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? Theme.primary : Theme.textMuted)
                Text(title)
                    .font(font)
                    .foregroundStyle(Theme.text)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isChecked ? "Checked" : "Unchecked")
        .accessibilityAddTraits(.isButton)
    }
}

private func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}
