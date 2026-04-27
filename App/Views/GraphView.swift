import SwiftUI
import SlipCore

/// Force-directed graph of the vault's wikilinks.
///
/// Simulation runs for ~400 ticks (≈6.5s at 60fps) after load then freezes.
/// Layout is O(n²) repulsion — fine up to a few hundred notes. Replace with
/// Barnes–Hut if vaults grow past ~1k.
///
/// Interactions:
/// - Tap a node → open that note in the main window.
/// - Drag a node → pin it to the cursor (simulation keeps running on others).
/// - Drag the empty background → pan.
/// - Pinch → zoom.
/// - When `appState.selectedTag` is set, non-matching nodes fade so the
///   user can see where that tag lives inside the full graph.
struct GraphView: View {
    @EnvironmentObject var appState: AppState
    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdge] = []
    @State private var ticksRemaining: Int = 400
    @State private var loaded = false

    // Viewport transform.
    @State private var panOffset: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var zoomAtGestureStart: CGFloat = 1.0

    // Drag state. Decided once at the start of a drag based on where it began.
    @State private var dragMode: DragMode = .idle

    /// Tag the user clicked in the legend. Isolates that group visually
    /// (matching nodes/edges stay vivid; everything else dims). Null means
    /// no group is focused.
    @State private var focusedTag: String? = nil

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
                VStack {
                    HStack(alignment: .top) {
                        if !tagsInGraph.isEmpty {
                            legend
                        }
                        Spacer()
                    }
                    .padding(10)
                    Spacer()
                    HStack {
                        Spacer()
                        controls
                    }
                    .padding(10)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in handleDragChanged(value, viewSize: geo.size) }
                        .onEnded   { value in handleDragEnded(value, viewSize: geo.size) },
                    MagnificationGesture()
                        .onChanged { value in zoom = clampZoom(zoomAtGestureStart * value) }
                        .onEnded   { _ in zoomAtGestureStart = zoom }
                )
            )
        }
        .navigationTitle("Graph")
        .task { await loadSnapshot() }
        // Re-pull the snapshot whenever the index is rewritten in the
        // main window (note/tag/link changes), so an open graph stays
        // current with edits the user just made.
        .onChange(of: appState.graphRevision) { _, _ in
            Task { await loadSnapshot() }
        }
        .onReceive(timer) { _ in
            guard loaded, ticksRemaining > 0, !nodes.isEmpty else { return }
            tick()
            ticksRemaining -= 1
        }
    }

    /// Tags that actually appear on at least one node in the current graph,
    /// sorted alphabetically for stable legend ordering.
    private var tagsInGraph: [String] {
        var set = Set<String>()
        for node in nodes { set.formUnion(node.tags) }
        return set.sorted()
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Groups")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 8)
                if focusedTag != nil {
                    Button { focusedTag = nil } label: {
                        Text("Clear")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(tagsInGraph.prefix(10)), id: \.self) { tag in
                Button {
                    focusedTag = (focusedTag == tag) ? nil : tag
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Self.colorForTag(tag))
                            .frame(width: 9, height: 9)
                        Text("#\(tag)")
                            .font(.system(size: 11, weight: focusedTag == tag ? .semibold : .regular))
                            .foregroundStyle(focusedTag == tag ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            if tagsInGraph.count > 10 {
                Text("+\(tagsInGraph.count - 10) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Deterministic tag → color. djb2 hash mapped onto a hue wheel with
    /// mid saturation/brightness so colors stay distinct but not garish.
    static func colorForTag(_ tag: String) -> Color {
        var hash: UInt32 = 5381
        for byte in tag.utf8 {
            hash = (hash &<< 5) &+ hash &+ UInt32(byte)
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.85)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button { zoom = clampZoom(zoom * 1.2); zoomAtGestureStart = zoom } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            Button { zoom = clampZoom(zoom / 1.2); zoomAtGestureStart = zoom } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            Button { resetViewport(); restartSimulation() } label: {
                Image(systemName: "scope")
            }
            .help("Reset view and re-cluster groups")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
                tags: Set(n.tags),
                position: CGPoint(
                    x: CGFloat(cos(angle)) * (radius + jitter),
                    y: CGFloat(sin(angle)) * (radius + jitter)
                ),
                velocity: .zero
            ))
        }
        let builtEdges: [GraphEdge] = snapshot.edges.compactMap { edge in
            guard let a = indexByID[edge.from], let b = indexByID[edge.to] else { return nil }
            return GraphEdge(a: a, b: b, kind: edge.kind)
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

        // Spring attraction along edges. Unlinked mentions pull weaker than
        // explicit wikilinks so implicit connections cluster more loosely.
        let kSpringWiki: CGFloat = 0.05
        let kSpringMention: CGFloat = 0.015
        let restLength: CGFloat = 90
        for edge in edges {
            let a = edge.a, b = edge.b
            let dx = nodes[b].position.x - nodes[a].position.x
            let dy = nodes[b].position.y - nodes[a].position.y
            let dist = sqrt(dx * dx + dy * dy)
            guard dist > 0.01 else { continue }
            let diff = dist - restLength
            let k = edge.kind == "wikilink" ? kSpringWiki : kSpringMention
            let fx = (dx / dist) * k * diff
            let fy = (dy / dist) * k * diff
            forces[a].dx += fx; forces[a].dy += fy
            forces[b].dx -= fx; forces[b].dy -= fy
        }

        // Same-tag attraction: nodes sharing a tag pull toward each other so
        // groups coalesce in space. Scales linearly with distance so it
        // doesn't explode at close range; clamped distance floor avoids
        // singularities.
        let kTagAttract: CGFloat = 0.003
        for i in 0..<count {
            let tagsI = nodes[i].tags
            guard !tagsI.isEmpty else { continue }
            for j in (i + 1)..<count {
                guard !tagsI.isDisjoint(with: nodes[j].tags) else { continue }
                let dx = nodes[j].position.x - nodes[i].position.x
                let dy = nodes[j].position.y - nodes[i].position.y
                let dist = max(8, sqrt(dx * dx + dy * dy))
                let fx = (dx / dist) * kTagAttract * dist
                let fy = (dy / dist) * kTagAttract * dist
                forces[i].dx += fx; forces[i].dy += fy
                forces[j].dx -= fx; forces[j].dy -= fy
            }
        }

        // Gentle center pull keeps everything on-screen.
        let kCenter: CGFloat = 0.02
        for i in 0..<count {
            forces[i].dx -= nodes[i].position.x * kCenter
            forces[i].dy -= nodes[i].position.y * kCenter
        }

        // Integrate with damping. Skip the node the user is currently dragging.
        let damping: CGFloat = 0.82
        let pinned: Int? = {
            if case .node(let idx, _) = dragMode { return idx }
            return nil
        }()
        for i in 0..<count {
            if i == pinned { continue }
            nodes[i].velocity.dx = (nodes[i].velocity.dx + forces[i].dx * dt) * damping
            nodes[i].velocity.dy = (nodes[i].velocity.dy + forces[i].dy * dt) * damping
            nodes[i].position.x += nodes[i].velocity.dx
            nodes[i].position.y += nodes[i].velocity.dy
        }
    }

    // MARK: - Transforms

    private func viewPoint(for graph: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: graph.x * zoom + panOffset.width + size.width / 2,
            y: graph.y * zoom + panOffset.height + size.height / 2
        )
    }

    private func graphPoint(for view: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (view.x - size.width / 2 - panOffset.width) / zoom,
            y: (view.y - size.height / 2 - panOffset.height) / zoom
        )
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, 0.25), 4.0)
    }

    private func resetViewport() {
        panOffset = .zero
        zoom = 1.0
        zoomAtGestureStart = 1.0
    }

    /// Shuffles nodes onto a new initial circle and refills the tick budget
    /// so the tag-cluster forces can pull groups into fresh positions. Used
    /// by the "reset" control after tags change or the layout has drifted.
    private func restartSimulation() {
        let count = nodes.count
        guard count > 0 else { return }
        let radius: CGFloat = 180
        for i in 0..<count {
            let angle = 2 * .pi * Double(i) / Double(count)
            let jitter = CGFloat.random(in: -40...40)
            nodes[i].position = CGPoint(
                x: CGFloat(cos(angle)) * (radius + jitter),
                y: CGFloat(sin(angle)) * (radius + jitter)
            )
            nodes[i].velocity = .zero
        }
        ticksRemaining = 400
    }

    // MARK: - Render

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let currentID = appState.currentNoteID
        // Both the sidebar tag filter (appState.selectedTag) and the in-graph
        // legend click (focusedTag) can isolate a group. Focused-in-graph
        // takes priority so the user can drill in without touching sidebar.
        let filterTag = focusedTag ?? appState.selectedTag

        // Tag-group bubbles: soft colored circles enclosing each tag's nodes.
        // Drawn first so they sit behind edges and nodes. Groups with only
        // one tagged node are skipped — a single-node bubble looks like a
        // halo, not a group.
        drawGroupBubbles(ctx: ctx, size: size, focus: filterTag)

        // Edges under nodes — explicit wikilinks as solid lines, bare-title
        // mentions as thinner dashed lines so the eye weights real links
        // first.
        var wikiPath = Path()
        var mentionPath = Path()
        for edge in edges {
            let from = viewPoint(for: nodes[edge.a].position, in: size)
            let to = viewPoint(for: nodes[edge.b].position, in: size)
            if edge.kind == "wikilink" {
                wikiPath.move(to: from); wikiPath.addLine(to: to)
            } else {
                mentionPath.move(to: from); mentionPath.addLine(to: to)
            }
        }
        let edgeOpacity: Double = filterTag == nil ? 0.45 : 0.18
        ctx.stroke(wikiPath, with: .color(.secondary.opacity(edgeOpacity)), lineWidth: 1.2)
        ctx.stroke(
            mentionPath,
            with: .color(.secondary.opacity(edgeOpacity * 0.7)),
            style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])
        )

        for node in nodes {
            let p = viewPoint(for: node.position, in: size)
            let radius: CGFloat = (4 + min(12, CGFloat(log2(Double(node.degree + 2))) * 2.2)) * max(0.6, min(zoom, 1.5))
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)

            let matchesFilter = filterTag.map(node.tags.contains) ?? true
            let isCurrent = node.id == currentID

            // Tag-based grouping color: nodes sharing a tag get the same hue.
            // Untagged nodes stay muted so the eye still clusters around the
            // colored groups rather than getting noise from every note.
            let fill: Color
            if isCurrent {
                fill = .accentColor
            } else if !matchesFilter {
                fill = .secondary.opacity(0.25)
            } else if let primaryTag = node.tags.sorted().first {
                fill = Self.colorForTag(primaryTag)
            } else if node.degree == 0 {
                fill = .secondary.opacity(0.7)
            } else {
                fill = .secondary
            }
            ctx.fill(Path(ellipseIn: rect), with: .color(fill))
            // Outline on the current node so it reads clearly against a
            // tag-colored background in the same cluster.
            if isCurrent {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)),
                           with: .color(.accentColor), lineWidth: 1.5)
            }

            // Only label if the node isn't dimmed away.
            guard matchesFilter || isCurrent else { continue }
            var label = Text(node.title).font(.system(size: 11))
            if isCurrent {
                label = label.bold().foregroundColor(.accentColor)
            } else if filterTag != nil {
                label = label.foregroundColor(.accentColor.opacity(0.9))
            } else {
                label = label.foregroundColor(.secondary)
            }
            ctx.draw(label, at: CGPoint(x: p.x, y: p.y + radius + 10), anchor: .top)
        }
    }

    private func drawGroupBubbles(ctx: GraphicsContext, size: CGSize, focus: String?) {
        // Build primary-tag → node-indices map.
        var byTag: [String: [Int]] = [:]
        for (i, node) in nodes.enumerated() {
            guard let primary = node.tags.sorted().first else { continue }
            byTag[primary, default: []].append(i)
        }
        for (tag, indices) in byTag where !indices.isEmpty {
            let path = groupShapePath(for: indices, in: size)
            let fillAlpha: Double = focus == tag ? 0.28 : (focus == nil ? 0.10 : 0.03)
            let strokeAlpha: Double = focus == tag ? 0.55 : (focus == nil ? 0.22 : 0.08)
            ctx.fill(path, with: .color(Self.colorForTag(tag).opacity(fillAlpha)))
            ctx.stroke(
                path,
                with: .color(Self.colorForTag(tag).opacity(strokeAlpha)),
                lineWidth: 1
            )
        }
    }

    /// Build a smooth, rounded shape that contains every node in the
    /// given group. Uses the convex hull of the node positions, expanded
    /// outward so the nodes sit comfortably inside, then drawn with
    /// quadratic Bezier curves through hull-edge midpoints (each hull
    /// vertex acts as a control point) so the outline reads as a soft
    /// blob rather than a sharp polygon. Single-node and 2-node groups
    /// fall back to a circle and a capsule, since their hulls degenerate.
    private func groupShapePath(for indices: [Int], in size: CGSize) -> Path {
        let padding: CGFloat = 28
        let nodePositions = indices.map { nodes[$0].position }

        if nodePositions.count == 1 {
            let center = viewPoint(for: nodePositions[0], in: size)
            let r = padding * zoom
            return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                          width: r * 2, height: r * 2))
        }
        if nodePositions.count == 2 {
            return capsulePath(from: nodePositions[0], to: nodePositions[1],
                               radius: padding, in: size)
        }

        let hull = Self.convexHull(nodePositions)
        let expanded = Self.expandHull(hull, by: padding)
        return roundedPath(through: expanded, in: size)
    }

    private func capsulePath(from a: CGPoint, to b: CGPoint, radius: CGFloat, in size: CGSize) -> Path {
        // Build a 4-point hull around the two endpoints, then round it.
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = max(0.0001, sqrt(dx * dx + dy * dy))
        let nx = -dy / len
        let ny = dx / len
        let r = radius
        let p1 = CGPoint(x: a.x + nx * r, y: a.y + ny * r)
        let p2 = CGPoint(x: b.x + nx * r, y: b.y + ny * r)
        let p3 = CGPoint(x: b.x - nx * r, y: b.y - ny * r)
        let p4 = CGPoint(x: a.x - nx * r, y: a.y - ny * r)
        let expanded = Self.expandHull([p1, p2, p3, p4], by: r * 0.6)
        return roundedPath(through: expanded, in: size)
    }

    /// Walk a closed polygon as quadratic Bezier curves: start at the
    /// midpoint of the first edge, then for every vertex draw a quad
    /// curve to the next edge midpoint with the vertex itself as the
    /// control point. This rounds every corner softly, which reads as
    /// a "blob" containing the cluster.
    private func roundedPath(through points: [CGPoint], in size: CGSize) -> Path {
        var path = Path()
        guard points.count >= 3 else {
            // Degenerate — just stroke a polyline.
            if let first = points.first {
                path.move(to: viewPoint(for: first, in: size))
                for p in points.dropFirst() {
                    path.addLine(to: viewPoint(for: p, in: size))
                }
            }
            return path
        }
        let n = points.count
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let firstMid = mid(points[n - 1], points[0])
        path.move(to: viewPoint(for: firstMid, in: size))
        for i in 0..<n {
            let curr = points[i]
            let next = points[(i + 1) % n]
            let m = mid(curr, next)
            path.addQuadCurve(
                to: viewPoint(for: m, in: size),
                control: viewPoint(for: curr, in: size)
            )
        }
        path.closeSubpath()
        return path
    }

    /// Andrew's monotone chain convex-hull algorithm. Returns vertices
    /// in counter-clockwise order. Points are sorted by x then y; we
    /// build the lower and upper hulls in one pass each, then concatenate.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { a, b in
            if a.x != b.x { return a.x < b.x }
            return a.y < b.y
        }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Move every hull vertex outward along the ray from the polygon's
    /// centroid by `padding`, so the resulting shape sits comfortably
    /// outside the nodes rather than touching them.
    static func expandHull(_ hull: [CGPoint], by padding: CGFloat) -> [CGPoint] {
        guard !hull.isEmpty else { return hull }
        let cx = hull.reduce(0) { $0 + $1.x } / CGFloat(hull.count)
        let cy = hull.reduce(0) { $0 + $1.y } / CGFloat(hull.count)
        return hull.map { p in
            let dx = p.x - cx
            let dy = p.y - cy
            let d = sqrt(dx * dx + dy * dy)
            guard d > 0.0001 else { return p }
            let scale = (d + padding) / d
            return CGPoint(x: cx + dx * scale, y: cy + dy * scale)
        }
    }

    // MARK: - Gestures

    private enum DragMode {
        case idle
        case pendingTap(location: CGPoint)
        case node(index: Int, pointerGraphOffset: CGVector) // offset from node center at grab time
        case pan(initialOffset: CGSize)
    }

    private func handleDragChanged(_ value: DragGesture.Value, viewSize size: CGSize) {
        switch dragMode {
        case .idle:
            // Decide what this gesture is. If it starts on a node, we grab it.
            if let hit = nodeIndex(at: value.startLocation, in: size) {
                let gp = graphPoint(for: value.startLocation, in: size)
                let offset = CGVector(
                    dx: gp.x - nodes[hit].position.x,
                    dy: gp.y - nodes[hit].position.y
                )
                dragMode = .node(index: hit, pointerGraphOffset: offset)
            } else {
                // No node hit — start as a tap (might upgrade to pan on movement).
                dragMode = .pendingTap(location: value.startLocation)
            }
            // Re-enter with the decided mode.
            handleDragChanged(value, viewSize: size)

        case .pendingTap(let start):
            let dx = value.location.x - start.x
            let dy = value.location.y - start.y
            if dx * dx + dy * dy > 16 {  // >4pt movement — treat as pan.
                dragMode = .pan(initialOffset: panOffset)
                handleDragChanged(value, viewSize: size)
            }

        case .node(let idx, let offset):
            let gp = graphPoint(for: value.location, in: size)
            nodes[idx].position = CGPoint(x: gp.x - offset.dx, y: gp.y - offset.dy)
            nodes[idx].velocity = .zero

        case .pan(let initial):
            panOffset = CGSize(
                width: initial.width + value.translation.width,
                height: initial.height + value.translation.height
            )
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, viewSize size: CGSize) {
        switch dragMode {
        case .pendingTap(let loc):
            // A tap without movement — open the node under the cursor, if any.
            if let hit = nodeIndex(at: loc, in: size) {
                appState.openNote(nodes[hit].id)
            }
        case .idle, .node, .pan:
            break
        }
        dragMode = .idle
    }

    private func nodeIndex(at location: CGPoint, in size: CGSize) -> Int? {
        // Threshold in view space, scaled by zoom so it feels consistent.
        let threshold: CGFloat = 18
        var best: (index: Int, dist: CGFloat)? = nil
        for (i, node) in nodes.enumerated() {
            let vp = viewPoint(for: node.position, in: size)
            let dx = vp.x - location.x
            let dy = vp.y - location.y
            let d = sqrt(dx * dx + dy * dy)
            if d < threshold, best == nil || d < best!.dist {
                best = (i, d)
            }
        }
        return best?.index
    }
}

private struct GraphNode: Identifiable {
    let id: NoteID
    let title: String
    let degree: Int
    let tags: Set<String>
    var position: CGPoint
    var velocity: CGVector
}

private struct GraphEdge {
    let a: Int
    let b: Int
    /// "wikilink" (explicit `[[...]]`) or "unlinked" (bare title mention).
    let kind: String
}
