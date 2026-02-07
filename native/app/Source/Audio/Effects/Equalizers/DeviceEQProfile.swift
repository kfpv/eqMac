//
//  DeviceEQProfile.swift
//  eqMac
//
//  Stores per-device EQ profile so each output device can have its own EQ settings.
//

import Foundation
import SwiftyUserDefaults
import EmitterKit

struct DeviceEQProfile: Codable, DefaultsSerializable {
  var equalizerType: String  // "Basic", "Advanced", "Parametric"
  var basicPresetId: String
  var advancedPresetId: String
  var parametricPresetId: String

  static var `default`: DeviceEQProfile {
    return DeviceEQProfile(
      equalizerType: EqualizerType.basic.rawValue,
      basicPresetId: "flat",
      advancedPresetId: "flat",
      parametricPresetId: "flat"
    )
  }

  /// A profile is considered "configured" if it differs from the default (basic + flat everywhere)
  var hasConfig: Bool {
    let d = DeviceEQProfile.default
    return equalizerType != d.equalizerType
      || basicPresetId != d.basicPresetId
      || advancedPresetId != d.advancedPresetId
      || parametricPresetId != d.parametricPresetId
  }
}

class DeviceEQProfiles {
  private static let storageKey = "deviceEQProfiles"

  /// Emitted whenever a profile is saved or removed, so the UI can refresh device list
  static let profilesChanged = EmitterKit.Event<Void>()

  /// All stored profiles keyed by device UID
  static var all: [String: DeviceEQProfile] {
    get {
      guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
      return (try? JSONDecoder().decode([String: DeviceEQProfile].self, from: data)) ?? [:]
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: storageKey)
      }
    }
  }

  /// Get profile for a device UID, returns default if none stored
  static func get(for deviceUID: String) -> DeviceEQProfile {
    return all[deviceUID] ?? .default
  }

  /// Save a profile for a device UID. If it matches default, remove it instead.
  static func save(_ profile: DeviceEQProfile, for deviceUID: String) {
    var profiles = all
    if profile.hasConfig {
      profiles[deviceUID] = profile
    } else {
      profiles.removeValue(forKey: deviceUID)
    }
    all = profiles
    profilesChanged.emit()
    Console.log("Saved EQ profile for device \(deviceUID): type=\(profile.equalizerType), basic=\(profile.basicPresetId), advanced=\(profile.advancedPresetId), parametric=\(profile.parametricPresetId), hasConfig=\(profile.hasConfig)")
  }

  /// Remove profile for a device UID (resets to default)
  static func remove(for deviceUID: String) {
    var profiles = all
    profiles.removeValue(forKey: deviceUID)
    all = profiles
  }

  /// Returns the set of device UIDs that have a non-default profile
  static var configuredDeviceUIDs: Set<String> {
    return Set(all.filter { $0.value.hasConfig }.keys)
  }

  /// Build a profile snapshot from the current application state
  static func currentProfile() -> DeviceEQProfile {
    let state = Application.store.state.effects.equalizers
    return DeviceEQProfile(
      equalizerType: state.type.rawValue,
      basicPresetId: state.basic.selectedPresetId,
      advancedPresetId: state.advanced.selectedPresetId,
      parametricPresetId: state.parametric.selectedPresetId
    )
  }

  /// Save the current EQ state for the given device UID
  static func saveCurrentProfile(for deviceUID: String) {
    save(currentProfile(), for: deviceUID)
  }

  /// Apply a stored profile: dispatches actions to switch EQ type and presets
  static func applyProfile(for deviceUID: String) {
    let profile = get(for: deviceUID)
    Console.log("Applying EQ profile for device \(deviceUID): type=\(profile.equalizerType), hasConfig=\(profile.hasConfig)")

    // Determine the equalizer type
    let eqType: EqualizerType
    switch profile.equalizerType {
    case EqualizerType.advanced.rawValue:
      eqType = .advanced
    case EqualizerType.parametric.rawValue:
      eqType = .parametric
    default:
      eqType = .basic
    }

    // Dispatch preset selections first (so when type change triggers engine rebuild, presets are ready)
    Application.dispatchAction(BasicEqualizerAction.selectPreset(profile.basicPresetId, false))
    Application.dispatchAction(AdvancedEqualizerAction.selectPreset(profile.advancedPresetId, false))
    Application.dispatchAction(ParametricEqualizerAction.selectPreset(profile.parametricPresetId, false))

    // Then switch equalizer type if needed (this may trigger an engine rebuild)
    let currentType = Application.store.state.effects.equalizers.type
    if currentType != eqType {
      Application.dispatchAction(EqualizersAction.setType(eqType))
    }
  }
}
