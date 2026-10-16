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
// Modified in 2026 from the original Google release (google/JacquardSDKiOS @ 7db0fe2): event list, raw touch mode with a software tap/double tap detector, and gesture inputs for the game.

import Combine
import CoreBluetooth
import JacquardSDK
import SwiftUI


/// Gesture inputs the game and UI care about.
enum GameInput {
  case brushIn, brushOut, doubleTap, cover
}

/// One row in the event list.
struct TagEvent: Identifiable {
  enum Kind { case gesture, unknown, software }
  let id = UUID()
  let time = Date()
  let kind: Kind
  let title: String
  let detail: String?
}

/// Detects taps and double taps from raw 12-line touch data.
struct TapDetector {
  enum Result {
    case none
    case tap(duration: Double)
    case doubleTap(gap: Double)
  }

  var threshold: UInt8 = 20

  static let maxTapDuration = 0.30
  static let maxDoubleTapGap = 0.50
  static let maxCentroidDrift = 1.5
  static let sampleGapTimeout = 0.40

  private var touching = false
  private var startTime = Date.distantPast
  private var lastTouchedTime = Date.distantPast
  private var startCentroid = 0.0
  private var lastCentroid = 0.0
  private var lastTapEnd: Date?

  static func centroid(_ lines: [UInt8]) -> Double {
    let total = lines.reduce(0.0) { $0 + Double($1) }
    guard total > 0 else { return 0 }
    let weighted = lines.enumerated().reduce(0.0) { $0 + Double($1.offset) * Double($1.element) }
    return weighted / total
  }

  mutating func process(_ lines: [UInt8], now: Date = Date()) -> Result {
    var result = Result.none

    // If samples stopped arriving mid-touch, close that touch where it last registered.
    if touching && now.timeIntervalSince(lastTouchedTime) > Self.sampleGapTimeout {
      result = finish(at: lastTouchedTime)
    }

    let peak = lines.max() ?? 0
    if peak >= threshold {
      let centroid = Self.centroid(lines)
      if !touching {
        touching = true
        startTime = now
        startCentroid = centroid
      }
      lastCentroid = centroid
      lastTouchedTime = now
      return result
    }

    if touching {
      let finished = finish(at: now)
      if case .none = result { result = finished }
    }
    return result
  }

  private mutating func finish(at end: Date) -> Result {
    touching = false
    let duration = end.timeIntervalSince(startTime)
    let drift = abs(lastCentroid - startCentroid)
    guard duration <= Self.maxTapDuration, drift <= Self.maxCentroidDrift else {
      lastTapEnd = nil
      return .none
    }
    if let previous = lastTapEnd, startTime.timeIntervalSince(previous) <= Self.maxDoubleTapGap {
      lastTapEnd = nil
      return .doubleTap(gap: startTime.timeIntervalSince(previous))
    }
    lastTapEnd = end
    return .tap(duration: duration)
  }
}

/// Wraps a Jacquard `ConnectedTag` in a SwiftUI-friendly way.
class Tag: ObservableBase {
  private var underlyingTag: ConnectedTag
  private var updateTimer =
    Timer
    .publish(every: 1, on: .main, in: .common)
    .autoconnect()

  private(set) var name: String
  private(set) var connectedGear: Component?
  private(set) var rssi: Float = 0
  private(set) var batteryStatus: BatteryStatus?

  /// Newest event first.
  private(set) var events = [TagEvent]()
  private(set) var touchMode: TouchMode = .gesture
  private(set) var touchLines = [UInt8](repeating: 0, count: 12)
  private(set) var touchProximity: UInt32 = 0
  private(set) var touchThreshold: Double = 20
  private var detector = TapDetector()
  let gestureInputs = PassthroughSubject<GameInput, Never>()
  /// Every raw gesture event number the tag sends.
  let rawEvents = PassthroughSubject<Int, Never>()

  init(_ tag: ConnectedTag) {
    self.underlyingTag = tag
    self.name = tag.name

    super.init()

    bind(tag.namePublisher) { [weak self] in self?.name = $0 }
    bind(tag.connectedGear) { [weak self] in self?.connectedGear = $0 }
    bind(tag.rssiPublisher) { [weak self] in self?.rssi = $0 }

    // Ensure we get an initial battery status.
    bind(tag.enqueue(BatteryStatusCommand())) { [weak self] in self?.batteryStatus = $0 }

    // Request updates to rssi status every second.
    // In a real app you will usually want to do this more judiciously.
    updateTimer
      .sink { [weak self] _ in
        self?.underlyingTag.readRSSI()
      }.addTo(&observations)

    // Observe periodic battery and gesture notifications.
    underlyingTag.registerSubscriptions { [weak self] subscribableTag in
      guard let self = self else { return }

      bind(subscribableTag.subscribe(BatteryStatusNotificationSubscription())) { [weak self] in
        self?.batteryStatus = $0
      }

      bind(subscribableTag.subscribe(RawInferenceNotificationSubscription())) { [weak self] in
        self?.handleInference($0)
      }

      bind(subscribableTag.subscribe(ContinuousTouchNotificationSubscription())) { [weak self] in
        self?.handleTouch($0)
      }
    }
  }
  // MARK: - Events and touch

  private func addEvent(_ event: TagEvent) {
    events.insert(event, at: 0)
    if events.count > 300 { events.removeLast(events.count - 300) }
  }

  func clearEvents() {
    objectWillChange.send()
    events.removeAll()
  }

  /// Display name for a raw gesture event number. After "Teach gestures" in the game, the
  /// taught left, right and jump events use those names; otherwise the SDK's names apply, with
  /// events 1 and 8 shown as Double Tap (8 is what this tag sent for a double tap in testing).
  static func eventName(_ event: Int) -> String {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: "gesturesTaught") {
      if event == defaults.integer(forKey: "gestureLeft") { return "Brush Left" }
      if event == defaults.integer(forKey: "gestureRight") { return "Brush Right" }
      if event == defaults.integer(forKey: "gestureJump") { return "Double Tap" }
    }
    switch event {
    case 1, 8: return "Double Tap"
    case 2: return "Brush In"
    case 3: return "Brush Out"
    case 7: return "Cover"
    case 13: return "Brush Up"
    case 14: return "Brush Down"
    default: return "Event \(event)"
    }
  }

  private func handleInference(_ event: Int) {
    let name = Tag.eventName(event)
    addEvent(
      TagEvent(
        kind: name.hasPrefix("Event ") ? .unknown : .gesture, title: name,
        detail: "event \(event)"))
    rawEvents.send(event)
  }

  private func handleTouch(_ data: TouchData) {
    touchLines = data.linesArray
    touchProximity = data.proximity
    guard touchMode == .continuous else { return }
    switch detector.process(touchLines) {
    case .none:
      break
    case .tap(let duration):
      addEvent(
        TagEvent(
          kind: .software, title: "Tap (software)", detail: "\(Int(duration * 1000)) ms"))
    case .doubleTap(let gap):
      addEvent(
        TagEvent(
          kind: .software, title: "Double Tap (software)", detail: "gap \(Int(gap * 1000)) ms"))
      gestureInputs.send(.doubleTap)
    }
  }

  func setTouchThreshold(_ value: Double) {
    objectWillChange.send()
    touchThreshold = value
    detector.threshold = UInt8(max(1, min(127, value)))
  }

  func setTouchMode(_ mode: TouchMode) {
    guard let gear = connectedGear else {
      objectWillChange.send()
      addEvent(TagEvent(kind: .unknown, title: "No gear attached", detail: nil))
      return
    }
    underlyingTag.setTouchMode(mode, for: gear)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self = self else { return }
          if case .failure(let error) = completion {
            self.objectWillChange.send()
            self.addEvent(
              TagEvent(kind: .unknown, title: "Mode change failed", detail: "\(error)"))
          }
        },
        receiveValue: { [weak self] _ in
          guard let self = self else { return }
          self.objectWillChange.send()
          self.touchMode = mode
          var fresh = TapDetector()
          fresh.threshold = UInt8(max(1, min(127, self.touchThreshold)))
          self.detector = fresh
          self.addEvent(
            TagEvent(
              kind: .unknown, title: mode == .continuous ? "Raw touch mode on" : "Gesture mode on",
              detail: nil))
        }
      ).addTo(&observations)
  }
}
