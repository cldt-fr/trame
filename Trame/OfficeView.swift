import SceneKit
import SwiftUI
import TrameProtocol

/// The Agent Office: a live 3D open space where every session is a little
/// agent at a desk — screens glow with scrolling code while they work,
/// badges pop when they need you, and talkie-walkie messages fly between
/// desks. Chef wears the toque. 👨‍🍳
struct OfficeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var traffic: [AppModel.MeshTrafficEntry] = []
    @State private var lastAnimated: Date = Date()

    // Demo mode: a scripted team plays a whole feature cycle on a loop.
    @State private var demoMode = false
    @State private var demoStep = 0
    @State private var demoSessions: [SessionInfo] = []
    @State private var demoMessages: [AppModel.MeshTrafficEntry] = []

    private static let demoRoles: [String: String] = [
        "demo-chef": "chef", "demo-dev": "dev",
        "demo-reviewer": "reviewer", "demo-tester": "tester",
    ]

    var body: some View {
        OfficeSceneView(
            sessions: demoMode ? demoSessions : model.sessions,
            meshRoles: demoMode ? Self.demoRoles
                                : Dictionary(uniqueKeysWithValues: model.meshMembers.map { ($0.id, $0.role) }),
            newMessages: demoMode ? demoMessages : traffic.filter { $0.timestamp > lastAnimated }
        )
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                legend
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    demoMode.toggle()
                    demoStep = 0
                    demoMessages = []
                    if demoMode { applyDemoStep() }
                } label: {
                    Label(demoMode ? "Stop Demo" : "Play Demo",
                          systemImage: demoMode ? "stop.fill" : "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
            }
            .task {
                lastAnimated = Date()
                while !Task.isCancelled {
                    if !demoMode {
                        let entries = await model.loadMeshTraffic()
                        traffic = entries
                        if let newest = entries.first?.timestamp, newest > lastAnimated {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            lastAnimated = newest
                            continue
                        }
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            .task(id: demoMode) {
                guard demoMode else { return }
                while !Task.isCancelled && demoMode {
                    try? await Task.sleep(nanoseconds: 2_300_000_000)
                    demoStep += 1
                    applyDemoStep()
                }
            }
    }

    // MARK: - Demo script

    /// One step: per-role (activity, attention) plus messages fired on entry.
    private struct DemoStep {
        var states: [String: (activity: String?, attention: String?)]
        var messages: [(from: String, to: String?, text: String)] = []
    }

    private static let script: [DemoStep] = [
        DemoStep(states: ["chef": ("Thinking", nil)]),
        DemoStep(states: ["chef": ("Thinking", nil)],
                 messages: [("chef", "dev", "Implement the login feature with validation")]),
        DemoStep(states: ["chef": (nil, "done"), "dev": ("Editing", nil)]),
        DemoStep(states: ["dev": ("Running command", nil)]),
        DemoStep(states: ["dev": (nil, "permission")]),
        DemoStep(states: ["dev": ("Editing", nil)]),
        DemoStep(states: ["dev": (nil, "done")],
                 messages: [("dev", "reviewer", "Done! Please review my diff 🙏")]),
        DemoStep(states: ["reviewer": ("Reading", nil), "dev": (nil, nil)]),
        DemoStep(states: ["reviewer": ("Thinking", nil)],
                 messages: [("reviewer", "dev", "LGTM — one nit on error handling")]),
        DemoStep(states: ["reviewer": (nil, "done"), "dev": ("Editing", nil)]),
        DemoStep(states: ["dev": (nil, "done")],
                 messages: [("dev", "tester", "Fixed. Can you run the suite?")]),
        DemoStep(states: ["tester": ("Running command", nil), "dev": (nil, nil)]),
        DemoStep(states: ["tester": ("Running command", nil)]),
        DemoStep(states: ["tester": (nil, "done")],
                 messages: [("tester", nil, "All 142 tests green ✅")]),
        DemoStep(states: ["chef": ("Thinking", nil), "tester": (nil, nil)]),
        DemoStep(states: ["chef": (nil, "done"), "dev": (nil, nil), "reviewer": (nil, nil), "tester": (nil, nil)]),
        DemoStep(states: ["chef": (nil, nil)]),
    ]

    private func applyDemoStep() {
        let step = Self.script[demoStep % Self.script.count]
        var current: [String: (String?, String?)] = [:]
        for session in demoSessions {
            let role = Self.demoRoles[session.id] ?? ""
            current[role] = (session.activity, session.attention)
        }
        for (role, state) in step.states {
            current[role] = state
        }
        let base = Date(timeIntervalSinceNow: -600)
        demoSessions = Self.demoRoles
            .sorted { $0.value < $1.value }
            .enumerated()
            .map { index, entry in
                let (id, role) = entry
                let state = current[role] ?? (nil, nil)
                return SessionInfo(
                    id: id, name: role, cwd: "/demo", command: ["claude"],
                    state: .running, createdAt: base.addingTimeInterval(Double(index)),
                    attention: state.1,
                    attentionMessage: state.1 == "permission" ? "Claude needs your permission to use Bash" : nil,
                    attentionAt: state.1 != nil ? Date() : nil,
                    activity: state.0,
                    activitySince: state.0 != nil ? Date() : nil
                )
            }
        demoMessages = step.messages.map {
            AppModel.MeshTrafficEntry(timestamp: Date(), from: $0.from, to: $0.to,
                                      text: $0.text, isBroadcast: $0.to == nil)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            if demoMode {
                Label("demo", systemImage: "sparkles")
                    .foregroundStyle(Color.purple)
            }
            Label("working", systemImage: "display")
                .foregroundStyle(Color.accentColor)
            Label("needs you", systemImage: "bell.badge.fill")
                .foregroundStyle(Color.orange)
            Label("message", systemImage: "circle.fill")
                .foregroundStyle(Color.teal)
            Text("drag to orbit · scroll to zoom")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct OfficeSceneView: NSViewRepresentable {
    let sessions: [SessionInfo]
    let meshRoles: [String: String]
    let newMessages: [AppModel.MeshTrafficEntry]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.buildScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = NSColor(calibratedRed: 0.82, green: 0.86, blue: 0.93, alpha: 1)
        view.antialiasingMode = .multisampling4X
        context.coordinator.sync(sessions: sessions, meshRoles: meshRoles)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.sync(sessions: sessions, meshRoles: meshRoles)
        context.coordinator.animate(messages: newMessages, meshRoles: meshRoles, sessions: sessions)
    }

    @MainActor
    final class Coordinator {
        private var scene = SCNScene()
        private var deskRoot = SCNNode()
        private var fxRoot = SCNNode()
        private var wallsRoot = SCNNode()
        private var deskNodes: [String: SCNNode] = [:]
        private var deskStates: [String: String] = [:]
        private var animatedMessageIDs = Set<UUID>()

        private static let codeFrames: [NSImage] = (0..<3).map { codeImage(seed: $0) }

        // MARK: Scene

        func buildScene() -> SCNScene {
            scene = SCNScene()
            scene.rootNode.addChildNode(deskRoot)
            scene.rootNode.addChildNode(fxRoot)
            scene.rootNode.addChildNode(wallsRoot)

            // Wooden floor
            let floor = SCNFloor()
            floor.reflectivity = 0.12
            floor.firstMaterial?.lightingModel = .physicallyBased
            floor.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.6, blue: 0.47, alpha: 1)
            floor.firstMaterial?.roughness.contents = 0.7
            scene.rootNode.addChildNode(SCNNode(geometry: floor))

            // Lights: warm key + cool fill + ambient
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 420
            ambient.light?.color = NSColor(calibratedRed: 1, green: 0.98, blue: 0.94, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 750
            key.light?.color = NSColor(calibratedRed: 1, green: 0.96, blue: 0.88, alpha: 1)
            key.light?.castsShadow = true
            key.light?.shadowRadius = 8
            key.light?.shadowSampleCount = 16
            key.light?.shadowColor = NSColor(white: 0, alpha: 0.28)
            key.eulerAngles = SCNVector3(-Double.pi / 2.6, Double.pi / 5, 0)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .directional
            fill.light?.intensity = 220
            fill.light?.color = NSColor(calibratedRed: 0.75, green: 0.83, blue: 1, alpha: 1)
            fill.eulerAngles = SCNVector3(-Double.pi / 4, -Double.pi / 3, 0)
            scene.rootNode.addChildNode(fill)

            // Camera with bloom so screens and orbs glow
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 42
            camera.camera?.wantsHDR = true
            camera.camera?.bloomThreshold = 0.7
            camera.camera?.bloomIntensity = 0.8
            camera.camera?.bloomBlurRadius = 12
            camera.position = SCNVector3(0, 7.5, 13)
            camera.eulerAngles = SCNVector3(-0.42, 0, 0)
            scene.rootNode.addChildNode(camera)

            return scene
        }

        private func buildWalls(extent: (x: Double, z: Double)) {
            wallsRoot.childNodes.forEach { $0.removeFromParentNode() }
            let width = CGFloat(max(16, extent.x * 2 + 12))
            let backZ = CGFloat(-extent.z - 5)
            let wallColor = NSColor(calibratedRed: 0.94, green: 0.93, blue: 0.9, alpha: 1)

            // Back wall
            let back = SCNNode(geometry: SCNBox(width: width, height: 5, length: 0.3, chamferRadius: 0))
            back.geometry?.firstMaterial?.diffuse.contents = wallColor
            back.geometry?.firstMaterial?.lightingModel = .physicallyBased
            back.position = SCNVector3(0, 2.5, backZ)
            wallsRoot.addChildNode(back)

            // Windows with daylight glow
            for i in 0..<3 {
                let window = SCNNode(geometry: SCNPlane(width: 2.2, height: 2.4))
                window.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.85, blue: 1, alpha: 1)
                window.geometry?.firstMaterial?.emission.contents = NSColor(calibratedRed: 0.65, green: 0.8, blue: 1, alpha: 1)
                window.position = SCNVector3(Double(i - 1) * 4.5, 2.7, Double(backZ) + 0.17)
                wallsRoot.addChildNode(window)
                // Frame bar
                let bar = SCNNode(geometry: SCNBox(width: 0.08, height: 2.4, length: 0.05, chamferRadius: 0))
                bar.geometry?.firstMaterial?.diffuse.contents = NSColor.white
                bar.position = SCNVector3(Double(i - 1) * 4.5, 2.7, Double(backZ) + 0.2)
                wallsRoot.addChildNode(bar)
            }

            // Whiteboard with scribbles
            let board = SCNNode(geometry: SCNPlane(width: 3.4, height: 1.9))
            board.geometry?.firstMaterial?.diffuse.contents = Self.whiteboardImage()
            board.position = SCNVector3(Double(width) / 2 - 4, 2.4, Double(backZ) + 0.17)
            wallsRoot.addChildNode(board)

            // Plants in the corners
            for x in [-Double(width) / 2 + 1.5, Double(width) / 2 - 1.5] {
                wallsRoot.addChildNode(plant(at: SCNVector3(x, 0, Double(backZ) + 1.2)))
            }
        }

        // MARK: Sync sessions → desks

        func sync(sessions: [SessionInfo], meshRoles: [String: String]) {
            let visible = sessions.sorted { $0.createdAt < $1.createdAt }
            let ids = visible.map(\.id)

            if Set(ids) != Set(deskNodes.keys) {
                deskRoot.childNodes.forEach { $0.removeFromParentNode() }
                deskNodes = [:]
                deskStates = [:]
                var maxX = 4.0, maxZ = 2.0
                for (index, session) in visible.enumerated() {
                    let role = meshRoles[session.id]
                    let desk = makeDesk(session: session, role: role)
                    let position = deskPosition(index: index, total: visible.count)
                    desk.position = position
                    desk.eulerAngles.y = .pi
                    deskRoot.addChildNode(desk)
                    deskNodes[session.id] = desk
                    maxX = max(maxX, abs(Double(position.x)))
                    maxZ = max(maxZ, abs(Double(position.z)))
                }
                buildWalls(extent: (maxX, maxZ))
            }

            for session in visible {
                updateDeskState(session: session)
            }
        }

        private func deskPosition(index: Int, total: Int) -> SCNVector3 {
            let perRow = max(1, Int(ceil(Double(total).squareRoot())))
            let row = index / perRow
            let col = index % perRow
            let rowCount = Int(ceil(Double(total) / Double(perRow)))
            let x = (Double(col) - Double(min(perRow, total) - 1) / 2) * 4.4
            let z = (Double(row) - Double(rowCount - 1) / 2) * 4.6
            return SCNVector3(x, 0, z)
        }

        // MARK: Desk construction

        private func pbr(_ color: NSColor, roughness: CGFloat = 0.6) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.roughness.contents = roughness
            return m
        }

        private static let rolePalette: [NSColor] = [
            NSColor(calibratedRed: 0.37, green: 0.36, blue: 0.91, alpha: 1),  // indigo
            NSColor.systemTeal, NSColor.systemOrange, NSColor.systemPink,
            NSColor.systemGreen, NSColor.systemPurple, NSColor.systemBrown,
        ]

        private func roleColor(_ key: String) -> NSColor {
            var hash = 5381
            for byte in key.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
            return Self.rolePalette[abs(hash) % Self.rolePalette.count]
        }

        private func makeDesk(session: SessionInfo, role: String?) -> SCNNode {
            let root = SCNNode()
            root.name = session.id
            let color = roleColor(role ?? session.name)

            // Rug
            let rug = SCNNode(geometry: SCNCylinder(radius: 1.9, height: 0.02))
            rug.geometry?.materials = [pbr(color.withAlphaComponent(0.22), roughness: 1)]
            rug.position = SCNVector3(0, 0.011, 0.2)
            root.addChildNode(rug)

            // Desk top + legs
            let wood = NSColor(calibratedRed: 0.85, green: 0.76, blue: 0.62, alpha: 1)
            let top = SCNNode(geometry: SCNBox(width: 2.4, height: 0.1, length: 1.1, chamferRadius: 0.04))
            top.geometry?.materials = [pbr(wood, roughness: 0.5)]
            top.position = SCNVector3(0, 0.85, 0)
            root.addChildNode(top)
            for (lx, lz) in [(-1.05, -0.42), (1.05, -0.42), (-1.05, 0.42), (1.05, 0.42)] {
                let leg = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.85))
                leg.geometry?.materials = [pbr(NSColor(white: 0.25, alpha: 1), roughness: 0.4)]
                leg.position = SCNVector3(lx, 0.42, lz)
                root.addChildNode(leg)
            }

            // Monitor with a visible screen face
            let frame = SCNNode(geometry: SCNBox(width: 1.2, height: 0.72, length: 0.06, chamferRadius: 0.02))
            frame.geometry?.materials = [pbr(NSColor(white: 0.15, alpha: 1), roughness: 0.35)]
            frame.position = SCNVector3(0, 1.4, -0.25)
            root.addChildNode(frame)
            let screenPlane = SCNNode(geometry: SCNPlane(width: 1.08, height: 0.6))
            screenPlane.name = "screen"
            screenPlane.geometry?.firstMaterial?.diffuse.contents = NSColor.black
            screenPlane.geometry?.firstMaterial?.emission.contents = NSColor.black
            screenPlane.position = SCNVector3(0, 1.4, -0.21)
            root.addChildNode(screenPlane)
            let stand = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.22))
            stand.geometry?.materials = [pbr(NSColor(white: 0.25, alpha: 1))]
            stand.position = SCNVector3(0, 1.0, -0.25)
            root.addChildNode(stand)

            // Keyboard + mug
            let keyboard = SCNNode(geometry: SCNBox(width: 0.7, height: 0.03, length: 0.24, chamferRadius: 0.01))
            keyboard.geometry?.materials = [pbr(NSColor(white: 0.9, alpha: 1), roughness: 0.5)]
            keyboard.position = SCNVector3(0, 0.92, 0.15)
            root.addChildNode(keyboard)
            let mug = SCNNode(geometry: SCNCylinder(radius: 0.06, height: 0.13))
            mug.geometry?.materials = [pbr(color, roughness: 0.3)]
            mug.position = SCNVector3(0.85, 0.97, 0.2)
            root.addChildNode(mug)

            // Chair
            let seat = SCNNode(geometry: SCNBox(width: 0.55, height: 0.08, length: 0.55, chamferRadius: 0.03))
            seat.geometry?.materials = [pbr(NSColor(white: 0.22, alpha: 1), roughness: 0.6)]
            seat.position = SCNVector3(0, 0.5, 0.85)
            root.addChildNode(seat)
            let back = SCNNode(geometry: SCNBox(width: 0.55, height: 0.55, length: 0.06, chamferRadius: 0.03))
            back.geometry?.materials = [pbr(NSColor(white: 0.22, alpha: 1), roughness: 0.6)]
            back.position = SCNVector3(0, 0.8, 1.12)
            root.addChildNode(back)

            // Agent
            let agent = SCNNode()
            agent.name = "agent"
            let body = SCNNode(geometry: SCNCapsule(capRadius: 0.19, height: 0.64))
            body.name = "body"
            body.geometry?.materials = [pbr(color, roughness: 0.55)]
            body.position = SCNVector3(0, 0.86, 0)
            agent.addChildNode(body)
            let head = SCNNode(geometry: SCNSphere(radius: 0.17))
            head.name = "head"
            head.geometry?.materials = [pbr(NSColor(calibratedRed: 0.96, green: 0.86, blue: 0.73, alpha: 1), roughness: 0.7)]
            head.position = SCNVector3(0, 1.33, 0)
            agent.addChildNode(head)
            // Hands on the keyboard
            for hx in [-0.18, 0.18] {
                let hand = SCNNode(geometry: SCNSphere(radius: 0.06))
                hand.name = "hand"
                hand.geometry?.materials = [pbr(NSColor(calibratedRed: 0.96, green: 0.86, blue: 0.73, alpha: 1), roughness: 0.7)]
                hand.position = SCNVector3(hx, 0.95 - 0.84, -0.62) // relative to agent at z 0.8
                agent.addChildNode(hand)
            }
            addAccessory(to: agent, role: role, color: color)
            agent.position = SCNVector3(0, 0, 0.82)
            root.addChildNode(agent)

            // Crisp name chip
            let labelText = role.map { "\(session.name) · \($0)" } ?? session.name
            let chipImage = Self.chipImage(text: labelText, tint: color)
            let ratio = chipImage.size.width / chipImage.size.height
            let chip = SCNNode(geometry: SCNPlane(width: 0.34 * ratio, height: 0.34))
            chip.geometry?.firstMaterial?.diffuse.contents = chipImage
            chip.geometry?.firstMaterial?.isDoubleSided = true
            chip.position = SCNVector3(0, 2.25, 0)
            chip.constraints = [SCNBillboardConstraint()]
            root.addChildNode(chip)

            // Status badge
            let badgePlane = SCNPlane(width: 0.55, height: 0.55)
            badgePlane.firstMaterial?.diffuse.contents = Self.emojiImage("🔔")
            badgePlane.firstMaterial?.isDoubleSided = true
            let badge = SCNNode(geometry: badgePlane)
            badge.name = "badge"
            badge.position = SCNVector3(0, 1.95, 0.82)
            badge.constraints = [SCNBillboardConstraint()]
            badge.isHidden = true
            root.addChildNode(badge)

            return root
        }

        /// Role-specific headgear: toque for the chef, glasses for reviewers,
        /// a cap for testers, headphones for everyone else.
        private func addAccessory(to agent: SCNNode, role: String?, color: NSColor) {
            let r = (role ?? "").lowercased()
            let headY = 1.33
            if r.contains("chef") {
                let toqueBase = SCNNode(geometry: SCNCylinder(radius: 0.13, height: 0.08))
                toqueBase.geometry?.materials = [pbr(.white, roughness: 0.8)]
                toqueBase.position = SCNVector3(0, headY + 0.17, 0)
                agent.addChildNode(toqueBase)
                let toqueTop = SCNNode(geometry: SCNSphere(radius: 0.15))
                toqueTop.geometry?.materials = [pbr(.white, roughness: 0.8)]
                toqueTop.scale = SCNVector3(1, 0.75, 1)
                toqueTop.position = SCNVector3(0, headY + 0.28, 0)
                agent.addChildNode(toqueTop)
            } else if r.contains("rev") {
                for gx in [-0.08, 0.08] {
                    let lens = SCNNode(geometry: SCNTorus(ringRadius: 0.055, pipeRadius: 0.012))
                    lens.geometry?.materials = [pbr(NSColor(white: 0.1, alpha: 1), roughness: 0.3)]
                    lens.eulerAngles.x = .pi / 2
                    lens.position = SCNVector3(gx, headY + 0.02, -0.15)
                    agent.addChildNode(lens)
                }
            } else if r.contains("test") {
                let cap = SCNNode(geometry: SCNCylinder(radius: 0.16, height: 0.07))
                cap.geometry?.materials = [pbr(color, roughness: 0.6)]
                cap.position = SCNVector3(0, headY + 0.16, 0)
                agent.addChildNode(cap)
                let brim = SCNNode(geometry: SCNBox(width: 0.2, height: 0.02, length: 0.18, chamferRadius: 0.05))
                brim.geometry?.materials = [pbr(color, roughness: 0.6)]
                brim.position = SCNVector3(0, headY + 0.13, -0.18)
                agent.addChildNode(brim)
            } else {
                let band = SCNNode(geometry: SCNTorus(ringRadius: 0.17, pipeRadius: 0.02))
                band.geometry?.materials = [pbr(NSColor(white: 0.15, alpha: 1), roughness: 0.4)]
                band.eulerAngles.z = .pi / 2
                band.eulerAngles.x = 0.25
                band.position = SCNVector3(0, headY + 0.05, 0)
                agent.addChildNode(band)
                for ex in [-0.17, 0.17] {
                    let cup = SCNNode(geometry: SCNSphere(radius: 0.05))
                    cup.geometry?.materials = [pbr(NSColor(white: 0.15, alpha: 1), roughness: 0.4)]
                    cup.position = SCNVector3(ex, headY, 0)
                    agent.addChildNode(cup)
                }
            }
        }

        // MARK: State updates

        private func updateDeskState(session: SessionInfo) {
            guard let desk = deskNodes[session.id] else { return }
            let state: String
            if !session.isRunning {
                state = "exited"
            } else if session.attention == "permission" {
                state = "permission"
            } else if session.activity != nil {
                state = "working"
            } else if session.attention == "done" {
                state = "done"
            } else {
                state = "idle"
            }
            guard deskStates[session.id] != state else { return }
            deskStates[session.id] = state

            let screen = desk.childNode(withName: "screen", recursively: false)
            let badge = desk.childNode(withName: "badge", recursively: false)
            let agent = desk.childNode(withName: "agent", recursively: false)
            let hands = agent?.childNodes.filter { $0.name == "hand" } ?? []

            agent?.removeAllActions()
            screen?.removeAllActions()
            hands.forEach { $0.removeAllActions() }
            agent?.eulerAngles.x = 0

            switch state {
            case "working":
                badge?.isHidden = true
                agent?.eulerAngles.x = -0.16
                // Scrolling code on the screen
                var frame = 0
                let flip = SCNAction.repeatForever(.sequence([
                    .run { node in
                        frame = (frame + 1) % Self.codeFrames.count
                        let image = Self.codeFrames[frame]
                        node.geometry?.firstMaterial?.diffuse.contents = image
                        node.geometry?.firstMaterial?.emission.contents = image
                    },
                    .wait(duration: 0.5),
                ]))
                screen?.runAction(flip)
                // Typing hands
                for (i, hand) in hands.enumerated() {
                    let jitter = SCNAction.repeatForever(.sequence([
                        .wait(duration: Double(i) * 0.09),
                        .moveBy(x: 0, y: 0.05, z: 0, duration: 0.09),
                        .moveBy(x: 0, y: -0.05, z: 0, duration: 0.09),
                    ]))
                    hand.runAction(jitter)
                }
            case "permission":
                setScreen(screen, color: NSColor.systemOrange.withAlphaComponent(0.8))
                badge?.isHidden = false
                badge?.geometry?.firstMaterial?.diffuse.contents = Self.emojiImage("🔔")
                let pulse = SCNAction.repeatForever(.sequence([
                    .scale(to: 1.3, duration: 0.35),
                    .scale(to: 1.0, duration: 0.35),
                ]))
                badge?.runAction(pulse, forKey: "pulse")
            case "done":
                setScreen(screen, color: NSColor.systemGreen.withAlphaComponent(0.55))
                badge?.isHidden = false
                badge?.removeAction(forKey: "pulse")
                badge?.geometry?.firstMaterial?.diffuse.contents = Self.emojiImage("✅")
                breathe(agent)
            case "exited":
                setScreen(screen, color: .black)
                badge?.isHidden = true
            default: // idle
                setScreen(screen, color: NSColor(white: 0.12, alpha: 1))
                badge?.isHidden = true
                breathe(agent)
            }
        }

        private func setScreen(_ screen: SCNNode?, color: NSColor) {
            screen?.geometry?.firstMaterial?.diffuse.contents = color
            screen?.geometry?.firstMaterial?.emission.contents = color
        }

        private func breathe(_ agent: SCNNode?) {
            let breath = SCNAction.repeatForever(.sequence([
                .scale(to: 1.015, duration: 1.6),
                .scale(to: 1.0, duration: 1.6),
            ]))
            agent?.runAction(breath)
        }

        // MARK: Mesh message particles

        func animate(messages: [AppModel.MeshTrafficEntry], meshRoles: [String: String], sessions: [SessionInfo]) {
            let roleToSession = Dictionary(uniqueKeysWithValues: meshRoles.map { ($0.value, $0.key) })
            for message in messages where !animatedMessageIDs.contains(message.id) {
                animatedMessageIDs.insert(message.id)
                guard let fromID = roleToSession[message.from],
                      let fromDesk = deskNodes[fromID] else { continue }
                let targets: [SCNNode]
                if message.isBroadcast {
                    targets = deskNodes.filter { $0.key != fromID }.map(\.value)
                } else if let to = message.to, let toID = roleToSession[to], let desk = deskNodes[toID] {
                    targets = [desk]
                } else {
                    continue
                }
                for target in targets {
                    fly(from: fromDesk.position, to: target.position)
                }
            }
            if animatedMessageIDs.count > 500 { animatedMessageIDs.removeAll() }
        }

        private func fly(from: SCNVector3, to: SCNVector3) {
            let orb = SCNNode(geometry: SCNSphere(radius: 0.1))
            orb.geometry?.firstMaterial?.diffuse.contents = NSColor.systemTeal
            orb.geometry?.firstMaterial?.emission.contents = NSColor.systemTeal
            orb.position = SCNVector3(from.x, from.y + 1.7, from.z)
            fxRoot.addChildNode(orb)

            let mid = SCNVector3((from.x + to.x) / 2, 3.1, (from.z + to.z) / 2)
            let rise = SCNAction.move(to: mid, duration: 0.45)
            rise.timingMode = .easeOut
            let fall = SCNAction.move(to: SCNVector3(to.x, to.y + 1.7, to.z), duration: 0.45)
            fall.timingMode = .easeIn
            orb.runAction(.sequence([rise, fall, .fadeOut(duration: 0.2), .removeFromParentNode()]))
        }

        // MARK: Props & textures

        private func plant(at position: SCNVector3) -> SCNNode {
            let root = SCNNode()
            let pot = SCNNode(geometry: SCNCylinder(radius: 0.3, height: 0.36))
            pot.geometry?.materials = [pbr(NSColor(calibratedRed: 0.78, green: 0.47, blue: 0.36, alpha: 1), roughness: 0.8)]
            pot.position = SCNVector3(0, 0.18, 0)
            root.addChildNode(pot)
            for (dy, radius) in [(0.7, 0.42), (1.05, 0.3), (1.32, 0.18)] {
                let tier = SCNNode(geometry: SCNCone(topRadius: 0.02, bottomRadius: radius, height: 0.5))
                tier.geometry?.materials = [pbr(NSColor(calibratedRed: 0.3, green: 0.62, blue: 0.36, alpha: 1), roughness: 0.9)]
                tier.position = SCNVector3(0, dy, 0)
                root.addChildNode(tier)
            }
            root.position = position
            return root
        }

        /// Fake code frame for busy screens: dark editor with colored lines.
        nonisolated private static func codeImage(seed: Int) -> NSImage {
            let size = NSSize(width: 216, height: 120)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.13, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            let palette: [NSColor] = [
                NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: 1),
                NSColor(calibratedRed: 0.62, green: 0.9, blue: 0.6, alpha: 1),
                NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.5, alpha: 1),
                NSColor(calibratedRed: 0.8, green: 0.65, blue: 1, alpha: 1),
                NSColor(white: 0.55, alpha: 1),
            ]
            var rng = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 12345)
            func next() -> Double {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                return Double(rng >> 33) / Double(UInt32.max)
            }
            var y: CGFloat = size.height - 14
            while y > 6 {
                var x: CGFloat = 10 + CGFloat(next() * 18)
                let segments = 2 + Int(next() * 3)
                for _ in 0..<segments {
                    let width = CGFloat(14 + next() * 46)
                    palette[Int(next() * Double(palette.count)) % palette.count].setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 5),
                                 xRadius: 2.5, yRadius: 2.5).fill()
                    x += width + 8
                    if x > size.width - 24 { break }
                }
                y -= 11
            }
            image.unlockFocus()
            return image
        }

        /// Crisp rounded name chip rendered as a texture.
        nonisolated private static func chipImage(text: String, tint: NSColor) -> NSImage {
            let font = NSFont.systemFont(ofSize: 30, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let string = NSAttributedString(string: text, attributes: attrs)
            let textSize = string.size()
            let size = NSSize(width: textSize.width + 44, height: 56)
            let image = NSImage(size: size)
            image.lockFocus()
            let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                                    xRadius: 28, yRadius: 28)
            tint.withAlphaComponent(0.92).setFill()
            path.fill()
            string.draw(at: NSPoint(x: 22, y: (size.height - textSize.height) / 2))
            image.unlockFocus()
            return image
        }

        nonisolated static func emojiImage(_ emoji: String, size: CGFloat = 128) -> NSImage {
            let image = NSImage(size: NSSize(width: size, height: size))
            image.lockFocus()
            let string = NSAttributedString(string: emoji, attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.78),
            ])
            let bounds = string.size()
            string.draw(at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2))
            image.unlockFocus()
            return image
        }

        /// Whiteboard covered in very serious architecture diagrams.
        nonisolated private static func whiteboardImage() -> NSImage {
            let size = NSSize(width: 340, height: 190)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()
            NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.87, alpha: 1).setStroke()
            let border = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4), xRadius: 8, yRadius: 8)
            border.lineWidth = 4
            border.stroke()
            // Scribbles
            let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen]
            for (i, color) in colors.enumerated() {
                color.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 3
                let y = CGFloat(140 - i * 34)
                path.move(to: NSPoint(x: 30, y: y))
                path.curve(to: NSPoint(x: 180, y: y - 12),
                           controlPoint1: NSPoint(x: 80, y: y + 16),
                           controlPoint2: NSPoint(x: 140, y: y - 24))
                path.stroke()
            }
            NSColor.systemBlue.setStroke()
            let box = NSBezierPath(rect: NSRect(x: 220, y: 60, width: 80, height: 50))
            box.lineWidth = 3
            box.stroke()
            let arrow = NSBezierPath()
            arrow.lineWidth = 3
            arrow.move(to: NSPoint(x: 200, y: 130))
            arrow.line(to: NSPoint(x: 250, y: 112))
            arrow.stroke()
            image.unlockFocus()
            return image
        }
    }
}
