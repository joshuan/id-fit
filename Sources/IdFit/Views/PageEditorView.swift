import SwiftUI

/// Framing one page, in the main window and in place of the grid: a bar of
/// controls on top, the page itself on a dark canvas, and the rest of the
/// document as a filmstrip along the bottom.
///
/// Everything here works in the page's *rotated* space — what the export will
/// look like — and crops are converted back to source space on the way out.
struct PageEditorView: View {
    let store: DocumentStore
    /// The page being framed. Writing to it moves the editor along, which is
    /// how the arrows and the filmstrip navigate.
    @Binding var pageID: UUID?
    /// Back to the grid.
    let onClose: () -> Void

    @State private var preview: CGImage?
    @State private var ordering = PartOrdering()
    /// Which pieces of guidance have already been said, kept where every window
    /// reads the same answer.
    @AppStorage(EditorHint.storageKey) private var readHints = ""

    private var index: Int? {
        guard let pageID else { return nil }
        return store.state.pages.firstIndex { $0.id == pageID }
    }

    private var page: Page? {
        index.map { store.state.pages[$0] }
    }

    /// Source size as seen after rotation.
    private var displayedSize: CGSize? {
        guard let page, let size = store.sourceSizes[page.source] else { return nil }
        return page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    private var hasRatio: Bool { store.state.cropAspectRatio != nil }
    private var isStraightened: Bool { page?.quad != nil }
    private var isComposed: Bool { page?.composition != nil }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if isComposed {
                compositionBar
                Divider()
            }
            canvas
            Divider()
            if page != nil, !isStraightened, !isComposed {
                tiltBar
                Divider()
            }
            PageFilmstrip(store: store, currentID: $pageID)
        }
        .task(id: page.map { PagePreviewKey($0, sourceRevision: store.sourceRevision) }) { await loadPreview() }
        .background {
            PartOrderKeyMonitor(
                enabled: isComposed && !store.isLoading && !store.isExporting,
                onPress: { ordering.begin() },
                onRelease: {
                    if ordering.end(), let page { store.cyclePartOrder(forPageID: page.id) }
                },
                onCancel: { ordering = PartOrdering() }
            )
        }
        .onChange(of: pageID) { ordering = PartOrdering() }
        .onChange(of: page?.composition?.partCount) { ordering = PartOrdering() }
        .onChange(of: page?.composition?.regions.count) { ordering = PartOrdering() }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                onClose()
            } label: {
                Label("All Pages", systemImage: "square.grid.2x2")
            }
            .help("Back to all pages, keeping this page's edits")

            Divider().frame(height: 20)

            pageStepper

            Spacer(minLength: 12)

            Button {
                if let page { store.rotatePage(id: page.id, by: -90) }
            } label: {
                Label("Rotate Left", systemImage: "rotate.left").labelStyle(.iconOnly)
            }
            .keyboardShortcut("[", modifiers: .command)
            .help("Rotate left (⌘L or ⌘[)")

            Button {
                if let page { store.rotatePage(id: page.id, by: 90) }
            } label: {
                Label("Rotate Right", systemImage: "rotate.right").labelStyle(.iconOnly)
            }
            .keyboardShortcut("]", modifiers: .command)
            .help("Rotate right (⌘R or ⌘])")

            Divider().frame(height: 20)

            Toggle(isOn: Binding(
                get: { isStraightened },
                set: { _ in if let page { store.toggleStraightening(forPageID: page.id) } }
            )) {
                Label("Straighten", systemImage: "skew")
            }
            .toggleStyle(.button)
            .disabled(isComposed)
            .help("Map the document's four corners onto a true rectangle")

            Button("Auto-Straighten", systemImage: "wand.and.rays") {
                if let page {
                    Task { await store.redetectEdges(forPageIDs: [page.id]) }
                }
            }
            .disabled(store.isDetectingEdges)
            .help("Find and straighten up to four parts in this scan")

            Button {
                if let page { store.resetPage(forPageID: page.id) }
            } label: {
                Label("Reset Page", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly)
            }
            .keyboardShortcut(.cancelAction)
            .help("Clear this page's crop, straightening and rotation; keep the original untouched (Esc)")

            Menu {
                Picker("Number of Parts", selection: Binding(
                    get: { page?.composition?.partCount ?? 1 },
                    set: { count in
                        if let page { store.setPartCount(count, forPageID: page.id) }
                    }
                )) {
                    ForEach(1...4, id: \.self) { count in
                        Text(count == 1 ? "1 Part" : "\(count) Parts").tag(count)
                    }
                }
                Button("Cycle Part Order") {
                    if let page { store.cyclePartOrder(forPageID: page.id) }
                }
                .disabled((page?.composition?.regions.count ?? 0) < 2)

                Divider()

                Button("Reset Crop") {
                    if let page { store.resetCrop(forPageID: page.id) }
                }
                .disabled(isComposed || isStraightened || (!hasRatio && page?.crop == nil))

                Button("Apply This Framing to All Pages") {
                    if let page { store.applyCropToAllPages(fromPageID: page.id) }
                }
                .disabled(page?.crop == nil || isStraightened)

                Button("Use This Framing as Common Format") {
                    if let page { store.useFramingAsCommonFormat(fromPageID: page.id) }
                }
                .disabled(page?.crop == nil || isStraightened)
                .help("Crop every page to the shape this one is framed with")

                Button(orientationButtonTitle) {
                    if let page { store.toggleCropOrientation(forPageID: page.id) }
                }
                .disabled(isComposed || !hasRatio || isStraightened)
                .help("Use the document's shape the other way round on this page")

                Divider()

                Button("Duplicate Page") {
                    if let page { store.duplicatePage(id: page.id) }
                }

                Divider()

                Button("Show Hints Again") { readHints = "" }
                    .disabled(readHints.isEmpty)
                    .help("Bring back the guidance shown under a page")
            } label: {
                Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var compositionBar: some View {
        HStack(spacing: 12) {
            Text("\(page?.composition?.partCount ?? 2) Parts")
                .font(.callout.weight(.medium))
            Picker("Arrangement", selection: Binding(
                get: { page?.composition?.layout ?? .vertical },
                set: { layout in if let page { store.setPartLayout(layout, forPageID: page.id) } }
            )) {
                ForEach(PartComposition.Layout.allCases, id: \.self) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            Text(compositionInstruction)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                if let page { store.cyclePartOrder(forPageID: page.id) }
            } label: {
                Label("Cycle Part Order", systemImage: "arrow.triangle.2.circlepath").labelStyle(.iconOnly)
            }
            .disabled((page?.composition?.regions.count ?? 0) < 2)
            .help("Cycle part order (C). Hold C and click parts to choose their order.")
            Button("Redraw Parts") {
                if let page { store.redrawParts(forPageID: page.id) }
            }
            Button("Save JPG…", systemImage: "square.and.arrow.down") {
                if let page { Task { await store.runCombinedJPGExport(forPageID: page.id) } }
            }
            .disabled(page?.composition?.isComplete != true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var compositionInstruction: String {
        guard let composition = page?.composition else { return "" }
        if ordering.isHeld {
            return ordering.nextSlot < composition.regions.count
                ? "Click part \(ordering.nextSlot + 1). Remaining numbers update automatically."
                : "Order set. Release C to finish."
        }
        if !composition.isComplete { return "Draw part \(composition.regions.count + 1) of \(composition.partCount)." }
        return "C: cycle order. Hold C and click parts to set their order."
    }

    private var pageStepper: some View {
        HStack(spacing: 10) {
            Button {
                step(by: -1)
            } label: {
                Label("Previous Page", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled((index ?? 0) <= 0)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Previous page (←)")

            VStack(spacing: 1) {
                Text("Page \((index ?? 0) + 1) of \(store.state.pages.count)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                if let page {
                    Text(page.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // Fixed, so the arrows keep still as the file name changes.
            .frame(width: 190)

            Button {
                step(by: 1)
            } label: {
                Label("Next Page", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .disabled((index ?? 0) >= store.state.pages.count - 1)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Next page (→)")
        }
    }

    // MARK: - Tilt

    /// A strip of its own rather than another button in the bar above: this is
    /// a continuous adjustment, wants room to be dragged in, and should stay
    /// quiet until somebody looks for it.
    private var tiltBar: some View {
        HStack(spacing: 10) {
            Text("Tilt")
                .font(.caption)
                .foregroundStyle(.secondary)

            // The curve spends most of the travel near zero, where scans
            // actually lie, and the quantized angle is 0 across a small band
            // around the middle — which is the detent.
            Slider(value: tiltPosition, in: -1...1)
                .controlSize(.small)
                .frame(maxWidth: 420)

            TextField("Degrees", value: tiltDegrees, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 62)
            Text("°")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                if let page { store.setTilt(0, forPageID: page.id) }
            } label: {
                Label("Reset Tilt", systemImage: "arrow.counterclockwise").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Straighten up (0°)")
            // Kept in the layout so the row does not twitch as the tilt
            // crosses zero.
            .opacity(page?.tilt == 0 ? 0 : 1)
            .disabled(page?.tilt == 0)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var tiltPosition: Binding<Double> {
        Binding(
            get: { TiltGeometry.sliderPosition(forAngle: page?.tilt ?? 0) },
            set: { position in
                guard let page else { return }
                store.setTilt(TiltGeometry.angle(atSliderPosition: position), forPageID: page.id)
            }
        )
    }

    private var tiltDegrees: Binding<Double> {
        Binding(
            get: { page?.tilt ?? 0 },
            set: { degrees in
                guard let page else { return }
                store.setTilt(degrees, forPageID: page.id)
            }
        )
    }

    /// Names the shape the button would switch to, not the current one.
    private var orientationButtonTitle: String {
        guard let page, let ratio = store.state.outputRatio(for: page) else {
            return "Flip Crop Orientation"
        }
        return ratio >= 1 ? "Make Crop Upright" : "Lay Crop Sideways"
    }

    private func step(by offset: Int) {
        guard let index else { return }
        let target = index + offset
        guard store.state.pages.indices.contains(target) else { return }
        pageID = store.state.pages[target].id
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
            content
                .padding(.trailing, 176)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { hint }
        .overlay(alignment: .topTrailing) {
            if let page, let folder = store.folderURL {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Result")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    PageCell(page: page, number: 0, folder: folder,
                             outputRatio: store.state.outputRatio(for: page),
                             isMissing: store.missingSources.contains(page.source), layout: .result,
                             sourceRevision: store.sourceRevision)
                }
                .padding(10)
                .frame(width: 170)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
                .allowsHitTesting(false)
            }
        }
        .clipped()
        // The canvas is a dark surface whatever the system appearance, so
        // anything standing on it — the hint, a spinner, a missing-file
        // notice — has to be drawn for a dark background.
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        if let page, let size = displayedSize, let preview {
            if let composition = page.composition {
                PartsCanvas(
                    image: preview, displayedSize: size,
                    regions: composition.regions.map { DocumentQuadGeometry.rotated($0, by: page.rotation) },
                    partCount: composition.partCount,
                    isChoosingOrder: ordering.isHeld,
                    onSelect: { part in
                        if let slot = ordering.select(part: part, count: composition.regions.count), let part {
                            store.movePart(at: part, to: slot, forPageID: page.id)
                        }
                    },
                    onAdd: { region in
                        store.addPart(DocumentQuadGeometry.rotated(region, by: -page.rotation), forPageID: page.id)
                    },
                    onChange: { index, region in
                        store.setPart(DocumentQuadGeometry.rotated(region, by: -page.rotation), at: index, forPageID: page.id)
                    }
                )
                .id(page.id)
            } else if let quad = page.quad {
                // Straightened: the four corners are what matters, and they
                // need not form a rectangle.
                QuadCanvas(
                    image: preview,
                    displayedSize: size,
                    quad: DocumentQuadGeometry.rotated(quad, by: page.rotation)
                ) { edited in
                    store.setQuad(
                        DocumentQuadGeometry.rotated(edited, by: -page.rotation),
                        forPageID: page.id
                    )
                }
            } else {
                CropCanvas(
                    image: preview,
                    displayedSize: size,
                    crop: page.crop.map { CropGeometry.rotated($0, by: page.rotation) },
                    // A quarter turn does not change which way a fine turn
                    // goes, so the same angle serves both spaces.
                    tilt: page.tilt,
                    outputRatio: store.state.outputRatio(for: page),
                    onChange: { edited in
                        store.setCrop(CropGeometry.rotated(edited, by: -page.rotation), forPageID: page.id)
                    },
                    onDraw: { drawn in
                        store.drawCrop(drawn, onPageID: page.id)
                    },
                    onDistort: { quad in
                        store.setQuad(
                            DocumentQuadGeometry.rotated(quad, by: -page.rotation),
                            forPageID: page.id
                        )
                    }
                )
            }
        } else if let page, store.missingSources.contains(page.source) {
            ContentUnavailableView(
                "File is missing",
                systemImage: "exclamationmark.triangle",
                description: Text("\(page.source.file) is not in the folder right now. Its crop is kept.")
            )
        } else {
            ProgressView()
        }
    }

    /// One line of guidance for whichever gesture this page is waiting for —
    /// until it has been read, which it only needs to be once.
    ///
    /// Nothing here answers to the pointer but the close button: the capsule
    /// stands over the middle of the bottom edge of the page, and a crop drawn
    /// from there must reach the canvas rather than the advice about drawing it.
    @ViewBuilder
    private var hint: some View {
        if let advice {
            HStack(spacing: 8) {
                Label(advice.text, systemImage: advice.icon)
                    .allowsHitTesting(false)

                Button {
                    markRead(advice)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide this hint for good")
            }
            .font(.callout)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background { Capsule().fill(.regularMaterial).allowsHitTesting(false) }
            .padding(.bottom, 16)
            .transition(.opacity)
            // Long enough to be read, and then gone: guidance that returns on
            // every page is noise by the third one. It goes quiet on its own so
            // that dismissing it is not one more thing to do; *Show Hints
            // Again* is how it comes back.
            .task(id: advice) {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                markRead(advice)
            }
        }
    }

    private var advice: EditorHint? {
        guard let page, preview != nil, !isComposed else { return nil }
        let hint: EditorHint = if isStraightened {
            .straighten
        } else if page.crop == nil {
            .drawCrop
        } else {
            .perspective
        }
        return EditorHint.read(from: readHints).contains(hint) ? nil : hint
    }

    private func markRead(_ hint: EditorHint) {
        withAnimation(.easeOut(duration: 0.2)) {
            readHints = EditorHint.marking(hint, readIn: readHints)
        }
    }

    private func loadPreview() async {
        preview = nil
        guard let page, let folder = store.folderURL else { return }
        guard let image = await ThumbnailProvider.shared.thumbnail(
            for: page.source, in: folder, maxPixel: 1600
        ) else { return }
        // Rotate once here rather than on every redraw.
        preview = page.rotation == 0 ? image : PageRenderer.rotate(image, by: page.rotation)
    }
}
