import PDFKit
import SwiftUI

struct TimelinePanel: View {
    let project: Project
    let selection: Int?
    let select: (Int) -> Void

    var body: some View {
        let _ = project.audioRevision
        let cache = project.clipCache()
        let durations = Dictionary(uniqueKeysWithValues: project.slides.map { slide in
            (slide.num, (cache?.isFresh(slide) ?? false) ? AudioIO.duration(cache!.clipURL(slide.num)) : nil)
        })
        let total = durations.values.compactMap { $0 }.reduce(0, +)

        VStack(spacing: 0) {
            HStack {
                SectionLabel("Timeline")
                Spacer()
                let count = project.slides.count
                Text("\(count) slide\(count == 1 ? "" : "s")\(total > 0 ? String(format: " / %.1fs", total) : "")")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderMuted).frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(project.slides.enumerated()), id: \.element.id) { index, slide in
                            if index > 0 {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Theme.borderMuted)
                                    .frame(width: 2, height: 24)
                                    .frame(width: 8)
                            }
                            TimelineItem(
                                page: project.page(for: slide),
                                slide: slide,
                                duration: durations[slide.num] ?? nil,
                                hasAudio: durations[slide.num] != nil,
                                isSelected: slide.num == selection
                            )
                            .id(slide.num)
                            .onTapGesture { select(slide.num) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.automatic)
                .onChange(of: selection) { _, num in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(num, anchor: .center) }
                }
            }
        }
        .background(Theme.bgSecondary)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderMuted).frame(height: 1) }
    }
}

struct TimelineItem: View {
    let page: PDFPage?
    let slide: Slide
    let duration: Double?
    let hasAudio: Bool
    let isSelected: Bool
    @State private var hovering = false

    private var borderColor: Color {
        if isSelected { return Theme.green }
        if hasAudio { return Theme.greenDim }
        return hovering ? Theme.borderSubtle : .clear
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.bgSlide
                if let page {
                    Image(nsImage: page.thumbnail(of: CGSize(width: 320, height: 180), for: .mediaBox))
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 126, height: 126 * 9 / 16)
            .clipped()
            HStack {
                Text("\(slide.num)")
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(duration.map { String(format: "%.1fs", $0) } ?? "--")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(width: 126)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(hasAudio ? Theme.green : Theme.textMuted)
                .frame(width: 7, height: 7)
                .shadow(color: hasAudio ? Theme.green.opacity(0.4) : .clear, radius: 3)
                .padding(4)
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2).strokeBorder(borderColor, lineWidth: 2))
        .shadow(color: isSelected ? Theme.green.opacity(0.2) : .clear, radius: 6)
        .offset(y: hovering && !isSelected ? -1 : 0)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contentShape(Rectangle())
    }
}
