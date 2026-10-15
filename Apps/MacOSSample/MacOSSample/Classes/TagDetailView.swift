// Copyright 2021 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Modified in 2026 from the original Google release (google/JacquardSDKiOS @ 7db0fe2): handles firmware-update connection states, adds the event list, raw touch view and the Jacket Dodger game.

import Combine
import JacquardSDK
import SwiftUI

struct TagDetailView: View {

  @EnvironmentObject
  private var appState: AppState

  private var tagID: UUID

  var connectionState: TagConnectionState? {
    appState.connectionStates.first { $0.id == tagID }?.state
  }

  init(_ tagID: UUID) {
    self.tagID = tagID
  }

  var body: some View {
    if let connectionState = connectionState {
      switch connectionState {
      case .preparingToConnect:
        Text("Preparing to connect…")
      case .connecting(let step, let ofSteps):
        Text("Connecting \(step) / \(ofSteps)…")
      case .initializing(let step, let ofSteps):
        Text("Intializing \(step) / \(ofSteps)…")
      case .configuring(let step, let ofSteps):
        Text("Configuring \(step) / \(ofSteps)…")
      case .firmwareUpdateInitiated:
        Text("Firmware update starting…")
      case .firmwareTransferring(let progress):
        Text("Firmware transfer \(Int(progress * 100))%")
      case .firmwareTransferCompleted:
        Text("Firmware transfer complete")
      case .firmwareExecuting:
        Text("Firmware installing…")
      case .connected(let connectedTag):
        ConnectedTagDetailView(Tag(connectedTag))
          .background(Color.white)
      case .disconnected(let error):
        if let error = error {
          Text("Disconnected: \(error.localizedDescription)")
        } else {
          Text("Disconnected")
        }
      }
    } else {
      Text("Connection not found")
    }
  }
}

struct IdentifiableGesture: Identifiable {
  var gesture: JacquardSDK.Gesture
  var id = UUID()
}

struct ConnectedTagDetailView: View {

  var gearImageName: String {
    tag.connectedGear?.product.image ?? "Gear_Not_Attached"
  }

  var gearName: String {
    tag.connectedGear?.product.name ?? "Gear not attached"
  }

  var batteryStatus: String {
    if let status = tag.batteryStatus {
      return "Battery: \(status.batteryLevel)%, \(status.chargingState.text)"
    } else {
      return "Battery: ---"
    }
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()

  @ObservedObject
  private var tag: Tag

  @State
  private var showingGame = false

  init(_ tag: Tag) {
    self.tag = tag
  }

  private func color(for kind: TagEvent.Kind) -> Color {
    switch kind {
    case .gesture: return .primary
    case .unknown: return .orange
    case .software: return .blue
    }
  }

  var body: some View {
    VStack(alignment: .leading) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 8) {
          Text(tag.name)
          Text("RSSI: \(tag.rssi)")
            .foregroundColor(.signalColor(tag.rssi))
          Text(gearName)
          Text(batteryStatus)
        }
        Spacer()
        Image(gearImageName, bundle: nil)
      }.padding()

      Button("Play Game") { showingGame = true }.padding(.horizontal)

      Toggle(
        "Raw touch mode (enables software tap and double tap)",
        isOn: Binding(
          get: { tag.touchMode == .continuous },
          set: { tag.setTouchMode($0 ? .continuous : .gesture) }
        )
      ).padding(.horizontal)

      if tag.touchMode == .continuous {
        VStack(alignment: .leading) {
          HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<12, id: \.self) { index in
              Rectangle()
                .fill(Double(tag.touchLines[index]) >= tag.touchThreshold ? Color.blue : Color.gray)
                .frame(width: 16, height: max(2, CGFloat(tag.touchLines[index]) / 128 * 60))
            }
          }.frame(height: 60, alignment: .bottom)
          HStack {
            Text("Touch threshold: \(Int(tag.touchThreshold))")
            Slider(
              value: Binding(get: { tag.touchThreshold }, set: { tag.setTouchThreshold($0) }),
              in: 1...100)
          }
          Text("Proximity: \(tag.touchProximity)").foregroundColor(.secondary)
        }.padding(.horizontal)
      }

      List {
        HStack {
          Text("Events (newest first)").bold()
          Spacer()
          Button("Clear") { tag.clearEvents() }
        }
        ForEach(tag.events) { event in
          HStack {
            Text(event.title).bold().foregroundColor(color(for: event.kind))
            if let detail = event.detail {
              Text(detail).foregroundColor(.secondary)
            }
            Spacer()
            Text(Self.timeFormatter.string(from: event.time))
              .font(.caption.monospacedDigit())
              .foregroundColor(.secondary)
          }
        }
      }
    }
    .sheet(isPresented: $showingGame) { GameView(tag: tag) }
  }
}

// MARK: - Game

/// A three-lane dodger driven by jacket gestures.
final class GameModel: ObservableObject {
  enum Phase { case ready, playing, over }
  enum Kind { case wall, hurdle, laser }
  struct Obstacle {
    var kind: Kind
    var lane: Int
    var y: Double
    var resolved = false
  }

  static let playerY = 0.82
  static let jumpDuration = 0.6
  static let shieldDuration = 0.9
  static let jumpRecharge = 0.25
  static let shieldRecharge = 1.1

  private(set) var phase = Phase.ready
  private(set) var score = 0
  private(set) var lives = 3
  private(set) var best = 0
  private(set) var lane = 1
  private(set) var jumpLeft = 0.0
  private(set) var shieldLeft = 0.0
  private(set) var jumpCooldown = 0.0
  private(set) var shieldCooldown = 0.0
  private(set) var obstacles = [Obstacle]()
  private(set) var flash = 0.0
  private(set) var lastInput = "-"
  private(set) var elapsed = 0.0

  private var spawnTimer = 1.0
  private var overAt = Date.distantPast
  private var lastTick = Date()
  private var timer: Timer?

  func handle(_ input: GameInput, swap: Bool) {
    switch input {
    case .brushIn:
      lastInput = "Brush In"
      move(swap ? 1 : -1)
    case .brushOut:
      lastInput = "Brush Out"
      move(swap ? -1 : 1)
    case .doubleTap:
      lastInput = "Double Tap"
      jump()
    case .cover:
      lastInput = "Cover"
      shield()
    }
  }

  /// Returns true if the input was used to start or restart the game.
  private func consumeForStart() -> Bool {
    switch phase {
    case .playing:
      return false
    case .ready:
      start()
      return true
    case .over:
      if Date().timeIntervalSince(overAt) > 0.8 { start() }
      return true
    }
  }

  func move(_ delta: Int) {
    if consumeForStart() { return }
    lane = min(2, max(0, lane + delta))
  }

  func jump() {
    if consumeForStart() { return }
    guard jumpLeft <= 0, jumpCooldown <= 0 else { return }
    jumpLeft = Self.jumpDuration
    jumpCooldown = Self.jumpDuration + Self.jumpRecharge
  }

  func shield() {
    if consumeForStart() { return }
    guard shieldLeft <= 0, shieldCooldown <= 0 else { return }
    shieldLeft = Self.shieldDuration
    shieldCooldown = Self.shieldDuration + Self.shieldRecharge
  }

  func start() {
    score = 0
    lives = 3
    lane = 1
    jumpLeft = 0
    shieldLeft = 0
    jumpCooldown = 0
    shieldCooldown = 0
    obstacles = []
    flash = 0
    elapsed = 0
    spawnTimer = 1.0
    lastTick = Date()
    phase = .playing
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    if phase == .playing { phase = .ready }
  }

  private func spawn() {
    let roll = Double.random(in: 0..<1)
    if roll < 0.45 {
      obstacles.append(Obstacle(kind: .wall, lane: Int.random(in: 0...2), y: -0.05))
    } else if roll < 0.80 {
      obstacles.append(Obstacle(kind: .hurdle, lane: Int.random(in: 0...2), y: -0.05))
    } else {
      obstacles.append(Obstacle(kind: .laser, lane: -1, y: -0.05))
    }
  }

  private func resolve(_ index: Int) {
    obstacles[index].resolved = true
    let obstacle = obstacles[index]
    let cleared: Bool
    switch obstacle.kind {
    case .wall: cleared = obstacle.lane != lane
    case .hurdle: cleared = obstacle.lane != lane || jumpLeft > 0
    case .laser: cleared = shieldLeft > 0
    }
    if cleared {
      score += obstacle.kind == .wall ? 10 : 15
    } else {
      lives -= 1
      flash = 1
      if lives <= 0 {
        phase = .over
        best = max(best, score)
        overAt = Date()
        timer?.invalidate()
        timer = nil
      }
    }
  }

  private func tick() {
    let now = Date()
    let dt = min(0.05, now.timeIntervalSince(lastTick))
    lastTick = now
    guard phase == .playing else { return }

    elapsed += dt
    jumpLeft = max(0, jumpLeft - dt)
    shieldLeft = max(0, shieldLeft - dt)
    jumpCooldown = max(0, jumpCooldown - dt)
    shieldCooldown = max(0, shieldCooldown - dt)
    flash = max(0, flash - dt * 3)

    let speed = min(0.9, 0.38 + elapsed * 0.008)
    spawnTimer -= dt
    if spawnTimer <= 0 {
      spawn()
      spawnTimer = max(0.75, 1.7 - elapsed * 0.012) + Double.random(in: 0...0.4)
    }
    for index in obstacles.indices {
      obstacles[index].y += speed * dt
      if !obstacles[index].resolved && obstacles[index].y >= Self.playerY {
        resolve(index)
        if phase != .playing { return }
      }
    }
    obstacles.removeAll { $0.y > 1.15 }
  }
}

struct GameView: View {
  @ObservedObject
  var tag: Tag

  @StateObject
  private var model = GameModel()

  @State
  private var swapDirections = false

  @Environment(\.presentationMode)
  private var presentationMode

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Text("Jacket Dodger").font(.title2).bold()
        Spacer()
        Toggle("Swap left/right", isOn: $swapDirections)
        Button("Close") { presentationMode.wrappedValue.dismiss() }
      }

      TimelineView(.animation) { _ in
        VStack(spacing: 8) {
          HStack {
            Text("Score \(model.score)").bold()
            Text("Best \(model.best)").foregroundColor(.secondary)
            Spacer()
            Text(String(repeating: "♥", count: max(0, model.lives))).foregroundColor(.red)
            Spacer()
            Text("Last: \(model.lastInput)").foregroundColor(.secondary)
          }
          Canvas { context, size in
            draw(&context, size: size)
          }
          .frame(minWidth: 380, minHeight: 480)
          .background(Color.black)
          .cornerRadius(8)
        }
      }

      Text("Brush In = left   Brush Out = right   Double Tap = jump   Cover = shield")
        .font(.caption)
      Text("Keyboard: arrows, Space = jump, S = shield, Return = start")
        .font(.caption).foregroundColor(.secondary)
    }
    .padding()
    .frame(minWidth: 460, minHeight: 680)
    .onReceive(tag.gestureInputs) { input in
      model.handle(input, swap: swapDirections)
    }
    .onDisappear { model.stop() }
    .background(shortcuts)
  }

  private var shortcuts: some View {
    Group {
      Button("") { model.move(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
      Button("") { model.move(1) }.keyboardShortcut(.rightArrow, modifiers: [])
      Button("") { model.jump() }.keyboardShortcut(.space, modifiers: [])
      Button("") { model.shield() }.keyboardShortcut("s", modifiers: [])
      Button("") { model.move(0) }.keyboardShortcut(.return, modifiers: [])
    }
    .opacity(0)
    .frame(width: 0, height: 0)
  }

  private func draw(_ context: inout GraphicsContext, size: CGSize) {
    let trackW = min(size.width, 360.0)
    let x0 = (size.width - trackW) / 2
    let laneW = trackW / 3
    func laneCenter(_ lane: Int) -> CGFloat { x0 + laneW * (CGFloat(lane) + 0.5) }

    context.fill(
      Path(CGRect(x: x0, y: 0, width: trackW, height: size.height)),
      with: .color(Color(white: 0.12)))
    for index in 1..<3 {
      var line = Path()
      line.move(to: CGPoint(x: x0 + laneW * CGFloat(index), y: 0))
      line.addLine(to: CGPoint(x: x0 + laneW * CGFloat(index), y: size.height))
      context.stroke(
        line, with: .color(Color.gray.opacity(0.4)),
        style: StrokeStyle(lineWidth: 1, dash: [8, 8]))
    }

    let playerY = CGFloat(GameModel.playerY) * size.height
    for obstacle in model.obstacles {
      let oy = CGFloat(obstacle.y) * size.height
      switch obstacle.kind {
      case .wall:
        let rect = CGRect(
          x: laneCenter(obstacle.lane) - laneW * 0.4, y: oy - 22, width: laneW * 0.8, height: 44)
        context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(.red))
        context.draw(
          Text("DODGE").font(.caption2).foregroundColor(.white),
          at: CGPoint(x: rect.midX, y: rect.midY))
      case .hurdle:
        let rect = CGRect(
          x: laneCenter(obstacle.lane) - laneW * 0.45, y: oy - 10, width: laneW * 0.9, height: 20)
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.yellow))
        context.draw(
          Text("JUMP").font(.caption2).foregroundColor(.black),
          at: CGPoint(x: rect.midX, y: rect.midY))
      case .laser:
        let rect = CGRect(x: x0, y: oy - 8, width: trackW, height: 16)
        context.fill(Path(rect), with: .color(.cyan))
        context.draw(
          Text("COVER").font(.caption2).foregroundColor(.black),
          at: CGPoint(x: rect.midX, y: rect.midY))
      }
    }

    let progress = model.jumpLeft > 0 ? 1 - model.jumpLeft / GameModel.jumpDuration : 0
    let lift = CGFloat(sin(progress * Double.pi)) * 0.09 * size.height
    let cx = laneCenter(model.lane)
    context.fill(
      Path(ellipseIn: CGRect(x: cx - 18, y: playerY + 12, width: 36, height: 10)),
      with: .color(Color.black.opacity(0.5)))
    context.fill(
      Path(ellipseIn: CGRect(x: cx - 16, y: playerY - 16 - lift, width: 32, height: 32)),
      with: .color(.green))
    if model.shieldLeft > 0 {
      context.stroke(
        Path(ellipseIn: CGRect(x: cx - 28, y: playerY - 28 - lift, width: 56, height: 56)),
        with: .color(.cyan), lineWidth: 4)
    }

    if model.flash > 0 {
      context.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .color(Color.red.opacity(model.flash * 0.35)))
    }

    let center = CGPoint(x: size.width / 2, y: size.height * 0.4)
    switch model.phase {
    case .ready:
      context.draw(
        Text("Any gesture or Return to start").font(.title3).foregroundColor(.white), at: center)
    case .over:
      context.draw(
        Text("Game over: \(model.score)\nAny gesture to retry").font(.title3)
          .foregroundColor(.white),
        at: center)
    case .playing:
      break
    }
  }
}

extension BatteryStatus.ChargingState {
  var text: String {
    switch self {
    case .charging: return "Charging"
    case .notCharging: return "Not Charging"
    }
  }
}

extension Color {
  static let goodSignalRSSI = Color(red: 0.117, green: 0.557, blue: 0.243)
  static let fairSignalRSSI = Color(red: 0.95, green: 0.6, blue: 0.0)
  static let weakSignalRSSI = Color(red: 0.850, green: 0.188, blue: 0.145)

  /// Provides signal color depending upon the range value.
  static func signalColor(_ signalValue: Float) -> Color {
    if signalValue >= -65.0 {
      return .goodSignalRSSI
    } else if signalValue <= -66.0 && signalValue >= -80.0 {
      return .fairSignalRSSI
    } else {
      return .weakSignalRSSI
    }
  }
}
