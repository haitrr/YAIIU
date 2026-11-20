import Photos
import SwiftUI

struct UploadProgressView: View {
    @EnvironmentObject var uploadManager: UploadManager
    @ObservedObject private var hashManager = HashManager.shared
    @StateObject private var model = UploadStatusModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                PhotoKitBaselineBanner()
                List {
                    if !uploadManager.uploadQueue.isEmpty {
                        Section(L10n.UploadProgress.sectionCurrent) {
                            currentRunHeader
                        }
                    }
                    librarySection
                    recentSection
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle(L10n.UploadProgress.title)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if uploadManager.isUploading {
                        Button(L10n.UploadProgress.pause) {
                            uploadManager.pauseUpload()
                        }
                    } else if !uploadManager.uploadQueue.isEmpty {
                        Button(L10n.UploadProgress.resume) {
                            uploadManager.resumeUpload()
                        }
                    }
                }
            }
        }
        .onAppear { model.start(uploadManager: uploadManager) }
        .onDisappear { model.stop() }
    }

    // MARK: - Current run

    private var currentRunHeader: some View {
        VStack(spacing: 8) {
            HStack {
                if uploadManager.isUploading {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(L10n.UploadProgress.uploading)
                        .font(.subheadline)
                } else {
                    Text(L10n.UploadProgress.paused)
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
                Spacer()
                Text("\(uploadManager.completedCount)/\(uploadManager.totalCount)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: min(uploadManager.overallProgress, 1))
                .progressViewStyle(LinearProgressViewStyle())
        }
        .padding(.vertical, 4)
    }

    // MARK: - Library stages

    @ViewBuilder
    private var librarySection: some View {
        Section {
            if let summary = model.summary {
                ForEach(UploadStage.allCases, id: \.self) { stage in
                    if summary.count(stage) > 0 || stage.alwaysShown {
                        NavigationLink {
                            UploadStageListView(stage: stage, identifiers: summary.identifiers[stage] ?? [])
                        } label: {
                            UploadStageRow(
                                stage: stage,
                                count: summary.count(stage),
                                detail: detail(for: stage)
                            )
                        }
                    }
                }
                if summary.count(.failed) > 0 && !uploadManager.isUploading {
                    Button(L10n.UploadProgress.retryFailed) {
                        uploadManager.retryFailedItems()
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.UploadProgress.loading)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            HStack {
                Text(L10n.UploadProgress.sectionLibrary)
                Spacer()
                if let summary = model.summary {
                    Text(L10n.UploadProgress.photoCount(summary.total))
                }
            }
        }
    }

    private func detail(for stage: UploadStage) -> String? {
        if stage == .waitingForHash, hashManager.isProcessing, hashManager.totalAssetsToProcess > 0 {
            return L10n.UploadProgress.hashing(hashManager.processedAssetsCount, hashManager.totalAssetsToProcess)
        }
        return L10n.UploadProgress.stageHint(stage)
    }

    // MARK: - History

    private var recentSection: some View {
        Section(L10n.UploadProgress.sectionRecent) {
            if model.recent.isEmpty {
                Text(L10n.UploadProgress.recentEmpty)
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.recent) { upload in
                    RecentUploadRow(upload: upload)
                }
            }
        }
    }
}

private extension UploadStage {
    /// Rows kept visible at zero so the summary reads the same every time.
    var alwaysShown: Bool {
        switch self {
        case .uploaded, .queued, .waitingForHash, .notUploaded: return true
        default: return false
        }
    }

    var iconName: String {
        switch self {
        case .uploading: return "arrow.up.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .queued: return "clock.fill"
        case .uploaded: return "checkmark.circle.fill"
        case .waitingForHash: return "number.circle.fill"
        case .checkingServer: return "magnifyingglass.circle.fill"
        case .notUploaded: return "circle.dashed"
        case .hashError: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .uploading: return .blue
        case .failed, .hashError: return .red
        case .queued: return .gray
        case .uploaded: return .green
        case .waitingForHash, .checkingServer: return .orange
        case .notUploaded: return .secondary
        }
    }
}

private struct UploadStageRow: View {
    let stage: UploadStage
    let count: Int
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: stage.iconName)
                .foregroundColor(stage.tint)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.UploadProgress.stage(stage))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Text("\(count)")
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Stage detail

private struct UploadStageListView: View {
    @EnvironmentObject var uploadManager: UploadManager
    let stage: UploadStage
    let identifiers: [String]

    var body: some View {
        Group {
            if stage.isQueueStage {
                let items = uploadManager.uploadQueue.filter {
                    UploadStatusSummary.stage(for: $0.status) == stage
                }
                if items.isEmpty {
                    emptyView
                } else {
                    List(items) { item in
                        UploadItemRow(item: item)
                    }
                    .listStyle(.plain)
                }
            } else if identifiers.isEmpty {
                emptyView
            } else {
                List(identifiers, id: \.self) { identifier in
                    StageAssetRow(localIdentifier: identifier)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(L10n.UploadProgress.stage(stage))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if stage == .failed && !uploadManager.isUploading {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.UploadProgress.retryFailed) {
                        uploadManager.retryFailedItems()
                    }
                }
            }
        }
    }

    private var emptyView: some View {
        Text(L10n.UploadProgress.stageEmpty)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Thumbnail, filename and capture date for a library photo, loaded lazily.
private struct StageAssetRow: View {
    let localIdentifier: String
    var subtitle: String?
    var trailing: String?
    var fallbackFilename: String?

    @State private var thumbnail: UIImage?
    @State private var filename: String?
    @State private var creationDate: Date?
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 12) {
            AssetThumbnailBox(image: thumbnail)
            VStack(alignment: .leading, spacing: 3) {
                Text(filename ?? fallbackFilename ?? " ")
                    .font(.subheadline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let creationDate {
                    Text(creationDate, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear(perform: load)
        .onDisappear {
            isVisible = false
            thumbnail = nil
        }
    }

    private func load() {
        isVisible = true
        let identifier = localIdentifier
        Task.detached(priority: .userInitiated) {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename
            let date = asset.creationDate
            await MainActor.run {
                filename = filename ?? name
                creationDate = date
                guard isVisible else { return }
                // Rows render at 50pt; 150px covers a 3x display.
                ThumbnailCache.shared.getThumbnail(for: asset, targetSize: CGSize(width: 150, height: 150)) { image in
                    Task { @MainActor in
                        guard isVisible else { return }
                        thumbnail = image
                    }
                }
            }
        }
    }
}

private struct AssetThumbnailBox: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct RecentUploadRow: View {
    let upload: RecentUpload

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        StageAssetRow(
            localIdentifier: upload.localIdentifier,
            subtitle: subtitle,
            trailing: Self.relativeFormatter.localizedString(for: upload.uploadedAt, relativeTo: Date()),
            // The receipt's filename shows even if the photo was since deleted.
            fallbackFilename: upload.filename
        )
    }

    private var subtitle: String {
        let types = upload.resourceTypes.map(Self.label(for:)).joined(separator: " · ")
        return upload.isDuplicate ? "\(types) — \(L10n.UploadProgress.duplicate)" : types
    }

    private static func label(for resourceType: String) -> String {
        switch resourceType {
        case LivePhotoResourcePolicy.resourceType: return "Live"
        case "video": return L10n.UploadProgress.video
        default: return resourceType.uppercased()
        }
    }
}

struct UploadItemRow: View {
    @ObservedObject var item: UploadItem
    @State private var thumbnail: UIImage?
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 12) {
            AssetThumbnailBox(image: thumbnail)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.subheadline)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !item.isVideo {
                        badge("JPEG", done: item.resourcesUploaded["jpeg"] == true || item.resourcesUploaded["heic"] == true, color: .blue)
                    }
                    if item.hasRAW {
                        badge("RAW", done: item.resourcesUploaded["raw"] == true, color: .orange)
                    }
                    if item.isVideo {
                        badge(L10n.UploadProgress.video, done: item.resourcesUploaded["video"] == true, color: .purple)
                    }
                    if item.isLivePhoto {
                        Image(systemName: "livephoto")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(item.resourcesUploaded[LivePhotoResourcePolicy.resourceType] == true ? Color.green : Color.purple)
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 4) {
                    Text(item.statusText)
                        .font(.caption)
                        .foregroundColor(item.statusColor)

                    if item.totalResources > 1 && item.status == .uploading {
                        Text(L10n.UploadProgress.files(item.resourcesUploaded.count, item.totalResources))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if item.status == .uploading {
                    ProgressView(value: item.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                }
            }

            Spacer()

            VStack(spacing: 2) {
                Group {
                    switch item.status {
                    case .pending:
                        Image(systemName: "clock")
                            .foregroundColor(.gray)
                    case .preparing, .uploading, .processing:
                        ProgressView()
                            .scaleEffect(0.8)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failed:
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }

                if item.totalResources > 1 {
                    Text(L10n.UploadProgress.fileCount(item.totalResources))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            isVisible = true
            // This row renders at 50pt; 150px covers even a 3x display.
            // Do not decode the gallery's much larger preview during uploads.
            ThumbnailCache.shared.getThumbnail(
                for: item.asset, targetSize: CGSize(width: 150, height: 150)
            ) { image in
                Task { @MainActor in
                    // Old cache cancellation is keyed by asset, not consumer.
                    // Preserve shared requests and ignore results for hidden rows.
                    guard isVisible else { return }
                    thumbnail = image
                }
            }
        }
        .onDisappear {
            isVisible = false
            thumbnail = nil
        }
    }

    private func badge(_ text: String, done: Bool, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(done ? Color.green : color)
            .cornerRadius(3)
    }
}

#Preview {
    UploadProgressView()
        .environmentObject(UploadManager())
}
