import SwiftUI

/// All outlines remain visible; numbering follows the chosen output order.
struct PartsCanvas: View {
    let image: CGImage
    let displayedSize: CGSize
    let regions: [DocumentQuad]
    let partCount: Int
    let isChoosingOrder: Bool
    let onSelect: (Int?) -> Void
    let onAdd: (DocumentQuad) -> Void
    let onChange: (Int, DocumentQuad) -> Void

    @State private var drawnCrop: CropRect?
    @State private var gestureStart: DocumentQuad?
    @State private var focusedHandle: Handle?

    private struct Handle: Equatable {
        let part: Int
        let corner: DocumentQuad.Corner
    }

    private let canvasSpace = "partsCanvas"

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / displayedSize.width, geometry.size.height / displayedSize.height)
            let frame = CGRect(
                x: (geometry.size.width - displayedSize.width * scale) / 2,
                y: (geometry.size.height - displayedSize.height * scale) / 2,
                width: displayedSize.width * scale, height: displayedSize.height * scale
            )
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                    .offset(x: frame.minX, y: frame.minY)

                if !regions.isEmpty {
                    Rectangle()
                        .fill(.black.opacity(0.5))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .mask {
                            ZStack(alignment: .topLeading) {
                                Path { $0.addRect(frame) }.fill(.white)
                                ForEach(regions.indices, id: \.self) { index in
                                    QuadShape(points: regions[index].corners.map { point($0, in: frame) })
                                        .fill(.black)
                                        .blendMode(.destinationOut)
                                }
                            }
                            .compositingGroup()
                        }
                        .allowsHitTesting(false)
                }

                if regions.count < partCount {
                    Color.white.opacity(0.001)
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .pointerStyle(.rectSelection)
                        .offset(x: frame.minX, y: frame.minY)
                        .gesture(drawGesture(in: frame))
                }

                if let drawnCrop {
                    QuadShape(points: DocumentQuad(drawnCrop).corners.map { point($0, in: frame) })
                        .stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .allowsHitTesting(false)
                }

                ForEach(regions.indices, id: \.self) { index in
                    let region = regions[index]
                    let color: Color = [.cyan, .orange, .green, .pink][index % 4]
                    QuadShape(points: region.corners.map { point($0, in: frame) })
                        .stroke(color, lineWidth: 2)
                        .allowsHitTesting(false)
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(.black)
                        .padding(5)
                        .background(color, in: Circle())
                        .position(point(CGPoint(x: region.boundingCrop.x + region.boundingCrop.width / 2,
                                                y: region.boundingCrop.y + region.boundingCrop.height / 2), in: frame))
                        .allowsHitTesting(false)

                    ForEach(DocumentQuad.Corner.allCases, id: \.self) { corner in
                        let position = point(region[corner], in: frame)
                        Circle()
                            .fill(color)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                            .frame(width: 14, height: 14)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                            .pointerStyle(.grabIdle)
                            .offset(x: position.x - 16, y: position.y - 16)
                            .onHover { hovering in
                                if gestureStart == nil {
                                    focusedHandle = hovering ? Handle(part: index, corner: corner) : nil
                                }
                            }
                            .gesture(cornerGesture(part: index, corner: corner, in: frame))
                    }
                }

                if let handle = focusedHandle, regions.indices.contains(handle.part) {
                    let region = regions[handle.part]
                    LoupeView(image: image, focus: region[handle.corner], imageSize: frame.size,
                              guides: region.neighbours(of: handle.corner))
                        .position(LoupeView.position(awayFrom: handle.corner, in: frame))
                        .allowsHitTesting(false)
                }

                if isChoosingOrder {
                    Color.white.opacity(0.001)
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .offset(x: frame.minX, y: frame.minY)
                        .gesture(SpatialTapGesture(coordinateSpace: .named(canvasSpace)).onEnded { value in
                            let normalized = CGPoint(x: (value.location.x - frame.minX) / frame.width,
                                                     y: (value.location.y - frame.minY) / frame.height)
                            onSelect(regions.indices.first { regions[$0].contains(normalized) })
                        })
                }
            }
        }
        .coordinateSpace(name: canvasSpace)
    }

    private func point(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }

    private func crop(from start: CGPoint, to end: CGPoint, in frame: CGRect) -> CropRect {
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                    y: min(max((point.y - frame.minY) / frame.height, 0), 1))
        }
        let a = normalized(start)
        let b = normalized(end)
        return CropRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func drawGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(canvasSpace))
            .onChanged { value in
                drawnCrop = crop(from: value.startLocation, to: value.location, in: frame)
            }
            .onEnded { value in
                let crop = crop(from: value.startLocation, to: value.location, in: frame)
                drawnCrop = nil
                guard crop.width > 0.02, crop.height > 0.02 else { return }
                onAdd(DocumentQuad(crop))
            }
    }

    private func cornerGesture(part: Int, corner: DocumentQuad.Corner, in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard regions.indices.contains(part) else { return }
                let start = gestureStart ?? regions[part]
                gestureStart = start
                focusedHandle = Handle(part: part, corner: corner)
                var edited = start
                edited[corner] = CGPoint(x: start[corner].x + value.translation.width / frame.width,
                                         y: start[corner].y + value.translation.height / frame.height)
                onChange(part, edited.clampedToUnitSquare())
            }
            .onEnded { _ in
                gestureStart = nil
                focusedHandle = nil
            }
    }
}
