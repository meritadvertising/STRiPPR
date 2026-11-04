import AppKit
import Foundation
import Observation
import StripprCore

@Observable @MainActor
final class BatchStore {
    var items: [FileItem] = [] {
        didSet { updateQueuePresentation(previous: oldValue) }
    }
    var fileFilter: FileFilter = .both {
        didSet { if fileFilter != oldValue { updateVisibleIDs() } }
    }
    var fileSort: FileSort = .name {
        didSet { if fileSort != oldValue { updateQueueOrder() } }
    }
    var sortAscending = true {
        didSet { if sortAscending != oldValue { updateQueueOrder() } }
    }
    private(set) var visibleItemIDs: [UUID] = []
    private(set) var withTagsCount = 0
    private(set) var withoutTagsCount = 0
    private(set) var unknownTagsCount = 0
    @ObservationIgnored private var queueEntries: [UUID: QueueEntry] = [:]
    @ObservationIgnored private var itemIndices: [UUID: Int] = [:]
    @ObservationIgnored private var orderedIDs: [UUID] = []
    @ObservationIgnored private var nameOrderedIDs: [UUID] = []
    @ObservationIgnored private var nameRanks: [UUID: Int] = [:]
    // Internal counters make the no-resort-on-progress guarantee testable.
    @ObservationIgnored private(set) var presentationSortCount = 0
    @ObservationIgnored private(set) var presentationNameSortCount = 0
    var isBusy = false
    var isScanning = false
    var isCancelling = false
    var overallProgress: Double = 0
    var activity = "Drop your videos. Keep your originals."
    var outputDirectory: URL?
    var keepOriginals = true
    var keepEncoderInfo = true
    var replacementRequest: ReplacementRequest?
    var skipped = 0
    private var armedReplacementID: UUID?
    private var token: CancellationToken?
    private var job: Task<Void, Never>?

    var readyCount: Int { items.filter { $0.phase == .ready && $0.scan?.canClean == true }.count }
    var verifiedCount: Int { items.filter { $0.phase == .verified }.count }
    var removableCount: Int { items.filter { $0.phase == .ready }.reduce(0) { $0 + $1.removableCount } }
    var filteredCount: Int { visibleItemIDs.count }
    var visibleItems: [FileItem] {
        visibleItemIDs.compactMap { id in
            guard let index = index(for: id) else { return nil }
            return items[index]
        }
    }

    func index(for id: UUID) -> Int? { itemIndices[id] }

    func setExpanded(_ expanded: Bool, for id: UUID) {
        guard let index = index(for: id) else { return }
        items[index].expanded = expanded
    }

    /// This is a projection of the whole queue. It never changes cleaning scope
    /// or the armed replacement request, and its IDs survive row reordering.
    private func updateQueuePresentation(previous: [FileItem]) {
        // Progress/detail/expansion are intentionally absent from projection
        // keys. Avoid allocating dictionaries or reclassifying the whole queue
        // for the frequent row-only updates made while copying media.
        if previous.count == items.count && zip(previous, items).allSatisfy({ old, new in
            old.id == new.id && old.url == new.url && old.phase == new.phase &&
                old.didReplaceOriginal == new.didReplaceOriginal &&
                old.scan?.fileSize == new.scan?.fileSize && old.scan?.tags == new.scan?.tags &&
                old.scan?.warnings == new.scan?.warnings
        }) { return }
        var entries: [UUID: QueueEntry] = [:]
        var indices: [UUID: Int] = [:]
        entries.reserveCapacity(items.count)
        indices.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            entries[item.id] = QueueEntry(item)
            indices[item.id] = index
        }
        itemIndices = indices
        guard entries != queueEntries else { return }
        let namesChanged = entries.count != queueEntries.count || entries.contains { id, entry in
            queueEntries[id]?.url != entry.url
        }
        let sortChanged = namesChanged || entries.contains { id, entry in
            guard let previous = queueEntries[id] else { return true }
            switch fileSort {
            case .name: return false
            case .removableTags: return previous.removableTags != entry.removableTags
            case .size: return previous.size != entry.size
            case .status: return previous.phase != entry.phase
            }
        }
        queueEntries = entries
        withTagsCount = entries.values.filter { $0.category == .withTags }.count
        withoutTagsCount = entries.values.filter { $0.category == .withoutTags }.count
        unknownTagsCount = entries.count - withTagsCount - withoutTagsCount
        if namesChanged {
            presentationNameSortCount += 1
            nameOrderedIDs = entries.keys.sorted { left, right in
                let a = entries[left]!.url, b = entries[right]!.url
                let nameOrder = a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                let pathOrder = a.path.localizedStandardCompare(b.path)
                if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
                return left.uuidString < right.uuidString
            }
            nameRanks = Dictionary(uniqueKeysWithValues: nameOrderedIDs.enumerated().map { ($0.element, $0.offset) })
        }
        if sortChanged { updateQueueOrder() } else { updateVisibleIDs() }
    }

    private func updateQueueOrder() {
        presentationSortCount += 1
        if fileSort == .name {
            orderedIDs = sortAscending ? nameOrderedIDs : Array(nameOrderedIDs.reversed())
        } else {
            orderedIDs = nameOrderedIDs.sorted { left, right in
                let a = queueEntries[left]!, b = queueEntries[right]!
                switch fileSort {
                case .name: break
                case .removableTags:
                    if let x = a.removableTags, let y = b.removableTags {
                        if x != y { return sortAscending ? x < y : x > y }
                    } else if (a.removableTags == nil) != (b.removableTags == nil) {
                        return a.removableTags != nil // Unknown stays last in either direction.
                    }
                case .size:
                    if let x = a.size, let y = b.size {
                        if x != y { return sortAscending ? x < y : x > y }
                    } else if (a.size == nil) != (b.size == nil) {
                        return a.size != nil
                    }
                case .status:
                    if a.statusOrder != b.statusOrder {
                        return sortAscending ? a.statusOrder < b.statusOrder : a.statusOrder > b.statusOrder
                    }
                }
                return nameRanks[left]! < nameRanks[right]!
            }
        }
        updateVisibleIDs()
    }

    private func updateVisibleIDs() {
        let ids = orderedIDs.filter { id in
            switch fileFilter {
            case .both: return true
            case .withTags: return queueEntries[id]?.category == .withTags
            case .withoutTags: return queueEntries[id]?.category == .withoutTags
            }
        }
        if ids != visibleItemIDs { visibleItemIDs = ids }
    }

    func chooseFiles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Scan"
        panel.message = "Choose videos or folders. Subfolders are scanned; symbolic links are skipped."
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.add(panel.urls) }
        }
    }

    func chooseDestination() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        panel.message = "Verified copies keep unique names. Existing files are never replaced."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.outputDirectory = url }
        }
    }

    func add(_ urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        cancelReplacement()
        let encoderPolicy = keepEncoderInfo
        let cancellation = CancellationToken()
        token = cancellation
        isBusy = true
        isScanning = true
        isCancelling = false
        overallProgress = 0
        activity = "Finding videos in subfolders…"
        let existing = Set(items.map { $0.url.standardizedFileURL.path })
        job = Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.enumerate(urls, existing: existing, token: cancellation)
            }.value
            skipped = found.skipped
            let fresh = found.urls.map { FileItem(id: UUID(), url: $0) }
            items.append(contentsOf: fresh)
            for (index, item) in fresh.enumerated() {
                if cancellation.isCancelledForUI { break }
                activity = "Scanning \(index + 1) of \(fresh.count) · \(item.url.lastPathComponent)"
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try MediaScanner.scan(url: item.url, cancellation: cancellation, keepEncoderInfo: encoderPolicy) }
                }.value
                guard let row = items.firstIndex(where: { $0.id == item.id }) else { continue }
                applyScan(result, at: row)
                overallProgress = Double(index + 1) / Double(max(fresh.count, 1))
            }
            markUnfinishedScansCancelled()
            let wasCancelled = isCancelling
            finish()
            overallProgress = 0
            activity = wasCancelled ? "Scan cancelled · \(items.count) files in queue" : "\(items.count) \(items.count == 1 ? "file" : "files") inspected · \(readyCount) ready\(skipped > 0 ? " · \(skipped) skipped" : "")"
        }
    }

    func clean() {
        guard !isBusy else { return }
        let pending = items.filter { $0.phase == .ready && $0.scan?.canClean == true }
        guard !pending.isEmpty else { return }
        guard pending.allSatisfy({ $0.scan?.keepEncoderInfo == keepEncoderInfo }) else {
            rescanAll()
            return
        }
        if !keepOriginals {
            guard replacementRequest == nil else { return }
            let request = ReplacementRequest(files: pending, keepEncoderInfo: keepEncoderInfo)
            armedReplacementID = request.id
            replacementRequest = request
            return
        }
        startCleaning(pending, replaceOriginal: false)
    }

    func confirmReplacement(_ request: ReplacementRequest) {
        guard !isBusy, !keepOriginals, request.id == armedReplacementID,
              request.keepEncoderInfo == keepEncoderInfo,
              Set(items.filter { $0.phase == .ready && $0.scan?.canClean == true }.map(\.id)) == Set(request.files.map(\.id)) else {
            cancelReplacement()
            activity = "The queue or options changed. Review the files and try again."
            return
        }
        cancelReplacement()
        startCleaning(request.files, replaceOriginal: true)
    }

    func cancelReplacement() {
        replacementRequest = nil
        armedReplacementID = nil
    }

    func setKeepOriginals(_ value: Bool) {
        guard !isBusy else { return }
        cancelReplacement()
        keepOriginals = value
        if items.isEmpty { activity = value ? "Drop your videos. Keep your originals." : "Drop your videos. Replacement mode is on." }
    }

    func setKeepEncoderInfo(_ value: Bool) {
        guard !isBusy, value != keepEncoderInfo else { return }
        cancelReplacement()
        keepEncoderInfo = value
        rescanAll()
    }

    private func startCleaning(_ pending: [FileItem], replaceOriginal: Bool) {
        let cancellation = CancellationToken()
        token = cancellation
        isBusy = true
        isScanning = false
        isCancelling = false
        overallProgress = 0
        let destination = replaceOriginal ? nil : outputDirectory
        job = Task { [self] in
            var completed = 0
            var failures = 0
            for (index, item) in pending.enumerated() {
                if cancellation.isCancelledForUI { break }
                guard let scan = item.scan, let row = items.firstIndex(where: { $0.id == item.id }) else { continue }
                items[row].phase = .cleaning
                items[row].progress = 0
                items[row].outcomeWarnings = []
                let base = Double(index) / Double(pending.count)
                let scale = 1.0 / Double(pending.count)
                activity = "Cleaning \(index + 1) of \(pending.count) · \(item.url.lastPathComponent)"
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        try MediaCleaner.clean(scan, outputDirectory: destination, replaceOriginal: replaceOriginal, cancellation: cancellation) { fraction, stage in
                            Task { @MainActor [weak self] in
                                guard let self, self.token === cancellation,
                                      let current = self.items.firstIndex(where: { $0.id == item.id }),
                                      self.items[current].phase == .cleaning,
                                      fraction >= self.items[current].progress else { return }
                                self.items[current].progress = fraction
                                self.items[current].detail = stage
                                self.overallProgress = base + fraction * scale
                            }
                        }
                    }
                }.value
                guard let current = items.firstIndex(where: { $0.id == item.id }) else { continue }
                switch result {
                case .success(let result):
                    completed += 1
                    items[current].phase = .verified
                    items[current].progress = 1
                    items[current].output = result.outputURL
                    items[current].didReplaceOriginal = result.didReplaceOriginal
                    items[current].outcomeWarnings = result.warnings
                    if let recovery = result.recoveryURL {
                        items[current].outcomeWarnings.append("Original retained for recovery: \(recovery.path)")
                    }
                    items[current].detail = "\(result.removedTagCount) tags removed · \(result.didReplaceOriginal ? "original replaced after verification" : "all other bytes verified")"
                case .failure(let error):
                    if !isCancelling { failures += 1 }
                    items[current].phase = isCancelling ? .cancelled : .failed
                    items[current].detail = error.localizedDescription
                }
                if !isCancelling { overallProgress = Double(index + 1) / Double(pending.count) }
            }
            let wasCancelled = isCancelling
            finish()
            let outcome = replaceOriginal ? "verified \(completed == 1 ? "replacement" : "replacements")" : "verified \(completed == 1 ? "copy" : "copies") · originals preserved"
            let errors = failures > 0 ? " · \(failures) failed" : ""
            activity = wasCancelled ? "Cancelled · completed results are kept · remaining files stay queued" : "Batch finished · \(completed) \(outcome)\(errors)"
        }
    }

    func cancel() {
        guard isBusy else { return }
        isCancelling = true
        activity = "Cancelling and removing the unfinished temporary copy…"
        token?.cancel()
    }

    func clear() {
        guard !isBusy else { return }
        cancelReplacement()
        items.removeAll()
        overallProgress = 0
        activity = keepOriginals ? "Drop your videos. Keep your originals." : "Drop your videos. Replacement mode is on."
    }

    func retry(_ id: UUID) {
        guard !isBusy, let index = items.firstIndex(where: { $0.id == id }) else { return }
        cancelReplacement()
        let url = items[index].url
        let encoderPolicy = keepEncoderInfo
        let cancellation = CancellationToken()
        token = cancellation
        isBusy = true
        isScanning = true
        isCancelling = false
        overallProgress = 0
        activity = "Rescanning \(url.lastPathComponent)…"
        items[index].scan = nil
        items[index].phase = .scanning
        items[index].progress = 0
        items[index].detail = "Reading current metadata…"
        job = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MediaScanner.scan(url: url, cancellation: cancellation, keepEncoderInfo: encoderPolicy) }
            }.value
            if let current = items.firstIndex(where: { $0.id == id }) { applyScan(result, at: current) }
            finish()
            activity = "Rescan finished · \(readyCount) ready"
        }
    }

    private func rescanAll() {
        guard !isBusy, !items.isEmpty else { return }
        let cancellation = CancellationToken()
        let encoderPolicy = keepEncoderInfo
        let pending = items.map { ($0.id, $0.url) }
        token = cancellation
        isBusy = true
        isScanning = true
        isCancelling = false
        overallProgress = 0
        var rescanning = items
        for index in rescanning.indices {
            rescanning[index].phase = .scanning
            rescanning[index].scan = nil
            rescanning[index].output = nil
            rescanning[index].didReplaceOriginal = false
            rescanning[index].outcomeWarnings = []
            rescanning[index].progress = 0
            rescanning[index].detail = "Reading current metadata…"
        }
        items = rescanning
        activity = "Rescanning for the encoder setting…"
        job = Task {
            for (number, entry) in pending.enumerated() {
                if cancellation.isCancelled { break }
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try MediaScanner.scan(url: entry.1, cancellation: cancellation, keepEncoderInfo: encoderPolicy) }
                }.value
                if let row = items.firstIndex(where: { $0.id == entry.0 }) { applyScan(result, at: row) }
                overallProgress = Double(number + 1) / Double(pending.count)
            }
            markUnfinishedScansCancelled()
            let cancelled = isCancelling
            finish()
            overallProgress = 0
            activity = cancelled ? "Rescan cancelled" : "Encoder setting updated · \(readyCount) ready"
        }
    }

    private func applyScan(_ result: Result<ScanResult, Error>, at row: Int) {
        var item = items[row]
        switch result {
        case .success(let scan):
            item.scan = scan
            let readOnly = scan.warnings.contains { $0.hasPrefix("Read only:") }
            item.phase = scan.canClean ? .ready : (readOnly ? .readOnly : .inspected)
            item.detail = scan.canClean ? "\(scan.removableTagCount) removable tags" : (readOnly ? "Embedded tags not inventoried · unsupported for cleaning" : "No safely removable tags found")
            item.progress = 0
        case .failure(let error):
            item.phase = isCancelling ? .cancelled : .failed
            item.detail = error.localizedDescription
        }
        items[row] = item
    }

    private func markUnfinishedScansCancelled() {
        guard items.contains(where: { $0.phase == .scanning }) else { return }
        var cancelled = items
        for index in cancelled.indices where cancelled[index].phase == .scanning {
            cancelled[index].phase = .cancelled
            cancelled[index].detail = "Scan cancelled"
        }
        items = cancelled
    }

    private func finish() {
        isBusy = false
        isScanning = false
        isCancelling = false
        token = nil
    }

    nonisolated private static func enumerate(_ inputs: [URL], existing: Set<String>, token: CancellationToken) -> (urls: [URL], skipped: Int) {
        let extensions = MediaScanner.videoExtensions.union(["m2v"])
        var seen = existing
        var urls: [URL] = []
        var skipped = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        func collect(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true, values.isRegularFile == true else { skipped += 1; return }
            let stem = url.deletingPathExtension().lastPathComponent
            let generatedCopy = stem.range(of: #"\.stripped(?:-\d+)?$"#, options: .regularExpression) != nil
            guard extensions.contains(url.pathExtension.lowercased()), !url.lastPathComponent.hasPrefix("."), !generatedCopy else { skipped += 1; return }
            let normalized = url.standardizedFileURL
            if seen.insert(normalized.path).inserted { urls.append(normalized) }
        }
        for input in inputs {
            if token.isCancelledForUI { break }
            let values = try? input.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { skipped += 1; continue }
            if values?.isDirectory == true {
                guard let walker = FileManager.default.enumerator(at: input, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in skipped += 1; return true }) else { skipped += 1; continue }
                while let url = walker.nextObject() as? URL {
                    if token.isCancelledForUI { break }
                    let child = try? url.resourceValues(forKeys: Set(keys))
                    if child?.isSymbolicLink == true { walker.skipDescendants(); skipped += 1; continue }
                    if child?.isDirectory == true { continue }
                    collect(url)
                }
            } else { collect(input) }
        }
        return (urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, skipped)
    }
}

private extension CancellationToken {
    var isCancelledForUI: Bool { (try? check()) == nil }
}
