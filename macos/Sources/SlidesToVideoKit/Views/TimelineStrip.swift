import PDFKit
import SwiftUI

struct TimelineStrip: View {
    let project: Project
    @Binding var selection: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    let _ = project.audioRevision
                    let cache = project.clipCache()
                    ForEach(project.slides) { slide in
                        TimelineItem(
                            page: project.page(for: slide),
                            slide: slide,
                            isSelected: slide.num == selection,
                            hasAudio: cache?.isFresh(slide) ?? false
                        )
                        .id(slide.num)
                        .onTapGesture { selection = slide.num }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: selection) { _, num in
                withAnimation { proxy.scrollTo(num, anchor: .center) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TimelineItem: View {
    let page: PDFPage?
    let slide: Slide
    let isSelected: Bool
    let hasAudio: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                if let page {
                    Image(nsImage: page.thumbnail(of: CGSize(width: 320, height: 180), for: .mediaBox))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 136, height: 77)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? Color.green : Color.clear, lineWidth: 2.5)
            )
            HStack {
                Text("\(slide.num)").font(.caption.monospacedDigit().weight(.semibold))
                Spacer()
                if slide.narration.isEmpty {
                    Text("no narration").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Circle()
                        .fill(hasAudio ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                        .help(hasAudio ? "Audio is up to date" : "Needs audio")
                }
            }
            .frame(width: 136)
        }
        .contentShape(Rectangle())
    }
}
