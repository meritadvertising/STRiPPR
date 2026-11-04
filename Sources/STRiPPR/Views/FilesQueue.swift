import SwiftUI

struct FilesQueue: View {
    @Bindable var store: BatchStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("FILES").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5)
                Text("\(store.items.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("Filter files", selection: $store.fileFilter) {
                    ForEach(FileFilter.allCases) { filter in
                        Text("\(filter.shortTitle) \(count(for: filter))").tag(filter)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 342)
                .help("With tags means supported removable tags found by the latest scan. Unscanned or unsupported files appear in Both.")
                Picker("Sort by", selection: $store.fileSort) {
                    ForEach(FileSort.allCases) { sort in Text(sort.title).tag(sort) }
                }
                .frame(width: 167).controlSize(.small)
                .accessibilityLabel("Sort files by")
                Button { store.sortAscending.toggle() } label: {
                    Image(systemName: store.sortAscending ? "arrow.up" : "arrow.down").frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(store.sortAscending ? "Ascending order. Click for descending." : "Descending order. Click for ascending.")
                .accessibilityLabel(store.sortAscending ? "Sort ascending" : "Sort descending")
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 8)
            HStack {
                Text("Showing \(store.filteredCount) of \(store.items.count)")
                if store.unknownTagsCount > 0 { Text("· \(store.unknownTagsCount) unclassified") }
                Spacer()
                Text("Strip processes all \(store.readyCount) ready files")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.bottom, 11)
            Rectangle().fill(Theme.border).frame(height: 1)
            if store.items.isEmpty {
                emptyQueue.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.visibleItems.isEmpty {
                VStack(spacing: 12) {
                    Text("No files match this filter").font(.system(size: 15, weight: .medium))
                    Button("Show both") { store.fileFilter = .both }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.visibleItems) { snapshot in
                            FileRow(item: rowBinding(snapshot), busy: store.isBusy, retry: { store.retry(snapshot.id) })
                            Rectangle().fill(Theme.border).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private func rowBinding(_ snapshot: FileItem) -> Binding<FileItem> {
        Binding(get: {
            guard let index = store.index(for: snapshot.id) else { return snapshot }
            return store.items[index]
        }, set: { store.setExpanded($0.expanded, for: snapshot.id) })
    }

    private func count(for filter: FileFilter) -> Int {
        switch filter {
        case .both: return store.items.count
        case .withTags: return store.withTagsCount
        case .withoutTags: return store.withoutTagsCount
        }
    }

    private var emptyQueue: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.document").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(Theme.cyan)
            Text("Drop videos or folders here").font(.system(size: 20, weight: .semibold))
            Text("Subfolders included. No thumbnails. Just the files and their tags.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Choose files…") { store.chooseFiles() }.buttonStyle(.bordered)
            Text("MP4 · MOV · M4V · AVI supported fields\nMKV · MPEG and other formats inspected with explicit limits")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).multilineTextAlignment(.center).lineSpacing(5)
        }.padding(28)
    }
}
