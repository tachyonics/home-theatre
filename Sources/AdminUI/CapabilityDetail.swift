import HomeTheatreCore
import ImageIO
import SwiftUI

/// The files behind one capability — or, when there are none, the names Emby
/// would have accepted.
///
/// Showing the accepted names is the point of the empty state: "no poster" is an
/// observation, "no poster, and here are the five filenames that would be one" is
/// something you can act on.
struct AssetList: View {
    let entry: CapabilityInventory.Entry

    var body: some View {
        if entry.assets.isEmpty {
            MissingCapability(entry: entry)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entry.assets, id: \.file) { asset in
                    AssetRow(asset: asset, beatenBy: beatenBy(asset))
                }

                if entry.shadowedCount > 0 {
                    Text("Emby checks the documented filenames in order and stops at the first, so the greyed files are on disk and never read.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The file that won, which is the only useful thing to say about a file that
    /// lost. Assets arrive in precedence order, so it is simply the first survivor.
    private func beatenBy(_ asset: MediaAsset) -> String? {
        guard asset.isShadowed else { return nil }
        return entry.assets.first { !$0.isShadowed }?.name
    }
}

struct MissingCapability: View {
    let entry: CapabilityInventory.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Nothing on disk provides this.", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
            AcceptedNames(capability: entry.capability, level: entry.level)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The filenames Emby accepts for a capability, in the order it checks them.
struct AcceptedNames: View {
    let capability: Capability
    let level: ItemLevel

    var body: some View {
        let names = AssetScanner.acceptedRules(for: capability, at: level)

        VStack(alignment: .leading, spacing: 2) {
            // Precedence is only worth explaining when there is a contest: one
            // accepted name has nothing to win against.
            Text(capability.isMultiValued || names.count < 2
                 ? "Named as"
                 : "Named as, first match wins")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 5))
    }
}

struct AssetRow: View {
    let asset: MediaAsset
    /// The higher-precedence file that shadows this one, if any.
    let beatenBy: String?

    @State private var preview: ImagePreview?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leading

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(detailLine)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let note = asset.locationNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let beatenBy {
                    Text("Ignored — \(beatenBy) is checked first")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .opacity(asset.isShadowed ? 0.55 : 1)
        .help(asset.file.path)
        .task(id: asset.file) {
            guard isImage else { return }
            let url = asset.file
            preview = await Task.detached(priority: .utility) { ImagePreview.load(url) }.value
        }
    }

    private var isImage: Bool {
        AssetScanner.imageExtensions.contains(asset.file.pathExtension.lowercased())
    }

    /// A fixed box either way, so rows line up whether or not the artwork has
    /// decoded yet — and whether or not there is artwork at all.
    @ViewBuilder
    private var leading: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let preview {
                Image(decorative: preview.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if !isImage {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(.rect(cornerRadius: 4))
    }

    private var symbol: String {
        switch asset.capability {
        case .themeSong: "music.note"
        case .themeVideo: "film"
        case .subtitles: "captions.bubble"
        default: "photo"
        }
    }

    /// What the file is, told in the order it is asked about: what kind of track it
    /// is, which rule claimed it, how big it is.
    private var detailLine: String {
        var parts: [String] = []
        if let subtitle = asset.subtitle { parts.append(subtitle.summary) }
        parts.append(asset.rule)
        if let preview { parts.append("\(preview.pixelWidth)×\(preview.pixelHeight)") }
        if let bytes = asset.byteCount {
            // .byteCount spells zero as "Zero kB", which reads like a rounding
            // artefact rather than the fact that matters: the file is empty.
            parts.append(bytes == 0 ? "empty" : Int64(bytes).formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }
}

/// A decoded thumbnail plus the source image's real size.
///
/// `CGImage` is immutable and safe to hand between threads; it simply predates
/// `Sendable`, which is what the unchecked conformance is standing in for.
struct ImagePreview: @unchecked Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int

    /// Decoded straight to thumbnail size: a 4K fanart shown at 56 points has no
    /// business costing tens of megabytes to put on screen.
    static func load(_ url: URL, maxPixel: Int = 160) -> ImagePreview? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return ImagePreview(
            image: image,
            pixelWidth: properties?[kCGImagePropertyPixelWidth] as? Int ?? image.width,
            pixelHeight: properties?[kCGImagePropertyPixelHeight] as? Int ?? image.height
        )
    }
}
