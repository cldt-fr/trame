import SceneKit
import SwiftUI
import TrameProtocol

/// The Agent Office: a live 3D open space where every session is a little
/// agent at a desk — screens glow while they work, badges pop when they
/// need you, and talkie-walkie messages fly between desks.
struct OfficeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var traffic: [AppModel.MeshTrafficEntry] = []
    @State private var lastAnimated: Date = Date()

    var body: some View {
        OfficeSceneView(sessions: model.sessions,
                        meshRoles: Dictionary(uniqueKeysWithValues: model.meshMembers.map { ($0.id, $0.role) }),
                        newMessages: traffic.filter { $0.timestamp > lastAnimated })
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                legend
                    .padding(12)
            }
            .task {
                lastAnimated = Date()
                while !Task.isCancelled {
                    let entries = await model.loadMeshTraffic()
                    traffic = entries
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if let newest = entries.first?.timestamp, newest > lastAnimated {
                        lastAnimated = newest
                    }
                }
            }
    }

    private var legend: some View {
        HStack(spacing: 14) {
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
        view.backgroundColor = NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.96, alpha: 1)
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
        private var deskNodes: [String: SCNNode] = [:]
        private var deskStates: [String: String] = [:]
        private var animatedMessageIDs = Set<UUID>()

        // MARK: Scene

        func buildScene() -> SCNScene {
            scene = SCNScene()
            scene.rootNode.addChildNode(deskRoot)
            scene.rootNode.addChildNode(fxRoot)

            // Floor
            let floor = SCNFloor()
            floor.reflectivity = 0.06
            floor.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.92, alpha: 1)
            scene.rootNode.addChildNode(SCNNode(geometry: floor))

            // Lights
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 500
            scene.rootNode.addChildNode(ambient)

            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 700
            sun.light?.castsShadow = true
            sun.light?.shadowRadius = 6
            sun.light?.shadowColor = NSColor(white: 0, alpha: 0.25)
            sun.eulerAngles = SCNVector3(-Double.pi / 3, Double.pi / 5, 0)
            scene.rootNode.addChildNode(sun)

            // Camera
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 45
            camera.position = SCNVector3(0, 8, 13)
            camera.eulerAngles = SCNVector3(-0.5, 0, 0)
            scene.rootNode.addChildNode(camera)

            // A couple of plants for coziness
            for x in [-7.0, 7.0] {
                scene.rootNode.addChildNode(plant(at: SCNVector3(x, 0, -4)))
            }
            return scene
        }

        // MARK: Sync sessions → desks

        func sync(sessions: [SessionInfo], meshRoles: [String: String]) {
            let visible = sessions.sorted { $0.createdAt < $1.createdAt }
            let ids = visible.map(\.id)

            // Rebuild desk layout when the roster changes.
            if Set(ids) != Set(deskNodes.keys) {
                deskRoot.childNodes.forEach { $0.removeFromParentNode() }
                deskNodes = [:]
                deskStates = [:]
                for (index, session) in visible.enumerated() {
                    let desk = makeDesk(session: session, role: meshRoles[session.id])
                    desk.position = deskPosition(index: index, total: visible.count)
                    // Face the camera side
                    desk.eulerAngles.y = .pi
                    deskRoot.addChildNode(desk)
                    deskNodes[session.id] = desk
                }
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
            let x = (Double(col) - Double(min(perRow, total) - 1) / 2) * 4.2
            let z = (Double(row) - Double(rowCount - 1) / 2) * 4.2
            return SCNVector3(x, 0, z)
        }

        // MARK: Desk construction

        private func makeDesk(session: SessionInfo, role: String?) -> SCNNode {
            let root = SCNNode()
            root.name = session.id

            let wood = NSColor(calibratedRed: 0.82, green: 0.72, blue: 0.58, alpha: 1)

            // Desk top + legs
            let top = SCNNode(geometry: SCNBox(width: 2.4, height: 0.1, length: 1.1, chamferRadius: 0.02))
            top.geometry?.firstMaterial?.diffuse.contents = wood
            top.position = SCNVector3(0, 0.85, 0)
            root.addChildNode(top)
            for (lx, lz) in [(-1.1, -0.45), (1.1, -0.45), (-1.1, 0.45), (1.1, 0.45)] {
                let leg = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 0.85))
                leg.geometry?.firstMaterial?.diffuse.contents = NSColor.darkGray
                leg.position = SCNVector3(lx, 0.42, lz)
                root.addChildNode(leg)
            }

            // Monitor (named so we can light the screen up)
            let screen = SCNNode(geometry: SCNBox(width: 1.1, height: 0.65, length: 0.05, chamferRadius: 0.02))
            screen.name = "screen"
            screen.geometry?.firstMaterial?.diffuse.contents = NSColor.black
            screen.position = SCNVector3(0, 1.35, -0.25)
            root.addChildNode(screen)
            let stand = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.25))
            stand.geometry?.firstMaterial?.diffuse.contents = NSColor.darkGray
            stand.position = SCNVector3(0, 1.0, -0.25)
            root.addChildNode(stand)

            // Coffee mug ☕
            let mug = SCNNode(geometry: SCNCylinder(radius: 0.06, height: 0.12))
            mug.geometry?.firstMaterial?.diffuse.contents = NSColor.white
            mug.position = SCNVector3(0.8, 0.96, 0.15)
            root.addChildNode(mug)

            // Chair
            let seat = SCNNode(geometry: SCNBox(width: 0.55, height: 0.08, length: 0.55, chamferRadius: 0.02))
            seat.geometry?.firstMaterial?.diffuse.contents = NSColor.darkGray
            seat.position = SCNVector3(0, 0.5, 0.85)
            root.addChildNode(seat)
            let back = SCNNode(geometry: SCNBox(width: 0.55, height: 0.5, length: 0.06, chamferRadius: 0.02))
            back.geometry?.firstMaterial?.diffuse.contents = NSColor.darkGray
            back.position = SCNVector3(0, 0.78, 1.1)
            root.addChildNode(back)

            // Agent 🧑‍💻 — body + head, facing the screen
            let agent = SCNNode()
            agent.name = "agent"
            let body = SCNNode(geometry: SCNCapsule(capRadius: 0.18, height: 0.62))
            body.name = "body"
            body.geometry?.firstMaterial?.diffuse.contents = NSColor.controlAccentColor
            body.position = SCNVector3(0, 0.84, 0)
            agent.addChildNode(body)
            let head = SCNNode(geometry: SCNSphere(radius: 0.16))
            head.name = "head"
            head.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.95, green: 0.85, blue: 0.72, alpha: 1)
            head.position = SCNVector3(0, 1.3, 0)
            agent.addChildNode(head)
            agent.position = SCNVector3(0, 0, 0.8)
            root.addChildNode(agent)

            // Name · role label (billboarded)
            let labelText = role.map { "\(session.name) · \($0)" } ?? session.name
            let text = SCNText(string: labelText, extrusionDepth: 0.2)
            text.font = NSFont.systemFont(ofSize: 2.6, weight: .semibold)
            text.firstMaterial?.diffuse.contents = NSColor.labelColor
            text.flatness = 0.3
            let label = SCNNode(geometry: text)
            label.scale = SCNVector3(0.09, 0.09, 0.09)
            let (minB, maxB) = label.boundingBox
            label.pivot = SCNMatrix4MakeTranslation((maxB.x - minB.x) / 2, 0, 0)
            label.position = SCNVector3(0, 2.15, 0)
            label.constraints = [SCNBillboardConstraint()]
            root.addChildNode(label)

            // Status badge (emoji billboard), hidden by default
            let badgePlane = SCNPlane(width: 0.55, height: 0.55)
            badgePlane.firstMaterial?.diffuse.contents = Self.emojiImage("🔔")
            badgePlane.firstMaterial?.isDoubleSided = true
            let badge = SCNNode(geometry: badgePlane)
            badge.name = "badge"
            badge.position = SCNVector3(0, 1.9, 0.8)
            badge.constraints = [SCNBillboardConstraint()]
            badge.isHidden = true
            root.addChildNode(badge)

            return root
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
            let body = agent?.childNode(withName: "body", recursively: false)

            agent?.removeAllActions()
            agent?.eulerAngles.x = 0

            switch state {
            case "working":
                screen?.geometry?.firstMaterial?.emission.contents = NSColor.controlAccentColor
                badge?.isHidden = true
                agent?.eulerAngles.x = -0.18 // lean toward the screen
                let bob = SCNAction.repeatForever(.sequence([
                    .moveBy(x: 0, y: 0.04, z: 0, duration: 0.35),
                    .moveBy(x: 0, y: -0.04, z: 0, duration: 0.35),
                ]))
                agent?.runAction(bob)
                body?.geometry?.firstMaterial?.diffuse.contents = NSColor.controlAccentColor
            case "permission":
                screen?.geometry?.firstMaterial?.emission.contents = NSColor.systemOrange.withAlphaComponent(0.7)
                badge?.isHidden = false
                badge?.geometry?.firstMaterial?.diffuse.contents = Self.emojiImage("🔔")
                let pulse = SCNAction.repeatForever(.sequence([
                    .scale(to: 1.25, duration: 0.4),
                    .scale(to: 1.0, duration: 0.4),
                ]))
                badge?.runAction(pulse, forKey: "pulse")
            case "done":
                screen?.geometry?.firstMaterial?.emission.contents = NSColor.systemGreen.withAlphaComponent(0.5)
                badge?.isHidden = false
                badge?.removeAction(forKey: "pulse")
                badge?.geometry?.firstMaterial?.diffuse.contents = Self.emojiImage("✅")
            case "exited":
                screen?.geometry?.firstMaterial?.emission.contents = NSColor.black
                badge?.isHidden = true
                body?.geometry?.firstMaterial?.diffuse.contents = NSColor.systemGray
            default: // idle
                screen?.geometry?.firstMaterial?.emission.contents = NSColor(white: 0.15, alpha: 1)
                badge?.isHidden = true
                body?.geometry?.firstMaterial?.diffuse.contents = NSColor.controlAccentColor
            }
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
            let orb = SCNNode(geometry: SCNSphere(radius: 0.09))
            orb.geometry?.firstMaterial?.diffuse.contents = NSColor.systemTeal
            orb.geometry?.firstMaterial?.emission.contents = NSColor.systemTeal
            orb.position = SCNVector3(from.x, from.y + 1.6, from.z)
            fxRoot.addChildNode(orb)

            let mid = SCNVector3((from.x + to.x) / 2, 2.8, (from.z + to.z) / 2)
            let rise = SCNAction.move(to: mid, duration: 0.45)
            rise.timingMode = .easeOut
            let fall = SCNAction.move(to: SCNVector3(to.x, to.y + 1.6, to.z), duration: 0.45)
            fall.timingMode = .easeIn
            orb.runAction(.sequence([rise, fall, .fadeOut(duration: 0.2), .removeFromParentNode()]))
        }

        // MARK: Helpers

        private func plant(at position: SCNVector3) -> SCNNode {
            let root = SCNNode()
            let pot = SCNNode(geometry: SCNCylinder(radius: 0.25, height: 0.3))
            pot.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.75, green: 0.45, blue: 0.35, alpha: 1)
            pot.position = SCNVector3(0, 0.15, 0)
            root.addChildNode(pot)
            let leaves = SCNNode(geometry: SCNCone(topRadius: 0.02, bottomRadius: 0.35, height: 0.9))
            leaves.geometry?.firstMaterial?.diffuse.contents = NSColor.systemGreen
            leaves.position = SCNVector3(0, 0.75, 0)
            root.addChildNode(leaves)
            root.position = position
            return root
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
    }
}
