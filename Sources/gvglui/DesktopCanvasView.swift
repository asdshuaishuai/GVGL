import SwiftUI
import GVGLCore

/// Color coding by AX role.
enum RoleStyle {
    static func color(for role: String) -> Color {
        switch role {
        case "AXWindow": return .blue
        case "AXSheet", "AXDrawer": return .blue.opacity(0.8)
        case "AXButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle": return .indigo
        case "AXTextField", "AXComboBox", "AXTextArea", "AXSecureTextField": return .green
        case "AXCheckBox", "AXRadioButton": return .orange
        case "AXSlider", "AXStepper", "AXProgressIndicator": return .yellow
        case "AXMenu", "AXMenuItem", "AXMenuBarItem": return .teal
        case "AXMenuBar": return .secondary
        case "AXTabGroup", "AXTab": return .pink
        case "AXToolbar": return .brown
        case "AXList", "AXOutline", "AXTable": return .mint
        case "AXRow", "AXCell": return .mint.opacity(0.7)
        case "AXLink": return .cyan
        case "AXImage": return .purple
        case "AXStaticText", "AXHeading": return .gray
        case "AXSplitter": return .gray.opacity(0.5)
        default: return .gray.opacity(0.6)
        }
    }

    static func label(for role: String) -> String {
        role.replacingOccurrences(of: "AX", with: "")
    }
}

/// Desktop canvas: draws entities in normalized screen space with auto-fit.
struct DesktopCanvasView: View {
    let frame: GVGLFrame?
    let selectedID: String?
    let onSelect: (String?) -> Void

    @State private var dragging: DragGesture.Value?
    @State private var hoveredID: String?

    var body: some View {
        Canvas { context, size in
            guard let frame else { return }
            let entities = frame.allEntities
            let bounds = drawingBounds(entities)
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let offset = CGPoint(
                x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale
            )

            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
            }

            func rect(_ r: NormRect) -> CGRect {
                let p1 = point(r.x, r.y)
                let p2 = point(r.x + r.w, r.y + r.h)
                return CGRect(x: p1.x, y: p1.y, width: p2.x - p1.x, height: p2.y - p1.y)
            }

            // Main display boundary (screen space [0,1]×[0,1]).
            let main = rect(NormRect(x: 0, y: 0, w: 1, h: 1))
            context.stroke(Path(main), with: .color(.primary.opacity(0.25)), lineWidth: 1)
            let mainLabel = Text("主屏 1.0×1.0").font(.system(size: 9)).foregroundStyle(.secondary)
            context.draw(mainLabel, at: CGPoint(x: main.minX + 4, y: main.minY + 10), anchor: .topLeading)

            // Menu bar band first (it's the top strip of the screen; drawing
            // it early keeps windows/elements visually on top).
            for bar in entities where bar.role == "AXMenuBar" {
                let r = rect(bar.geometry.screen)
                context.fill(Path(r), with: .color(.secondary.opacity(0.18)))
                context.stroke(Path(r), with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)
                context.draw(Text("菜单栏").font(.system(size: 8)).foregroundStyle(.secondary),
                             at: CGPoint(x: r.maxX - 4, y: r.midY), anchor: .trailing)
            }

            // Windows first (borders + app-name labels), then smaller elements.
            let windows = entities.filter { $0.role == "AXWindow" }
            let elements = entities.filter { $0.role != "AXWindow" && $0.role != "AXMenuBar" }
                .sorted { $0.geometry.area < $1.geometry.area }

            for w in windows {
                let r = rect(w.geometry.screen)
                let isFrontmost = w.appID == frame.frontmostApp
                context.stroke(
                    Path(roundedRect: r, cornerRadius: 3),
                    with: .color(.blue.opacity(isFrontmost ? 1.0 : 0.9)),
                    lineWidth: isFrontmost ? 2.5 : 1.5
                )
                // App title above the window frame (captured app label).
                let appName = w.appName?.isEmpty == false
                    ? w.appName!
                    : (w.title?.isEmpty == false ? w.title! : "未命名应用")
                let title = Text(appName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.blue)
                let labelPoint = CGPoint(x: r.minX + 3, y: max(r.minY - 12, 2))
                context.draw(title, at: labelPoint, anchor: .topLeading)
                if isFrontmost {
                    context.draw(Text("前台").font(.system(size: 8, weight: .bold)).foregroundStyle(.blue),
                                 at: CGPoint(x: r.maxX - 4, y: max(r.minY - 10, 2)), anchor: .topTrailing)
                }
            }

            for e in elements {
                let r = rect(e.geometry.screen)
                guard r.width > 1, r.height > 1 else { continue }
                let isSelected = e.id == selectedID
                let isHovered = e.id == hoveredID
                let color = RoleStyle.color(for: e.role)
                context.fill(Path(roundedRect: r, cornerRadius: 2),
                             with: .color(isSelected ? .red : color.opacity(isHovered ? 0.85 : 0.55)))
                // Keyboard focus is first-class desktop state (V3): ring it.
                if e.focused {
                    context.stroke(Path(roundedRect: r.insetBy(dx: -1, dy: -1), cornerRadius: 3),
                                   with: .color(.yellow), lineWidth: 1.5)
                }
                if isSelected {
                    context.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(.red), lineWidth: 2)
                    let app = e.appName?.isEmpty == false ? "\(e.appName!) · " : ""
                    let label = Text(app + entityDisplayTitle(e))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                    context.draw(label, at: CGPoint(x: r.midX, y: r.minY - 4), anchor: .bottom)
                }
            }
        }
        .background(Color.black.opacity(0.03))
        .overlay(alignment: .topTrailing) {
            if let frame {
                Text("\(frame.allEntities.count) 实体 · v\(frame.version) · \(frame.status.rawValue)")
                    .font(.caption2.monospaced())
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
        .overlay(alignment: .bottomLeading) { legend }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    if let frame, let entity = hitTest(frame.allEntities, at: value.location, in: currentSize) {
                        onSelect(entity.id)
                    } else {
                        onSelect(nil)
                    }
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if let frame, let entity = hitTest(frame.allEntities, at: location, in: currentSize) {
                    hoveredID = entity.id
                } else {
                    hoveredID = nil
                }
            case .ended:
                hoveredID = nil
            }
        }
    }

    @State private var currentSize: CGSize = .zero

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach([("AXWindow", RoleStyle.color(for: "AXWindow")),
                     ("AXButton", RoleStyle.color(for: "AXButton")),
                     ("AXTextField", RoleStyle.color(for: "AXTextField")),
                     ("AXCheckBox", RoleStyle.color(for: "AXCheckBox")),
                     ("AXImage", RoleStyle.color(for: "AXImage")),
                     ("AXStaticText", RoleStyle.color(for: "AXStaticText"))], id: \.0) { role, color in
                HStack(spacing: 3) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(RoleStyle.label(for: role)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    private func drawingBounds(_ entities: [Entity]) -> CGRect {
        var minX = 0.0, minY = 0.0, maxX = 1.0, maxY = 1.0
        for e in entities {
            let r = e.geometry.screen
            minX = min(minX, r.x)
            minY = min(minY, r.y)
            maxX = max(maxX, r.x + r.w)
            maxY = max(maxY, r.y + r.h)
        }
        let pad = 0.05
        return CGRect(x: minX - pad, y: minY - pad,
                      width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
    }

    private func hitTest(_ entities: [Entity], at location: CGPoint, in size: CGSize) -> Entity? {
        guard size.width > 0, size.height > 0 else { return nil }
        let bounds = drawingBounds(entities)
        let scale = min(size.width / bounds.width, size.height / bounds.height)
        let offset = CGPoint(
            x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
            y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale
        )
        func screenPoint(_ p: CGPoint) -> (Double, Double) {
            ((p.x - offset.x) / scale, (p.y - offset.y) / scale)
        }
        let (sx, sy) = screenPoint(location)
        // Smallest area first (topmost visual).
        let hit = entities
            .filter { $0.role != "AXWindow" }
            .filter { $0.geometry.screen.contains(sx: sx, sy: sy) }
            .sorted { $0.geometry.area < $1.geometry.area }
            .first
        if hit != nil { return hit }
        return entities
            .filter { $0.role == "AXWindow" }
            .first { $0.geometry.screen.contains(sx: sx, sy: sy) }
    }
}

private extension NormRect {
    func contains(sx: Double, sy: Double) -> Bool {
        sx >= x && sx <= x + w && sy >= y && sy <= y + h
    }
}
