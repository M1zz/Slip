import SwiftUI
import SlipCore

/// Force-directed graph of the vault's wikilinks.
///
/// Simulation runs for ~400 ticks (≈6.5s at 60fps) after load then freezes.
/// Layout is O(n²) repulsion — fine up to a few hundred notes. Replace with
/// Barnes–Hut if vaults grow past ~1k.
struct GraphView: View {
    @EnvironmentObject var appState: AppState
    @State private var nodes: [GraphNode] = []
    @State private var edges: [(Int, Int)] = []
    @State private var ticksRemaining: Int = 400
    @State private var loaded = false

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .textBackgroundColor)
                Canvas { ctx, size in
                    draw(ctx: ctx, size: size)
                }
                if !loaded {
                    ProgressView("Building graph…")
                }
                if loaded && nodes.isEmpty {
                    Text("No notes yet — create a few and link them with [[…]] to see the graph.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { handleTap(at: $0.location, in: geo.size) }
            )
        }
        .navigationTitle("Graph")
        .task {
            await loadSnapshot()
        }
        .onReceive(timer) { _ in
            guard loaded, ticksRemaining > 0, !nodes.isEmpty else { return }
            tick()
            ticksRemaining -= 1
        }
    }

    // MARK: - Load

    @MainActor
    private func loadSnapshot() async {
        guard let snapshot = appState.graphSnapshot() else {
            loaded = true
            return
        }
        let indexByID = Dictionary(uniqueKeysWithValues:
            snapshot.nodes.enumerated().map { ($0.element.id, $0.offset) }
        )
        let count = snapshot.nodes.count
        let radius: CGFloat = 180
        var built: [GraphNode] = []
        built.reserveCapacity(count)
        for (i, n) in snapshot.nodes.enumerated() {
            let angle = 2 * .pi * Double(i) / Double(max(1, count))
            let jitter = CGFloat.random(in: -40...40)
            built.append(GraphNode(
                id: n.id,
                title: n.title,
                degree: n.degree,
                position: CGPoint(
                    x: CGFloat(cos(angle)) * (radius + jitter),
                    y: CGFloat(sin(angle)) * (radius + jitter)
                ),
                velocity: .zero
            ))
        }
        let builtEdges: [(Int, Int)] = snapshot.edges.compactMap {
            guard let a = indexByID[$0.from], let b = indexByID[$0.to] else { return nil }
            return (a, b)
        }
        self.nodes = built
        self.edges = builtEdges
        self.loaded = true
    }

    // MARK: - Physics

    private func tick() {
        let dt: CGFloat = 1.0 / 60.0
        let count = nodes.count
        var forces = [CGVector](repeating: .zero, count: count)

        // Pairwise repulsion (Coulomb-like).
        let kRepel: CGFloat = 5000
        for i in 0..<count {
            for j in (i + 1)..<count {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                let distSq = max(1, dx * dx + dy * dy)
                let dist = sqrt(distSq)
                let force = kRepel / distSq
                forces[i].dx += (dx / dist) * force
                forces[i].dy += (dy / dist) * force
                forces[j].dx -= (dx / dist) * force
                forces[j].dy -= (dy / dist) * force
            }
        }

        // Spring attraction along edges.
        let kSpring: CGFloat = 0.05
        let restLength: CGFloat = 90
        for (a, b) in edges {
            let dx = nodes[b].position.x - nodes[a].position.x
            let dy = nodes[b].position.y - nodes[a].position.y
            let dist = sqrt(dx * dx + dy * dy)
            guard dist > 0.01 else { continue }
            let diff = dist - restLength
            let fx = (dx / dist) * kSpring * diff
            let fy = (dy / dist) * kSpring * diff
            forces[a].dx += fx; forces[a].dy += fy
            forces[b].dx -= fx; forces[b].dy -= fy
        }

        // Gentle center pull keeps everything on-screen.
        let kCenter: CGFloat = 0.02
        for i in 0..<count {
            forces[i].dx -= nodes[i].position.x * kCenter
            forces[i].dy -= nodes[i].position.y * kCenter
        }

        // Integrate with damping.
        let damping: CGFloat = 0.82
        for i in 0..<count {
            nodes[i].velocity.dx = (nodes[i].velocity.dx + forces[i].dx * dt) * damping
            nodes[i].velocity.dy = (nodes[i].velocity.dy + forces[i].dy * dt) * damping
            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
        }
    }

    // MARK: - Render

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let cx = size.width / 2
        let cy = size.height / 2
        let currentID = appState.currentNoteID

        // Edges under nodes.
        let edgePath = Path { p in
            for (a, b) in edges {
                p.move(to: CGPoint(x: nodes[a].position.x + cx, y: nodes[a].position.y + cy))
                p.addLine(to: CGPoint(x: nodes[b].position.x + cx, y: nodes[b].position.y + cy))
            }
        }
        ctx.stroke(edgePath, with: .color(.secondary.opacity(0.35)), lineWidth: 1)

        for node in nodes {
            let p = CGPoint(x: node.position.x + cx, y: node.position.y + cy)
            let radius: CGFloat = 4 + min(12, CGFloat(log2(Double(node.degree + 2))) * 2.2)
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            let isCurrent = node.id == currentID
            let fill: Color = isCurrent ? .accentColor : (node.degree == 0 ? .secondary : .primary.opacity(0.8))
            ctx.fill(Path(ellipseIn: rect), with: .color(fill))

            var label = Text(node.title).font(.system(size: 11))
            if isCurrent {
                label = label.bold().foregroundColor(.accentColor)
            } else {
                label = label.foregroundColor(.secondary)
            }
            ctx.draw(label, at: CGPoint(x: p.x, y: p.y + radius + 10), anchor: .top)
        }
    }

    // MARK: - Interaction

    private func handleTap(at location: CGPoint, in size: CGSize) {
        let cx = size.width / 2
        let cy = size.height / 2
        let threshold: CGFloat = 18
        var best: (index: Int, dist: CGFloat)? = nil
        for (i, node) in nodes.enumerated() {
            let dx = (node.position.x + cx) - location.x
            let dy = (node.position.y + cy) - location.y
            let d = sqrt(dx * dx + dy * dy)
            if d < threshold, best == nil || d < best!.dist {
                best = (i, d)
            }
        }
        if let best {
            appState.openNote(nodes[best.index].id)
        }
    }
}

private struct GraphNode: Identifiable {
    let id: NoteID
    let title: String
    let degree: Int
    var position: CGPoint
    var velocity: CGVector
}
