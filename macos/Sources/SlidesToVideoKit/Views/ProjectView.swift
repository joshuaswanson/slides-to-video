import PDFKit
import SwiftUI

struct ProjectView: View {
    @Bindable var project: Project
    @State private var selection: Int?
    @State private var showInspector = true

    private var selectedSlide: Slide? {
        project.slides.first { $0.num == selection } ?? project.slides.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = project.scriptError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.red.opacity(0.15))
            }
            HSplitView {
                SlidePreview(page: selectedSlide.flatMap(project.page(for:)), number: selectedSlide?.num)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                if let slide = selectedSlide {
                    ScriptEditor(project: project, slide: slide)
                        .id(slide.num)
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
                }
            }
            Divider()
            TimelineStrip(project: project, selection: Binding(
                get: { selectedSlide?.num },
                set: { selection = $0 }
            ))
            .frame(height: 132)
        }
        .navigationTitle(project.name)
        .inspector(isPresented: $showInspector) {
            ProjectInspector(project: project)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Settings", systemImage: "sidebar.trailing")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            project.reloadScript()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard let current = selectedSlide,
              let index = project.slides.firstIndex(of: current) else { return .ignored }
        let next = index + delta
        guard project.slides.indices.contains(next) else { return .handled }
        selection = project.slides[next].num
        return .handled
    }
}

struct SlidePreview: View {
    let page: PDFPage?
    let number: Int?

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let page {
                GeometryReader { geometry in
                    PageImage(page: page, size: geometry.size)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .padding(24)
            } else {
                ContentUnavailableView(
                    number.map { "No PDF page for slide \($0)" } ?? "No slides",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Choose a slides PDF in the settings sidebar.")
                )
            }
        }
    }
}

struct PageImage: View {
    let page: PDFPage
    let size: CGSize

    var body: some View {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}
